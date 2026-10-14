import Foundation
import MusicBackendKit
import Testing
@testable import MusicAssistantKit

struct MAURITests {
    @Test func parsesLibraryURIs() throws {
        let uri = try #require(MAURI.parse("library://artist/432"))
        #expect(uri.provider == "library")
        #expect(uri.mediaType == .artist)
        #expect(uri.itemID == "432")
    }

    @Test func parsesOtherProviders() throws {
        let plex = try #require(MAURI.parse("plex--abc://album/12"))
        #expect(plex.provider == "plex--abc")
        #expect(plex.mediaType == .album)
        let spotify = try #require(MAURI.parse("spotify://track/6rqhFgbbKwnb9MLmUQDhG6"))
        #expect(spotify.provider == "spotify")
        #expect(spotify.itemID == "6rqhFgbbKwnb9MLmUQDhG6")
    }

    @Test func keepsSlashesInTheItemID() throws {
        let uri = try #require(MAURI.parse("filesystem_smb--x://track/Artist/Album/01 Song.mp3"))
        #expect(uri.itemID == "Artist/Album/01 Song.mp3")
    }

    @Test func rejectsGarbage() {
        #expect(MAURI.parse("") == nil)
        #expect(MAURI.parse("library:/album") == nil)
        #expect(MAURI.parse("library://thing/1") == nil)
        #expect(MAURI.parse("library://album/") == nil)
        #expect(MAURI.parse("://album/1") == nil)
    }

    @Test func roundTripsThroughString() throws {
        for text in ["library://album/27", "plex--abc://track/a/b", "library://playlist/4"] {
            #expect(try #require(MAURI.parse(text)).string == text)
        }
    }

    @Test func mapsToMediaKind() {
        #expect(MAMediaKind.playlist.mediaKind == .playlist)
        for kind in MediaKind.allCases { #expect(MAMediaKind(kind).mediaKind == kind) }
    }
}
