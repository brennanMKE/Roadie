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
}
