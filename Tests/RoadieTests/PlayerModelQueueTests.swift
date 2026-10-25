import AudioCore
import Foundation
import LibraryBrowser
import MusicAssistantKit
import MusicAssistantKitStub
import MusicBackendKit
import XCTest

@testable import Roadie

/// LIST › Load, Save Queue, Library plays and queue persistence through `PlayerModel` (#0211).
@MainActor
final class PlayerModelQueueTests: PlayerModelTestCase {
    /// #0190: the shown queue decides what LIST › Load offers.
    func testLoadListChoosesByTarget() async throws {
        // The local queue without Music Assistant, on the folder source.
        let local = try makeModel(folder: true)
        _ = try await folderAlbums(local)
        XCTAssertFalse(local.canLoadLibraryPlaylist, "the folder backend has no playlists")
        local.loadList()
        XCTAssertEqual(systemRequests.last, .openPlaylistFile)
        XCTAssertTrue(popUps.isEmpty)

        // The local queue with the Library on Music Assistant: both choices.
        popUps = []
        systemRequests = []
        let model = try makeModel(scenario: .queueLoaded)
        XCTAssertEqual(model.sources.selectedID, model.musicAssistant.sourceID)
        XCTAssertTrue(model.canLoadLibraryPlaylist)
        model.loadList()
        let menu = try XCTUnwrap(popUps.last)
        XCTAssertEqual(menu.titles, ["Library Playlist\u{2026}", "Playlist File\u{2026}"])
        XCTAssertTrue(menu.enabled)
        menu.items[1]?.action()
        XCTAssertEqual(systemRequests.last, .openPlaylistFile)
        menu.items[0]?.action()
        XCTAssertTrue(model.isPickingPlaylist)

        // A remote queue: straight to the picker.
        model.isPickingPlaylist = false
        try await selectSpeakerWithQueue(model)
        let shown = popUps.count
        model.loadList()
        XCTAssertTrue(model.isPickingPlaylist)
        XCTAssertTrue(model.isPlaylistWindowOpen)
        XCTAssertEqual(popUps.count, shown)
    }

    func testPickLibraryPlaylistOpensTheEditorAndPicker() throws {
        let model = try makeModel(scenario: .libraryIdle)
        XCTAssertFalse(model.isPlaylistWindowOpen)
        model.pickLibraryPlaylist()
        XCTAssertTrue(model.isPlaylistWindowOpen)
        XCTAssertTrue(model.isPickingPlaylist)
    }

    func testLoadPlaylistPlaysThroughTheLibrary() async throws {
        let model = try makeModel(scenario: .queueLoaded)
        let server = try XCTUnwrap(model.scriptedMusicAssistant)
        try await selectSpeakerWithQueue(model)
        let playlists = try await model.musicAssistant.playlists(page: PageRequest()).items
        let playlist = try XCTUnwrap(playlists.first, "the recording has playlists")
        model.loadPlaylist(playlist)
        try await waitUntil("play_media") { self.commands(server).contains("player_queues/play_media") }
        let sent = try XCTUnwrap(server.receivedCommands.last { $0.command == "player_queues/play_media" })
        let media = (sent.args["media"]?.arrayValue ?? []).compactMap(\.stringValue)
        XCTAssertEqual(media, [playlist.id.rawValue])
    }

    func testSaveQueueTargets() async throws {
        let local = try makeModel()
        XCTAssertTrue(local.canSaveQueue, "the local queue saves to a file")
        let model = try makeModel(scenario: .queueLoaded)
        try await selectSpeakerWithQueue(model)
        XCTAssertTrue(model.canSaveQueue, "a Music Assistant queue saves as its playlist")
    }

    func testPlayFromLibraryOnTheFolderBackend() async throws {
        let model = try makeModel(folder: true)
        let albums = try await folderAlbums(model)
        let album = try XCTUnwrap(albums.first { $0.title == "Tone Album" })
        let two = try XCTUnwrap(albums.first { $0.title == "Singles" })
        model.playFromLibrary(.play(container: album.id))
        try await waitUntil("the album in the local queue") { model.player.queue.tracks.count == 3 }
        XCTAssertEqual(model.player.queue.tracks.map(\.title), ["Tone A", "Tone B", "Tone C"])
        XCTAssertTrue(model.playsLocalQueue)
        model.stop()

        model.playFromLibrary(.next(container: two.id))
        try await waitUntil("up next") { model.player.queue.tracks.count == 4 }
        XCTAssertEqual(model.player.queue.tracks.filter { $0.title == "Tone C" }.count, 2)

        model.playFromLibrary(.append(container: two.id))
        try await waitUntil("appended") { model.player.queue.tracks.count == 5 }
        XCTAssertEqual(model.player.queue.tracks.last?.title, "Tone C")
        model.stop()
    }

    func testPlayFromLibraryOnMusicAssistant() async throws {
        let model = try makeModel(scenario: .queueLoaded)
        let server = try XCTUnwrap(model.scriptedMusicAssistant)
        try await selectSpeakerWithQueue(model)
        let albums = try await model.musicAssistant.albums(of: nil, page: PageRequest()).items
        let album = try XCTUnwrap(albums.first)
        model.playFromLibrary(.play(container: album.id))
        try await waitUntil("play_media") { self.commands(server).contains("player_queues/play_media") }
        let sent = try XCTUnwrap(server.receivedCommands.last { $0.command == "player_queues/play_media" })
        XCTAssertEqual((sent.args["media"]?.arrayValue ?? []).compactMap(\.stringValue), [album.id.rawValue])
    }

    func testQueuePersistsAcrossModels() throws {
        let configuration = try testConfiguration()
        let first = makeModel(configuration)
        restoreThreeTracks(first, current: 2)
        first.flushQueue()
        let second = makeModel(
            try testConfiguration(dataDirectory: configuration.dataDirectory, defaults: configuration.defaults))
        XCTAssertEqual(second.player.queue.tracks.map(\.title), ["Tone A", "Tone B", "Tone C"])
        XCTAssertEqual(second.player.queue.currentIndex, 2)
        XCTAssertEqual(second.player.state, .stopped)
    }

    /// #0187 at the model level: the row is the queue position.
    func testPlayRemoteQueueRowSendsPlayIndex() async throws {
        let model = try makeModel(scenario: .queueLoaded)
        let server = try XCTUnwrap(model.scriptedMusicAssistant)
        try await selectSpeakerWithQueue(model)
        model.playlist.playRow(3)
        try await waitUntil("play_index") { server.receivedCommands.last?.command == "player_queues/play_index" }
        XCTAssertEqual(server.receivedCommands.last?.args["index"]?.intValue, 3)
    }
}
