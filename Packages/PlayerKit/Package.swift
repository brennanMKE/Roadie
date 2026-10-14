// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlayerKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AudioCore", targets: ["AudioCore"]),
        .library(name: "PlexKit", targets: ["PlexKit"]),
        .library(name: "PlexKitStub", targets: ["PlexKitStub"]),
        .library(name: "TrackCache", targets: ["TrackCache"]),
        .library(name: "MusicBackendKit", targets: ["MusicBackendKit"]),
        .library(name: "LocalPlayback", targets: ["LocalPlayback"]),
        .library(name: "PlexBackendKit", targets: ["PlexBackendKit"]),
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
        // Download cache with LRU eviction. Depends on both sides; AudioCore stays Plex-free.
        .target(name: "TrackCache", dependencies: ["AudioCore", "PlexKit"]),
        .testTarget(name: "TrackCacheTests", dependencies: ["TrackCache", "AudioCore", "PlexKit", "PlexKitStub"]),
        // Source-neutral protocol and models. Foundation only: MusicAssistantKit and the browser depend on it.
        .target(name: "MusicBackendKit"),
        .testTarget(name: "MusicBackendKitTests", dependencies: ["MusicBackendKit"]),
        // The "This Mac" output: AudioCore's Player as a MusicBackend output. Shared by Plex and the folder backend.
        .target(name: "LocalPlayback", dependencies: ["MusicBackendKit", "AudioCore"]),
        .testTarget(name: "LocalPlaybackTests", dependencies: ["LocalPlayback", "MusicBackendKit", "AudioCore"]),
        // Plex behind MusicBackend. The only target that knows both Plex and the local output.
        .target(name: "PlexBackendKit", dependencies: ["MusicBackendKit", "LocalPlayback", "AudioCore", "PlexKit", "TrackCache"]),
        .testTarget(name: "PlexBackendKitTests", dependencies: [
            "PlexBackendKit", "MusicBackendKit", "LocalPlayback", "PlexKit", "PlexKitStub", "TrackCache", "AudioCore",
        ]),
    ]
)
