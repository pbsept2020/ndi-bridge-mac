//
//  NetworkReceiver.swift
//  NDI Bridge Mac
//
//  Receives video packets over UDP using Network.framework
//

import Foundation
import Network
import QuartzCore

/// Callback for received data
protocol NetworkReceiverDelegate: AnyObject {
    func networkReceiver(_ receiver: NetworkReceiver, didReceiveVideoFrame data: Data, isKeyframe: Bool, timestamp: UInt64)
    func networkReceiver(_ receiver: NetworkReceiver, didReceiveAudioFrame data: Data, timestamp: UInt64, sampleRate: Int32, channels: Int32)
    func networkReceiver(_ receiver: NetworkReceiver, didDisconnect error: Error?)
}

/// Extension with default implementation for backward compatibility
extension NetworkReceiverDelegate {
    func networkReceiver(_ receiver: NetworkReceiver, didReceiveAudioFrame data: Data, timestamp: UInt64, sampleRate: Int32, channels: Int32) {
        // Default: ignore audio if not implemented
    }
}

/// Parsed media packet header
struct ParsedMediaHeader {
    var version: UInt8 = 1
    var mediaType: UInt8 = 0        // 0 = video, 1 = audio
    var sourceId: UInt8 = 0
    var flags: UInt8 = 0            // For video: bit 0 = keyframe
    var sequenceNumber: UInt32 = 0
    var timestamp: UInt64 = 0
    var totalSize: UInt32 = 0
    var fragmentIndex: UInt16 = 0
    var fragmentCount: UInt16 = 0
    var payloadSize: UInt16 = 0
    var sampleRate: UInt32 = 48000  // Audio only
    var channels: UInt8 = 2         // Audio only

    var isKeyframe: Bool { flags & 1 != 0 }
    var isVideo: Bool { mediaType == 0 }
    var isAudio: Bool { mediaType == 1 }
}

/// Complete reassembled frame with metadata
struct ReassembledFrame {
    let data: Data
    let timestamp: UInt64
    let mediaType: UInt8
    let isKeyframe: Bool
    let sampleRate: UInt32
    let channels: UInt8
}

/// Reassembles fragmented media frames
final class FrameReassembler {
    private var fragments: [UInt16: Data] = [:]
    private var expectedCount: UInt16 = 0
    private var currentSequence: UInt32 = 0
    private var timestamp: UInt64 = 0
    private var flags: UInt8 = 0
    private var mediaType: UInt8 = 0
    private var totalSize: UInt32 = 0
    private var sampleRate: UInt32 = 48000
    private var channels: UInt8 = 2

    func reset() {
        fragments.removeAll()
        expectedCount = 0
        currentSequence = 0
    }

    func addFragment(header: ParsedMediaHeader, payload: Data) -> ReassembledFrame? {
        // New frame sequence
        if header.sequenceNumber != currentSequence {
            if !fragments.isEmpty {
                logger.warning("Incomplete frame dropped (seq: \(currentSequence), got \(fragments.count)/\(expectedCount))", subsystem: .network)
            }
            reset()
            currentSequence = header.sequenceNumber
            expectedCount = header.fragmentCount
            timestamp = header.timestamp
            flags = header.flags
            mediaType = header.mediaType
            totalSize = header.totalSize
            sampleRate = header.sampleRate
            channels = header.channels
        }

        // Store fragment
        fragments[header.fragmentIndex] = payload

        // Check if complete
        if fragments.count == Int(expectedCount) {
            // Reassemble in order
            var completeFrame = Data(capacity: Int(totalSize))
            for i in 0..<expectedCount {
                if let fragment = fragments[i] {
                    completeFrame.append(fragment)
                }
            }

            let result = ReassembledFrame(
                data: completeFrame,
                timestamp: timestamp,
                mediaType: mediaType,
                isKeyframe: flags & 1 != 0,
                sampleRate: sampleRate,
                channels: channels
            )

            reset()
            return result
        }

        return nil
    }
}

/// Receives video packets over UDP
final class NetworkReceiver {
    weak var delegate: NetworkReceiverDelegate?

    private var listener: NWListener?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.ndibridge.network.receiver", qos: .userInteractive)
    private var isListening = false

    // Separate reassemblers for video and audio to avoid mixing frames
    private let videoReassembler = FrameReassembler()
    private let audioReassembler = FrameReassembler()

    // Statistics
    private var totalBytesReceived: UInt64 = 0
    private var totalPacketsReceived: UInt64 = 0
    private var framesReceived: UInt64 = 0
    private var lastStatsTime: CFTimeInterval = 0

    private var listenPort: UInt16

    init(port: UInt16 = 5990) {
        self.listenPort = port
        logger.info("NetworkReceiver initializing on port \(port)...", subsystem: .network)
    }

    deinit {
        stop()
        logger.info("NetworkReceiver deinitialized", subsystem: .network)
    }

    /// Start listening for incoming packets
    func startListening(port: UInt16? = nil) throws {
        if let p = port { listenPort = p }

        guard !isListening else {
            logger.warning("Already listening", subsystem: .network)
            return
        }

        logger.info("Starting UDP listener on port \(listenPort)...", subsystem: .network)

        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: listenPort) else {
            throw NSError(domain: "NetworkReceiver", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid port"])
        }

        listener = try NWListener(using: parameters, on: nwPort)

        listener?.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState(state)
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener?.start(queue: queue)
        isListening = true
    }

    /// Stop listening
    func stop() {
        guard isListening else { return }

        logger.info("Stopping receiver...", subsystem: .network)

        connection?.cancel()
        connection = nil

        listener?.cancel()
        listener = nil

        isListening = false

        logger.success("Receiver stopped. Total received: \(formatBytes(totalBytesReceived)), Frames: \(framesReceived)", subsystem: .network)
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener?.port?.rawValue {
                logger.success("Listening on UDP port \(port)", subsystem: .network)
            }

        case .failed(let error):
            logger.error("Listener failed: \(error.localizedDescription)", subsystem: .network)
            isListening = false

        case .cancelled:
            logger.info("Listener cancelled", subsystem: .network)
            isListening = false

        case .waiting(let error):
            logger.warning("Listener waiting: \(error.localizedDescription)", subsystem: .network)

        default:
            break
        }
    }

    private func handleNewConnection(_ newConnection: NWConnection) {
        logger.info("New connection from: \(newConnection.endpoint)", subsystem: .network)

        // Cancel existing connection
        connection?.cancel()
        connection = newConnection

        connection?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                logger.success("Connection ready", subsystem: .network)
                self?.receivePacket()

            case .failed(let error):
                logger.error("Connection failed: \(error.localizedDescription)", subsystem: .network)
                self?.delegate?.networkReceiver(self!, didDisconnect: error)

            case .cancelled:
                logger.info("Connection cancelled", subsystem: .network)

            default:
                break
            }
        }

        connection?.start(queue: queue)
    }

    private func receivePacket() {
        guard let conn = connection else { return }

        conn.receiveMessage { [weak self] content, contentContext, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                logger.error("Receive error: \(error.localizedDescription)", subsystem: .network)
                return
            }

            if let data = content {
                self.processPacket(data)
            }

            // Continue receiving
            self.receivePacket()
        }
    }

    private func processPacket(_ data: Data) {
        totalPacketsReceived += 1
        totalBytesReceived += UInt64(data.count)

        // Minimum header size for version detection
        guard data.count >= 6 else {
            logger.warning("Packet too small: \(data.count) bytes", subsystem: .network)
            return
        }

        // Read magic and version
        var offset = 0
        let magic = data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        offset += 4

        guard magic == 0x4E444942 else {  // "NDIB"
            logger.warning("Invalid packet magic: \(String(format: "0x%08X", magic))", subsystem: .network)
            return
        }

        let version = data[offset]
        offset += 1

        // Parse based on version
        var header = ParsedMediaHeader()
        header.version = version

        if version >= 2 {
            // Version 2 header (38 bytes) - with audio support
            guard data.count >= 38 else {
                logger.warning("V2 packet too small: \(data.count) bytes", subsystem: .network)
                return
            }

            header.mediaType = data[offset]
            offset += 1
            header.sourceId = data[offset]
            offset += 1
            header.flags = data[offset]
            offset += 1
            header.sequenceNumber = data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            offset += 4
            header.timestamp = data.subdata(in: offset..<(offset + 8)).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
            offset += 8
            header.totalSize = data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            offset += 4
            header.fragmentIndex = data.subdata(in: offset..<(offset + 2)).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
            offset += 2
            header.fragmentCount = data.subdata(in: offset..<(offset + 2)).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
            offset += 2
            header.payloadSize = data.subdata(in: offset..<(offset + 2)).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
            offset += 2
            header.sampleRate = data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            offset += 4
            header.channels = data[offset]
            offset += 1
            offset += 3  // Skip reserved bytes (offset now = 38)

            let payload = data.subdata(in: offset..<data.count)

            // Use appropriate reassembler based on media type
            let reassembler = header.mediaType == 0 ? videoReassembler : audioReassembler

            // Try to reassemble frame
            if let frame = reassembler.addFragment(header: header, payload: payload) {
                framesReceived += 1

                // Log periodically
                let now = CACurrentMediaTime()
                if now - lastStatsTime >= 1.0 {
                    logger.logNetwork(bytesSent: 0, bytesReceived: totalBytesReceived, rtt: 0, subsystem: .network)
                    lastStatsTime = now
                }

                // Route to appropriate delegate method based on media type
                if frame.mediaType == 0 {
                    // Video frame
                    delegate?.networkReceiver(
                        self,
                        didReceiveVideoFrame: frame.data,
                        isKeyframe: frame.isKeyframe,
                        timestamp: frame.timestamp
                    )
                } else {
                    // Audio frame
                    delegate?.networkReceiver(
                        self,
                        didReceiveAudioFrame: frame.data,
                        timestamp: frame.timestamp,
                        sampleRate: Int32(frame.sampleRate),
                        channels: Int32(frame.channels)
                    )
                }
            }
        } else {
            // Version 1 header (28 bytes) - legacy video only
            guard data.count >= 28 else {
                logger.warning("V1 packet too small: \(data.count) bytes", subsystem: .network)
                return
            }

            let packetType = data[offset]
            offset += 1
            header.mediaType = 0  // Video only in v1
            header.flags = packetType  // In v1, packetType 1 = keyframe
            header.sequenceNumber = data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            offset += 4
            header.timestamp = data.subdata(in: offset..<(offset + 8)).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
            offset += 8
            header.totalSize = data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            offset += 4
            header.fragmentIndex = data.subdata(in: offset..<(offset + 2)).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
            offset += 2
            header.fragmentCount = data.subdata(in: offset..<(offset + 2)).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
            offset += 2
            header.payloadSize = data.subdata(in: offset..<(offset + 2)).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
            offset += 2

            let payload = data.subdata(in: 28..<data.count)

            // Try to reassemble frame (v1 is video only)
            if let frame = videoReassembler.addFragment(header: header, payload: payload) {
                framesReceived += 1

                let now = CACurrentMediaTime()
                if now - lastStatsTime >= 1.0 {
                    logger.logNetwork(bytesSent: 0, bytesReceived: totalBytesReceived, rtt: 0, subsystem: .network)
                    lastStatsTime = now
                }

                // Video frame (v1 is video only)
                delegate?.networkReceiver(
                    self,
                    didReceiveVideoFrame: frame.data,
                    isKeyframe: frame.isKeyframe,
                    timestamp: frame.timestamp
                )
            }
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        } else {
            return String(format: "%.2f MB", Double(bytes) / (1024 * 1024))
        }
    }
}
