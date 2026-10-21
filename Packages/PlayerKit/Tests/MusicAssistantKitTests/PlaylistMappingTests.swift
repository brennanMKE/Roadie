import Foundation
import MusicAssistantKitStub
import MusicBackendKit
import Testing
@testable import MusicAssistantKit

/// #0134: playlist flags, source and editing from recorded and synthetic `Playlist` items.
extension ModelDecodingTests {
    @Test func playlistDecodesEditableOwnerAndSource() throws {
        let raw = try recordedResult(.playlistsPage).decode(as: [MAPlaylist].self)
        let playlists = raw.map { LibraryPlaylist(ma: $0) }
        #expect(playlists.count == 3)
        for playlist in playlists {
            #expect(playlist.source == .builtIn)
            #expect(playlist.isEditable == false)
            #expect(playlist.editing.isEmpty)
            #expect(playlist.libraryID != nil)
        }
        #expect(playlists[0].libraryID == "4")
        #expect(playlists[0].owner == "user")
        #expect(playlists[0].isFavorite == false)
        #expect(playlists[2].isDynamic == true)
        #expect(raw[0].supportedMediatypes == nil || raw[0].supportedMediatypes?.contains("track") == true)
    }

    @Test func playlistTrackDecodesPosition() throws {
        let tracks = try #require(try MAFixture.playlistTracks.frames()[0]["result"]).decode(as: [MATrack].self)
        #expect(tracks[0].position == 1)
        #expect(LibraryTrack(ma: tracks[0]).playlistPosition == 1)
    }
}

struct MAMappingTests {
    private func playlist(domain: String, owner: String?, editable: Bool, dynamic: Bool = false) throws -> MAPlaylist {
        var json: [String: Any] = [
            "item_id": "12", "provider": "library", "name": "Road Trip", "uri": "library://playlist/12",
            "is_editable": editable, "is_dynamic": dynamic, "favorite": true,
            "supported_mediatypes": ["track"],
            "provider_mappings": [["item_id": "abc", "provider_domain": domain, "provider_instance": domain]],
        ]
        if let owner { json["owner"] = owner }
        return try JSONDecoder().decode(MAPlaylist.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func builtinUserPlaylistIsEditableUser() throws {
        let ma = try playlist(domain: "builtin", owner: "Brennan", editable: true)
        #expect(ma.supportedMediatypes == ["track"])
        let mapped = LibraryPlaylist(ma: ma)
        #expect(mapped.source == .user)
        #expect(mapped.isEditable)
        #expect(mapped.editing == [.addRemove, .rename, .delete])
        #expect(mapped.libraryID == "12")
        #expect(mapped.isFavorite == true)
        #expect(LibraryPlaylist(ma: ma, canReorder: true).editing.contains(.reorder))
    }

    @Test func builtinOwnedByMusicAssistantIsBuiltIn() throws {
        let mapped = LibraryPlaylist(ma: try playlist(domain: "builtin", owner: "Music Assistant", editable: false))
        #expect(mapped.source == .builtIn)
        #expect(mapped.editing.isEmpty)
    }

    @Test func providerPlaylistNamesItsProvider() throws {
        let readOnly = LibraryPlaylist(ma: try playlist(domain: "spotify", owner: "Spotify", editable: false))
        #expect(readOnly.source == .provider(name: "Spotify"))
        #expect(readOnly.editing == [.rename, .delete])
        let dynamic = LibraryPlaylist(ma: try playlist(domain: "apple_music", owner: nil, editable: true, dynamic: true))
        #expect(dynamic.source == .provider(name: "Apple Music"))
        #expect(!dynamic.editing.contains(.addRemove))
    }
}
