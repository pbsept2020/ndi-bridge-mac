//
//  JoinMode.swift
//  NDI Bridge Mac
//
//  Orchestrates network reception → H.264 decoding → NDI output
//

import Foundation
import CoreVideo

/// Join mode configuration
struct JoinModeConfig {
    var listenPort: UInt16 = 5990
    var ndiOutputName: String = "NDI Bridge Output"
    var outputWidth: Int32 = 1920
    var outputHeight: Int32 = 1080
}

/// Error types for join mode
enum JoinModeError: Error, LocalizedError {
    case networkFailed
    case decoderFailed
    case ndiOutputFailed
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .networkFailed: return "Network listener failed"
        case .decoderFailed: return "Video decoder failed"
        case .ndiOutputFailed: return "NDI output failed"
        case .alreadyRunning: return "Join mode is already running"
        }
    }
}

/// Main join mode controller
/// Receives network → Decodes H.264 → Outputs NDI
final class JoinMode: NetworkReceiverDelegate, VideoDecoderDelegate, NDISenderDelegate {

    private let networkReceiver: NetworkReceiver
    private let decoder = VideoDecoder()
    private let ndiSender: NDISender

    private var config: JoinModeConfig
    private var isRunning = false

    // Statistics
    private var startTime: Date?
    private var framesOutput: UInt64 = 0

    init(config: JoinModeConfig = JoinModeConfig()) {
        self.config = config
        self.networkReceiver = NetworkReceiver(port: config.listenPort)
        self.ndiSender = NDISender(name: config.ndiOutputName)

        logger.info("JoinMode initialized", subsystem: .join)
    }

    deinit {
        stop()
        logger.info("JoinMode deinitialized", subsystem: .join)
    }

    /// Start join mode - listens for incoming stream and outputs as NDI
    func start() throws {
        guard !isRunning else {
            throw JoinModeError.alreadyRunning
        }

        logger.info("═══════════════════════════════════════════════════════", subsystem: .join)
        logger.info("Starting JOIN MODE (Receiver)", subsystem: .join)
        logger.info("Listen port: \(config.listenPort)", subsystem: .join)
        logger.info("NDI output: '\(config.ndiOutputName)'", subsystem: .join)
        logger.info("═══════════════════════════════════════════════════════", subsystem: .join)

        // Step 1: Setup decoder
        logger.info("Step 1/3: Initializing H.264 decoder...", subsystem: .join)
        decoder.delegate = self
        logger.success("Decoder ready (waiting for SPS/PPS)", subsystem: .join)

        // Step 2: Start NDI sender
        logger.info("Step 2/3: Starting NDI output...", subsystem: .join)
        ndiSender.delegate = self
        do {
            try ndiSender.start(
                width: config.outputWidth,
                height: config.outputHeight
            )
        } catch {
            logger.error("Failed to start NDI output: \(error.localizedDescription)", subsystem: .join)
            throw JoinModeError.ndiOutputFailed
        }

        // Step 3: Start network receiver
        logger.info("Step 3/3: Starting network listener...", subsystem: .join)
        networkReceiver.delegate = self
        do {
            try networkReceiver.startListening(port: config.listenPort)
        } catch {
            logger.error("Failed to start network listener: \(error.localizedDescription)", subsystem: .join)
            ndiSender.stop()
            throw JoinModeError.networkFailed
        }

        isRunning = true
        startTime = Date()

        logger.success("═══════════════════════════════════════════════════════", subsystem: .join)
        logger.success("JOIN MODE STARTED", subsystem: .join)
        logger.success("Waiting for incoming stream on port \(config.listenPort)...", subsystem: .join)
        logger.success("NDI output available as '\(config.ndiOutputName)'", subsystem: .join)
        logger.success("═══════════════════════════════════════════════════════", subsystem: .join)
    }

    /// Stop join mode
    func stop() {
        guard isRunning else { return }

        logger.info("Stopping Join Mode...", subsystem: .join)

        isRunning = false
        networkReceiver.stop()
        decoder.invalidate()
        ndiSender.stop()

        if let start = startTime {
            let duration = Date().timeIntervalSince(start)
            logger.success("Join mode stopped. Duration: \(String(format: "%.1f", duration))s, Frames output: \(framesOutput)", subsystem: .join)
        }
    }

    /// Update NDI output name
    func setOutputName(_ name: String) {
        config.ndiOutputName = name
        ndiSender.setSourceName(name)
    }

    // MARK: - NetworkReceiverDelegate

    func networkReceiver(_ receiver: NetworkReceiver, didReceiveVideoFrame data: Data, isKeyframe: Bool, timestamp: UInt64) {
        // Decode the received video frame
        do {
            try decoder.decode(data: data, timestamp: timestamp)
        } catch {
            logger.error("Decode error: \(error.localizedDescription)", subsystem: .join)
        }
    }

    func networkReceiver(_ receiver: NetworkReceiver, didReceiveAudioFrame data: Data, timestamp: UInt64, sampleRate: Int32, channels: Int32) {
        // Send audio directly to NDI output (no decoding needed for PCM)
        do {
            try ndiSender.sendAudio(data: data, timestamp: timestamp, sampleRate: sampleRate, channels: channels)
        } catch {
            logger.error("NDI audio send error: \(error.localizedDescription)", subsystem: .join)
        }
    }

    func networkReceiver(_ receiver: NetworkReceiver, didDisconnect error: Error?) {
        if let error = error {
            logger.error("Network disconnected: \(error.localizedDescription)", subsystem: .join)
        } else {
            logger.warning("Network connection closed", subsystem: .join)
        }
    }

    // MARK: - VideoDecoderDelegate

    func videoDecoder(_ decoder: VideoDecoder, didDecodeFrame pixelBuffer: CVPixelBuffer, timestamp: UInt64) {
        framesOutput += 1

        // Send decoded frame to NDI output
        do {
            try ndiSender.send(pixelBuffer: pixelBuffer, timestamp: timestamp)
        } catch {
            logger.error("NDI send error: \(error.localizedDescription)", subsystem: .join)
        }
    }

    func videoDecoder(_ decoder: VideoDecoder, didFailWithError error: Error) {
        logger.error("Decoder error: \(error.localizedDescription)", subsystem: .join)
    }

    // MARK: - NDISenderDelegate

    func ndiSender(_ sender: NDISender, didStartWithName name: String) {
        logger.success("NDI output broadcasting as '\(name)'", subsystem: .join)
    }

    func ndiSender(_ sender: NDISender, didFailWithError error: Error?) {
        if let error = error {
            logger.error("NDI sender error: \(error.localizedDescription)", subsystem: .join)
        }
    }
}
