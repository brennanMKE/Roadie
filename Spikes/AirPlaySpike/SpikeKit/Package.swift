// swift-tools-version: 6.0
import PackageDescription

// Throwaway AirPlay routing spike (#0050). Not linked into SkinAmp; nothing here depends on AudioCore.
let package = Package(
    name: "SpikeKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SpikeKit", targets: ["SpikeKit"]),
    ],
    targets: [
        .target(name: "SpikeKit"),
        .testTarget(name: "SpikeKitTests", dependencies: ["SpikeKit"]),
    ]
)
