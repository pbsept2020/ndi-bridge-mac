//
//  NDISender.swift
//  NDI Bridge Mac
//
//  Broadcasts video frames as NDI source on local network
//

import Foundation
import CoreVideo
import QuartzCore
import CNDIWrapper

/// Callback for sender events
protocol NDISenderDelegate: AnyObject {
    func ndiSender(_ sender: NDISender, didStartWithName name: String)
    func ndiSender(_ sender: NDISender, didFailWithError error: Error?)
}

/// Error types for NDI sender
enum NDISenderError: Error, LocalizedError {
    case initializationFailed
    case senderCreationFailed
    case invalidPixelBuffer
    case notStarted

    var errorDescription: String? {
        switch self {
        case .initializationFailed: return "Failed to initialize NDI SDK"
        case .senderCreationFailed: return "Failed to create NDI sender"
        case .invalidPixelBuffer: return "Invalid pixel buffer"
        case .notStarted: return "NDI sender not started"
        }
    }
}

/// Broadcasts decoded video as NDI source
final class NDISender {
    weak var delegate: NDISenderDelegate?

    private var sender: UnsafeMutableRawPointer?
    private var isRunning = false
    private var sourceName: String

    // Video frame - allocated once and reused
    private var videoFrame: UnsafeMutablePointer<NDIBridgeVideoFrame>?

    // Audio frame - allocated once and reused
    private var audioFrame: UnsafeMutablePointer<NDIBridgeAudioFrame>?

    // Video format (updated dynamically from actual frames)
    private var width: Int32 = 1920
    private var height: Int32 = 1080
    private var frameRateN: Int32 = 30000
    private var frameRateD: Int32 = 1001

    // Audio statistics
    private var audioFramesSent: UInt64 = 0

    // Frame rate detection
    private var lastFrameTimestamp: UInt64 = 0
    private var frameIntervals: [Double] = []
    private var detectedFrameRate: Double = 0

    // Statistics
    private var framesSent: UInt64 = 0
    private var lastStatsTime: CFTimeInterval = 0

    init(name: String = "NDI Bridge Output") {
        self.sourceName = name
        logger.info("NDISender initializing with name: \(name)", subsystem: .ndi)
    }

    deinit {
        stop()
        logger.info("NDISender deinitialized", subsystem: .ndi)
    }

    /// Start the NDI sender
    func start(width: Int32 = 1920, height: Int32 = 1080, frameRate: Double = 59.94) throws {
        guard !isRunning else {
            logger.warning("NDI sender already running", subsystem: .ndi)
            return
        }

        logger.info("Starting NDI sender: \(sourceName)", subsystem: .ndi)
        logger.info("Output format: \(width)x\(height) @ \(String(format: "%.2f", frameRate)) fps", subsystem: .ndi)

        self.width = width
        self.height = height

        // Convert frame rate to fraction
        if frameRate > 59 && frameRate < 60 {
            frameRateN = 60000
            frameRateD = 1001
        } else if frameRate > 29 && frameRate < 30 {
            frameRateN = 30000
            frameRateD = 1001
        } else {
            frameRateN = Int32(frameRate * 1000)
            frameRateD = 1000
        }

        // Initialize NDI if not already
        guard ndi_initialize() else {
            logger.error("Failed to initialize NDI SDK", subsystem: .ndi)
            throw NDISenderError.initializationFailed
        }

        // Allocate video frame structure
        videoFrame = ndi_video_frame_create()
        guard videoFrame != nil else {
            logger.error("Failed to allocate video frame", subsystem: .ndi)
            throw NDISenderError.senderCreationFailed
        }

        // Allocate audio frame structure
        audioFrame = ndi_audio_frame_create()
        guard audioFrame != nil else {
            logger.error("Failed to allocate audio frame", subsystem: .ndi)
            ndi_video_frame_destroy(videoFrame)
            videoFrame = nil
            throw NDISenderError.senderCreationFailed
        }

        // Create sender
        sender = sourceName.withCString { namePtr in
            ndi_sender_create(namePtr)
        }

        guard sender != nil else {
            logger.error("Failed to create NDI sender", subsystem: .ndi)
            ndi_video_frame_destroy(videoFrame)
            ndi_audio_frame_destroy(audioFrame)
            videoFrame = nil
            audioFrame = nil
            throw NDISenderError.senderCreationFailed
        }

        isRunning = true
        framesSent = 0

        logger.success("NDI sender started: '\(sourceName)' broadcasting on local network", subsystem: .ndi)
        delegate?.ndiSender(self, didStartWithName: sourceName)
    }

    /// Send a video frame
    func send(pixelBuffer: CVPixelBuffer, timestamp: UInt64) throws {
        guard isRunning, let senderPtr = sender, let frame = videoFrame else {
            throw NDISenderError.notStarted
        }

        // Lock the pixel buffer
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        // Get pixel buffer info
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw NDISenderError.invalidPixelBuffer
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let actualWidth = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let actualHeight = Int32(CVPixelBufferGetHeight(pixelBuffer))

        // Detect frame rate from timestamps (first 10 frames)
        if lastFrameTimestamp > 0 && frameIntervals.count < 10 {
            // Timestamp is in 100ns intervals (10MHz)
            let intervalNs = Double(timestamp - lastFrameTimestamp) * 100.0
            let intervalMs = intervalNs / 1_000_000.0
            if intervalMs > 0 && intervalMs < 200 {  // Sanity check (5-200fps range)
                frameIntervals.append(intervalMs)

                if frameIntervals.count == 10 {
                    // Calculate average frame rate
                    let avgInterval = frameIntervals.reduce(0, +) / Double(frameIntervals.count)
                    detectedFrameRate = 1000.0 / avgInterval

                    // Set frame rate fraction
                    if detectedFrameRate > 59 && detectedFrameRate < 61 {
                        frameRateN = 60000; frameRateD = 1001
                    } else if detectedFrameRate > 49 && detectedFrameRate < 51 {
                        frameRateN = 50000; frameRateD = 1000
                    } else if detectedFrameRate > 29 && detectedFrameRate < 31 {
                        frameRateN = 30000; frameRateD = 1001
                    } else if detectedFrameRate > 24 && detectedFrameRate < 26 {
                        frameRateN = 24000; frameRateD = 1001
                    } else {
                        frameRateN = Int32(detectedFrameRate * 1000)
                        frameRateD = 1000
                    }

                    logger.info("Detected frame rate: \(String(format: "%.2f", detectedFrameRate)) fps → \(frameRateN)/\(frameRateD)", subsystem: .ndi)
                    logger.info("Output resolution: \(actualWidth)x\(actualHeight)", subsystem: .ndi)
                }
            }
        }
        lastFrameTimestamp = timestamp

        // Initialize the video frame using the helper function
        // NDI FourCC uses little-endian: 'B' | ('G'<<8) | ('R'<<16) | ('A'<<24) = 0x41524742
        ndi_video_frame_init(
            frame,
            actualWidth,
            actualHeight,
            0x41524742,  // NDIlib_FourCC_video_type_BGRA
            frameRateN,
            frameRateD,
            baseAddress.assumingMemoryBound(to: UInt8.self),
            Int32(bytesPerRow)
        )

        // Set timestamp
        frame.pointee.timestamp = Int64(bitPattern: timestamp)

        // Send frame
        ndi_sender_send_video(senderPtr, frame)

        framesSent += 1

        // Log periodically
        let now = CACurrentMediaTime()
        if now - lastStatsTime >= 1.0 {
            logger.debug("NDI frames sent: \(framesSent)", subsystem: .ndi)
            lastStatsTime = now
        }
    }

    /// Send an audio frame
    func sendAudio(data: Data, timestamp: UInt64, sampleRate: Int32, channels: Int32) throws {
        guard isRunning, let senderPtr = sender, let frame = audioFrame else {
            throw NDISenderError.notStarted
        }

        // NDI audio expects 32-bit float planar format
        // Each channel's samples are stored contiguously
        let bytesPerSample: Int32 = 4  // 32-bit float
        let noSamples = Int32(data.count) / (channels * bytesPerSample)

        // We need to keep the data alive during send
        data.withUnsafeBytes { rawBuffer in
            guard let dataPtr = rawBuffer.baseAddress else { return }

            // Initialize audio frame
            ndi_audio_frame_init(
                frame,
                sampleRate,
                channels,
                noSamples,
                UnsafeMutablePointer(mutating: dataPtr.assumingMemoryBound(to: UInt8.self)),
                noSamples * bytesPerSample  // channel_stride for planar format
            )

            // Set timestamp
            frame.pointee.timestamp = Int64(bitPattern: timestamp)

            // Send audio frame
            ndi_sender_send_audio(senderPtr, frame)
        }

        audioFramesSent += 1
    }

    /// Stop the NDI sender
    func stop() {
        guard isRunning else { return }

        logger.info("Stopping NDI sender...", subsystem: .ndi)

        if let senderPtr = sender {
            ndi_sender_destroy(senderPtr)
            sender = nil
        }

        if let frame = videoFrame {
            ndi_video_frame_destroy(frame)
            videoFrame = nil
        }

        if let frame = audioFrame {
            ndi_audio_frame_destroy(frame)
            audioFrame = nil
        }

        isRunning = false

        // Reset frame rate detection for next start
        lastFrameTimestamp = 0
        frameIntervals.removeAll()
        detectedFrameRate = 0
        frameRateN = 30000
        frameRateD = 1001

        logger.success("NDI sender stopped. Video frames: \(framesSent), Audio frames: \(audioFramesSent)", subsystem: .ndi)
    }

    /// Update source name (requires restart)
    func setSourceName(_ name: String) {
        let wasRunning = isRunning
        if wasRunning {
            stop()
        }

        sourceName = name

        if wasRunning {
            do {
                try start(width: width, height: height)
            } catch {
                logger.error("Failed to restart with new name: \(error.localizedDescription)", subsystem: .ndi)
            }
        }
    }
}
