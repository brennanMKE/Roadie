import AudioCore
import FolderBackendKit
import Foundation
import MusicAssistantKit
import MusicAssistantKitStub
import MusicBackendKit
import PlayerKitTestFixtures
import XCTest

@testable import Roadie

/// `PlayerModel.dropLibraryItems` (#0188's SwiftUI fallback, #0210): a Library drop on the playlist window
/// goes to the selected output's backend at the end of the queue. Built from isolated test configurations (#0194): the
/// folder backend on #0195's fixture library in a temp folder, or the scripted Music Assistant (#0197). Nothing plays:
/// the local queue already holds tracks, so an insert never starts playback.
@MainActor
final class PlayerModelDropTests: XCTestCase {
    private var suiteNames: [String] = []
    private var folders: [URL] = []
    private var models: [PlayerModel] = []

    override func tearDown() async throws {
        for model in models { model.player.stop() }
        for name in suiteNames { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        suiteNames = []
        folders = []
        models = []
    }

    private func makeFolder(_ prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(prefix)-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folders.append(url)
        return url
    }

    private func makeModel(_ musicAssistant: RoadieConfiguration.MusicAssistantMode) throws -> PlayerModel {
        let data = try makeFolder("roadie-drop")
        let suite = "co.sstools.roadie.tests.drop.\(UUID())"
        suiteNames.append(suite)
        var configuration = RoadieConfiguration()
        configuration.dataDirectory = data
        configuration.defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        configuration.musicAssistant = musicAssistant
        configuration.museum = .fixtures(skinsFolder: data.appending(path: "MuseumSkins", directoryHint: .isDirectory))
        configuration.discovery = false
        configuration.externalOpens = .record
        let model = PlayerModel(configuration: configuration)
        models.append(model)
        return model
    }

    /// Polls `condition` every 20 ms for up to `seconds`.
    private func waitUntil(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// Selects the scripted Music Assistant source, then connects and waits until connected. Selecting the source
    /// after `connect()` starts a second connection, and a drop while that one was still authenticating failed with
    /// "Can't reach the Music Assistant server" (run 20261027-173236-61397, #0228 Gotchas).
    private func connectMusicAssistant(_ model: PlayerModel) async throws {
        model.sources.select(model.musicAssistant.sourceID)
        try await model.musicAssistant.connect()
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline, !(await model.musicAssistant.isConnected) {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.backend.sourceID, model.musicAssistant.sourceID)
    }

    func testAppendDroppedLibraryItemsAppendsAtTheEnd() async throws {
        let model = try makeModel(.none)
        model.player.clearQueue()
        let existing = ["X", "Y", "Z"].map {
            Track(title: "Old \($0)", artist: "Old", duration: 60, source: .file(URL(fileURLWithPath: "/nonexistent/roadie-tests/\($0).mp3")))
        }
        model.player.restoreQueue(existing, currentIndex: nil, repeatMode: .off, isShuffled: false)

        let library = try makeFolder("roadie-drop-library")
        try AudioFixtures.makeLibrary(at: library)
        model.sources.select("folder")
        model.folderSettings.choose(library)
        await model.folderSettings.waitForPending()
        try await model.folderBackend.connect()
        XCTAssertEqual(model.backend.sourceID, "folder")

        let album = MediaID(.album, "\(AudioFixtures.artist)/\(AudioFixtures.album)")
        XCTAssertTrue(model.dropLibraryItems([MediaIDTransfer([album])], replacing: false))
        let arrived = await waitUntil { model.player.queue.tracks.count == 6 }
        XCTAssertTrue(arrived, "queue: \(model.player.queue.tracks.map(\.title))")
        XCTAssertEqual(
            model.playlist.tracks.map(\.title), ["Old X", "Old Y", "Old Z", "Tone A", "Tone B", "Tone C"])
        XCTAssertEqual(model.player.state, .stopped, "an insert into a non-empty queue doesn't play")
        XCTAssertFalse(model.dropLibraryItems([MediaIDTransfer([])], replacing: false), "an empty drop is refused")
    }

    func testDropOnAMusicAssistantQueueAppends() async throws {
        let model = try makeModel(.scripted(scenario: "libraryIdle"))
        let server = try XCTUnwrap(model.scriptedMusicAssistant)
        try await connectMusicAssistant(model)
        XCTAssertEqual(model.backend.sourceID, model.musicAssistant.sourceID)
        model.selectedOutput = OutputDevice.ID(rawValue: ScriptedMusicAssistant.speakerID)

        let album = MediaID(.album, "library://album/27")
        XCTAssertTrue(model.dropLibraryItems([MediaIDTransfer([album])], replacing: false))
        let sent = await waitUntil { server.receivedCommands.contains { $0.command == "player_queues/play_media" } }
        XCTAssertTrue(sent, "\(server.recentCommandSummaries())")
        let play = try XCTUnwrap(server.receivedCommands.last { $0.command == "player_queues/play_media" })
        XCTAssertEqual(play.args["option"]?.stringValue, "add")
        XCTAssertEqual((play.args["media"]?.arrayValue ?? []).compactMap(\.stringValue), ["library://album/27"])
        XCTAssertEqual(play.args["queue_id"]?.stringValue, ScriptedMusicAssistant.speakerID)
    }

    // MARK: ⌥-drop replaces (#0228)

    private func oldTracks() -> [Track] {
        ["X", "Y", "Z"].map {
            Track(title: "Old \($0)", artist: "Old", duration: 60, source: .file(URL(fileURLWithPath: "/nonexistent/roadie-tests/\($0).mp3")))
        }
    }

    func testOptionDropReplacesTheLocalQueue() async throws {
        let model = try makeModel(.none)
        model.player.clearQueue()
        model.player.restoreQueue(oldTracks(), currentIndex: nil, repeatMode: .off, isShuffled: false)
        let library = try makeFolder("roadie-drop-library")
        try AudioFixtures.makeLibrary(at: library)
        model.sources.select("folder")
        model.folderSettings.choose(library)
        await model.folderSettings.waitForPending()
        try await model.folderBackend.connect()

        let album = MediaID(.album, "\(AudioFixtures.artist)/\(AudioFixtures.album)")
        model.dropLibraryItems([album], at: 1, replacing: true)
        let replaced = await waitUntil { model.playlist.tracks.map(\.title) == ["Tone A", "Tone B", "Tone C"] }
        XCTAssertTrue(replaced, "queue: \(model.playlist.tracks.map(\.title))")
        let playing = await waitUntil { model.player.state == .playing }
        XCTAssertTrue(playing, "state: \(model.player.state)")
        XCTAssertEqual(model.player.queue.currentIndex, 0)
    }

    func testOptionDropOnAMusicAssistantQueueReplaces() async throws {
        let model = try makeModel(.scripted(scenario: "libraryIdle"))
        let server = try XCTUnwrap(model.scriptedMusicAssistant)
        try await connectMusicAssistant(model)
        model.selectedOutput = OutputDevice.ID(rawValue: ScriptedMusicAssistant.speakerID)

        let album = MediaID(.album, "library://album/27")
        model.dropLibraryItems([album], at: 0, replacing: true)
        let sent = await waitUntil { server.receivedCommands.contains { $0.command == "player_queues/play_media" } }
        XCTAssertTrue(sent, "\(server.recentCommandSummaries())")
        let play = try XCTUnwrap(server.receivedCommands.last { $0.command == "player_queues/play_media" })
        XCTAssertEqual(play.args["option"]?.stringValue, "replace")
        XCTAssertEqual((play.args["media"]?.arrayValue ?? []).compactMap(\.stringValue), ["library://album/27"])
        XCTAssertEqual(play.args["queue_id"]?.stringValue, ScriptedMusicAssistant.speakerID)
    }

    /// The path a ⌥ file drop takes: `open(urls, replace: true)` clears the list and plays the first file.
    func testOptionDropOfFilesReplacesAndPlays() async throws {
        let model = try makeModel(.none)
        model.player.clearQueue()
        model.player.restoreQueue(oldTracks(), currentIndex: nil, repeatMode: .off, isShuffled: false)
        let library = try makeFolder("roadie-drop-files")
        try AudioFixtures.makeLibrary(at: library)
        let album = library.appending(path: "\(AudioFixtures.artist)/\(AudioFixtures.album)", directoryHint: .isDirectory)

        XCTAssertTrue(model.open([album], replace: true))
        let replaced = await waitUntil { model.playlist.tracks.map(\.title) == ["Tone A", "Tone B", "Tone C"] }
        XCTAssertTrue(replaced, "queue: \(model.playlist.tracks.map(\.title))")
        let playing = await waitUntil { model.player.state == .playing }
        XCTAssertTrue(playing, "state: \(model.player.state)")
    }

    /// A ⌥ file drop while a speaker is selected is refused like any local-files drop (#0084): nothing is cleared.
    func testOptionDropOfFilesOnASpeakerKeepsTheQueue() async throws {
        let model = try makeModel(.scripted(scenario: "libraryIdle"))
        try await connectMusicAssistant(model)
        model.selectedOutput = OutputDevice.ID(rawValue: ScriptedMusicAssistant.speakerID)
        model.player.clearQueue()
        model.player.restoreQueue(oldTracks(), currentIndex: nil, repeatMode: .off, isShuffled: false)
        let library = try makeFolder("roadie-drop-files")
        try AudioFixtures.makeLibrary(at: library)

        _ = model.open([library], replace: true)
        XCTAssertNotNil(model.notice, "no refusal notice")
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.player.queue.tracks.map(\.title), ["Old X", "Old Y", "Old Z"])
    }

    /// The SwiftUI fallback (title bar, bottom bar, shade) with ⌥ held replaces too.
    func testOptionDropOnTheWindowFallbackReplaces() async throws {
        let model = try makeModel(.none)
        model.player.clearQueue()
        model.player.restoreQueue(oldTracks(), currentIndex: nil, repeatMode: .off, isShuffled: false)
        let library = try makeFolder("roadie-drop-library")
        try AudioFixtures.makeLibrary(at: library)
        model.sources.select("folder")
        model.folderSettings.choose(library)
        await model.folderSettings.waitForPending()
        try await model.folderBackend.connect()

        let album = MediaID(.album, "\(AudioFixtures.artist)/\(AudioFixtures.album)")
        XCTAssertTrue(model.dropLibraryItems([MediaIDTransfer([album])], replacing: true))
        let replaced = await waitUntil { model.playlist.tracks.map(\.title) == ["Tone A", "Tone B", "Tone C"] }
        XCTAssertTrue(replaced, "queue: \(model.playlist.tracks.map(\.title))")
    }

    /// The fallback on a Music Assistant queue.
    func testOptionDropOnAMusicAssistantWindowFallbackReplaces() async throws {
        let model = try makeModel(.scripted(scenario: "libraryIdle"))
        let server = try XCTUnwrap(model.scriptedMusicAssistant)
        try await connectMusicAssistant(model)
        model.selectedOutput = OutputDevice.ID(rawValue: ScriptedMusicAssistant.speakerID)

        let album = MediaID(.album, "library://album/27")
        XCTAssertTrue(model.dropLibraryItems([MediaIDTransfer([album])], replacing: true))
        let sent = await waitUntil { server.receivedCommands.contains { $0.command == "player_queues/play_media" } }
        XCTAssertTrue(sent, "\(server.recentCommandSummaries()); notice: \(model.notice?.text ?? "none")")
        let play = try XCTUnwrap(server.receivedCommands.last { $0.command == "player_queues/play_media" })
        XCTAssertEqual(play.args["option"]?.stringValue, "replace")
        XCTAssertEqual(play.args["queue_id"]?.stringValue, ScriptedMusicAssistant.speakerID)
    }
}
