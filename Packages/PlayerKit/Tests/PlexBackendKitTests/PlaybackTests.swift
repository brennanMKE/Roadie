import AudioCore
import Foundation
import MusicBackendKit
import PlexKit
import PlexKitStub
import Testing
import TrackCache

@MainActor
struct PlexBackendPlaybackTests {
    private func connected() async throws -> BackendFixture {
        let f = try BackendFixture()
        try f.register([
            try .json(.albumChildren, path: "/library/metadata/3684/children"),
            .init(path: testPartPath, headers: ["Content-Type": "audio/mp4"], body: Data(repeating: 7, count: testPartSize)),
        ])
        try await f.backend.connect()
        return f
    }

    @Test func outputsListThisMacOnly() async throws {
        let f = try BackendFixture(); defer { f.cleanup() }
        let outputs = try await f.backend.outputs()
        #expect(outputs == [OutputDevice.thisMac])
        #expect(f.handle.recorded.isEmpty)
    }

    @Test func playAlbumQueuesItsTracksAndResolvesThroughTheCache() async throws {
        let f = try await connected(); defer { f.cleanup() }
        var iterator = await f.backend.nowPlaying(on: OutputDevice.thisMacID).makeAsyncIterator()
        let idle = try #require(await iterator.next())
        #expect(idle.state == .stopped)

        try await f.backend.play([MediaID(.album, "3684")], on: OutputDevice.thisMacID, mode: .replace())
        #expect(f.player.queue.tracks.count == 1)
        let track = try #require(f.player.queue.tracks.first)
        #expect(track.source == .plex(
            partKey: testPartPath, cacheKey: "\(testMachine)-5010-1791856627", size: Int64(testPartSize)))

        #expect(await waitFor { await f.cache.entries().count == 1 })
        let part = try #require(f.handle.recorded.first { $0.url.path == testPartPath })
        #expect(header(part, "X-Plex-Token") == testSecret)
        #expect(!part.url.absoluteString.contains(testSecret))

        // The bytes are not audio, so the player gives up with an error message.
        #expect(await waitFor { f.player.state == .stopped && f.player.errorMessage != nil })

        var sawItem = false
        for _ in 0..<10 {
            guard let snapshot = await iterator.next() else { break }
            if snapshot.item == MediaID(.track, "3685") { sawItem = true; break }
        }
        #expect(sawItem)
    }

    @Test func playKnownTrackByIdAfterListing() async throws {
        let f = try await connected(); defer { f.cleanup() }
        _ = try await f.backend.tracks(of: MediaID(.album, "3684"))
        try await f.backend.play([MediaID(.track, "3685")], on: OutputDevice.thisMacID, mode: .replace())
        #expect(f.player.queue.tracks.count == 1)
        let albumRequests = f.handle.recorded.filter { $0.url.path == "/library/metadata/3684/children" }
        #expect(albumRequests.count == 1)
        #expect(await waitFor { f.player.errorMessage != nil })
    }

    @Test func playUnknownTrackThrowsNotFound() async throws {
        let f = try await connected(); defer { f.cleanup() }
        let id = MediaID(.track, "99999")
        await #expect(throws: MusicBackendError.notFound(id)) {
            try await f.backend.play([id], on: OutputDevice.thisMacID, mode: .replace())
        }
        #expect(f.player.queue.tracks.isEmpty)
    }

    @Test func playAppendKeepsTheQueue() async throws {
        let f = try await connected(); defer { f.cleanup() }
        try await f.backend.play([MediaID(.album, "3684")], on: OutputDevice.thisMacID, mode: .replace())
        try await f.backend.play([MediaID(.track, "3685")], on: OutputDevice.thisMacID, mode: .append)
        #expect(f.player.queue.tracks.count == 2)
        #expect(f.player.queue.currentIndex == 0)
        #expect(await waitFor { f.player.errorMessage != nil })
    }

    @Test func playOnAnUnknownOutputThrows() async throws {
        let f = try await connected(); defer { f.cleanup() }
        let output = OutputDevice.ID(rawValue: "homepod")
        await #expect(throws: MusicBackendError.unknownOutput(output)) {
            try await f.backend.play([MediaID(.album, "3684")], on: output, mode: .replace())
        }
        #expect(f.player.queue.tracks.isEmpty)
    }

    @Test func playBeforeConnectThrowsNotConnected() async throws {
        let f = try BackendFixture(); defer { f.cleanup() }
        await #expect(throws: MusicBackendError.notConnected) {
            try await f.backend.play([MediaID(.album, "3684")], on: OutputDevice.thisMacID, mode: .replace())
        }
        #expect(f.handle.recorded.isEmpty)
    }

    @Test func transportDrivesThePlayerWithoutAConnection() async throws {
        let f = try BackendFixture(); defer { f.cleanup() }
        try await f.backend.transport(.setVolume(0.5), on: OutputDevice.thisMacID)
        #expect(f.player.volume == 0.5)
        try await f.backend.transport(.stop, on: OutputDevice.thisMacID)
        #expect(f.player.state == .stopped)
        #expect(f.handle.recorded.isEmpty)
    }

    @Test func transportOnAnUnknownOutputThrows() async throws {
        let f = try BackendFixture(); defer { f.cleanup() }
        let output = OutputDevice.ID(rawValue: "homepod")
        await #expect(throws: MusicBackendError.unknownOutput(output)) {
            try await f.backend.transport(.play, on: output)
        }
    }

    @Test func nowPlayingOnAnUnknownOutputFinishesAtOnce() async throws {
        let f = try BackendFixture(); defer { f.cleanup() }
        var iterator = await f.backend.nowPlaying(on: OutputDevice.ID(rawValue: "homepod")).makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test func nowPlayingStreamStartsIdleThenFollowsPlayback() async throws {
        let f = try await connected(); defer { f.cleanup() }
        var iterator = await f.backend.nowPlaying(on: OutputDevice.thisMacID).makeAsyncIterator()
        let first = try #require(await iterator.next())
        #expect(first.state == .stopped)
        try await f.backend.play([MediaID(.album, "3684")], on: OutputDevice.thisMacID, mode: .replace())
        var sawLoading = false
        for _ in 0..<10 {
            guard let snapshot = await iterator.next() else { break }
            if snapshot.title == "Candy Everybody Wants", snapshot.state == .loading { sawLoading = true; break }
        }
        #expect(sawLoading)
        #expect(await waitFor { f.player.errorMessage != nil })
    }

    // MARK: Albums that span pages (#0018)

    private static let albumPath = "/library/metadata/3684/children"

    /// The `tracks-page` fixture with `totalSize` 4, then `tracks-last-page`: four tracks over two requests.
    private static func pagedAlbumRoutes() throws -> [StubURLProtocol.Route] {
        var json = try #require(JSONSerialization.jsonObject(with: PlexFixture.tracksPage.data) as? [String: Any])
        var container = try #require(json["MediaContainer"] as? [String: Any])
        container["totalSize"] = 4
        json["MediaContainer"] = container
        let first = try JSONSerialization.data(withJSONObject: json)
        return [
            .init(path: albumPath, containerStart: 0, body: first),
            .init(path: albumPath, containerStart: 3, body: try PlexFixture.tracksLastPage.data),
        ]
    }

    private static func pagedTitles() throws -> [String] {
        func titles(_ fixture: PlexFixture) throws -> [String] {
            let root = try #require(JSONSerialization.jsonObject(with: fixture.data) as? [String: Any])
            let container = try #require(root["MediaContainer"] as? [String: Any])
            return ((container["Metadata"] as? [[String: Any]]) ?? []).compactMap { $0["title"] as? String }
        }
        return try titles(.tracksPage) + titles(.tracksLastPage)
    }

    private func connectedPaged() async throws -> BackendFixture {
        let f = try BackendFixture()
        try f.register(try Self.pagedAlbumRoutes())
        try await f.backend.connect()
        return f
    }

    private func childrenRequests(_ f: BackendFixture) -> Int {
        f.handle.recorded.filter { $0.url.path == Self.albumPath }.count
    }

    @Test func playAlbumQueuesEveryTrackInOrderAcrossPages() async throws {
        let f = try await connectedPaged(); defer { f.cleanup() }
        try await f.backend.play([MediaID(.album, "3684")], on: OutputDevice.thisMacID, mode: .replace())
        let expected = try Self.pagedTitles()
        #expect(expected.count == 4)
        #expect(f.player.queue.tracks.map(\.title) == expected)
        #expect(f.player.queue.currentIndex == 0)
        for track in f.player.queue.tracks {
            guard case .plex(_, let cacheKey, _) = track.source else { Issue.record("not a Plex source"); continue }
            #expect(cacheKey.hasPrefix(testMachine))
        }
        #expect(childrenRequests(f) == 2)
    }

    @Test func playFromARowStartsAtThatIndex() async throws {
        let f = try await connectedPaged(); defer { f.cleanup() }
        let rows = try await f.backend.tracks(of: MediaID(.album, "3684"))
        #expect(childrenRequests(f) == 2)
        try await f.backend.play(rows.map(\.id), on: OutputDevice.thisMacID, mode: .replace(startIndex: 2))
        #expect(f.player.queue.tracks.count == 4)
        #expect(f.player.queue.currentIndex == 2)
        #expect(childrenRequests(f) == 2)
    }

    @Test func appendAnAlbumKeepsTheCurrentTrackAndOrder() async throws {
        let f = try await connectedPaged(); defer { f.cleanup() }
        try await f.backend.play([MediaID(.album, "3684")], on: OutputDevice.thisMacID, mode: .replace())
        // The tracks have no server behind them, so the player skips through them (#0068); let it stop first.
        #expect(await waitFor { f.player.state == .stopped })
        let index = f.player.queue.currentIndex
        try await f.backend.play([MediaID(.album, "3684")], on: OutputDevice.thisMacID, mode: .append)
        let expected = try Self.pagedTitles()
        #expect(f.player.queue.tracks.count == 8)
        #expect(f.player.queue.currentIndex == index)
        #expect(f.player.queue.tracks.map(\.title) == expected + expected)
    }

    @Test func playWithAnUnknownIdQueuesNothing() async throws {
        let f = try await connectedPaged(); defer { f.cleanup() }
        let rows = try await f.backend.tracks(of: MediaID(.album, "3684"))
        let unknown = MediaID(.track, "999")
        await #expect(throws: MusicBackendError.notFound(unknown)) {
            try await f.backend.play([rows[0].id, unknown], on: OutputDevice.thisMacID, mode: .replace())
        }
        #expect(f.player.queue.tracks.isEmpty)
    }
}
