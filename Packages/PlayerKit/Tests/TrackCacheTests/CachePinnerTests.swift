import AudioCore
import Foundation
import Testing
@testable import TrackCache

/// Fails every load, so `play(at:)` emits its events and never creates an audio graph.
private struct FailingResolver: TrackResolver {
    func localURL(for track: Track) async throws -> URL { throw TrackCacheError.noServer }
}

private func plexTrack(_ key: String) -> Track {
    Track(title: key, artist: "", duration: 1, source: .plex(partKey: "/library/parts/\(key)/file.m4a", cacheKey: key))
}

private func pinned(_ cache: TrackCache, equals expected: Set<String>) async -> Bool {
    await waitFor { await cache.pinned == expected }
}

@MainActor
struct CachePinnerTests {
    private func makeCache() -> (TrackCache, URL) {
        let dir = makeTempDir()
        return (TrackCache(directory: dir, downloader: StubDownloader()), dir)
    }

    @Test func pinnedKeysFollowCurrentAndNext() async throws {
        let (cache, dir) = makeCache(); defer { try? FileManager.default.removeItem(at: dir) }
        let player = Player(resolver: FailingResolver())
        let pinner = CachePinner(cache: cache, player: player)
        pinner.install()
        player.enqueue(["k0", "k1", "k2"].map(plexTrack))

        player.play(at: 0)
        #expect(await pinned(cache, equals: ["k0", "k1"]))
        player.next()
        #expect(await pinned(cache, equals: ["k1", "k2"]))
        player.play(at: 2)
        #expect(await pinned(cache, equals: ["k2"]))
        // Setting repeatMode alone emits no event; the pins move on the next transport call.
        player.repeatMode = .all
        player.play(at: 2)
        #expect(await pinned(cache, equals: ["k2", "k0"]))
        pinner.uninstall()
    }

    @Test func pinnedKeysIgnoreLocalFiles() {
        var queue = PlayQueue(tracks: [
            Track(title: "local", artist: "", duration: 1, source: .file(URL(fileURLWithPath: "/tmp/a.mp3"))),
            plexTrack("k1"),
            Track(title: "local2", artist: "", duration: 1, source: .file(URL(fileURLWithPath: "/tmp/b.mp3"))),
        ])
        #expect(CachePinner.pinnedKeys(in: PlayQueue()).isEmpty)
        queue.select(0)
        #expect(CachePinner.pinnedKeys(in: queue) == ["k1"])
        queue.select(1)
        #expect(CachePinner.pinnedKeys(in: queue) == ["k1"])
        queue.select(2)
        #expect(CachePinner.pinnedKeys(in: queue).isEmpty)
    }

    @Test func uninstallClearsThePins() async throws {
        let (cache, dir) = makeCache(); defer { try? FileManager.default.removeItem(at: dir) }
        let player = Player(resolver: FailingResolver())
        let pinner = CachePinner(cache: cache, player: player)
        pinner.install()
        player.enqueue(["k0", "k1", "k2"].map(plexTrack))
        player.play(at: 0)
        #expect(await pinned(cache, equals: ["k0", "k1"]))
        pinner.uninstall()
        #expect(await pinned(cache, equals: []))
        player.next()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await cache.pinned.isEmpty)
    }
}
