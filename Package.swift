// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "A8AirControl",
    platforms: [.macOS(.v26)],
    targets: [
        // Pure protocol layer (frame parsing, command building, models).
        // No CoreBluetooth / SwiftUI so it can be unit-tested headlessly.
        .target(
            name: "ISDTCore",
            path: "Sources/ISDTCore"
        ),
        .executableTarget(
            name: "A8AirControl",
            dependencies: ["ISDTCore"],
            path: "Sources/A8AirControl"
        ),
        .testTarget(
            name: "ISDTCoreTests",
            dependencies: ["ISDTCore"],
            path: "Tests/ISDTCoreTests"
        ),
    ]
)
