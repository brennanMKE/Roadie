import FolderBackendKit
import Foundation
import LocalPlayback
import SkinLibrary

/// What `PlayerModel` wires to (#0194): the real Keychain, network and disk (`.standard`), or the stubs each package
/// already has, for UI tests (launch arguments) and unit tests (built directly). Design: docs/design/test-automation.md §2.2.
struct RoadieConfiguration: @unchecked Sendable {
    enum MusicAssistantMode: Sendable, Equatable {
        case live
        /// A scripted server (`ScriptedMusicAssistant`) with one verified server and an in-memory token.
        case scripted(scenario: String)
        /// Music Assistant unconfigured, for folder-only tests. No Keychain and no network either.
        case none
    }

    enum MuseumMode: Sendable, Equatable {
        case live
        /// Recorded pages; downloads copy the file with that md5 from `skinsFolder`.
        case fixtures(skinsFolder: URL)
    }

    enum ExternalOpenMode: Sendable, Equatable { case workspace, record }

    /// nil: the real Application Support / Caches paths.
    var dataDirectory: URL? = nil
    var defaults: UserDefaults = .standard
    var musicAssistant: MusicAssistantMode = .live
    var museum: MuseumMode = .live
    /// Bonjour, Wi-Fi name, network events, wake notifications.
    var discovery = true
    var externalOpens: ExternalOpenMode = .workspace
    /// `-RoadieUITest 1`: the state probe (#0199) and test-only menu behaviour.
    var isUITest = false
    /// Reserved; not read yet (design §8).
    var silentOutput = false

    static let standard = RoadieConfiguration()

    /// The launch-argument keys (`-key value` lands in `NSArgumentDomain`, so `open --args` and
    /// `XCUIApplication.launchArguments` both work).
    enum Argument {
        static let uiTest = "RoadieUITest"
        static let dataDir = "RoadieDataDir"
        static let maScenario = "RoadieMAScenario"
        static let museum = "RoadieMuseum"
        static let museumSkins = "RoadieMuseumSkins"
        static let noDiscovery = "RoadieNoDiscovery"
        static let externalOpens = "RoadieExternalOpens"
    }

    /// Test mode switches on only with `-RoadieUITest 1` (a stray `-RoadieDataDir` alone does nothing), or when the
    /// app hosts the unit-test bundle (#0193), so `⌘U` on a dev Mac never touches the real defaults, stores,
    /// Keychain or network. Debug builds only: a Release build always returns `.standard`, since it doesn't ship the
    /// stubs' fixtures (project.yml strips them) and must not reach the test paths' `fatalError`s.
    static func fromProcess(
        arguments: UserDefaults = .standard, hostedTestRun: Bool = HostedTestRun.isActive
    ) -> RoadieConfiguration {
        #if !DEBUG
        return .standard
        #else
        guard arguments.bool(forKey: Argument.uiTest) else {
            return hostedTestRun ? .hostedUnitTests() : .standard
        }
        let data = arguments.string(forKey: Argument.dataDir).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Self.temporaryDirectory("RoadieUITest")
        var configuration = RoadieConfiguration()
        configuration.isUITest = true
        configuration.dataDirectory = data
        // A suite still reads `NSArgumentDomain`, so `-firstRunVersion 1` and friends reach it.
        configuration.defaults = Self.freshDefaults("co.sstools.roadie.uitest")
        configuration.musicAssistant = arguments.string(forKey: Argument.maScenario).map { .scripted(scenario: $0) } ?? .none
        if arguments.string(forKey: Argument.museum) == "fixtures" {
            let skins = arguments.string(forKey: Argument.museumSkins).map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? data.appending(path: "MuseumSkins", directoryHint: .isDirectory)
            configuration.museum = .fixtures(skinsFolder: skins)
        }
        configuration.discovery = !arguments.bool(forKey: Argument.noDiscovery)
        configuration.externalOpens = arguments.string(forKey: Argument.externalOpens) == "record" ? .record : .workspace
        return configuration
        #endif
    }

    /// The hosted unit-test run's host model (#0193 review): a temp data directory, a fresh defaults suite, Music
    /// Assistant unconfigured, no discovery, the fixture Museum and recorded external opens.
    static func hostedUnitTests() -> RoadieConfiguration {
        let data = temporaryDirectory("RoadieHostedTests")
        var configuration = RoadieConfiguration()
        configuration.dataDirectory = data
        configuration.defaults = freshDefaults("co.sstools.roadie.hostedtests")
        configuration.musicAssistant = .none
        configuration.museum = .fixtures(skinsFolder: data.appending(path: "MuseumSkins", directoryHint: .isDirectory))
        configuration.discovery = false
        configuration.externalOpens = .record
        return configuration
    }

    /// false only when the model may use the real Keychain and the user's defaults: Music Assistant `.live` (Keychain
    /// tokens, real servers) with `.standard` defaults. `LegacyDataCleanup` (a Keychain query and `.standard`) runs only
    /// then; any test configuration (in-memory tokens, or a defaults suite) is isolated.
    var isIsolated: Bool { musicAssistant != .live || defaults !== UserDefaults.standard }

    var queueFileURL: URL {
        dataDirectory.map { $0.appending(path: "queue.json", directoryHint: .notDirectory) } ?? QueueStore.defaultURL()
    }

    var skinsDatabaseURL: URL {
        dataDirectory.map { $0.appending(path: "skins.sqlite", directoryHint: .notDirectory) } ?? SkinIndexStore.defaultURL
    }

    var thumbnailsDirectory: URL {
        dataDirectory.map { $0.appending(path: "SkinThumbnails", directoryHint: .isDirectory) }
            ?? SkinThumbnailCache.defaultDirectory()
    }

    var folderIndexDirectory: URL {
        dataDirectory.map { $0.appending(path: "FolderIndex", directoryHint: .isDirectory) }
            ?? FolderIndexCache.defaultDirectory()
    }

    var museumCachesDirectory: URL {
        if let dataDirectory { return dataDirectory.appending(path: "Museum", directoryHint: .isDirectory) }
        return (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appending(path: "co.sstools.roadie/Museum", directoryHint: .isDirectory)
    }

    private static func temporaryDirectory(_ prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// An emptied suite, so every test launch starts from a fresh install.
    private static func freshDefaults(_ suite: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
