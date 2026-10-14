import Foundation
import MusicBackendKit
import PlexKit
import PlexKitStub
import Testing

@MainActor
struct PlexBackendLibraryTests {
    private func connected(_ routes: [StubURLProtocol.Route]) async throws -> BackendFixture {
        let f = try BackendFixture()
        try f.register(routes)
        try await f.backend.connect()
        return f
    }

    @Test func artistsPageMapsFieldsAndPaging() async throws {
        let f = try await connected([try .json(.artistsPage, path: "/library/sections/5/all", query: ["type": "8"])])
        defer { f.cleanup() }
        let page = try await f.backend.artists(page: .first)
        #expect(page.items.map(\.id) == [MediaID(.artist, "3683"), MediaID(.artist, "2099"), MediaID(.artist, "2070")])
        #expect(page.items[0].name == "10,000 Maniacs")
        #expect(page.items[0].artwork == ArtworkRef("/library/metadata/3683/thumb/1791860627"))
        #expect(page.total == 242)
        #expect(page.nextOffset == 3)
        let request = try #require(f.libraryRequests.first)
        #expect(header(request, "X-Plex-Container-Start") == "0")
        #expect(header(request, "X-Plex-Container-Size") == "100")
    }

    @Test func secondPageSendsItsOffset() async throws {
        let f = try await connected([try .json(.artistsPage, path: "/library/sections/5/all", query: ["type": "8"])])
        defer { f.cleanup() }
        _ = try await f.backend.artists(page: PageRequest(offset: 20, limit: 50))
        let request = try #require(f.libraryRequests.first)
        #expect(header(request, "X-Plex-Container-Start") == "20")
        #expect(header(request, "X-Plex-Container-Size") == "50")
    }

    @Test func albumsOfAnArtistUseTheChildrenPath() async throws {
        let f = try await connected([try .json(.artistChildren, path: "/library/metadata/3683/children")])
        defer { f.cleanup() }
        let page = try await f.backend.albums(of: MediaID(.artist, "3683"), page: .first)
        #expect(f.libraryRequests.first?.url.path == "/library/metadata/3683/children")
        let album = try #require(page.items.first)
        #expect(album.title == "Our Time in Eden")
        #expect(album.artistName == "10,000 Maniacs")
        #expect(album.year == 1992)
        #expect(album.artistID == MediaID(.artist, "3683"))
        await #expect(throws: MusicBackendError.notFound(MediaID(.album, "3684"))) {
            _ = try await f.backend.albums(of: MediaID(.album, "3684"), page: .first)
        }
    }

    @Test func albumsWithoutAnArtistListTheSection() async throws {
        let f = try await connected([try .json(.albumsPage, path: "/library/sections/5/all", query: ["type": "9"])])
        defer { f.cleanup() }
        let page = try await f.backend.albums(of: nil, page: .first)
        #expect(page.items.count == 3)
        #expect(page.total == 353)
        #expect(queryValue(try #require(f.libraryRequests.first), "type") == "9")
    }

    @Test func albumTracksMapMetadata() async throws {
        let f = try await connected([try .json(.albumChildren, path: "/library/metadata/3684/children")])
        defer { f.cleanup() }
        let tracks = try await f.backend.tracks(of: MediaID(.album, "3684"))
        let track = try #require(tracks.first)
        #expect(track.id == MediaID(.track, "3685"))
        #expect(track.title == "Candy Everybody Wants")
        #expect(track.trackNumber == 9)
        #expect(track.discNumber == 1)
        #expect(track.duration == 186.015)
        #expect(track.bitrate == 282)
        #expect(track.channels == 2)
        #expect(track.sampleRate == nil)
        #expect(track.albumID == MediaID(.album, "3684"))
        #expect(track.artistID == MediaID(.artist, "3683"))
    }

    @Test func albumTracksWalkEveryPage() async throws {
        var json = try #require(JSONSerialization.jsonObject(with: PlexFixture.tracksPage.data) as? [String: Any])
        var container = try #require(json["MediaContainer"] as? [String: Any])
        container["totalSize"] = 4
        json["MediaContainer"] = container
        let first = try JSONSerialization.data(withJSONObject: json)
        let f = try await connected([
            .init(path: "/library/metadata/3684/children", containerStart: 0, body: first),
            .init(path: "/library/metadata/3684/children", containerStart: 3, body: try PlexFixture.tracksLastPage.data),
        ])
        defer { f.cleanup() }
        let tracks = try await f.backend.tracks(of: MediaID(.album, "3684"))
        #expect(tracks.count == 4)
        #expect(f.libraryRequests.count == 2)
    }

    @Test func searchRunsThreeQueriesAndMerges() async throws {
        let f = try await connected([
            try .json(.artistsPage, path: "/library/sections/5/all", query: ["type": "8", "title": "eden"]),
            try .json(.albumsPage, path: "/library/sections/5/all", query: ["type": "9", "title": "eden"]),
            try .json(.tracksSearch, path: "/library/sections/5/all", query: ["type": "10", "title": "eden"]),
        ])
        defer { f.cleanup() }
        let results = try await f.backend.search("eden", limit: 7)
        #expect(!results.artists.isEmpty)
        #expect(!results.albums.isEmpty)
        #expect(!results.tracks.isEmpty)
        let requests = f.libraryRequests
        #expect(requests.count == 3)
        #expect(Set(requests.compactMap { queryValue($0, "type") }) == ["8", "9", "10"])
        #expect(requests.allSatisfy { queryValue($0, "title") == "eden" && header($0, "X-Plex-Container-Size") == "7" })
    }

    @Test func emptySearchSendsNothing() async throws {
        let f = try await connected([])
        defer { f.cleanup() }
        let before = f.handle.recorded.count
        let results = try await f.backend.search("   ", limit: 10)
        #expect(results.isEmpty)
        #expect(f.handle.recorded.count == before)
    }

    @Test func playlistsAreUnsupported() async throws {
        let f = try await connected([])
        defer { f.cleanup() }
        #expect(!f.backend.capabilities.contains(.playlists))
        let before = f.handle.recorded.count
        await #expect(throws: MusicBackendError.unsupported(.playlists)) { _ = try await f.backend.playlists(page: .first) }
        await #expect(throws: MusicBackendError.unsupported(.playlists)) {
            _ = try await f.backend.tracks(ofPlaylist: MediaID(.playlist, "1"))
        }
        #expect(f.handle.recorded.count == before)
    }

    @Test func artworkFetchesTheTranscodeWithTheTokenInTheHeader() async throws {
        let bytes = Data(repeating: 0xFF, count: 16)
        let f = try await connected([
            .init(path: "/photo/:/transcode", headers: ["Content-Type": "image/jpeg"], body: bytes),
        ])
        defer { f.cleanup() }
        let data = try await f.backend.artwork(ArtworkRef("/library/metadata/3684/thumb/1791860628"), maxPixels: 200)
        #expect(data == bytes)
        let request = try #require(f.libraryRequests.first)
        #expect(queryValue(request, "url") == "/library/metadata/3684/thumb/1791860628")
        #expect(queryValue(request, "width") == "200")
        #expect(queryValue(request, "height") == "200")
        #expect(header(request, "X-Plex-Token") == testSecret)
        #expect(header(request, "Accept")?.hasPrefix("image/") == true)
        #expect(!request.url.absoluteString.contains(testSecret))
    }

    @Test func clientErrorsMapToBackendErrors() async throws {
        let f = try await connected([.init(path: "/library/sections/5/all", status: 401)])
        defer { f.cleanup() }
        await #expect(throws: MusicBackendError.unauthorized) { _ = try await f.backend.artists(page: .first) }
        try f.register([.init(path: "/library/sections/5/all", status: 500)])
        do {
            _ = try await f.backend.artists(page: .first)
            Issue.record("should have thrown")
        } catch let error as MusicBackendError {
            guard case .backend(let message) = error else { Issue.record("wrong error \(error)"); return }
            #expect(message.contains("status 500"))
        }
    }
}
