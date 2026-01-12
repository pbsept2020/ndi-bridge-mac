//
//  VideoDecoder.swift
//  NDI Bridge Mac
//
//  Hardware H.264 decoding using VideoToolbox
//

import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import QuartzCore

/// Callback for decoded frames
protocol VideoDecoderDelegate: AnyObject {
    func videoDecoder(_ decoder: VideoDecoder, didDecodeFrame pixelBuffer: CVPixelBuffer, timestamp: UInt64)
    func videoDecoder(_ decoder: VideoDecoder, didFailWithError error: Error)
}

/// Error types for decoding
enum VideoDecoderError: Error, LocalizedError {
    case sessionCreationFailed(OSStatus)
    case decodingFailed(OSStatus)
    case invalidData
    case noParameterSets
    case formatDescriptionFailed

    var errorDescription: String? {
        switch self {
        case .sessionCreationFailed(let status):
            return "Failed to create decompression session: \(status)"
        case .decodingFailed(let status):
            return "Decoding failed: \(status)"
        case .invalidData:
            return "Invalid video data"
        case .noParameterSets:
            return "No SPS/PPS found in stream"
        case .formatDescriptionFailed:
            return "Failed to create format description"
        }
    }
}

/// Hardware H.264 decoder using VideoToolbox
final class VideoDecoder {
    weak var delegate: VideoDecoderDelegate?

    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var isConfigured = false

    // Parameter sets (SPS/PPS)
    private var sps: Data?
    private var pps: Data?

    // Statistics
    private var framesDecoded: UInt64 = 0
    private var lastStatsTime: CFTimeInterval = 0

    init() {
        logger.info("VideoDecoder initializing...", subsystem: .video)
    }

    deinit {
        invalidate()
        logger.info("VideoDecoder deinitialized", subsystem: .video)
    }

    /// Decode H.264 Annex-B data
    func decode(data: Data, timestamp: UInt64) throws {
        // Parse NAL units from Annex-B format
        let nalUnits = parseNALUnits(from: data)

        for nal in nalUnits {
            let nalType = nal[0] & 0x1F

            switch nalType {
            case 7:  // SPS
                sps = nal
                logger.debug("Received SPS (\(nal.count) bytes)", subsystem: .video)
                try updateFormatDescription()

            case 8:  // PPS
                pps = nal
                logger.debug("Received PPS (\(nal.count) bytes)", subsystem: .video)
                try updateFormatDescription()

            case 5:  // IDR (keyframe)
                try decodeNALUnit(nal, timestamp: timestamp)

            case 1:  // Non-IDR (P-frame)
                try decodeNALUnit(nal, timestamp: timestamp)

            default:
                logger.debug("Skipping NAL type \(nalType)", subsystem: .video)
            }
        }
    }

    /// Parse Annex-B NAL units (separated by 0x00 0x00 0x00 0x01 or 0x00 0x00 0x01)
    private func parseNALUnits(from data: Data) -> [Data] {
        var nalUnits: [Data] = []
        var startIndex = 0
        let bytes = [UInt8](data)

        var i = 0
        while i < bytes.count - 3 {
            // Check for start code (0x00 0x00 0x01 or 0x00 0x00 0x00 0x01)
            if bytes[i] == 0x00 && bytes[i + 1] == 0x00 {
                var startCodeLength = 0

                if bytes[i + 2] == 0x01 {
                    startCodeLength = 3
                } else if i < bytes.count - 3 && bytes[i + 2] == 0x00 && bytes[i + 3] == 0x01 {
                    startCodeLength = 4
                }

                if startCodeLength > 0 {
                    // Save previous NAL unit (if any)
                    if startIndex > 0 || i > 0 {
                        if startIndex < i {
                            let nalData = data.subdata(in: startIndex..<i)
                            if !nalData.isEmpty {
                                nalUnits.append(nalData)
                            }
                        }
                    }

                    // Move past start code
                    i += startCodeLength
                    startIndex = i
                    continue
                }
            }
            i += 1
        }

        // Add last NAL unit
        if startIndex < data.count {
            let nalData = data.subdata(in: startIndex..<data.count)
            if !nalData.isEmpty {
                nalUnits.append(nalData)
            }
        }

        return nalUnits
    }

    /// Update format description when SPS/PPS are received
    private func updateFormatDescription() throws {
        guard let sps = sps, let pps = pps else {
            return  // Wait for both
        }

        logger.info("Creating format description from SPS/PPS...", subsystem: .video)

        // Create format description from parameter sets
        let parameterSets: [Data] = [sps, pps]
        let parameterSetPointers: [UnsafePointer<UInt8>] = parameterSets.map {
            $0.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: UInt8.self) }
        }
        let parameterSetSizes: [Int] = parameterSets.map { $0.count }

        var newFormatDescription: CMVideoFormatDescription?

        // Need to keep data alive during call
        let status = sps.withUnsafeBytes { spsPtr in
            pps.withUnsafeBytes { ppsPtr in
                let pointers: [UnsafePointer<UInt8>] = [
                    spsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ppsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                ]
                let sizes: [Int] = [sps.count, pps.count]

                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &newFormatDescription
                )
            }
        }

        guard status == noErr, let formatDesc = newFormatDescription else {
            logger.error("Failed to create format description: \(status)", subsystem: .video)
            throw VideoDecoderError.formatDescriptionFailed
        }

        // Check if format changed
        if let existingFormat = formatDescription {
            if !CMFormatDescriptionEqual(existingFormat, otherFormatDescription: formatDesc) {
                logger.info("Format description changed, recreating session", subsystem: .video)
                invalidate()
            }
        }

        formatDescription = formatDesc

        // Create decompression session if needed
        if decompressionSession == nil {
            try createDecompressionSession()
        }
    }

    /// Create VideoToolbox decompression session
    private func createDecompressionSession() throws {
        guard let formatDesc = formatDescription else {
            throw VideoDecoderError.noParameterSets
        }

        logger.info("Creating decompression session...", subsystem: .video)

        // Output pixel buffer attributes
        let outputAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        // Callback info
        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: decompressionOutputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: nil,
            imageBufferAttributes: outputAttributes as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &session
        )

        guard status == noErr, let newSession = session else {
            logger.error("Failed to create decompression session: \(status)", subsystem: .video)
            throw VideoDecoderError.sessionCreationFailed(status)
        }

        decompressionSession = newSession
        isConfigured = true

        logger.success("Decompression session created", subsystem: .video)
    }

    /// Decode a single NAL unit
    private func decodeNALUnit(_ nalUnit: Data, timestamp: UInt64) throws {
        guard isConfigured, let session = decompressionSession else {
            logger.debug("Decoder not ready, skipping frame", subsystem: .video)
            return
        }

        // Convert to AVCC format (prepend 4-byte length)
        var avccData = Data(capacity: nalUnit.count + 4)
        var length = UInt32(nalUnit.count).bigEndian
        withUnsafeBytes(of: &length) { avccData.append(contentsOf: $0) }
        avccData.append(nalUnit)

        // Create CMBlockBuffer
        var blockBuffer: CMBlockBuffer?
        var status = avccData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> OSStatus in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: UnsafeMutableRawPointer(mutating: bytes.baseAddress),
                blockLength: avccData.count,
                blockAllocator: kCFAllocatorNull,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: avccData.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }

        guard status == kCMBlockBufferNoErr, let buffer = blockBuffer else {
            throw VideoDecoderError.decodingFailed(status)
        }

        // Create CMSampleBuffer
        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(value: CMTimeValue(timestamp), timescale: 10_000_000),
            decodeTimeStamp: .invalid
        )

        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: buffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let sample = sampleBuffer else {
            throw VideoDecoderError.decodingFailed(status)
        }

        // Decode
        var flagsOut: VTDecodeInfoFlags = []
        status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [._EnableAsynchronousDecompression],
            frameRefcon: UnsafeMutableRawPointer(bitPattern: UInt(timestamp)),
            infoFlagsOut: &flagsOut
        )

        if status != noErr {
            logger.error("Decode failed: \(status)", subsystem: .video)
            throw VideoDecoderError.decodingFailed(status)
        }
    }

    /// Handle decoded frame callback
    fileprivate func handleDecodedFrame(status: OSStatus, imageBuffer: CVImageBuffer?, timestamp: UInt64) {
        guard status == noErr else {
            logger.error("Decode callback error: \(status)", subsystem: .video)
            delegate?.videoDecoder(self, didFailWithError: VideoDecoderError.decodingFailed(status))
            return
        }

        guard let pixelBuffer = imageBuffer else {
            logger.warning("No image buffer in decode callback", subsystem: .video)
            return
        }

        framesDecoded += 1

        // Log periodically
        let now = CACurrentMediaTime()
        if now - lastStatsTime >= 1.0 {
            logger.debug("Decoded \(framesDecoded) frames total", subsystem: .video)
            lastStatsTime = now
        }

        // Notify delegate
        delegate?.videoDecoder(self, didDecodeFrame: pixelBuffer, timestamp: timestamp)
    }

    /// Clean up decoder
    func invalidate() {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        formatDescription = nil
        isConfigured = false
        sps = nil
        pps = nil
        logger.debug("Decoder invalidated", subsystem: .video)
    }
}

/// VTDecompressionSession callback
private func decompressionOutputCallback(
    decompressionOutputRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTDecodeInfoFlags,
    imageBuffer: CVImageBuffer?,
    presentationTimeStamp: CMTime,
    presentationDuration: CMTime
) {
    guard let refCon = decompressionOutputRefCon else { return }

    let decoder = Unmanaged<VideoDecoder>.fromOpaque(refCon).takeUnretainedValue()

    // Extract timestamp from refcon
    let timestamp = UInt64(UInt(bitPattern: sourceFrameRefCon))

    decoder.handleDecodedFrame(status: status, imageBuffer: imageBuffer, timestamp: timestamp)
}
