import Foundation
import Testing
@testable import MusicBackendKit

struct RecommendationsTests {
    @Test func recommendationItemProperties() {
        let art = ArtworkRef("art/1")
        let artist = RecommendationItem.artist(LibraryArtist(id: MediaID(.artist, "a/1"), name: "Ann", artwork: art))
        #expect(artist.id == "a/1")
        #expect(artist.mediaID == MediaID(.artist, "a/1"))
        #expect(artist.name == "Ann")
        #expect(artist.subtitle == "Artist")
        #expect(artist.kind == .artist)
        #expect(artist.artwork == art)
        #expect(!artist.isMapping)

        let album = RecommendationItem.album(LibraryAlbum(id: MediaID(.album, "al/1"), title: "First", artistName: "Ann"))
        #expect(album.id == "al/1")
        #expect(album.mediaID == MediaID(.album, "al/1"))
        #expect(album.name == "First")
        #expect(album.subtitle == "Ann")
        #expect(album.kind == .album)
        #expect(album.artwork == nil)
        #expect(!album.isMapping)
        #expect(RecommendationItem.album(LibraryAlbum(id: MediaID(.album, "al/2"), title: "X")).subtitle == "Album")

        let track = RecommendationItem.track(LibraryTrack(id: MediaID(.track, "t/1"), title: "Song", artistName: "Bo", artwork: art))
        #expect(track.id == "t/1")
        #expect(track.mediaID == MediaID(.track, "t/1"))
        #expect(track.name == "Song")
        #expect(track.subtitle == "Bo")
        #expect(track.kind == .track)
        #expect(track.artwork == art)
        #expect(!track.isMapping)

        let playlist = RecommendationItem.playlist(LibraryPlaylist(id: MediaID(.playlist, "p/1"), name: "Mix", artwork: art))
        #expect(playlist.id == "p/1")
        #expect(playlist.mediaID == MediaID(.playlist, "p/1"))
        #expect(playlist.name == "Mix")
        #expect(playlist.subtitle == "Playlist")
        #expect(playlist.kind == .playlist)
        #expect(playlist.artwork == art)
        #expect(!playlist.isMapping)

        let radio = RecommendationItem.other(uri: "library://radio/3", kind: .radio, name: "KEXP", subtitle: nil, artwork: art)
        #expect(radio.id == "library://radio/3")
        #expect(radio.mediaID == MediaID(.radio, "library://radio/3"))
        #expect(radio.name == "KEXP")
        #expect(radio.subtitle == "Radio")
        #expect(radio.kind == .radio)
        #expect(radio.artwork == art)
        #expect(radio.isMapping)

        let podcast = RecommendationItem.other(uri: "x://podcast/1", kind: nil, name: "Pod", subtitle: nil, artwork: nil)
        #expect(podcast.mediaID == nil)
        #expect(podcast.subtitle == "")
        #expect(podcast.kind == nil)
        let labelled = RecommendationItem.other(uri: "x://p/2", kind: .track, name: "T", subtitle: "By Cy", artwork: nil)
        #expect(labelled.subtitle == "By Cy")

        let row = RecommendationRow(provider: "library", itemID: "recent", name: "Recently played", kind: .timeline)
        #expect(row.id == "library/recent")
        #expect(row.kind == .timeline)
        #expect(row.isEnabledByDefault)
    }
}
