//
//  HostMode.swift
//  NDI Bridge Mac
//
//  Orchestrates NDI capture → H.264 encoding → network transmission
//

import Foundation
import CoreVideo
import Network

/// Host mode configuration
struct HostModeConfig {
    var targetHost: String = "127.0.0.1"
    var targetPort: UInt16 = 5990
    var encoder: VideoEncoderConfig = .auto  // Auto-detect from source
    var autoSelectFirstSource: Bool = false
    var sourceDiscoveryTimeout: TimeInterval = 5.0
    var sourceName: String? = nil                      // Specific source name to use
    var excludePatterns: [String] = ["Bridge"]         // Patterns to exclude from auto-selection
}

/// Error types for host mode
enum HostModeError: Error, LocalizedError {
    case noSourceSelected
    case encoderConfigFailed
    case networkFailed
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .noSourceSelected: return "No NDI source selected"
        case .encoderConfigFailed: return "Failed to configure encoder"
        case .networkFailed: return "Network connection failed"
        case .alreadyRunning: return "Host mode is already running"
        }
    }
}

/// Main host mode controller
/// Captures NDI → Encodes H.264 → Sends over network
final class HostMode: NDIReceiverDelegate, VideoEncoderDelegate, NetworkSenderDelegate {

    private let ndiReceiver = NDIReceiver()
    private let encoder = VideoEncoder()
    private let networkSender: NetworkSender

    private var config: HostModeConfig
    private var isRunning = false
    private var selectedSource: NDISource?

    // Statistics
    private var startTime: Date?
    private var framesProcessed: UInt64 = 0

    init(config: HostModeConfig = HostModeConfig()) {
        self.config = config
        self.networkSender = NetworkSender(config: NetworkSenderConfig(
            host: config.targetHost,
            port: config.targetPort
        ))

        logger.info("HostMode initialized", subsystem: .host)
    }

    deinit {
        stop()
        logger.info("HostMode deinitialized", subsystem: .host)
    }

    /// Start host mode - discovers sources and starts streaming
    func start() throws {
        guard !isRunning else {
            throw HostModeError.alreadyRunning
        }

        logger.info("═══════════════════════════════════════════════════════", subsystem: .host)
        logger.info("Starting HOST MODE (Sender)", subsystem: .host)
        logger.info("Target: \(config.targetHost):\(config.targetPort)", subsystem: .host)
        logger.info("═══════════════════════════════════════════════════════", subsystem: .host)

        // Step 1: Initialize NDI
        logger.info("Step 1/5: Initializing NDI SDK...", subsystem: .host)
        try ndiReceiver.initialize()
        ndiReceiver.delegate = self

        // Step 2: Discover sources
        logger.info("Step 2/5: Discovering NDI sources...", subsystem: .host)
        let allSources = try ndiReceiver.discoverSources(timeout: config.sourceDiscoveryTimeout)

        if allSources.isEmpty {
            throw NDIError.noSourcesFound
        }

        // Step 3: Select source
        logger.info("Step 3/5: Selecting NDI source...", subsystem: .host)

        // Filter out excluded patterns (like "Bridge" to avoid feedback loops)
        let filteredSources = allSources.filter { source in
            !config.excludePatterns.contains { pattern in
                source.name.localizedCaseInsensitiveContains(pattern)
            }
        }

        if filteredSources.isEmpty && !allSources.isEmpty {
            logger.warning("All sources filtered out by exclude patterns: \(config.excludePatterns)", subsystem: .host)
            logger.info("Available sources before filtering:", subsystem: .host)
            for src in allSources {
                logger.info("  - \(src.name)", subsystem: .host)
            }
            throw NDIError.noSourcesFound
        }

        // Source selection logic
        if let specificName = config.sourceName {
            // User specified a source name - find it
            selectedSource = allSources.first { $0.name.localizedCaseInsensitiveContains(specificName) }
            if selectedSource == nil {
                logger.error("Source '\(specificName)' not found", subsystem: .host)
                logger.info("Available sources:", subsystem: .host)
                for src in allSources {
                    logger.info("  - \(src.name)", subsystem: .host)
                }
                throw NDIError.noSourcesFound
            }
            logger.info("Using specified source: \(selectedSource?.name ?? "unknown")", subsystem: .host)
        } else if config.autoSelectFirstSource {
            // Auto mode - select first filtered source
            selectedSource = filteredSources.first
            logger.info("Auto-selected: \(selectedSource?.name ?? "unknown")", subsystem: .host)
        } else {
            // Interactive mode - prompt user to choose
            selectedSource = promptForSource(from: filteredSources)
            if selectedSource == nil {
                throw HostModeError.noSourceSelected
            }
            logger.info("User selected: \(selectedSource?.name ?? "unknown")", subsystem: .host)
        }

        guard let source = selectedSource else {
            throw HostModeError.noSourceSelected
        }

        // Connect to source
        try ndiReceiver.connect(to: source)

        // Step 4: Configure encoder
        logger.info("Step 4/5: Configuring H.264 encoder...", subsystem: .host)
        encoder.delegate = self
        do {
            try encoder.configure(config: config.encoder)
        } catch {
            logger.error("Encoder configuration failed: \(error.localizedDescription)", subsystem: .host)
            throw HostModeError.encoderConfigFailed
        }

        // Step 5: Connect network
        logger.info("Step 5/5: Connecting to network...", subsystem: .host)
        networkSender.delegate = self
        networkSender.connect(host: config.targetHost, port: config.targetPort)

        // Start capture
        isRunning = true
        startTime = Date()
        ndiReceiver.startCapture()

        logger.success("═══════════════════════════════════════════════════════", subsystem: .host)
        logger.success("HOST MODE STARTED", subsystem: .host)
        logger.success("Streaming: \(source.name) → \(config.targetHost):\(config.targetPort)", subsystem: .host)
        logger.success("═══════════════════════════════════════════════════════", subsystem: .host)
    }

    /// Stop host mode
    func stop() {
        guard isRunning else { return }

        logger.info("Stopping Host Mode...", subsystem: .host)

        isRunning = false
        ndiReceiver.stop()
        encoder.flush()
        encoder.invalidate()
        networkSender.disconnect()

        if let start = startTime {
            let duration = Date().timeIntervalSince(start)
            logger.success("Host mode stopped. Duration: \(String(format: "%.1f", duration))s, Frames: \(framesProcessed)", subsystem: .host)
        }
    }

    // MARK: - Private Helpers

    /// Prompt user to select an NDI source interactively
    private func promptForSource(from sources: [NDISource]) -> NDISource? {
        print("\n╔═══════════════════════════════════════════════════════╗")
        print("║          SELECT NDI SOURCE                            ║")
        print("╠═══════════════════════════════════════════════════════╣")
        for (i, src) in sources.enumerated() {
            print("║  [\(i + 1)] \(src.name.padding(toLength: 45, withPad: " ", startingAt: 0)) ║")
        }
        print("╚═══════════════════════════════════════════════════════╝")
        print("Enter source number (1-\(sources.count)): ", terminator: "")

        guard let input = readLine(),
              let choice = Int(input),
              choice >= 1, choice <= sources.count else {
            print("Invalid selection")
            return nil
        }

        return sources[choice - 1]
    }

    /// Get list of available NDI sources
    func listSources(timeout: TimeInterval = 5.0) throws -> [NDISource] {
        try ndiReceiver.initialize()
        return try ndiReceiver.discoverSources(timeout: timeout)
    }

    /// Select a specific source by name
    func selectSource(named name: String) throws {
        let sources = try ndiReceiver.discoverSources(timeout: config.sourceDiscoveryTimeout)
        guard let source = sources.first(where: { $0.name.contains(name) }) else {
            throw NDIError.noSourcesFound
        }
        selectedSource = source
        logger.info("Source selected: \(source.name)", subsystem: .host)
    }

    // MARK: - NDIReceiverDelegate

    func ndiReceiver(_ receiver: NDIReceiver, didReceiveVideoFrame pixelBuffer: CVPixelBuffer, timestamp: UInt64, frameNumber: UInt64) {
        framesProcessed = frameNumber

        // Encode the video frame
        do {
            try encoder.encode(pixelBuffer: pixelBuffer, timestamp: timestamp)
        } catch {
            logger.error("Encoding error: \(error.localizedDescription)", subsystem: .host)
        }
    }

    func ndiReceiver(_ receiver: NDIReceiver, didReceiveAudioFrame data: Data, timestamp: UInt64, sampleRate: Int32, channels: Int32, samplesPerChannel: Int32) {
        // Send audio directly over network (no encoding, PCM passthrough)
        networkSender.sendAudio(data: data, timestamp: timestamp, sampleRate: sampleRate, channels: channels)
    }

    func ndiReceiver(_ receiver: NDIReceiver, didDisconnect error: Error?) {
        if let error = error {
            logger.error("NDI disconnected: \(error.localizedDescription)", subsystem: .host)
        } else {
            logger.warning("NDI source disconnected", subsystem: .host)
        }

        // Attempt reconnect
        if isRunning, let source = selectedSource {
            logger.info("Attempting to reconnect...", subsystem: .host)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                do {
                    try self?.ndiReceiver.connect(to: source)
                    self?.ndiReceiver.startCapture()
                } catch {
                    logger.error("Reconnect failed: \(error.localizedDescription)", subsystem: .host)
                }
            }
        }
    }

    // MARK: - VideoEncoderDelegate

    func videoEncoder(_ encoder: VideoEncoder, didEncodeData data: Data, isKeyframe: Bool, timestamp: UInt64, duration: UInt64) {
        // Send encoded data over network
        networkSender.send(data: data, isKeyframe: isKeyframe, timestamp: timestamp)
    }

    func videoEncoder(_ encoder: VideoEncoder, didFailWithError error: Error) {
        logger.error("Encoder error: \(error.localizedDescription)", subsystem: .host)
    }

    // MARK: - NetworkSenderDelegate

    func networkSender(_ sender: NetworkSender, didConnect endpoint: NWEndpoint) {
        logger.success("Network connected to \(endpoint)", subsystem: .host)
    }

    func networkSender(_ sender: NetworkSender, didDisconnect error: Error?) {
        if let error = error {
            logger.error("Network disconnected: \(error.localizedDescription)", subsystem: .host)
        }
    }

    func networkSender(_ sender: NetworkSender, didUpdateStats bytesSent: UInt64, packetsent: UInt64) {
        // Statistics are logged by NetworkSender itself
    }
}
