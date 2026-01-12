//
//  NetworkSender.swift
//  NDI Bridge Mac
//
//  Sends encoded video data over UDP using Network.framework
//

import Foundation
import Network
import QuartzCore

/// Callback for network events
protocol NetworkSenderDelegate: AnyObject {
    func networkSender(_ sender: NetworkSender, didConnect endpoint: NWEndpoint)
    func networkSender(_ sender: NetworkSender, didDisconnect error: Error?)
    func networkSender(_ sender: NetworkSender, didUpdateStats bytesSent: UInt64, packetsent: UInt64)
}

/// Media types for packet header
enum MediaType: UInt8 {
    case video = 0
    case audio = 1
}

/// Packet header for media data (video or audio)
struct MediaPacketHeader {
    var magic: UInt32 = 0x4E444942  // "NDIB"
    var version: UInt8 = 2          // Version 2 with audio support
    var mediaType: UInt8 = 0        // 0 = video, 1 = audio
    var sourceId: UInt8 = 0         // Source ID (for future multi-source)
    var flags: UInt8 = 0            // Flags: bit 0 = keyframe (video) or reserved (audio)
    var sequenceNumber: UInt32 = 0
    var timestamp: UInt64 = 0
    var totalSize: UInt32 = 0
    var fragmentIndex: UInt16 = 0
    var fragmentCount: UInt16 = 0
    var payloadSize: UInt16 = 0

    // Audio-specific fields (only used when mediaType == 1)
    var sampleRate: UInt32 = 48000  // Audio sample rate
    var channels: UInt8 = 2         // Audio channels
    var reserved: [UInt8] = [0, 0, 0]  // Padding for alignment

    static let size = 38  // Total header size in bytes (verified from toData())

    func toData() -> Data {
        var data = Data(capacity: MediaPacketHeader.size)
        withUnsafeBytes(of: magic.bigEndian) { data.append(contentsOf: $0) }
        data.append(version)
        data.append(mediaType)
        data.append(sourceId)
        data.append(flags)
        withUnsafeBytes(of: sequenceNumber.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: timestamp.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: totalSize.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: fragmentIndex.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: fragmentCount.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: payloadSize.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: sampleRate.bigEndian) { data.append(contentsOf: $0) }
        data.append(channels)
        data.append(contentsOf: reserved)
        return data
    }
}

/// Legacy alias for backward compatibility
typealias VideoPacketHeader = MediaPacketHeader

/// Network configuration
struct NetworkSenderConfig {
    var host: String = "127.0.0.1"
    var port: UInt16 = 5990
    var mtu: Int = 1400  // Safe MTU for UDP (accounting for headers)
}

/// Sends video packets over UDP
final class NetworkSender {
    weak var delegate: NetworkSenderDelegate?

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.ndibridge.network.sender", qos: .userInteractive)
    private var config: NetworkSenderConfig
    private var isConnected = false

    // Statistics
    private var sequenceNumber: UInt32 = 0
    private var totalBytesSent: UInt64 = 0
    private var totalPacketsSent: UInt64 = 0
    private var lastStatsTime: CFTimeInterval = 0

    init(config: NetworkSenderConfig = NetworkSenderConfig()) {
        self.config = config
        logger.info("NetworkSender initializing...", subsystem: .network)
    }

    deinit {
        disconnect()
        logger.info("NetworkSender deinitialized", subsystem: .network)
    }

    /// Connect to the target endpoint
    func connect(host: String? = nil, port: UInt16? = nil) {
        if let h = host { config.host = h }
        if let p = port { config.port = p }

        logger.info("Connecting to \(config.host):\(config.port)...", subsystem: .network)

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(config.host),
            port: NWEndpoint.Port(rawValue: config.port)!
        )

        // UDP connection with parameters
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true

        // Enable expedited data if available
        if let options = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            options.disableFragmentation = false
        }

        connection = NWConnection(to: endpoint, using: parameters)

        connection?.stateUpdateHandler = { [weak self] state in
            self?.handleStateChange(state)
        }

        connection?.start(queue: queue)
    }

    /// Disconnect from the target
    func disconnect() {
        guard let conn = connection else { return }

        logger.info("Disconnecting...", subsystem: .network)

        conn.cancel()
        connection = nil
        isConnected = false

        logger.success("Disconnected. Total sent: \(formatBytes(totalBytesSent))", subsystem: .network)
    }

    /// Send encoded video data (will be fragmented if needed)
    func send(data: Data, isKeyframe: Bool, timestamp: UInt64) {
        guard isConnected, let conn = connection else {
            logger.warning("Cannot send - not connected", subsystem: .network)
            return
        }

        let maxPayload = config.mtu - MediaPacketHeader.size

        // Calculate number of fragments needed
        let fragmentCount = (data.count + maxPayload - 1) / maxPayload

        sequenceNumber += 1

        for i in 0..<fragmentCount {
            let start = i * maxPayload
            let end = min(start + maxPayload, data.count)
            let fragment = data.subdata(in: start..<end)

            var header = MediaPacketHeader()
            header.mediaType = MediaType.video.rawValue
            header.flags = isKeyframe ? 1 : 0
            header.sequenceNumber = sequenceNumber
            header.timestamp = timestamp
            header.totalSize = UInt32(data.count)
            header.fragmentIndex = UInt16(i)
            header.fragmentCount = UInt16(fragmentCount)
            header.payloadSize = UInt16(fragment.count)

            var packet = header.toData()
            packet.append(fragment)
            let packetToSend = packet  // Create immutable copy for closure

            // Send packet
            conn.send(content: packetToSend, completion: .contentProcessed { [weak self] error in
                if let error = error {
                    logger.error("Send error: \(error.localizedDescription)", subsystem: .network)
                } else {
                    self?.totalPacketsSent += 1
                    self?.totalBytesSent += UInt64(packet.count)
                }
            })
        }

        // Update statistics periodically
        let now = CACurrentMediaTime()
        if now - lastStatsTime >= 1.0 {
            delegate?.networkSender(self, didUpdateStats: totalBytesSent, packetsent: totalPacketsSent)
            logger.logNetwork(bytesSent: totalBytesSent, bytesReceived: 0, rtt: 0, subsystem: .network)
            lastStatsTime = now
        }
    }

    /// Send audio data (will be fragmented if needed)
    func sendAudio(data: Data, timestamp: UInt64, sampleRate: Int32, channels: Int32) {
        guard isConnected, let conn = connection else {
            logger.warning("Cannot send audio - not connected", subsystem: .network)
            return
        }

        let maxPayload = config.mtu - MediaPacketHeader.size

        // Calculate number of fragments needed
        let fragmentCount = (data.count + maxPayload - 1) / maxPayload

        sequenceNumber += 1

        for i in 0..<fragmentCount {
            let start = i * maxPayload
            let end = min(start + maxPayload, data.count)
            let fragment = data.subdata(in: start..<end)

            var header = MediaPacketHeader()
            header.mediaType = MediaType.audio.rawValue
            header.flags = 0
            header.sequenceNumber = sequenceNumber
            header.timestamp = timestamp
            header.totalSize = UInt32(data.count)
            header.fragmentIndex = UInt16(i)
            header.fragmentCount = UInt16(fragmentCount)
            header.payloadSize = UInt16(fragment.count)
            header.sampleRate = UInt32(sampleRate)
            header.channels = UInt8(channels)

            var packet = header.toData()
            packet.append(fragment)
            let packetToSend = packet

            conn.send(content: packetToSend, completion: .contentProcessed { [weak self] error in
                if let error = error {
                    logger.error("Audio send error: \(error.localizedDescription)", subsystem: .network)
                } else {
                    self?.totalPacketsSent += 1
                    self?.totalBytesSent += UInt64(packet.count)
                }
            })
        }
    }

    /// Send raw packet without fragmentation
    func sendRaw(_ data: Data) {
        guard isConnected, let conn = connection else { return }

        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                logger.error("Raw send error: \(error.localizedDescription)", subsystem: .network)
            } else {
                self?.totalPacketsSent += 1
                self?.totalBytesSent += UInt64(data.count)
            }
        })
    }

    private func handleStateChange(_ state: NWConnection.State) {
        switch state {
        case .ready:
            isConnected = true
            logger.success("Connected to \(config.host):\(config.port)", subsystem: .network)
            if let endpoint = connection?.currentPath?.remoteEndpoint {
                delegate?.networkSender(self, didConnect: endpoint)
            }

        case .failed(let error):
            isConnected = false
            logger.error("Connection failed: \(error.localizedDescription)", subsystem: .network)
            delegate?.networkSender(self, didDisconnect: error)

        case .cancelled:
            isConnected = false
            logger.info("Connection cancelled", subsystem: .network)
            delegate?.networkSender(self, didDisconnect: nil)

        case .waiting(let error):
            logger.warning("Connection waiting: \(error.localizedDescription)", subsystem: .network)

        case .preparing:
            logger.debug("Connection preparing...", subsystem: .network)

        case .setup:
            logger.debug("Connection setup...", subsystem: .network)

        @unknown default:
            break
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
