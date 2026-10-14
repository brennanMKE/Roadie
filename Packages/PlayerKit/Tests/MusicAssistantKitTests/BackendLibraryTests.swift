import Foundation
import MusicAssistantKitStub
import MusicBackendKit
import Testing
@testable import MusicAssistantKit

struct BackendLibraryTests {
    @Test func connectWithoutAnAddressThrowsNotConfiguredAndSendsNothing() async throws {
        let rig = try makeBackend(address: nil)
        do {
            try await rig.backend.connect()
            Issue.record("expected notConfigured")
        } catch let error as MusicBackendError {
            guard case .notConfigured(let message) = error else {
                Issue.record("wrong error \(error)")
                return
            }
            #expect(message.contains("Settings"))
        }
        #expect(rig.factory.made == 0)
        #expect(rig.tokenCalls.count == 0)
    }

    @Test func connectWithoutATokenThrowsNotConfigured() async throws {
        let rig = try makeBackend(token: nil)
        do {
            try await rig.backend.connect()
            Issue.record("expected notConfigured")
        } catch let error as MusicBackendError {
            guard case .notConfigured = error else {
                Issue.record("wrong error \(error)")
                return
            }
        }
        #expect(rig.factory.made == 0)
        #expect(rig.tokenCalls.count == 1)
    }

    @Test func connectMapsTokenRejectionToUnauthorized() async throws {
        let rig = try makeBackend(token: MusicAssistantToken("rejected-by-the-server"))
        await #expect(throws: MusicBackendError.unauthorized) { try await rig.backend.connect() }
    }

    @Test func connectMapsAServerMismatchToUnreachable() async throws {
        let other = MusicAssistantServerAddress(baseURL: testBaseURL, serverID: String(repeating: "f", count: 32))
        let rig = try makeBackend(address: other)
        do {
            try await rig.backend.connect()
            Issue.record("expected unreachable")
        } catch let error as MusicBackendError {
            guard case .unreachable(let message) = error else {
                Issue.record("wrong error \(error)")
                return
            }
            #expect(message.contains("different"))
        }
        #expect(rig.transport.sent.isEmpty)
    }

    @Test func connectMapsTransportFailuresToUnreachable() async throws {
        let rig = try makeBackend(connectError: .transport(.cannotConnectToHost))
        do {
            try await rig.backend.connect()
            Issue.record("expected unreachable")
        } catch let error as MusicBackendError {
            guard case .unreachable(let message) = error else {
                Issue.record("wrong error \(error)")
                return
            }
            #expect(message.hasPrefix("Can't reach"))
        }
    }

    @Test func libraryCallsBeforeConnectThrowNotConnected() async throws {
        let rig = try makeBackend()
        let backend = rig.backend
        await #expect(throws: MusicBackendError.notConnected) { try await backend.artists(page: .first) }
        await #expect(throws: MusicBackendError.notConnected) { try await backend.albums(of: nil, page: .first) }
        await #expect(throws: MusicBackendError.notConnected) { try await backend.tracks(of: MediaID(.album, "library://album/27")) }
        await #expect(throws: MusicBackendError.notConnected) { try await backend.playlists(page: .first) }
        await #expect(throws: MusicBackendError.notConnected) {
            try await backend.tracks(ofPlaylist: MediaID(.playlist, "library://playlist/4"))
        }
        await #expect(throws: MusicBackendError.notConnected) { try await backend.search("x", limit: 3) }
        await #expect(throws: MusicBackendError.notConnected) { try await backend.artwork(ArtworkRef("abc"), maxPixels: 200) }
        await #expect(throws: MusicBackendError.notConnected) { try await backend.outputs() }
    }

    @Test func artistsPageUsesTheCountWithTheSameFilters() async throws {
        let rig = try await connectedBackend()
        let page = try await rig.backend.artists(page: PageRequest(offset: 0, limit: 3))
        #expect(page.items.count == 3)
        #expect(page.total == 475)
        #expect(page.nextOffset == 3)
        let requests = rig.transport.sentRequests
        let count = try #require(requests.first { $0.command == "music/artists/count" })
        #expect(count.args["album_artists_only"] == true)
        let listing = try #require(requests.first { $0.command == "music/artists/library_items" })
        let expectedArgs: MAJSON = ["limit": 3, "offset": 0, "order_by": "sort_name", "album_artists_only": true]
        #expect(listing.args == expectedArgs)
        #expect(page.items[0].id == MediaID(.artist, "library://artist/432"))
        #expect(page.items[0].artwork == nil)
        #expect(try #require(page.items[1].artwork).rawValue.hasPrefix("e4225853"))
        #expect(page.items[0].sortName == "10,000 maniacs")
        await rig.backend.disconnect()
    }

    @Test func laterPagesReuseTheCount() async throws {
        let rig = try await connectedBackend()
        _ = try await rig.backend.artists(page: PageRequest(offset: 0, limit: 3))
        let later = try await rig.backend.artists(page: PageRequest(offset: 3, limit: 3))
        #expect(rig.transport.sentRequests.filter { $0.command == "music/artists/count" }.count == 1)
        #expect(later.total == 475)
        await rig.backend.disconnect()
    }

    @Test func theLastArtistPageHasNoNext() async throws {
        let rig = try await connectedBackend()
        let page = try await rig.backend.artists(page: PageRequest(offset: 474, limit: 3))
        #expect(page.items.isEmpty)
        #expect(page.nextOffset == nil)
        await rig.backend.disconnect()
    }

    @Test func aFailedCountGivesANilTotal() async throws {
        var script = try FixtureScript.recorded(token: testToken)
        script.routes.insert(.error(command: "music/albums/count", code: 12, details: "Invalid or unsupported command."), at: 0)
        let rig = try await connectedBackend(script: script)
        let page = try await rig.backend.albums(of: nil, page: PageRequest(offset: 0, limit: 3))
        #expect(page.items.count == 3)
        #expect(page.total == nil)
        #expect(page.nextOffset == 3)
        await rig.backend.disconnect()
    }

    @Test func albumsFallBackToTheMappingNameWhenTheTitleIsEmpty() async throws {
        let rig = try await connectedBackend()
        let page = try await rig.backend.albums(of: nil, page: PageRequest(offset: 0, limit: 3))
        let album = page.items[0]
        #expect(album.title == "Aphex Twins")
        #expect(album.artistName == "Various Artists")
        #expect(album.artistID == MediaID(.artist, "library://artist/15"))
        #expect(album.year == 1999)
        #expect(album.id == MediaID(.album, "library://album/27"))
        #expect(page.total == 449)
        await rig.backend.disconnect()
    }

    @Test func albumsOfAnArtistComeFromArtistAlbums() async throws {
        let rig = try await connectedBackend()
        let page = try await rig.backend.albums(of: MediaID(.artist, "library://artist/432"), page: .first)
        #expect(page.items.map(\.title) == ["Our Time In Eden"])
        #expect(page.total == 1)
        #expect(page.nextOffset == nil)
        let request = try #require(rig.transport.sentRequests.first { $0.command == "music/artists/artist_albums" })
        #expect(request.args["item_id"] == "432")
        #expect(request.args["provider_instance_id_or_domain"] == "library")
        await #expect(throws: MusicBackendError.notFound(MediaID(.track, "library://track/1"))) {
            try await rig.backend.albums(of: MediaID(.track, "library://track/1"), page: .first)
        }
        await rig.backend.disconnect()
    }

    @Test func albumTracksAreOrderedByDiscAndTrack() async throws {
        let rig = try await connectedBackend()
        let tracks = try await rig.backend.tracks(of: MediaID(.album, "library://album/27"))
        #expect(tracks.count == 1)
        let track = tracks[0]
        #expect(track.title == "Ghost In The Shell")
        #expect(track.duration == 530)
        #expect(track.bitrate == 128)
        #expect(track.sampleRate == 44100)
        #expect(track.channels == 2)
        #expect(track.artistName == "Aphex Twins")
        #expect(track.albumID == MediaID(.album, "library://album/27"))
        #expect(track.id == MediaID(.track, "library://track/132"))
        let request = try #require(rig.transport.sentRequests.first { $0.command == "music/albums/album_tracks" })
        #expect(request.args["in_library_only"] == true)
        await rig.backend.disconnect()

        // (disc, track): (2,1), (1,2), (1,1) comes back (1,1), (1,2), (2,1).
        func scripted(_ name: String, _ disc: Int, _ number: Int) -> MAJSON {
            [
                "item_id": .string(name), "name": .string(name), "uri": .string("library://track/\(name)"),
                "disc_number": .number(Double(disc)), "track_number": .number(Double(number)),
            ]
        }
        var script = try FixtureScript.recorded(token: testToken)
        script.routes.insert(
            .result(command: "music/albums/album_tracks", [scripted("a", 2, 1), scripted("b", 1, 2), scripted("c", 1, 1)]), at: 0)
        let second = try await connectedBackend(script: script)
        let ordered = try await second.backend.tracks(of: MediaID(.album, "library://album/27"))
        #expect(ordered.map(\.title) == ["c", "b", "a"])
        await second.backend.disconnect()
    }

    @Test func playlistsPageAndPlaylistTracks() async throws {
        let rig = try await connectedBackend()
        let page = try await rig.backend.playlists(page: .first)
        #expect(page.items.count == 3)
        #expect(page.total == 8)
        #expect(page.items[0].name == "500 Random tracks (from library)")
        let tracks = try await rig.backend.tracks(ofPlaylist: MediaID(.playlist, "library://playlist/4"))
        #expect(tracks.count == 5)
        #expect(tracks[0].title == "You've Been Flirting Again")
        #expect(tracks[0].artistName == "Björk")
        #expect(tracks[0].albumName == "Post")
        await rig.backend.disconnect()
    }

    @Test func searchSendsOneCallRestrictedToTheLibrary() async throws {
        let rig = try await connectedBackend()
        let found = try await rig.backend.search("008-tapbots", limit: 3)
        #expect(found.tracks.count == 1)
        #expect(found.tracks[0].title == "008-tapbots")
        let request = try #require(rig.transport.sentRequests.first { $0.command == "music/search" })
        #expect(request.args["search_query"] == "008-tapbots")
        #expect(request.args["media_types"] == ["artist", "album", "track"])
        #expect(request.args["limit"] == 3)
        #expect(request.args["providers"] == ["library"])
        let before = rig.transport.sentRequests.count
        let empty = try await rig.backend.search("  ", limit: 3)
        #expect(empty == .empty)
        #expect(rig.transport.sentRequests.count == before)
        await rig.backend.disconnect()
    }

    @Test func artworkAsksTheProxyForAnAllowedSizeWithoutAuth() async throws {
        let rig = try await connectedBackend()
        let proxyID = String(repeating: "9", count: 64)
        let bytes = try await rig.backend.artwork(ArtworkRef(proxyID), maxPixels: 200)
        #expect(bytes == StubHTTPTransport.imageBytes)
        let request = try #require(rig.http.requests.last)
        #expect(request.url.path == "/imageproxy/\(proxyID)")
        #expect(request.url.query == "size=256")
        #expect(request.headers.isEmpty)
        _ = try await rig.backend.artwork(ArtworkRef(proxyID), maxPixels: 80)
        #expect(rig.http.requests.last?.url.query == "size=80")
        _ = try await rig.backend.artwork(ArtworkRef(proxyID), maxPixels: 1000)
        #expect(rig.http.requests.last?.url.query == "size=1024")
        _ = try await rig.backend.artwork(ArtworkRef(proxyID), maxPixels: 2000)
        #expect(rig.http.requests.last?.url.query == "size=0")
        #expect(MAImageProxy.size(for: 1) == 80)
        #expect(MAImageProxy.size(for: 257) == 512)

        rig.http.setResponse(pathPrefix: "/imageproxy/", MAHTTPResponse(status: 404))
        await #expect(throws: MusicBackendError.unsupported(.artwork)) {
            try await rig.backend.artwork(ArtworkRef(proxyID), maxPixels: 200)
        }
        rig.http.setResponse(pathPrefix: "/imageproxy/", MAHTTPResponse(status: 400))
        do {
            _ = try await rig.backend.artwork(ArtworkRef(proxyID), maxPixels: 200)
            Issue.record("expected a backend error")
        } catch let error as MusicBackendError {
            guard case .backend = error else {
                Issue.record("wrong error \(error)")
                return
            }
        }
        rig.http.setFailure(pathPrefix: "/imageproxy/", code: .notConnectedToInternet)
        do {
            _ = try await rig.backend.artwork(ArtworkRef(proxyID), maxPixels: 200)
            Issue.record("expected unreachable")
        } catch let error as MusicBackendError {
            guard case .unreachable = error else {
                Issue.record("wrong error \(error)")
                return
            }
        }
        await rig.backend.disconnect()
    }

    @Test func serverErrorsMapToBackendErrors() async throws {
        var script = try FixtureScript.recorded(token: testToken)
        script.routes.insert(.error(command: "music/playlists/library_items", code: 20, details: "Authentication is required."), at: 0)
        script.routes.insert(.error(command: "music/search", code: 12, details: "Invalid or unsupported command."), at: 0)
        let rig = try await connectedBackend(script: script)
        await #expect(throws: MusicBackendError.unauthorized) { try await rig.backend.playlists(page: .first) }
        do {
            _ = try await rig.backend.search("anything", limit: 3)
            Issue.record("expected a backend error")
        } catch let error as MusicBackendError {
            guard case .backend = error else {
                Issue.record("wrong error \(error)")
                return
            }
        }
        // A close mid-call and a timeout both read as unreachable.
        rig.transport.holdReplies(for: "players/all")
        let outputs = Task { try await rig.backend.outputs() }
        #expect(await waitFor { rig.transport.sentRequests.contains { $0.command == "players/all" } })
        rig.transport.closeFromServer(code: 1006)
        do {
            _ = try await outputs.value
            Issue.record("expected unreachable")
        } catch let error as MusicBackendError {
            guard case .unreachable = error else {
                Issue.record("wrong error \(error)")
                return
            }
        }
        await rig.backend.disconnect()
    }

    @Test func disconnectClosesAndLaterCallsThrowNotConnected() async throws {
        let rig = try await connectedBackend()
        await rig.backend.disconnect()
        #expect(rig.transport.closeCodes == [1000])
        #expect(await !rig.backend.isConnected)
        await #expect(throws: MusicBackendError.notConnected) { try await rig.backend.artists(page: .first) }
    }

    @Test func connectIsIdempotentForTheSameAddress() async throws {
        let rig = try await connectedBackend()
        try await rig.backend.connect()
        #expect(rig.factory.made == 1)
        #expect(rig.tokenCalls.count == 1)
        await rig.backend.disconnect()
    }
}
