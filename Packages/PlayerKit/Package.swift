// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlayerKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AudioCore", targets: ["AudioCore"]),
    ],
    targets: [
        // Tiny local C shim for acquire/release atomics (no third-party dependency).
        .target(name: "CAtomics"),
        .target(name: "AudioCore", dependencies: ["CAtomics"]),
        .testTarget(name: "AudioCoreTests", dependencies: ["AudioCore"]),
    ]
)
