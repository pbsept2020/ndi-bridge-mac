// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NDIBridge",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "ndi-bridge",
            targets: ["NDIBridge"]
        )
    ],
    dependencies: [
        // No external dependencies - all native Apple frameworks + NDI SDK
    ],
    targets: [
        // C wrapper for NDI SDK
        .target(
            name: "CNDIWrapper",
            dependencies: [],
            cSettings: [
                .unsafeFlags(["-I/Library/NDI SDK for Apple/include"])
            ],
            linkerSettings: [
                .linkedLibrary("ndi"),
                .unsafeFlags(["-L/Library/NDI SDK for Apple/lib/macOS"])
            ]
        ),
        
        // Main executable
        .executableTarget(
            name: "NDIBridge",
            dependencies: ["CNDIWrapper"],
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug))
            ]
        ),
        
        // Tests
        .testTarget(
            name: "NDIBridgeTests",
            dependencies: ["NDIBridge"]
        )
    ]
)
