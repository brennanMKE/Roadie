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
    /// `-RoadieWindowLayout column` (#0200): main, equalizer and playlist stacked top-left in a column, ignoring any
    /// saved layout, and the Library, Skins and Jump to File windows moved off that column when they come forward, so
    /// no window covers another's controls in UI tests.
    var columnWindowLayout = false
    /// `-RoadieVolume N` (#0200): the player's volume at launch, 0...100 percent, so tests know the slider's value.
    var launchVolume: Float?
    /// `-RoadieMuseumFeatured <name>` (#0208): the fixture Museum's browse page leads with `<name>.wsz` from its skins
    /// folder (`FixtureMuseumTransport.featuredSkin`).
    var museumFeaturedSkin: String?
    /// `-RoadieVisRenderer classic|milk` (#0235, Debug): the visualization window's renderer. Release ignores it.
    var visRenderer: String?
    /// `-RoadieVisSeed N` (#0235, Debug): the preset navigator's random seed; else random. Release ignores it.
    var visSeed: UInt64?
    /// `-RoadieVisFullScreen borderless` (#0237, Debug): full screen is a screen-sized borderless window instead of a
    /// Space. Release ignores it.
    var visFullScreenBorderless = false
    /// `-RoadieVisAutoAdvance <seconds>` (#0236, Debug): the auto-advance interval, not varied. Release ignores it.
    var visAutoAdvance: TimeInterval?
    /// `-RoadieVisPresetsFolder <path>` (#0241, Debug): the presets folder at launch and Choose…'s answer.
    var visPresetsFolder: String?
    /// `-RoadieVisSeedPresets N` (#0241, Debug): N tiny `.milk` files written to that folder at launch.
    var visSeedPresets: Int?

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
        static let windowLayout = "RoadieWindowLayout"
        static let volume = "RoadieVolume"
        static let museumFeatured = "RoadieMuseumFeatured"
        static let seedSkins = "RoadieSeedSkins"
        static let seedSkinsOmit = "RoadieSeedSkinsOmit"
        static let visRenderer = "RoadieVisRenderer"
        static let visSeed = "RoadieVisSeed"
        static let visFullScreen = "RoadieVisFullScreen"
        static let visAutoAdvance = "RoadieVisAutoAdvance"
        static let visPresetsFolder = "RoadieVisPresetsFolder"
        static let visSeedPresets = "RoadieVisSeedPresets"
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
            var configuration = hostedTestRun ? Self.hostedUnitTests() : Self.standard
            configuration.readVisualizationArguments(arguments)
            return configuration
        }
        let data = arguments.string(forKey: Argument.dataDir).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Self.temporaryDirectory("RoadieUITest")
        // The XCUITest runner is sandboxed (read-only outside its container), so the app makes its own directories.
        try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        seedSkinsFolder(arguments: arguments)
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
            configuration.museumFeaturedSkin = arguments.string(forKey: Argument.museumFeatured)
        }
        configuration.discovery = !arguments.bool(forKey: Argument.noDiscovery)
        configuration.externalOpens = arguments.string(forKey: Argument.externalOpens) == "record" ? .record : .workspace
        configuration.columnWindowLayout = arguments.string(forKey: Argument.windowLayout) == "column"
        if arguments.object(forKey: Argument.volume) != nil {
            configuration.launchVolume = min(max(Float(arguments.integer(forKey: Argument.volume)) / 100, 0), 1)
        }
        configuration.readVisualizationArguments(arguments)
        return configuration
        #endif
    }

    #if DEBUG
    private mutating func readVisualizationArguments(_ arguments: UserDefaults) {
        visRenderer = arguments.string(forKey: Argument.visRenderer)
        visSeed = arguments.string(forKey: Argument.visSeed).flatMap { UInt64($0) }
        visFullScreenBorderless = arguments.string(forKey: Argument.visFullScreen) == "borderless"
        visAutoAdvance = arguments.string(forKey: Argument.visAutoAdvance).flatMap { TimeInterval($0) }.flatMap {
            $0 > 0 && $0.isFinite ? $0 : nil
        }
        visPresetsFolder = arguments.string(forKey: Argument.visPresetsFolder).flatMap { $0.isEmpty ? nil : $0 }
        visSeedPresets = arguments.string(forKey: Argument.visSeedPresets).flatMap { Int($0) }
    }
    #endif

    /// `-RoadieSeedSkins <folder>` with `-skinsFolderPath <copy>` (#0208): the copy is emptied and gets the folder's
    /// top-level `.wsz` files, except the names (without `.wsz`) listed comma-separated in `-RoadieSeedSkinsOmit`, so a
    /// UI test can trash or download skins. The app does it because the sandboxed test runner can't write there.
    private static func seedSkinsFolder(arguments: UserDefaults) {
        guard let source = arguments.string(forKey: Argument.seedSkins),
            let copy = arguments.string(forKey: "skinsFolderPath")  // SkinLibraryModel.folderKey (main-actor)
        else { return }
        let omit = Set((arguments.string(forKey: Argument.seedSkinsOmit) ?? "").split(separator: ",").map { "\($0).wsz" })
        let fm = FileManager.default
        try? fm.removeItem(atPath: copy)
        do {
            try fm.createDirectory(atPath: copy, withIntermediateDirectories: true)
            for name in try fm.contentsOfDirectory(atPath: source)
            where name.lowercased().hasSuffix(".wsz") && !omit.contains(name) {
                let target = (copy as NSString).appendingPathComponent(name)
                try fm.copyItem(atPath: (source as NSString).appendingPathComponent(name), toPath: target)
                try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target)
            }
        } catch {
            print("[RoadieSeedSkins] couldn't copy \(source) to \(copy): \(error)")
        }
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
