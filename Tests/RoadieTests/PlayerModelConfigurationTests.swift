import FolderBackendKit
import Foundation
import LibraryBrowser
import MusicAssistantKit
import MusicAssistantKitStub
import MusicBackendKit
import XCTest

@testable import Roadie

/// `RoadieConfiguration` (#0194): a test configuration builds `PlayerModel` with no Keychain, network or real disk.
@MainActor
final class PlayerModelConfigurationTests: XCTestCase {
    private var suiteNames: [String] = []
    private var folders: [URL] = []

    override func tearDown() async throws {
        for name in suiteNames { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        suiteNames = []
        folders = []
    }

    private func makeDefaults() -> UserDefaults {
        let name = "co.sstools.roadie.tests.\(UUID())"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "roadie-config-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folders.append(url)
        return url
    }

    private func testConfiguration(_ musicAssistant: RoadieConfiguration.MusicAssistantMode) throws -> RoadieConfiguration {
        let data = try makeFolder()
        var configuration = RoadieConfiguration()
        configuration.dataDirectory = data
        configuration.defaults = makeDefaults()
        configuration.musicAssistant = musicAssistant
        configuration.museum = .fixtures(skinsFolder: data.appending(path: "MuseumSkins", directoryHint: .isDirectory))
        configuration.discovery = false
        configuration.externalOpens = .record
        return configuration
    }

    /// What the real Application Support folder and the app's own real Caches folders (thumbnails, folder index, Museum)
    /// hold, with modification dates, to prove nothing was written there. The whole Caches folder isn't listed: the
    /// system keeps files of its own there for any app.
    private func realStorageListing() -> [String] {
        let caches = URL.cachesDirectory.appending(path: "co.sstools.roadie", directoryHint: .isDirectory)
        let folders = [URL.applicationSupportDirectory.appending(path: "co.sstools.roadie", directoryHint: .isDirectory)]
            + ["SkinThumbnails", "FolderIndex", "Museum"].map { caches.appending(path: $0, directoryHint: .isDirectory) }
        return folders.flatMap(listing(of:)).sorted()
    }

    private func listing(of folder: URL) -> [String] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return ["\(folder.path) missing"] }
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return "\(url.path) \(date?.timeIntervalSince1970 ?? 0)"
        }
    }

    /// The real defaults' value for every key a test-mode model or its views write (`@AppStorage` included).
    private static let watchedKeys = [
        QuitStop.defaultsKey, SettingsTab.defaultsKey, PlayerModel.museumShowsNSFWKey,
        "library.playlists.reorderCaptionDismissed", PlaylistsModel.recentTargetsKey, DiscoverModel.showAllKey,
        FolderBackend.folderDefaultsKey, LibrarySourceController.defaultsKey, SendspinController.enabledKey,
        PlayerModel.lastSkinKey, PlayerModel.equalizerKey, MusicAssistantServerStore.defaultsKey,
        FirstRunPolicy.defaultsKey, SkinLibraryModel.folderKey,
    ]

    private func standardSnapshot() -> [String] {
        Self.watchedKeys.map { "\($0)=\(String(describing: UserDefaults.standard.object(forKey: $0)))" }
    }

    func testModeTouchesNoKeychainOrNetwork() async throws {
        let model = PlayerModel(configuration: try testConfiguration(.scripted(scenario: "libraryIdle")))
        XCTAssertEqual(model.tokenStoreKind, "memory")
        try await model.musicAssistant.connect()
        let connected = await model.musicAssistant.isConnected
        XCTAssertTrue(connected)
        // Every socket came from #0197's server, and the handshake was answered by it: nothing reached URLSession.
        let server = try XCTUnwrap(model.scriptedMusicAssistant)
        XCTAssertEqual(server.scenario, .libraryIdle)
        XCTAssertFalse(server.transports.isEmpty)
        XCTAssertTrue(server.receivedCommands.contains { $0.command == "auth" })
        XCTAssertTrue(server.receivedCommands.allSatisfy { $0.command != "auth" || $0.args["token"]?.stringValue == "redacted" })
        // The seeded server is verified with the server id the scripted `/info` answers.
        model.musicAssistantSettings.appeared()
        let seeded = try XCTUnwrap(model.musicAssistantSettings.servers.first)
        XCTAssertEqual(model.musicAssistantSettings.servers.count, 1)
        XCTAssertEqual(seeded.address.baseURL, ScriptedMusicAssistant.serverURL)
        let info = try await MusicAssistantClient.serverInfo(at: ScriptedMusicAssistant.serverURL, http: server.http)
        XCTAssertEqual(seeded.address.serverID, info.serverID)
        XCTAssertTrue(server.http.requests.allSatisfy { $0.url.host() == "ma.example" })
        model.open(external: URL(string: "https://roadie.sstools.co/help.html")!)
        XCTAssertEqual(model.lastExternalOpen, URL(string: "https://roadie.sstools.co/help.html"))
    }

    func testDataDirectoryHoldsEveryStore() async throws {
        let before = realStorageListing()
        var configuration = try testConfiguration(.none)
        let skins = try makeFolder()
        configuration.defaults.set(skins.path, forKey: SkinLibraryModel.folderKey)
        let model = PlayerModel(configuration: configuration)
        let data = try XCTUnwrap(configuration.dataDirectory)
        XCTAssertEqual(model.queueFileURL.path, data.appending(path: "queue.json").path)
        model.saveQueueNow()
        model.flushQueue()
        _ = try await model.skinLibrary.openStoreIfNeeded()
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.appending(path: "queue.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.appending(path: "skins.sqlite").path))
        XCTAssertEqual(realStorageListing(), before)
        XCTAssertEqual(model.tokenStoreKind, "memory")
    }

    /// The review's finding 1: Settings › Library's folder model stores the folder in the configuration's defaults and
    /// removes index caches from its folder, so the backend (which reads the same suite) sees the choice.
    func testFolderSettingsUseTheConfiguration() async throws {
        let key = FolderBackend.folderDefaultsKey
        let realFolder = UserDefaults.standard.object(forKey: key) as? String
        let before = realStorageListing()
        let configuration = try testConfiguration(.none)
        let model = PlayerModel(configuration: configuration)
        XCTAssertNil(model.folderSettings.folderURL, "the empty suite has no folder, whatever the real defaults hold")

        let first = try makeFolder()
        model.folderSettings.choose(first)
        await model.folderSettings.waitForPending()
        XCTAssertNil(model.folderSettings.errorMessage)
        let connected = await model.folderBackend.isConnected
        XCTAssertTrue(connected, "the backend reads the folder from the same suite")
        XCTAssertEqual(configuration.defaults.string(forKey: key), first.path)

        // An index cache for the folder in the configuration's cache directory goes away with clear().
        let second = try makeFolder()
        model.folderSettings.choose(second)
        await model.folderSettings.waitForPending()
        let cache = FolderIndexCache.fileURL(for: second, in: configuration.folderIndexDirectory)
        try FileManager.default.createDirectory(at: configuration.folderIndexDirectory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: cache)
        model.folderSettings.clear()
        await model.folderSettings.waitForPending()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertNil(configuration.defaults.string(forKey: key))
        XCTAssertNil(model.folderSettings.folderURL)

        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? String, realFolder)
        XCTAssertEqual(realStorageListing(), before)
    }

    /// The review's finding 2: a test-mode model's typical writes land in its suite, never in `UserDefaults.standard`.
    func testModeWritesLeaveStandardDefaultsAlone() async throws {
        let before = standardSnapshot()
        let configuration = try testConfiguration(.scripted(scenario: "libraryIdle"))
        let recent = [MediaID(.playlist, "library://playlist/1")]
        configuration.defaults.set(try JSONEncoder().encode(recent), forKey: PlaylistsModel.recentTargetsKey)
        let model = PlayerModel(configuration: configuration)
        // The Library's playlists model (built by LibraryBrowserModel) reads the suite.
        XCTAssertEqual(model.library.playlistsModel.recentTargets, recent)
        XCTAssertTrue(configuration.defaults.object(forKey: MusicAssistantServerStore.defaultsKey) != nil)
        XCTAssertEqual(configuration.defaults.object(forKey: SendspinController.enabledKey) as? Bool, false)

        model.museumBrowser.showsNSFW = true
        XCTAssertTrue(configuration.defaults.bool(forKey: PlayerModel.museumShowsNSFWKey))
        XCTAssertTrue(model.sources.select("folder"))
        XCTAssertEqual(configuration.defaults.string(forKey: LibrarySourceController.defaultsKey), "folder")
        XCTAssertEqual(model.library.playlistsModel.recentTargets, recent, "a rebuilt browser reads the suite too")
        let folder = try makeFolder()
        model.folderSettings.choose(folder)
        await model.folderSettings.waitForPending()
        model.markFirstRunCompleted()
        XCTAssertNotNil(configuration.defaults.object(forKey: FirstRunPolicy.defaultsKey))
        // `QuitStop` is read from the suite: turned off there, nothing is stopped on quit.
        configuration.defaults.set(false, forKey: QuitStop.defaultsKey)
        XCTAssertNil(model.stopPlaybackForQuit())

        XCTAssertEqual(standardSnapshot(), before)
    }

    func testFromProcessReadsLaunchArguments() throws {
        let arguments = makeDefaults()
        arguments.set("1", forKey: "RoadieUITest")
        arguments.set("/tmp/x", forKey: "RoadieDataDir")
        arguments.set("queueLoaded", forKey: "RoadieMAScenario")
        arguments.set("1", forKey: "RoadieNoDiscovery")
        arguments.set("record", forKey: "RoadieExternalOpens")
        let configuration = RoadieConfiguration.fromProcess(arguments: arguments, hostedTestRun: false)
        XCTAssertTrue(configuration.isUITest)
        XCTAssertEqual(configuration.dataDirectory?.path, "/tmp/x")
        XCTAssertEqual(configuration.musicAssistant, .scripted(scenario: "queueLoaded"))
        XCTAssertFalse(configuration.discovery)
        XCTAssertEqual(configuration.externalOpens, .record)
        XCTAssertFalse(configuration.defaults === UserDefaults.standard)

        let stray = makeDefaults()
        stray.set("/tmp/x", forKey: "RoadieDataDir")
        stray.set("queueLoaded", forKey: "RoadieMAScenario")
        let normal = RoadieConfiguration.fromProcess(arguments: stray, hostedTestRun: false)
        XCTAssertNil(normal.dataDirectory)
        XCTAssertEqual(normal.musicAssistant, .live)
        XCTAssertFalse(normal.isUITest)
    }

    func testLiveConfigurationIsTheDefault() {
        let standard = RoadieConfiguration.standard
        XCTAssertEqual(standard.musicAssistant, .live)
        XCTAssertEqual(standard.museum, .live)
        XCTAssertTrue(standard.discovery)
        XCTAssertNil(standard.dataDirectory)
        XCTAssertTrue(standard.defaults === UserDefaults.standard)
        XCTAssertEqual(standard.externalOpens, .workspace)
        XCTAssertFalse(standard.isUITest)
        XCTAssertFalse(standard.isIsolated)
        // Isolation follows the Music Assistant mode and the defaults, not only the data directory.
        var scripted = RoadieConfiguration()
        scripted.musicAssistant = .scripted(scenario: "libraryIdle")
        XCTAssertTrue(scripted.isIsolated)
        var suite = RoadieConfiguration()
        suite.defaults = makeDefaults()
        XCTAssertTrue(suite.isIsolated)
    }

    /// #0193's review: the app hosting this bundle builds its model from the isolated configuration, not the live one.
    func testHostedRunUsesIsolatedConfiguration() throws {
        XCTAssertTrue(HostedTestRun.isActive)
        let hosted = RoadieConfiguration.fromProcess(arguments: makeDefaults(), hostedTestRun: true)
        XCTAssertNotNil(hosted.dataDirectory)
        XCTAssertEqual(hosted.musicAssistant, .none)
        XCTAssertFalse(hosted.discovery)

        let model = try XCTUnwrap(AppDelegate.current?.model)
        let configuration = model.configuration
        let data = try XCTUnwrap(configuration.dataDirectory)
        XCTAssertTrue(data.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        XCTAssertFalse(configuration.defaults === UserDefaults.standard)
        XCTAssertEqual(configuration.musicAssistant, .none)
        XCTAssertFalse(configuration.discovery)
        XCTAssertEqual(configuration.externalOpens, .record)
        XCTAssertEqual(model.tokenStoreKind, "memory")
        XCTAssertNil(model.scriptedMusicAssistant)
        XCTAssertTrue(model.queueFileURL.path.hasPrefix(data.path))
    }
}
