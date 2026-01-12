//
//  VideoEncoder.swift
//  NDI Bridge Mac
//
//  Hardware H.264 encoding using VideoToolbox
//

import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import QuartzCore

/// Callback for receiving encoded data
protocol VideoEncoderDelegate: AnyObject {
    func videoEncoder(_ encoder: VideoEncoder, didEncodeData data: Data, isKeyframe: Bool, timestamp: UInt64, duration: UInt64)
    func videoEncoder(_ encoder: VideoEncoder, didFailWithError error: Error)
}

/// Encoder configuration
struct VideoEncoderConfig {
    var width: Int32 = 0           // 0 = auto-detect from first frame
    var height: Int32 = 0          // 0 = auto-detect from first frame
    var frameRate: Float64 = 0     // 0 = auto-detect from timestamps
    var bitrate: Int = 8_000_000   // 8 Mbps default
    var keyframeInterval: Int = 60 // 1 keyframe per second at 60fps
    var enableLowLatency: Bool = true
    var profile: CFString = kVTProfileLevel_H264_High_AutoLevel

    static let auto = VideoEncoderConfig()  // Auto-detect everything

    static let hd1080p60 = VideoEncoderConfig(
        width: 1920,
        height: 1080,
        frameRate: 60.0,
        bitrate: 8_000_000
    )

    static let hd720p30 = VideoEncoderConfig(
        width: 1280,
        height: 720,
        frameRate: 30.0,
        bitrate: 4_000_000
    )
}

/// Error types for encoding
enum VideoEncoderError: Error, LocalizedError {
    case sessionCreationFailed(OSStatus)
    case encodingFailed(OSStatus)
    case invalidPixelBuffer
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .sessionCreationFailed(let status):
            return "Failed to create compression session: \(status)"
        case .encodingFailed(let status):
            return "Encoding failed: \(status)"
        case .invalidPixelBuffer:
            return "Invalid pixel buffer provided"
        case .notConfigured:
            return "Encoder not configured"
        }
    }
}

/// Hardware H.264 encoder using VideoToolbox
final class VideoEncoder {
    weak var delegate: VideoEncoderDelegate?

    private var compressionSession: VTCompressionSession?
    private var config: VideoEncoderConfig?
    private var isConfigured = false
    private var frameNumber: UInt64 = 0
    private var needsAutoConfig = false  // Waiting for first frame to detect resolution

    // Statistics
    private var totalBytesEncoded: UInt64 = 0
    private var lastStatsTime: CFTimeInterval = 0
    private var framesInInterval: Int = 0
    private var bytesInInterval: Int = 0

    init() {
        logger.info("VideoEncoder initializing...", subsystem: .video)
    }

    deinit {
        invalidate()
        logger.info("VideoEncoder deinitialized", subsystem: .video)
    }

    /// Configure the encoder with specified settings
    func configure(config: VideoEncoderConfig = .auto) throws {
        self.config = config

        // Clean up existing session
        invalidate()

        // If width/height are 0, wait for first frame to auto-detect
        if config.width == 0 || config.height == 0 {
            logger.info("Encoder configured for auto-detection (waiting for first frame)", subsystem: .video)
            needsAutoConfig = true
            isConfigured = true  // Mark as configured so encode() will be called
            return
        }

        try createCompressionSession(width: config.width, height: config.height)
    }

    /// Create the actual compression session with specific dimensions
    private func createCompressionSession(width: Int32, height: Int32) throws {
        guard var config = self.config else { return }

        logger.info("Creating encoder: \(width)x\(height) @ \(config.bitrate / 1_000_000) Mbps", subsystem: .video)

        // Update config with actual dimensions
        config.width = width
        config.height = height
        self.config = config

        // Create compression session
        let encoderSpec: [String: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
        ]

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: compressionOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )

        guard status == noErr, let compressionSession = session else {
            logger.error("Failed to create compression session: \(status)", subsystem: .video)
            throw VideoEncoderError.sessionCreationFailed(status)
        }

        self.compressionSession = compressionSession

        // Configure session properties
        try configureSessionProperties(config: config)

        // Prepare to encode
        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(compressionSession)
        guard prepareStatus == noErr else {
            logger.error("Failed to prepare encoder: \(prepareStatus)", subsystem: .video)
            throw VideoEncoderError.sessionCreationFailed(prepareStatus)
        }

        isConfigured = true
        logger.success("Encoder configured successfully", subsystem: .video)
    }

    private func configureSessionProperties(config: VideoEncoderConfig) throws {
        guard let session = compressionSession else { return }

        // Real-time encoding for low latency
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        // Profile and level
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: config.profile)

        // Bitrate (average)
        let bitrateNum = config.bitrate as CFNumber
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrateNum)

        // Data rate limits (peak bitrate = 1.5x average for bursts)
        let peakBitrate = config.bitrate * 3 / 2
        let limits: [Int] = [peakBitrate, 1]  // bytes per second, duration in seconds
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)

        // Frame rate
        let frameRateNum = config.frameRate as CFNumber
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: frameRateNum)

        // Keyframe interval
        let keyframeNum = config.keyframeInterval as CFNumber
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyframeNum)

        // Allow frame reordering (B-frames) - disable for lowest latency
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        // Low latency mode (macOS 11+)
        if config.enableLowLatency {
            if #available(macOS 11.0, *) {
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
            }
        }

        logger.debug("Encoder properties configured", subsystem: .video)
    }

    /// Encode a video frame
    func encode(pixelBuffer: CVPixelBuffer, timestamp: UInt64, duration: UInt64 = 0) throws {
        guard isConfigured else {
            throw VideoEncoderError.notConfigured
        }

        // Auto-configure from first frame if needed
        if needsAutoConfig {
            let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
            let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
            logger.info("Auto-detected resolution: \(width)x\(height)", subsystem: .video)
            try createCompressionSession(width: width, height: height)
            needsAutoConfig = false
        }

        guard let session = compressionSession else {
            throw VideoEncoderError.notConfigured
        }

        frameNumber += 1

        // Create presentation timestamp
        let pts = CMTime(value: CMTimeValue(timestamp), timescale: 10_000_000)
        let frameDuration = CMTime(value: CMTimeValue(duration > 0 ? duration : 166667), timescale: 10_000_000) // ~60fps default

        // Frame properties - request keyframe periodically
        var frameProperties: CFDictionary?
        if frameNumber == 1 || frameNumber % UInt64(config?.keyframeInterval ?? 60) == 0 {
            let props: [String: Any] = [
                kVTEncodeFrameOptionKey_ForceKeyFrame as String: true
            ]
            frameProperties = props as CFDictionary
        }

        // Encode frame
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: frameDuration,
            frameProperties: frameProperties,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )

        if status != noErr {
            logger.error("Encoding failed for frame \(frameNumber): \(status)", subsystem: .video)
            throw VideoEncoderError.encodingFailed(status)
        }
    }

    /// Force a keyframe on the next frame
    func forceKeyframe() {
        // Next frame will be encoded as keyframe
        frameNumber = 0
        logger.debug("Keyframe forced", subsystem: .video)
    }

    /// Flush pending frames
    func flush() {
        guard let session = compressionSession else { return }

        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        logger.debug("Encoder flushed", subsystem: .video)
    }

    /// Clean up encoder
    func invalidate() {
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
        isConfigured = false
        logger.debug("Encoder invalidated", subsystem: .video)
    }

    /// Called when a frame is encoded
    fileprivate func handleEncodedFrame(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        guard status == noErr else {
            logger.error("Encoding callback error: \(status)", subsystem: .video)
            delegate?.videoEncoder(self, didFailWithError: VideoEncoderError.encodingFailed(status))
            return
        }

        guard let buffer = sampleBuffer else {
            logger.warning("No sample buffer in callback", subsystem: .video)
            return
        }

        // Check if keyframe
        var isKeyframe = false
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first {
            isKeyframe = first[kCMSampleAttachmentKey_NotSync] as? Bool != true
        }

        // Get timing info
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        let duration = CMSampleBufferGetDuration(buffer)
        let timestamp = UInt64(CMTimeGetSeconds(pts) * 10_000_000)
        let durationValue = UInt64(CMTimeGetSeconds(duration) * 10_000_000)

        // Extract NAL units
        guard let data = extractNALUnits(from: buffer) else {
            logger.warning("Failed to extract NAL units", subsystem: .video)
            return
        }

        // Update statistics
        totalBytesEncoded += UInt64(data.count)
        bytesInInterval += data.count
        framesInInterval += 1

        let now = CACurrentMediaTime()
        if now - lastStatsTime >= 1.0 {
            let bitrate = Double(bytesInInterval * 8)  // bits per second
            logger.logEncoding(bitrate: bitrate, qp: 0, keyframe: isKeyframe, subsystem: .video)
            bytesInInterval = 0
            framesInInterval = 0
            lastStatsTime = now
        }

        // Notify delegate
        delegate?.videoEncoder(self, didEncodeData: data, isKeyframe: isKeyframe, timestamp: timestamp, duration: durationValue)
    }

    /// Extract NAL units from CMSampleBuffer with Annex-B start codes
    private func extractNALUnits(from sampleBuffer: CMSampleBuffer) -> Data? {
        // Get format description for SPS/PPS on keyframes
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }

        var result = Data()

        // For keyframes, prepend SPS and PPS
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first,
           first[kCMSampleAttachmentKey_NotSync] as? Bool != true {
            // This is a keyframe - add SPS and PPS
            if let parameterSets = extractParameterSets(from: formatDescription) {
                result.append(parameterSets)
            }
        }

        // Get data buffer
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        guard status == kCMBlockBufferNoErr, let ptr = dataPointer else {
            return nil
        }

        // Convert AVCC to Annex-B format
        let data = Data(bytes: ptr, count: totalLength)
        var offset = 0

        while offset < totalLength {
            // Read NAL unit length (4 bytes, big-endian)
            guard offset + 4 <= totalLength else { break }

            var nalLength: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &nalLength) { dest in
                data.copyBytes(to: dest, from: offset..<(offset + 4))
            }
            nalLength = nalLength.bigEndian
            offset += 4

            guard offset + Int(nalLength) <= totalLength else { break }

            // Add Annex-B start code
            let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
            result.append(contentsOf: startCode)

            // Add NAL unit data
            result.append(data.subdata(in: offset..<(offset + Int(nalLength))))
            offset += Int(nalLength)
        }

        return result
    }

    /// Extract SPS and PPS from format description
    private func extractParameterSets(from formatDescription: CMFormatDescription) -> Data? {
        var result = Data()
        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

        // Get SPS count and data
        var spsCount = 0
        var status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &spsCount,
            nalUnitHeaderLengthOut: nil
        )

        if status == noErr {
            for i in 0..<spsCount {
                var spsPtr: UnsafePointer<UInt8>?
                var spsSize = 0

                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDescription,
                    parameterSetIndex: i,
                    parameterSetPointerOut: &spsPtr,
                    parameterSetSizeOut: &spsSize,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil
                )

                if status == noErr, let ptr = spsPtr {
                    result.append(contentsOf: startCode)
                    result.append(ptr, count: spsSize)
                }
            }
        }

        // Get PPS (index starts after SPS)
        var ppsPtr: UnsafePointer<UInt8>?
        var ppsSize = 0

        status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: spsCount,
            parameterSetPointerOut: &ppsPtr,
            parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )

        if status == noErr, let ptr = ppsPtr {
            result.append(contentsOf: startCode)
            result.append(ptr, count: ppsSize)
        }

        return result.isEmpty ? nil : result
    }
}

/// VTCompressionSession callback
private func compressionOutputCallback(
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    guard let refCon = outputCallbackRefCon else { return }

    let encoder = Unmanaged<VideoEncoder>.fromOpaque(refCon).takeUnretainedValue()
    encoder.handleEncodedFrame(status: status, sampleBuffer: sampleBuffer)
}
