import AudioCore
import Foundation
import LibraryBrowser
import MusicAssistantKit
import MusicAssistantKitStub
import MusicBackendKit
import XCTest

@testable import Roadie

/// Add to Playlist and the favourites through `PlayerModel` (#0215): the scripted Music Assistant server for the
/// paths that reach a backend, the folder backend (no playlists, no favourites) for the refusals.
@MainActor
final class LibraryPlaylistActionsTests: PlayerModelTestCase {
    /// A Music Assistant model, connected, and two track ids: the recording's first album track, and a second id in
    /// the same `library://track/` form (the recording has one album track; the scripted server takes any uri).
    private func connectedModel(_ scenario: ScriptedMusicAssistant.Scenario = .libraryIdle) async throws
        -> (PlayerModel, ScriptedMusicAssistant, [MediaID])
    {
        let model = try makeModel(scenario: scenario)
        let server = try XCTUnwrap(model.scriptedMusicAssistant)
        var connected = false
        for _ in 0..<100 {
            connected = await model.musicAssistant.isConnected
            if connected { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(connected, "Music Assistant never connected")
        XCTAssertEqual(model.backend.sourceID, model.musicAssistant.sourceID)
        let albums = try await model.backend.albums(of: nil, page: PageRequest()).items
        var tracks: [LibraryTrack] = []
        for album in albums where tracks.isEmpty {
            tracks += try await model.backend.tracks(of: album.id)
        }
        let first = try XCTUnwrap(tracks.first, "the recording has no album tracks")
        return (model, server, [first.id, MediaID(.track, "library://track/synthetic-2")])
    }

    /// A folder-backend model (nothing to edit or favourite) and one of its tracks.
    private func folderModel() async throws -> (PlayerModel, LibraryTrack) {
        let model = try makeModel(folder: true)
        let albums = try await folderAlbums(model)
        let album = try XCTUnwrap(albums.first)
        let tracks = try await model.folderBackend.tracks(of: album.id)
        let track = try XCTUnwrap(tracks.first)
        return (model, track)
    }

    private func sent(_ server: ScriptedMusicAssistant, _ command: String) -> [SentRequest] {
        server.receivedCommands.filter { $0.command == command }
    }

    func testAddToPlaylistSendsItems() async throws {
        let (model, server, tracks) = try await connectedModel()
        let playlist = try await model.backend.createPlaylist(named: "Road Trip")
        let ids = tracks
        model.addToPlaylist(ids, playlist)
        try await waitUntil("the add") { !self.sent(server, "music/playlists/add_playlist_tracks").isEmpty }
        let add = try XCTUnwrap(sent(server, "music/playlists/add_playlist_tracks").last)
        XCTAssertEqual(add.args["db_playlist_id"]?.stringValue, playlist.libraryID ?? playlist.id.rawValue)
        XCTAssertEqual((add.args["uris"]?.arrayValue ?? []).compactMap(\.stringValue), ids.map(\.rawValue))
        try await waitUntil("the notice") { model.notice?.text == "Added 2 tracks to Road Trip" }
        XCTAssertEqual(model.library.playlistsModel.recentTargets.first, playlist.id)
        XCTAssertNil(model.library.playlistsModel.message)
    }

    func testCreatePlaylistThenAdds() async throws {
        let (model, server, tracks) = try await connectedModel()
        model.createPlaylist(named: "  Night Drive  ", adding: [tracks[0]])
        try await waitUntil("the add") { !self.sent(server, "music/playlists/add_playlist_tracks").isEmpty }
        let commands = commands(server)
        let create = try XCTUnwrap(commands.firstIndex(of: "music/playlists/create_playlist"))
        let add = try XCTUnwrap(commands.firstIndex(of: "music/playlists/add_playlist_tracks"))
        XCTAssertLessThan(create, add, "created, then filled")
        XCTAssertEqual(sent(server, "music/playlists/create_playlist").last?.args["name"]?.stringValue, "Night Drive")
        try await waitUntil("the notice") { model.notice?.text == "Added 1 track to Night Drive" }

        // Nothing to add: created, no notice.
        model.clearNotice()
        model.createPlaylist(named: "Empty", adding: [])
        try await waitUntil("the second create") { self.sent(server, "music/playlists/create_playlist").count == 2 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(model.notice)
        XCTAssertNil(model.library.playlistsModel.message)
        XCTAssertEqual(sent(server, "music/playlists/add_playlist_tracks").count, 1)
    }

    func testAddToPlaylistUnsupportedShowsNotice() async throws {
        let (model, track) = try await folderModel()
        XCTAssertFalse(model.library.playlistsModel.canEdit)

        // New Playlist… creates nothing and says nothing (the launch's "Using Local Folder" notice may be up).
        let before = model.notice
        model.createPlaylist(named: "Nope", adding: [track.id])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.notice == nil || model.notice == before, "\(String(describing: model.notice))")
        XCTAssertNil(model.library.playlistsModel.message)
        XCTAssertTrue(model.library.playlistsModel.recentTargets.isEmpty)

        let refused = try XCTUnwrap(MusicBackendError.unsupported(.playlistEditing).errorDescription)
        model.addToPlaylist([track.id], LibraryPlaylist(id: MediaID(.playlist, "nowhere"), name: "Nowhere"))
        try await waitUntil("the refusal") { model.notice?.text == refused }
        XCTAssertEqual(model.library.playlistsModel.message, refused, "PlaylistMessageBar shows it too")
        XCTAssertTrue(model.library.playlistsModel.recentTargets.isEmpty)
    }

    func testToggleFavoriteTargetsAll() async throws {
        let (model, server, tracks) = try await connectedModel()
        let a = tracks[0], b = tracks[1]
        // One already a favourite: both become favourites.
        model.toggleFavorite([a: true, b: false])
        try await waitUntil("two adds") { self.sent(server, "music/favorites/add_item").count == 2 }
        XCTAssertTrue(sent(server, "music/favorites/remove_item").isEmpty)
        try await waitUntil("confirmed") {
            model.library.favorites.isFavorite(a, stored: nil) && model.library.favorites.isFavorite(b, stored: nil)
        }
        // Every one a favourite: both unfavourited.
        model.toggleFavorite([a: true, b: true])
        try await waitUntil("two removes") { self.sent(server, "music/favorites/remove_item").count == 2 }
        XCTAssertEqual(sent(server, "music/favorites/add_item").count, 2)
        // Nothing selected: nothing sent.
        model.toggleFavorite([:])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(sent(server, "music/favorites/add_item").count + sent(server, "music/favorites/remove_item").count, 4)
        XCTAssertFalse(model.notice?.text.hasPrefix("Couldn't") ?? false, "\(String(describing: model.notice))")
    }

    func testFavoriteFailureShowsNotice() async throws {
        let (model, track) = try await folderModel()
        let refused = MusicBackendError.unsupported(.favorites).errorDescription
        model.setFavorite([track.id: nil], to: true)
        try await waitUntil("the refusal") { model.notice?.text == "Couldn't favorite" }
        XCTAssertEqual(model.notice?.detail, refused)
        XCTAssertFalse(model.library.favorites.isFavorite(track.id, stored: nil), "the heart is restored")

        model.clearNotice()
        model.setFavorite([track.id: true], to: false)
        try await waitUntil("the unfavorite refusal") { model.notice?.text == "Couldn't unfavorite" }
        XCTAssertEqual(model.notice?.detail, refused)
    }

    func testFavoriteCurrentTrackNotices() async throws {
        // The folder source has no favourites.
        let (local, _) = try await folderModel()
        XCTAssertFalse(local.canFavoriteCurrentTrack)

        // Music Assistant, nothing playing anywhere (libraryIdle): This Mac's local queue, so off, and the command
        // does nothing.
        let (idle, idleServer, _) = try await connectedModel()
        idle.selectOutput(OutputDevice.thisMacID)
        XCTAssertTrue(idle.playsLocalQueue, "selected \(idle.selectedOutput), feed \(idle.thisMacFeed)")
        XCTAssertFalse(idle.canFavoriteCurrentTrack)
        idle.favoriteCurrentTrack()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(sent(idleServer, "players/add_currently_playing_to_favorites").isEmpty)
        XCTAssertFalse(idle.notice?.text == "Couldn't favorite", "\(String(describing: idle.notice))")

        let (model, server, _) = try await connectedModel(.queueLoaded)

        // On a speaker: sent. The scripted server doesn't know the command, so the failure is the notice.
        try await selectSpeakerWithQueue(model)
        XCTAssertTrue(model.canFavoriteCurrentTrack)
        model.clearNotice()
        model.favoriteCurrentTrack()
        try await waitUntil("the notice") { model.notice?.text == "Couldn't favorite" }
        XCTAssertEqual(
            sent(server, "players/add_currently_playing_to_favorites").last?.args["player_id"]?.stringValue,
            ScriptedMusicAssistant.speakerID)
        XCTAssertNotNil(model.notice?.detail)
    }
}
