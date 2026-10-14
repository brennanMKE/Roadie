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
        .library(name: "FolderBackendKit", targets: ["FolderBackendKit"]),
        .library(name: "LibraryBrowser", targets: ["LibraryBrowser"]),
        .library(name: "MusicBackendStub", targets: ["MusicBackendStub"]),
        .library(name: "MusicLibraryKit", targets: ["MusicLibraryKit"]),
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
            "MusicLibraryKit",
        ]),
        // A local folder behind MusicBackend. Indexes Artist/Album/<tracks> with LocalTrackLoader; plays through LocalPlayback.
        .target(name: "FolderBackendKit", dependencies: ["MusicBackendKit", "LocalPlayback", "AudioCore"]),
        .testTarget(name: "FolderBackendKitTests", dependencies: ["FolderBackendKit", "MusicBackendKit", "LocalPlayback", "AudioCore"]),
        // Browser view models. Foundation + Observation; depends on the protocol only, never on a backend.
        .target(name: "LibraryBrowser", dependencies: ["MusicBackendKit", "MusicLibraryKit"]),
        // In-memory MusicBackend for tests of the browser and of anything that drives a backend.
        .target(name: "MusicBackendStub", dependencies: ["MusicBackendKit"]),
        .testTarget(name: "LibraryBrowserTests", dependencies: ["LibraryBrowser", "MusicBackendKit", "MusicBackendStub", "MusicLibraryKit"]),
        // Artwork cache for the browser and now-playing views. Decodes with ImageIO; Foundation + MusicBackendKit otherwise.
        .target(name: "MusicLibraryKit", dependencies: ["MusicBackendKit"]),
        .testTarget(name: "MusicLibraryKitTests", dependencies: ["MusicLibraryKit", "MusicBackendKit", "MusicBackendStub"]),
    ]
)
