//
//  NDIReceiver.swift
//  NDI Bridge Mac
//
//  Discovers and captures video from NDI sources on local network
//

import Foundation
import CoreVideo
import QuartzCore
import CNDIWrapper

/// Represents an NDI source discovered on the network
struct NDISource {
    let name: String
    let index: Int
    let sourcesPointer: UnsafeMutableRawPointer

    init(name: String, index: Int, sourcesPointer: UnsafeMutableRawPointer) {
        self.name = name
        self.index = index
        self.sourcesPointer = sourcesPointer
    }

    /// Get the NDI source pointer for connection
    var pointer: UnsafeMutableRawPointer {
        // NDIlib_source_t is 16 bytes (two pointers)
        return sourcesPointer.advanced(by: index * MemoryLayout<NDIBridgeSource>.stride)
    }
}

/// Callback for receiving video and audio frames
protocol NDIReceiverDelegate: AnyObject {
    func ndiReceiver(_ receiver: NDIReceiver, didReceiveVideoFrame pixelBuffer: CVPixelBuffer, timestamp: UInt64, frameNumber: UInt64)
    func ndiReceiver(_ receiver: NDIReceiver, didReceiveAudioFrame data: Data, timestamp: UInt64, sampleRate: Int32, channels: Int32, samplesPerChannel: Int32)
    func ndiReceiver(_ receiver: NDIReceiver, didDisconnect error: Error?)
}

/// Extension with default implementation for backward compatibility
extension NDIReceiverDelegate {
    func ndiReceiver(_ receiver: NDIReceiver, didReceiveAudioFrame data: Data, timestamp: UInt64, sampleRate: Int32, channels: Int32, samplesPerChannel: Int32) {
        // Default: ignore audio if not implemented
    }
}

/// Error types for NDI operations
enum NDIError: Error, LocalizedError {
    case initializationFailed
    case finderCreationFailed
    case receiverCreationFailed
    case noSourcesFound
    case connectionFailed
    case captureTimeout
    case invalidFrameData

    var errorDescription: String? {
        switch self {
        case .initializationFailed: return "Failed to initialize NDI SDK"
        case .finderCreationFailed: return "Failed to create NDI finder"
        case .receiverCreationFailed: return "Failed to create NDI receiver"
        case .noSourcesFound: return "No NDI sources found on network"
        case .connectionFailed: return "Failed to connect to NDI source"
        case .captureTimeout: return "Frame capture timed out"
        case .invalidFrameData: return "Invalid video frame data"
        }
    }
}

/// Captures video frames from NDI sources
final class NDIReceiver {
    weak var delegate: NDIReceiverDelegate?

    private var finder: UnsafeMutableRawPointer?
    private var receiver: UnsafeMutableRawPointer?
    private var isRunning = false
    private var captureQueue: DispatchQueue?
    private var frameCount: UInt64 = 0
    private var connectedSource: NDISource?

    // Video frame - allocated once and reused
    private var videoFrame: UnsafeMutablePointer<NDIBridgeVideoFrame>?

    // Audio frame - allocated once and reused
    private var audioFrame: UnsafeMutablePointer<NDIBridgeAudioFrame>?

    // Frame statistics
    private var lastFrameTime: CFTimeInterval = 0
    private var currentFPS: Double = 0
    private var audioFrameCount: UInt64 = 0

    init() {
        logger.info("NDIReceiver initializing...", subsystem: .ndi)
    }

    deinit {
        stop()
        cleanup()
        logger.info("NDIReceiver deinitialized", subsystem: .ndi)
    }

    /// Initialize NDI SDK - must be called before any other operations
    func initialize() throws {
        logger.info("Initializing NDI SDK...", subsystem: .ndi)

        guard ndi_initialize() else {
            logger.error("NDI SDK initialization failed", subsystem: .ndi)
            throw NDIError.initializationFailed
        }

        // Allocate video frame structure
        videoFrame = ndi_video_frame_create()

        // Allocate audio frame structure
        audioFrame = ndi_audio_frame_create()

        logger.success("NDI SDK initialized successfully", subsystem: .ndi)
    }

    /// Discover NDI sources on the network
    func discoverSources(timeout: TimeInterval = 5.0) throws -> [NDISource] {
        logger.info("Starting NDI source discovery (timeout: \(timeout)s)...", subsystem: .ndi)

        // Create finder if not exists
        if finder == nil {
            finder = ndi_find_create()
            guard finder != nil else {
                logger.error("Failed to create NDI finder", subsystem: .ndi)
                throw NDIError.finderCreationFailed
            }
            logger.debug("NDI finder created", subsystem: .ndi)
        }

        // Wait for sources to be discovered
        let startTime = Date()
        var sources: [NDISource] = []

        while Date().timeIntervalSince(startTime) < timeout {
            var sourcesPtr: UnsafeMutableRawPointer?
            let count = ndi_find_get_sources(finder, &sourcesPtr, 1000)

            if count > 0, let ptr = sourcesPtr {
                logger.debug("Found \(count) NDI source(s)", subsystem: .ndi)

                // Parse sources using the helper function
                for i in 0..<Int(count) {
                    if let namePtr = ndi_source_get_name(ptr, Int32(i)) {
                        let name = String(cString: namePtr)
                        let source = NDISource(name: name, index: i, sourcesPointer: ptr)
                        sources.append(source)
                        logger.info("  [\(i + 1)] \(name)", subsystem: .ndi)
                    }
                }

                break
            }

            Thread.sleep(forTimeInterval: 0.1)
        }

        if sources.isEmpty {
            logger.warning("No NDI sources found after \(timeout)s timeout", subsystem: .ndi)
        } else {
            logger.success("Discovered \(sources.count) NDI source(s)", subsystem: .ndi)
        }

        return sources
    }

    /// Connect to a specific NDI source
    func connect(to source: NDISource) throws {
        logger.info("Connecting to NDI source: \(source.name)", subsystem: .ndi)

        // Create receiver
        receiver = ndi_receiver_create()
        guard receiver != nil else {
            logger.error("Failed to create NDI receiver", subsystem: .ndi)
            throw NDIError.receiverCreationFailed
        }

        // Connect to source
        let connected = ndi_receiver_connect(receiver, source.pointer)
        guard connected else {
            logger.error("Failed to connect to source: \(source.name)", subsystem: .ndi)
            throw NDIError.connectionFailed
        }

        connectedSource = source
        logger.success("Connected to NDI source: \(source.name)", subsystem: .ndi)
    }

    /// Start capturing frames
    func startCapture() {
        guard !isRunning else {
            logger.warning("Capture already running", subsystem: .ndi)
            return
        }

        guard receiver != nil else {
            logger.error("Cannot start capture - no receiver connected", subsystem: .ndi)
            return
        }

        isRunning = true
        frameCount = 0

        captureQueue = DispatchQueue(label: "com.ndibridge.ndi.capture", qos: .userInteractive)
        captureQueue?.async { [weak self] in
            self?.captureLoop()
        }

        logger.info("NDI capture started", subsystem: .ndi)
    }

    /// Stop capturing frames
    func stop() {
        guard isRunning else { return }

        isRunning = false
        logger.info("Stopping NDI capture...", subsystem: .ndi)

        // Wait for capture loop to finish
        Thread.sleep(forTimeInterval: 0.1)

        logger.success("NDI capture stopped. Total frames: \(frameCount)", subsystem: .ndi)
    }

    /// Main capture loop running on dedicated thread
    private func captureLoop() {
        logger.debug("Capture loop started", subsystem: .ndi)

        guard let vFrame = videoFrame, let aFrame = audioFrame else {
            logger.error("Video/Audio frame not allocated", subsystem: .ndi)
            return
        }

        while isRunning {
            // Capture frame with 100ms timeout - pass both video and audio frames
            let result = ndi_receiver_capture(receiver, vFrame, aFrame, 100)

            switch result {
            case 1: // NDIlib_frame_type_video
                processVideoFrame(vFrame)

            case 2: // NDIlib_frame_type_audio
                processAudioFrame(aFrame)

            case 3: // NDIlib_frame_type_metadata
                // Ignore metadata for now
                break

            case 0: // NDIlib_frame_type_none (timeout)
                // No frame available, continue
                break

            case 4: // NDIlib_frame_type_error
                logger.error("NDI capture error", subsystem: .ndi)
                isRunning = false
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.ndiReceiver(self, didDisconnect: NDIError.captureTimeout)
                }

            default:
                break
            }
        }

        logger.debug("Capture loop ended", subsystem: .ndi)
    }

    /// Context for CVPixelBuffer release callback
    private class FrameReleaseContext {
        let receiver: UnsafeMutableRawPointer?
        let frame: UnsafeMutablePointer<NDIBridgeVideoFrame>
        
        init(receiver: UnsafeMutableRawPointer?, frame: UnsafeMutablePointer<NDIBridgeVideoFrame>) {
            self.receiver = receiver
            self.frame = frame
        }
    }
    
    /// Process a captured video frame using the proper NDI structure
    private func processVideoFrame(_ frame: UnsafeMutablePointer<NDIBridgeVideoFrame>) {
        let videoFrame = frame.pointee

        let width = videoFrame.xres
        let height = videoFrame.yres
        let lineStride = videoFrame.line_stride_in_bytes
        let dataPtr = videoFrame.p_data
        let timecode = videoFrame.timecode

        guard let data = dataPtr else {
            logger.warning("Frame has no data pointer", subsystem: .ndi)
            ndi_receiver_free_video(receiver, frame)
            return
        }

        frameCount += 1

        // Calculate FPS
        let now = CACurrentMediaTime()
        if lastFrameTime > 0 {
            let delta = now - lastFrameTime
            currentFPS = 1.0 / delta
        }
        lastFrameTime = now

        // Log every 60 frames (approximately once per second at 60fps)
        if frameCount % 60 == 0 {
            logger.logFrame(frameNumber: frameCount, width: Int(width), height: Int(height), fps: currentFPS, subsystem: .ndi)
        }

        // Create release context to free NDI frame when CVPixelBuffer is released
        let releaseContext = FrameReleaseContext(receiver: receiver, frame: frame)
        let contextPtr = Unmanaged.passRetained(releaseContext).toOpaque()
        
        // Release callback - called when CVPixelBuffer is deallocated
        let releaseCallback: CVPixelBufferReleaseBytesCallback = { releaseRefCon, baseAddress in
            guard let refCon = releaseRefCon else { return }
            let context = Unmanaged<FrameReleaseContext>.fromOpaque(refCon).takeRetainedValue()
            // Now safe to free the NDI frame
            ndi_receiver_free_video(context.receiver, context.frame)
        }

        // Create CVPixelBuffer from NDI frame data
        // NDI uses BGRA format by default (as configured in receiver_create)
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        let status = CVPixelBufferCreateWithBytes(
            kCFAllocatorDefault,
            Int(width),
            Int(height),
            kCVPixelFormatType_32BGRA,
            data,
            Int(lineStride),
            releaseCallback,
            contextPtr,
            attributes as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            logger.error("Failed to create CVPixelBuffer: \(status)", subsystem: .ndi)
            // Release context and free frame on error
            Unmanaged<FrameReleaseContext>.fromOpaque(contextPtr).release()
            ndi_receiver_free_video(receiver, frame)
            return
        }

        // Notify delegate - NDI frame will be freed when pixelBuffer is released
        delegate?.ndiReceiver(self, didReceiveVideoFrame: buffer, timestamp: UInt64(bitPattern: timecode), frameNumber: frameCount)
    }

    /// Process a captured audio frame
    private func processAudioFrame(_ frame: UnsafeMutablePointer<NDIBridgeAudioFrame>) {
        let audioData = frame.pointee

        let sampleRate = audioData.sample_rate
        let channels = audioData.no_channels
        let samplesPerChannel = audioData.no_samples
        let dataPtr = audioData.p_data
        let channelStride = audioData.channel_stride_in_bytes
        let timecode = audioData.timecode

        guard let data = dataPtr else {
            logger.warning("Audio frame has no data pointer", subsystem: .ndi)
            ndi_receiver_free_audio(receiver, frame)
            return
        }

        audioFrameCount += 1

        // Calculate total data size
        // For planar format: channels * samplesPerChannel * 4 (32-bit float)
        let totalSize: Int
        if channelStride > 0 {
            totalSize = Int(channels) * Int(channelStride)
        } else {
            // Interleaved format
            totalSize = Int(channels) * Int(samplesPerChannel) * 4
        }

        // Copy audio data before freeing NDI frame
        let audioBuffer = Data(bytes: data, count: totalSize)

        // Free the NDI audio frame
        ndi_receiver_free_audio(receiver, frame)

        // Log every 100 audio frames (approximately once per second at 48kHz with 512-sample buffers)
        if audioFrameCount % 100 == 0 {
            logger.debug("Audio: \(sampleRate)Hz, \(channels)ch, \(samplesPerChannel) samples, frame \(audioFrameCount)", subsystem: .ndi)
        }

        // Notify delegate
        delegate?.ndiReceiver(
            self,
            didReceiveAudioFrame: audioBuffer,
            timestamp: UInt64(bitPattern: timecode),
            sampleRate: sampleRate,
            channels: channels,
            samplesPerChannel: samplesPerChannel
        )
    }

    private func cleanup() {
        if let frame = videoFrame {
            ndi_video_frame_destroy(frame)
            videoFrame = nil
        }

        if let frame = audioFrame {
            ndi_audio_frame_destroy(frame)
            audioFrame = nil
        }

        if let recv = receiver {
            ndi_receiver_destroy(recv)
            receiver = nil
        }

        if let find = finder {
            ndi_find_destroy(find)
            finder = nil
        }

        ndi_destroy()
        logger.debug("NDI resources cleaned up", subsystem: .ndi)
    }
}
