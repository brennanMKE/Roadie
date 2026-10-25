import AudioCore
import FolderBackendKit
import Foundation
import MusicAssistantKit
import MusicAssistantKitStub
import MusicBackendKit
import PlayerKitTestFixtures
import XCTest

@testable import Roadie

/// The base of #0211's model tests: every model gets an isolated `RoadieConfiguration` (a temp data directory and
/// defaults suite, no discovery, the fixture Museum, recorded external opens), so nothing reaches the real defaults,
/// stores, Keychain or network. Panels and pop-up menus are captured instead of shown.
@MainActor
class PlayerModelTestCase: XCTestCase {
    private var suiteNames: [String] = []
    private var folders: [URL] = []
    /// What `systemRequestOverride` captured, across every model this test built.
    var systemRequests: [PlayerModel.SystemRequest] = []
    /// What `PlaylistContextMenus.popUp` was asked to show (the last call last).
    var popUps: [(titles: [String?], enabled: Bool, items: [PlaylistContextMenus.Item?])] = []

    override func setUp() async throws {
        PlaylistContextMenus.popUpOverride = { [weak self] items, enabled in
            self?.popUps.append((items.map { $0?.title }, enabled, items))
        }
    }

    override func tearDown() async throws {
        PlaylistContextMenus.popUpOverride = nil
        for name in suiteNames { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        suiteNames = []
        folders = []
        systemRequests = []
        popUps = []
    }

    /// A fresh temp directory, removed in `tearDown`.
    func temporaryDirectory(_ prefix: String = "roadie-model") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(prefix)-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folders.append(url)
        return url
    }

    /// An isolated configuration; pass `dataDirectory` and `defaults` to share them (a second model on the same disk).
    func testConfiguration(
        _ musicAssistant: RoadieConfiguration.MusicAssistantMode = .none,
        dataDirectory: URL? = nil, defaults: UserDefaults? = nil
    ) throws -> RoadieConfiguration {
        let data = try dataDirectory ?? temporaryDirectory("roadie-data")
        var configuration = RoadieConfiguration()
        configuration.dataDirectory = data
        if let defaults {
            configuration.defaults = defaults
        } else {
            let suite = "co.sstools.roadie.tests.model.\(UUID())"
            suiteNames.append(suite)
            configuration.defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        }
        configuration.musicAssistant = musicAssistant
        configuration.museum = .fixtures(skinsFolder: data.appending(path: "MuseumSkins", directoryHint: .isDirectory))
        configuration.discovery = false
        configuration.externalOpens = .record
        return configuration
    }

    /// A model on `scenario` (nil: Music Assistant unconfigured), with #0195's fixture music folder when `folder`.
    func makeModel(scenario: ScriptedMusicAssistant.Scenario? = nil, folder: Bool = false) throws -> PlayerModel {
        let configuration = try testConfiguration(scenario.map { .scripted(scenario: $0.rawValue) } ?? .none)
        if folder {
            let root = try temporaryDirectory("roadie-music")
            try AudioFixtures.makeLibrary(at: root)
            configuration.defaults.set(root.path, forKey: FolderBackend.folderDefaultsKey)
        }
        return makeModel(configuration)
    }

    func makeModel(_ configuration: RoadieConfiguration) -> PlayerModel {
        let model = PlayerModel(configuration: configuration)
        model.systemRequestOverride = { [weak self] in self?.systemRequests.append($0) }
        return model
    }

    /// Polls `condition` every 20 ms until it holds or `timeout` passes.
    func waitUntil(
        _ description: String, timeout: Duration = .seconds(5),
        file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("timed out waiting for \(description)", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The scripted server's command names, in order.
    func commands(_ server: ScriptedMusicAssistant) -> [String] { server.receivedCommands.map(\.command) }

    /// The scripted speaker, once Music Assistant is connected and the outputs are refreshed.
    func connectedSpeaker(_ model: PlayerModel) async throws -> OutputDevice.ID {
        var connected = false
        for _ in 0..<100 {
            connected = await model.musicAssistant.isConnected
            if connected { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(connected, "Music Assistant never connected")
        await model.refreshOutputs()
        return OutputDevice.ID(rawValue: ScriptedMusicAssistant.speakerID)
    }

    /// Selects the scripted speaker and waits for its queue rows.
    @discardableResult
    func selectSpeakerWithQueue(_ model: PlayerModel) async throws -> OutputDevice.ID {
        let speaker = try await connectedSpeaker(model)
        model.selectOutput(speaker)
        try await waitUntil("the speaker's queue rows") { (model.playlist.remote?.items.count ?? 0) > 3 }
        return speaker
    }

    /// Selects the folder source, indexes the fixture folder and returns its albums. Without Music Assistant the
    /// source fallback has usually switched to the folder already, and `select` returns false for the current source.
    func folderAlbums(_ model: PlayerModel) async throws -> [LibraryAlbum] {
        let folder = model.folderBackend.sourceID
        if model.sources.selectedID != folder {
            XCTAssertTrue(model.sources.select(folder, persist: false))
        }
        XCTAssertEqual(model.sources.selectedID, folder)
        try await model.folderBackend.connect()
        await model.folderBackend.waitForIndexing()
        return try await model.folderBackend.albums(of: nil, page: PageRequest()).items
    }

    /// Three 2:30 tracks (no files behind them) restored stopped with `current` selected.
    func restoreThreeTracks(_ model: PlayerModel, current: Int = 0) {
        model.player.clearQueue()
        let tracks = ["A", "B", "C"].map {
            Track(
                title: "Tone \($0)", artist: "Tone Artist", duration: 150,
                source: .file(URL(fileURLWithPath: "/nonexistent/Tone \($0).mp3")))
        }
        model.player.restoreQueue(tracks, currentIndex: current, repeatMode: .off, isShuffled: false)
    }

    /// A one-sheet `.wsz` (main.bmp only; the parser fills the other sheets from its generated base).
    func makeSkin(named name: String = "Test Skin") throws -> URL {
        let dir = try temporaryDirectory("roadie-skin")
        let content = dir.appending(path: "content", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try Self.bmp(width: 275, height: 116).write(to: content.appending(path: "main.bmp"))
        let wsz = dir.appending(path: "\(name).wsz")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", content.path, wsz.path]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        return wsz
    }

    /// A 24-bit bottom-up BMP filled with one colour.
    static func bmp(width: Int, height: Int) -> Data {
        let rowSize = (width * 3 + 3) & ~3
        let pixels = rowSize * height
        var data = Data([0x42, 0x4D])
        func le32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { data.append(contentsOf: $0) } }
        le32(54 + pixels); le32(0); le32(54)
        le32(40); le32(width); le32(height); le16(1); le16(24); le32(0); le32(pixels); le32(2835); le32(2835); le32(0); le32(0)
        var row = [UInt8](repeating: 0, count: rowSize)
        for x in 0..<width { row[x * 3] = 0x40; row[x * 3 + 1] = 0x80; row[x * 3 + 2] = 0xC0 }
        for _ in 0..<height { data.append(contentsOf: row) }
        return data
    }
}
