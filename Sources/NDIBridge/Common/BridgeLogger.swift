//
//  BridgeLogger.swift
//  NDI Bridge Mac
//
//  Unified logging system for all components
//

import Foundation
import os.log

/// Logging subsystems for different components
enum LogSubsystem: String {
    case host = "com.ndibridge.host"
    case join = "com.ndibridge.join"
    case ndi = "com.ndibridge.ndi"
    case video = "com.ndibridge.video"
    case network = "com.ndibridge.network"
}

/// Log levels with emoji prefixes for terminal visibility
enum LogLevel: String {
    case debug = "🔍"
    case info = "ℹ️"
    case success = "✅"
    case warning = "⚠️"
    case error = "❌"
    case fatal = "💀"
}

/// Thread-safe logger with timestamps and component identification
final class BridgeLogger {
    static let shared = BridgeLogger()

    private let dateFormatter: DateFormatter
    private let queue = DispatchQueue(label: "com.ndibridge.logger", qos: .utility)

    var isVerbose = true

    private init() {
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss.SSS"
    }

    func log(_ level: LogLevel, subsystem: LogSubsystem, message: String, file: String = #file, function: String = #function, line: Int = #line) {
        guard isVerbose || level != .debug else { return }

        queue.async { [weak self] in
            guard let self = self else { return }

            let timestamp = self.dateFormatter.string(from: Date())
            let filename = (file as NSString).lastPathComponent.replacingOccurrences(of: ".swift", with: "")

            let logMessage = "\(timestamp) \(level.rawValue) [\(subsystem.rawValue.split(separator: ".").last ?? "")] \(filename):\(line) - \(message)"

            print(logMessage)
        }
    }

    // Convenience methods
    func debug(_ message: String, subsystem: LogSubsystem = .host, file: String = #file, function: String = #function, line: Int = #line) {
        log(.debug, subsystem: subsystem, message: message, file: file, function: function, line: line)
    }

    func info(_ message: String, subsystem: LogSubsystem = .host, file: String = #file, function: String = #function, line: Int = #line) {
        log(.info, subsystem: subsystem, message: message, file: file, function: function, line: line)
    }

    func success(_ message: String, subsystem: LogSubsystem = .host, file: String = #file, function: String = #function, line: Int = #line) {
        log(.success, subsystem: subsystem, message: message, file: file, function: function, line: line)
    }

    func warning(_ message: String, subsystem: LogSubsystem = .host, file: String = #file, function: String = #function, line: Int = #line) {
        log(.warning, subsystem: subsystem, message: message, file: file, function: function, line: line)
    }

    func error(_ message: String, subsystem: LogSubsystem = .host, file: String = #file, function: String = #function, line: Int = #line) {
        log(.error, subsystem: subsystem, message: message, file: file, function: function, line: line)
    }

    func fatal(_ message: String, subsystem: LogSubsystem = .host, file: String = #file, function: String = #function, line: Int = #line) {
        log(.fatal, subsystem: subsystem, message: message, file: file, function: function, line: line)
    }

    /// Log video frame statistics
    func logFrame(frameNumber: UInt64, width: Int, height: Int, fps: Double, subsystem: LogSubsystem = .video) {
        debug("Frame #\(frameNumber) - \(width)x\(height) @ \(String(format: "%.2f", fps)) fps", subsystem: subsystem)
    }

    /// Log network statistics
    func logNetwork(bytesSent: UInt64, bytesReceived: UInt64, rtt: Double, subsystem: LogSubsystem = .network) {
        debug("Network: TX=\(formatBytes(bytesSent)) RX=\(formatBytes(bytesReceived)) RTT=\(String(format: "%.1f", rtt * 1000))ms", subsystem: subsystem)
    }

    /// Log encoding statistics
    func logEncoding(bitrate: Double, qp: Int, keyframe: Bool, subsystem: LogSubsystem = .video) {
        let bitrateStr = String(format: "%.2f", bitrate / 1_000_000)
        debug("Encode: \(bitrateStr) Mbps, QP=\(qp), KF=\(keyframe)", subsystem: subsystem)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        } else if bytes < 1024 * 1024 * 1024 {
            return String(format: "%.2f MB", Double(bytes) / (1024 * 1024))
        } else {
            return String(format: "%.2f GB", Double(bytes) / (1024 * 1024 * 1024))
        }
    }
}

/// Global shortcut
let logger = BridgeLogger.shared
