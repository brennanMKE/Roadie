import Foundation
import MusicBackendKit
import Testing
@testable import LibraryBrowser

struct AddToPlaylistMenuTests {
    private func playlist(_ name: String, editable: Bool = true, source: PlaylistSource = .user) -> LibraryPlaylist {
        LibraryPlaylist(
            id: MediaID(.playlist, "library://playlist/" + name), name: name, isEditable: editable, source: source,
            editing: editable ? [.addRemove, .rename, .delete] : [])
    }

    @Test func entriesPutRecentFirstThenByName() {
        let a = playlist("Apple"), b = playlist("banana"), c = playlist("Cherry"), d = playlist("Date"), e = playlist("Elder")
        let entries = AddToPlaylistMenu.entries(playlists: [e, d, c, b, a], recent: [d.id, a.id, e.id, c.id])
        #expect(entries == [.playlist(d), .playlist(a), .playlist(e), .playlist(b), .playlist(c), .separator, .newPlaylist])
        #expect(AddToPlaylistMenu.recording(c.id, in: [d.id, a.id, e.id]) == [c.id, d.id, a.id])
        #expect(AddToPlaylistMenu.recording(a.id, in: [d.id, a.id, e.id]) == [a.id, d.id, e.id])
    }

    @Test func entriesLeaveOutReadOnlyAndTheOpenPlaylist() {
        let mine = playlist("Mine"), open = playlist("Open")
        let builtIn = playlist("Random", editable: false, source: .builtIn)
        let spotify = playlist("Hits", editable: false, source: .provider(name: "Spotify"))
        let entries = AddToPlaylistMenu.entries(
            playlists: [builtIn, open, spotify, mine], recent: [builtIn.id, open.id], excluding: open.id)
        #expect(entries == [.playlist(mine), .separator, .newPlaylist])
    }

    @Test func entriesWithNoTargetOfferOnlyNewPlaylist() {
        #expect(AddToPlaylistMenu.entries(playlists: [], recent: []) == [.newPlaylist])
        let readOnly = playlist("Hits", editable: false, source: .provider(name: "Spotify"))
        #expect(AddToPlaylistMenu.entries(playlists: [readOnly], recent: [readOnly.id]) == [.newPlaylist])
        let one = playlist("One")
        #expect(AddToPlaylistMenu.notice(adding: [MediaID(.album, "a"), MediaID(.track, "t"), MediaID(.track, "u")], to: one)
            == "Added 1 album and 2 tracks to One")
    }
}
