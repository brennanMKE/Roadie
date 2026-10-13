import Foundation
import Testing
@testable import PlexKit
import PlexKitStub

struct ModelDecodingTests {
    private func container<Item: Decodable>(_ fixture: PlexFixture, as: Item.Type) throws -> MediaContainerEnvelope<Item>.Body {
        try JSONDecoder().decode(MediaContainerEnvelope<Item>.self, from: fixture.data).container
    }

    @Test func identityDecodes() throws {
        let identity = try JSONDecoder().decode(IdentityEnvelope.self, from: PlexFixture.identity.data).container
        #expect(identity.machineIdentifier == "0123456789abcdef0123456789abcdef01234567")
        #expect(!identity.version.isEmpty)
    }

    @Test func sectionsDecodeFromDirectoryAndMusicFilter() throws {
        let sections = try #require(container(.sections, as: PlexLibrarySection.self).directory)
        #expect(sections.count >= 1)
        let music = sections.filter(\.isMusic)
        #expect(music.count >= 1)
        #expect(music.allSatisfy { $0.type == "artist" && !$0.key.isEmpty })
        #expect(sections.filter { !$0.isMusic }.allSatisfy { $0.type != "artist" })
    }

    @Test func artistsPageDecodes() throws {
        let body = try container(.artistsPage, as: PlexArtist.self)
        let artists = try #require(body.metadata)
        #expect(artists.count == 3)
        #expect((body.totalSize ?? 0) >= 3)
        #expect(body.offset == 0)
        for artist in artists {
            #expect(!artist.ratingKey.isEmpty)
            #expect(artist.key.hasSuffix("/children"))
            #expect(!artist.title.isEmpty)
        }
    }

    @Test func albumsPageDecodes() throws {
        let albums = try #require(container(.albumsPage, as: PlexAlbum.self).metadata)
        #expect(albums.count == 3)
        #expect(albums.allSatisfy { $0.parentTitle != nil && $0.year != nil && $0.parentRatingKey != nil })
        #expect(albums.contains { $0.thumb != nil })
    }

    @Test func tracksPageDecodesMediaAndParts() throws {
        let tracks = try #require(container(.tracksPage, as: PlexTrack.self).metadata)
        #expect(tracks.count == 3)
        for track in tracks {
            #expect(track.media.count >= 1)
            let part = try #require(track.primaryPart)
            #expect(part.key.hasPrefix("/library/parts/"))
            #expect(part.size != nil)
            #expect(part.keyStamp != nil)
            #expect(["mp3", "m4a"].contains(part.fileExtension))
            let seconds = try #require(track.durationSeconds)
            let mediaDuration = try #require(track.media[0].duration)
            #expect(abs(seconds - Double(mediaDuration) / 1000) <= 1)
        }
        #expect(tracks.contains { $0.media[0].bitrate != nil && $0.media[0].audioChannels != nil })
    }

    @Test func partKeyStampAndExtension() throws {
        let json = #"{"id":7,"key":"/library/parts/7/1234567/file.mp3"}"#
        let part = try JSONDecoder().decode(PlexPart.self, from: Data(json.utf8))
        #expect(part.keyStamp == 1234567)
        #expect(part.fileExtension == "mp3")
    }

    @Test func artistChildrenAreAlbums() throws {
        let artist = try #require(container(.artistsPage, as: PlexArtist.self).metadata?.first)
        let albums = try #require(container(.artistChildren, as: PlexAlbum.self).metadata)
        #expect(!albums.isEmpty)
        #expect(albums.allSatisfy { $0.parentRatingKey == artist.ratingKey })
    }

    @Test func albumChildrenAreTracks() throws {
        let album = try #require(container(.artistChildren, as: PlexAlbum.self).metadata?.first)
        let tracks = try #require(container(.albumChildren, as: PlexTrack.self).metadata)
        #expect(!tracks.isEmpty)
        #expect(tracks.allSatisfy { $0.parentRatingKey == album.ratingKey })
    }

    @Test func searchResultsDecode() throws {
        let tracks = try #require(container(.tracksSearch, as: PlexTrack.self).metadata)
        #expect(!tracks.isEmpty)
    }

    @Test func minimalShapesDecode() throws {
        let decoder = JSONDecoder()
        let album = try decoder.decode(PlexAlbum.self, from: Data(#"{"ratingKey":"1","key":"/library/metadata/1/children","title":"A"}"#.utf8))
        #expect(album.year == nil && album.thumb == nil)
        let track = try decoder.decode(PlexTrack.self, from: Data(#"{"ratingKey":"2","key":"/library/metadata/2","title":"T"}"#.utf8))
        #expect(track.media == [])
        #expect(track.primaryPart == nil)
        let section = try decoder.decode(PlexLibrarySection.self, from: Data(#"{"key":"9","type":"artist","title":"M"}"#.utf8))
        #expect(section.uuid == nil)
        #expect(section.isMusic)
    }

    @Test func lastPageHasNoMore() throws {
        let body = try container(.tracksLastPage, as: PlexTrack.self)
        let items = try #require(body.metadata)
        let page = PlexPage(items: items, offset: body.offset ?? 0, size: body.size ?? items.count, totalSize: body.totalSize ?? 0)
        #expect(!page.hasMore)
        #expect(page.next == nil)
        #expect(page.offset + page.items.count == page.totalSize)
    }
}
