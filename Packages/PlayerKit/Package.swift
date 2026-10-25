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
        .library(name: "SendspinPlayback", targets: ["SendspinPlayback"]),
        // The fixture audio and music folder (#0195), test-only: the app's RoadieTests bundle links it (#0210, #0211);
        // the app itself never does.
        .library(name: "PlayerKitTestFixtures", targets: ["PlayerKitTestFixtures"]),
    ],
    targets: [
        // Tiny local C shim for acquire/release atomics (no third-party dependency).
        .target(name: "CAtomics"),
        .target(name: "AudioCore", dependencies: ["CAtomics"]),
        .testTarget(name: "AudioCoreTests", dependencies: ["AudioCore", "PlayerKitTestFixtures"]),
        // Generated, licence-clean audio files with real tags, shared by the test targets (#0195). Foundation only.
        .target(name: "PlayerKitTestFixtures", resources: [.copy("Audio")]),
        // Source-neutral protocol and models. Foundation only: MusicAssistantKit and the browser depend on it.
        .target(name: "MusicBackendKit"),
        .testTarget(name: "MusicBackendKitTests", dependencies: ["MusicBackendKit"]),
        // The "This Mac" output and the stack that builds it. Shared by the folder backend and, with #0066, Music Assistant's local playback.
        .target(name: "LocalPlayback", dependencies: ["MusicBackendKit", "AudioCore", "SendspinPlayback"]),
        .testTarget(name: "LocalPlaybackTests", dependencies: ["LocalPlayback", "MusicBackendKit", "AudioCore", "SendspinPlayback", "PlayerKitTestFixtures"]),
        // A local folder behind MusicBackend. Indexes Artist/Album/<tracks> with LocalTrackLoader; plays through LocalPlayback.
        .target(name: "FolderBackendKit", dependencies: ["MusicBackendKit", "LocalPlayback", "AudioCore"]),
        .testTarget(name: "FolderBackendKitTests", dependencies: ["FolderBackendKit", "MusicBackendKit", "LocalPlayback", "AudioCore", "PlayerKitTestFixtures"]),
        // Browser view models. Foundation + Observation; depends on the protocol only, never on a backend.
        .target(name: "LibraryBrowser", dependencies: ["MusicBackendKit", "MusicLibraryKit"]),
        // In-memory MusicBackend for tests of the browser and of anything that drives a backend.
        .target(name: "MusicBackendStub", dependencies: ["MusicBackendKit"]),
        .testTarget(name: "LibraryBrowserTests", dependencies: ["LibraryBrowser", "MusicBackendKit", "MusicBackendStub", "MusicLibraryKit", "PlayerKitTestFixtures"]),
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
        // The bridge from a Sendspin session to AudioCore's stream input (#0108). Built by LocalPlaybackStack.
        .target(name: "SendspinPlayback", dependencies: ["SendspinKit", "AudioCore"]),
        .testTarget(name: "SendspinPlaybackTests", dependencies: ["SendspinPlayback", "SendspinKit", "AudioCore"]),
    ]
)
