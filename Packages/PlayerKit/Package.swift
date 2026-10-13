// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlayerKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AudioCore", targets: ["AudioCore"]),
    ],
    targets: [
        .target(name: "AudioCore"),
        .testTarget(name: "AudioCoreTests", dependencies: ["AudioCore"]),
    ]
)
