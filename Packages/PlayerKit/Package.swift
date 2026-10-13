// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlayerKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AudioCore", targets: ["AudioCore"]),
        .library(name: "PlexKit", targets: ["PlexKit"]),
        .library(name: "PlexKitStub", targets: ["PlexKitStub"]),
    ],
    targets: [
        // Tiny local C shim for acquire/release atomics (no third-party dependency).
        .target(name: "CAtomics"),
        .target(name: "AudioCore", dependencies: ["CAtomics"]),
        .testTarget(name: "AudioCoreTests", dependencies: ["AudioCore"]),
        // Plex HTTP client and models. Foundation only: must not depend on AudioCore (and vice versa).
        .target(name: "PlexKit"),
        // URLProtocol stub plus recorded JSON fixtures, shared by unit tests and later UI tests.
        .target(name: "PlexKitStub", dependencies: ["PlexKit"], resources: [.copy("Fixtures")]),
        .testTarget(name: "PlexKitTests", dependencies: ["PlexKit", "PlexKitStub"]),
    ]
)
