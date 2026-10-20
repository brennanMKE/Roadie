// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlayerKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AudioCore", targets: ["AudioCore"]),
        .library(name: "MusicBackendKit", targets: ["MusicBackendKit"]),
        .library(name: "LocalPlayback", targets: ["LocalPlayback"]),
        .library(name: "FolderBackendKit", targets: ["FolderBackendKit"]),
        .library(name: "LibraryBrowser", targets: ["LibraryBrowser"]),
        .library(name: "MusicBackendStub", targets: ["MusicBackendStub"]),
        .library(name: "MusicLibraryKit", targets: ["MusicLibraryKit"]),
        .library(name: "MusicAssistantKit", targets: ["MusicAssistantKit"]),
        .library(name: "MusicAssistantKitStub", targets: ["MusicAssistantKitStub"]),
        .library(name: "SendspinKit", targets: ["SendspinKit"]),
    ],
    targets: [
        // Tiny local C shim for acquire/release atomics (no third-party dependency).
        .target(name: "CAtomics"),
        .target(name: "AudioCore", dependencies: ["CAtomics"]),
        .testTarget(name: "AudioCoreTests", dependencies: ["AudioCore"]),
        // Source-neutral protocol and models. Foundation only: MusicAssistantKit and the browser depend on it.
        .target(name: "MusicBackendKit"),
        .testTarget(name: "MusicBackendKitTests", dependencies: ["MusicBackendKit"]),
        // The "This Mac" output and the stack that builds it. Shared by the folder backend and, with #0066, Music Assistant's local playback.
        .target(name: "LocalPlayback", dependencies: ["MusicBackendKit", "AudioCore"]),
        .testTarget(name: "LocalPlaybackTests", dependencies: ["LocalPlayback", "MusicBackendKit", "AudioCore"]),
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
        // Music Assistant WebSocket client, models and the MusicBackend adapter. Foundation + MusicBackendKit only:
        // never AudioCore or LocalPlayback (#0066 adds local playback behind its own seam).
        .target(name: "MusicAssistantKit", dependencies: ["MusicBackendKit"]),
        // Scripted WebSocket/HTTP transports replaying #0060's recorded frames, plus an in-memory token store.
        .target(name: "MusicAssistantKitStub", dependencies: ["MusicAssistantKit", "MusicBackendKit"], resources: [.copy("Fixtures")]),
        .testTarget(name: "MusicAssistantKitTests", dependencies: ["MusicAssistantKit", "MusicAssistantKitStub", "MusicBackendKit"]),
        // Sendspin player protocol client (#0066). Foundation only: no AudioCore, no MusicAssistantKit; the token and
        // URL come in through `SendspinConnectionConfiguration`.
        .target(name: "SendspinKit"),
        .testTarget(name: "SendspinKitTests", dependencies: ["SendspinKit"], resources: [.copy("Fixtures")]),
    ]
)
