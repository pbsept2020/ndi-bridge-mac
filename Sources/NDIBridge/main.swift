//
//  main.swift
//  NDI Bridge Mac
//
//  Entry point for NDI Bridge application
//

import Foundation

struct NDIBridgeApp {
    static var hostMode: HostMode?
    static var joinMode: JoinMode?

    static func main() {
        print("🌉 NDI Bridge for Mac v0.1.0-alpha")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("")

        // Setup signal handlers for graceful shutdown
        setupSignalHandlers()

        // Parse command line arguments
        let arguments = CommandLine.arguments

        if arguments.count < 2 {
            printUsage()
            return
        }

        let mode = arguments[1]

        switch mode {
        case "host":
            startHostMode(arguments: arguments)

        case "join":
            startJoinMode(arguments: arguments)

        case "discover":
            discoverSources()

        case "--version", "-v":
            printVersion()

        case "--help", "-h":
            printUsage()

        default:
            print("❌ Unknown mode: \(mode)")
            print("")
            printUsage()
        }
    }

    static func startHostMode(arguments: [String]) {
        print("🚀 Starting HOST MODE (Sender)")
        print("")

        // Parse arguments
        var config = HostModeConfig()

        var i = 2
        while i < arguments.count {
            switch arguments[i] {
            case "--target", "-t":
                if i + 1 < arguments.count {
                    let parts = arguments[i + 1].split(separator: ":")
                    config.targetHost = String(parts[0])
                    if parts.count > 1, let port = UInt16(parts[1]) {
                        config.targetPort = port
                    }
                    i += 1
                }

            case "--port", "-p":
                if i + 1 < arguments.count, let port = UInt16(arguments[i + 1]) {
                    config.targetPort = port
                    i += 1
                }

            case "--bitrate", "-b":
                if i + 1 < arguments.count, let bitrate = Int(arguments[i + 1]) {
                    config.encoder.bitrate = bitrate * 1_000_000  // Convert Mbps to bps
                    i += 1
                }

            case "--auto":
                config.autoSelectFirstSource = true

            case "--source", "-s":
                if i + 1 < arguments.count {
                    config.sourceName = arguments[i + 1]
                    i += 1
                }

            case "--exclude", "-x":
                if i + 1 < arguments.count {
                    config.excludePatterns.append(arguments[i + 1])
                    i += 1
                }

            default:
                break
            }
            i += 1
        }

        // Create and start host mode
        hostMode = HostMode(config: config)

        do {
            try hostMode?.start()

            // Keep running until interrupted
            print("")
            print("Press Ctrl+C to stop...")
            RunLoop.main.run()

        } catch {
            print("")
            print("❌ Error: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func startJoinMode(arguments: [String]) {
        print("📥 Starting JOIN MODE (Receiver)")
        print("")

        // Parse arguments
        var config = JoinModeConfig()

        var i = 2
        while i < arguments.count {
            switch arguments[i] {
            case "--port", "-p":
                if i + 1 < arguments.count, let port = UInt16(arguments[i + 1]) {
                    config.listenPort = port
                    i += 1
                }

            case "--name", "-n":
                if i + 1 < arguments.count {
                    config.ndiOutputName = arguments[i + 1]
                    i += 1
                }

            default:
                break
            }
            i += 1
        }

        // Create and start join mode
        joinMode = JoinMode(config: config)

        do {
            try joinMode?.start()

            // Keep running until interrupted
            print("")
            print("Press Ctrl+C to stop...")
            RunLoop.main.run()

        } catch {
            print("")
            print("❌ Error: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func discoverSources() {
        print("🔍 Discovering NDI sources on network...")
        print("")

        let receiver = NDIReceiver()

        do {
            try receiver.initialize()
            let sources = try receiver.discoverSources(timeout: 10.0)

            if sources.isEmpty {
                print("No NDI sources found.")
            } else {
                print("Found \(sources.count) NDI source(s):")
                print("")
                for (index, source) in sources.enumerated() {
                    print("  [\(index + 1)] \(source.name)")
                }
            }
        } catch {
            print("❌ Error: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func printVersion() {
        print("NDI Bridge Mac v0.1.0-alpha")
        print("Built with Swift 5.9")
        print("VideoToolbox H.264 hardware encoding/decoding")
        print("NDI SDK 6.x")
        print("")
        print("Copyright 2026 Pierre Bessette")
    }

    static func printUsage() {
        print("Usage:")
        print("  ndi-bridge host [options]        Start in Host mode (sender)")
        print("  ndi-bridge join [options]        Start in Join mode (receiver)")
        print("  ndi-bridge discover              Discover NDI sources on network")
        print("")
        print("Host Mode Options:")
        print("  --target, -t <ip:port>           Target endpoint (default: 127.0.0.1:5990)")
        print("  --port, -p <port>                Target port (default: 5990)")
        print("  --bitrate, -b <mbps>             Encoding bitrate in Mbps (default: 8)")
        print("  --source, -s <name>              Select NDI source by name (partial match)")
        print("  --exclude, -x <pattern>          Exclude sources matching pattern (repeatable)")
        print("  --auto                           Auto-select first available source")
        print("")
        print("Join Mode Options:")
        print("  --port, -p <port>                Listen port (default: 5990)")
        print("  --name, -n <name>                NDI output name (default: 'NDI Bridge Output')")
        print("")
        print("General Options:")
        print("  --help, -h                       Show this help")
        print("  --version, -v                    Show version")
        print("")
        print("Examples:")
        print("  # Host mode - interactive source selection")
        print("  ndi-bridge host")
        print("")
        print("  # Host mode - select specific source by name")
        print("  ndi-bridge host --source \"OBS\"")
        print("")
        print("  # Host mode - auto-select (excludes 'Bridge' by default)")
        print("  ndi-bridge host --auto")
        print("")
        print("  # Host mode - stream to remote machine")
        print("  ndi-bridge host --source \"Camera\" --target 192.168.1.100:5990 --bitrate 15")
        print("")
        print("  # Join mode - receive and output as NDI")
        print("  ndi-bridge join --name \"Remote Camera\"")
        print("")
        print("  # Discover NDI sources")
        print("  ndi-bridge discover")
    }

    static func setupSignalHandlers() {
        // Handle SIGINT (Ctrl+C)
        signal(SIGINT) { _ in
            print("")
            print("Shutting down...")

            NDIBridgeApp.hostMode?.stop()
            NDIBridgeApp.joinMode?.stop()

            print("Goodbye! 👋")
            exit(0)
        }

        // Handle SIGTERM
        signal(SIGTERM) { _ in
            NDIBridgeApp.hostMode?.stop()
            NDIBridgeApp.joinMode?.stop()
            exit(0)
        }
    }
}

// Entry point
NDIBridgeApp.main()
