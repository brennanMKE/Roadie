import Foundation
import MusicAssistantKitStub
import MusicBackendKit
import Testing
@testable import MusicAssistantKit

/// A user playlist as `music/playlists/get` answers it (synthetic until the write capture lands, #0133).
private let roadTrip: MAJSON = [
    "item_id": "12", "provider": "library", "name": "Road Trip", "sort_name": "road trip",
    "uri": "library://playlist/12", "media_type": "playlist", "owner": "Test", "is_editable": true,
    "is_dynamic": false, "favorite": false, "extra_field": "kept",
    "provider_mappings": [[
        "item_id": "road_trip", "provider_domain": "builtin", "provider_instance": "builtin", "available": true,
        "in_library": true,
    ]],
]

/// A connected backend whose script answers `routes` first.
private func playlistBackend(_ routes: [FixtureScript.Route]) async throws -> BackendRig {
    var script = try FixtureScript.recorded(token: testToken)
    script.routes.insert(contentsOf: routes, at: 0)
    return try await connectedBackend(script: script)
}

extension MARequestEncodingTests {
    @Test func playlistCommandsUseTheDocumentedArgNames() {
        let create = MARequest.createPlaylist(name: "Road Trip")
        #expect(create.command == "music/playlists/create_playlist")
        #expect(MAJSON.object(create.args) == ["name": "Road Trip"])
        #expect(MARequest.createPlaylist(name: "X", provider: "builtin").args["provider_instance_or_domain"] == "builtin")

        let update = MARequest.updatePlaylist(itemID: "12", playlist: ["name": "Sunday"])
        #expect(update.command == "music/playlists/update")
        #expect(MAJSON.object(update.args) == ["item_id": "12", "update": ["name": "Sunday"], "overwrite": true])

        let remove = MARequest.removeLibraryItem(mediaType: .playlist, libraryItemID: "12")
        #expect(remove.command == "music/library/remove_item")
        #expect(MAJSON.object(remove.args) == ["media_type": "playlist", "library_item_id": "12"])
    }
}

extension BackendPlaylistTests {
    private var roadTripID: MediaID { MediaID(.playlist, "library://playlist/12") }

    @Test func createReturnsAnEditableUserPlaylist() async throws {
        let rig = try await playlistBackend([.result(command: "music/playlists/create_playlist", roadTrip)])
        let created = try await rig.backend.createPlaylist(named: "  Road Trip ")
        #expect(created.id == roadTripID)
        #expect(created.name == "Road Trip")
        #expect(created.isEditable)
        #expect(created.source == .user)
        #expect(created.libraryID == "12")
        #expect(created.editing.isSuperset(of: [.addRemove, .rename, .delete]))
        let sent = try #require(rig.transport.sentRequests.first { $0.command == "music/playlists/create_playlist" })
        #expect(sent.args == ["name": "Road Trip"])
        await rig.backend.disconnect()
    }

    @Test func renameSendsTheWholePlaylistWithOverwrite() async throws {
        let rig = try await playlistBackend([
            .result(command: "music/playlists/get", roadTrip),
            .result(command: "music/playlists/update", roadTrip),
        ])
        try await rig.backend.renamePlaylist(roadTripID, to: "Sunday")
        let get = try #require(rig.transport.sentRequests.first { $0.command == "music/playlists/get" })
        #expect(get.args == ["item_id": "12", "provider_instance_id_or_domain": "library"])
        let sent = try #require(rig.transport.sentRequests.first { $0.command == "music/playlists/update" })
        #expect(sent.args["item_id"] == "12")
        #expect(sent.args["overwrite"] == true)
        #expect(sent.args["update"]?["name"] == "Sunday")
        #expect(sent.args["update"]?["extra_field"] == "kept")
        #expect(sent.args["update"]?["uri"] == "library://playlist/12")
        await rig.backend.disconnect()
    }

    @Test func deleteUsesLibraryRemoveItem() async throws {
        let rig = try await playlistBackend([
            .result(command: "music/playlists/get", roadTrip),
            .result(command: "music/library/remove_item", nil),
        ])
        try await rig.backend.deletePlaylist(roadTripID)
        let sent = try #require(rig.transport.sentRequests.first { $0.command == "music/library/remove_item" })
        #expect(sent.args == ["media_type": "playlist", "library_item_id": "12"])
        await rig.backend.disconnect()
    }

    @Test func deleteRefusesBuiltIn() async throws {
        let builtIn = try #require(try recordedResult(.playlistsPage)[0])
        let rig = try await playlistBackend([.result(command: "music/playlists/get", builtIn)])
        let id = MediaID(.playlist, "library://playlist/4")
        await #expect(throws: MusicBackendError.forbidden("Built-in playlists can't be deleted.")) {
            try await rig.backend.deletePlaylist(id)
        }
        await #expect(throws: MusicBackendError.forbidden("Built-in playlists can't be renamed.")) {
            try await rig.backend.renamePlaylist(id, to: "Mine")
        }
        #expect(!rig.transport.sentRequests.contains { $0.command == "music/library/remove_item" })
        #expect(!rig.transport.sentRequests.contains { $0.command == "music/playlists/update" })
        await rig.backend.disconnect()
    }

    @Test func scopeErrorMapsToForbidden() async throws {
        let details = "Insufficient permissions: the token lacks scope library.manage"
        let rig = try await playlistBackend([
            .result(command: "music/playlists/get", roadTrip),
            .error(command: "music/playlists/update", code: 999, details: details),
        ])
        await #expect(throws: MusicBackendError.forbidden(details)) {
            try await rig.backend.renamePlaylist(roadTripID, to: "Sunday")
        }
        #expect(MusicBackendError.forbidden(details).errorDescription == details)
        await rig.backend.disconnect()
    }

    @Test func addSendsAlbumAndTrackURIsUnchanged() async throws {
        let rig = try await playlistBackend([
            .result(command: "music/playlists/get", roadTrip),
            .result(command: "music/playlists/add_playlist_tracks", ["id": "t1", "name": "add", "status": "pending"]),
        ])
        let items = [
            MediaID(.album, "library://album/27"), MediaID(.track, "spotify://track/abc"),
            MediaID(.artist, "library://artist/3"),
        ]
        try await rig.backend.add(items, toPlaylist: roadTripID)
        let sent = try #require(rig.transport.sentRequests.first { $0.command == "music/playlists/add_playlist_tracks" })
        #expect(sent.args == ["db_playlist_id": "12", "uris": ["library://album/27", "spotify://track/abc"]])
        #expect(MARequest.addPlaylistTracks(playlistID: "12", uris: []).command == "music/playlists/add_playlist_tracks")
        await rig.backend.disconnect()
    }

    @Test func addToReadOnlyPlaylistIsRefused() async throws {
        let builtIn = try #require(try recordedResult(.playlistsPage)[0])
        let rig = try await playlistBackend([.result(command: "music/playlists/get", builtIn)])
        await #expect(throws: MusicBackendError.self) {
            try await rig.backend.add([MediaID(.track, "library://track/1")], toPlaylist: MediaID(.playlist, "library://playlist/4"))
        }
        #expect(!rig.transport.sentRequests.contains { $0.command == "music/playlists/add_playlist_tracks" })
        await rig.backend.disconnect()
    }
}
