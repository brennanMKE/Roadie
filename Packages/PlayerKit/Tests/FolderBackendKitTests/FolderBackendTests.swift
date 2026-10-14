import AudioCore
import CoreGraphics
import Foundation
import ImageIO
import LocalPlayback
import MusicBackendKit
import Testing
@testable import FolderBackendKit

private let eden = "10,000 Maniacs/Our Time in Eden (1992)"
private let white = "The Beatles/The White Album"
private let backDisc1 = "The Beatles/The White Album/Disc 1/01 Back in the U.S.S.R..wav"

/// The error a call threw, or nil.
@MainActor
private func thrown<T>(_ body: @MainActor () async throws -> T) async -> MusicBackendError? {
    do { _ = try await body() } catch { return error as? MusicBackendError }
    return nil
}

@MainActor
@Suite struct FolderBackendTests {
    @Test func connectWithoutAFolderThrowsNotConfigured() async throws {
        let root = makeTempDir()
        let fixture = try BackendFixture(root: root, settings: { nil })
        defer { fixture.cleanup() }
        let error = await thrown { try await fixture.backend.connect() }
        guard case .notConfigured(let message) = error else {
            Issue.record("expected notConfigured, got \(String(describing: error))")
            return
        }
        #expect(message.contains("Settings"))
        #expect(await fixture.backend.isConnected == false)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: fixture.cache.path))?.isEmpty ?? true)
    }

    @Test func connectWithAMissingFolderThrowsUnreachable() async throws {
        let root = makeTempDir()
        let missing = root.appending(path: "Gone Music")
        let fixture = try BackendFixture(root: root, settings: { missing }, buildLibrary: false)
        defer { fixture.cleanup() }
        let error = await thrown { try await fixture.backend.connect() }
        guard case .unreachable(let message) = error else {
            Issue.record("expected unreachable, got \(String(describing: error))")
            return
        }
        #expect(message.contains("Gone Music"))
        #expect(!message.contains(root.lastPathComponent))
    }

    @Test func libraryCallsBeforeConnectThrowNotConnected() async throws {
        let fixture = try BackendFixture(root: makeTempDir())
        defer { fixture.cleanup() }
        let backend = fixture.backend
        #expect(await thrown { try await backend.artists(page: .first) } == .notConnected)
        #expect(await thrown { try await backend.albums(of: nil, page: .first) } == .notConnected)
        #expect(await thrown { try await backend.tracks(of: albumID(white)) } == .notConnected)
        #expect(await thrown { try await backend.search("a", limit: 5) } == .notConnected)
        #expect(await thrown { try await backend.play([trackID(backDisc1)], on: OutputDevice.thisMacID, mode: .replace()) } == .notConnected)
        #expect(await thrown { try await backend.reindex() } == .notConnected)
    }

    @Test func transportWorksBeforeConnect() async throws {
        let fixture = try BackendFixture(root: makeTempDir())
        defer { fixture.cleanup() }
        try await fixture.backend.transport(.setVolume(0.5), on: OutputDevice.thisMacID)
        #expect(fixture.player.volume == 0.5)
        try await fixture.backend.transport(.stop, on: OutputDevice.thisMacID)
        #expect(fixture.player.state == .stopped)
    }

    @Test func outputsListThisMacOnly() async throws {
        let fixture = try BackendFixture(root: makeTempDir())
        defer { fixture.cleanup() }
        #expect(try await fixture.backend.outputs() == [OutputDevice.thisMac])
        #expect(fixture.backend.sourceID == "folder")
        #expect(fixture.backend.capabilities.contains([.search, .artwork, .localOutput]))
    }

    @Test func firstConnectScansWritesTheCacheAndEndsReady() async throws {
        let fixture = try BackendFixture(root: makeTempDir())
        defer { fixture.cleanup() }
        try await fixture.backend.connect()
        guard case .ready(let summary) = await fixture.backend.status else {
            Issue.record("expected ready")
            return
        }
        #expect(summary.tracks == 7)
        #expect(await fixture.backend.isConnected)
        #expect(FolderIndexCache.load(for: fixture.root, in: fixture.cache) != nil)
        #expect(fixture.watchers.watchers.count == 1)
        #expect(fixture.watchers.last?.isRunning == true)
        #expect(fixture.watchers.last?.url == fixture.resolvedRoot)
    }

    @Test func secondConnectServesTheCacheThenRescansWithoutRereadingUnchangedFiles() async throws {
        let root = makeTempDir()
        let first = try BackendFixture(root: root)
        defer { first.cleanup() }
        try await first.backend.connect()
        guard case .ready(let summary) = await first.backend.status else {
            Issue.record("expected ready")
            return
        }

        // A new file makes the second scan read exactly one; the gate holds it so the cached index is what answers.
        try writeWAV(to: root.appending(path: "\(eden)/03 Candy.wav"))
        let second = try BackendFixture(root: root, cache: first.cache, buildLibrary: false)
        await second.gate.arm()
        let statuses = StatusCollector(await second.backend.statusUpdates())
        defer { statuses.stop() }
        try await second.backend.connect()

        #expect(await second.backend.status == .indexing(previous: summary))
        #expect(await second.backend.isConnected)
        let page = try await second.backend.artists(page: .first)
        #expect(page.items.count == 3)
        let stale = try await second.backend.albums(of: artistID("10,000 Maniacs"), page: .first)
        #expect(stale.items.first?.trackCount == 2)

        #expect(await waitFor { await second.gate.waiting == 1 })
        await second.gate.open()
        await second.backend.waitForIndexing()
        #expect(await waitFor { statuses.sawReady })
        #expect(statuses.values.contains(.indexing(previous: summary)))
        let fresh = try await second.backend.albums(of: artistID("10,000 Maniacs"), page: .first)
        #expect(fresh.items.first?.trackCount == 3)
        #expect(await second.counter.count == 1)
    }

    @Test func connectIsIdempotentAndSwitchesRoots() async throws {
        let root = makeTempDir()
        let other = makeTempDir()
        defer { try? FileManager.default.removeItem(at: other) }
        let current = OSLockedURL(root)
        let fixture = try BackendFixture(root: root, settings: { current.value })
        defer { fixture.cleanup() }
        try await fixture.backend.connect()
        try await fixture.backend.connect()
        #expect(fixture.watchers.watchers.count == 1)
        #expect(await fixture.counter.count == 8)

        try writeWAV(to: other.appending(path: "Solo/Album/01 Only.wav"))
        current.value = other
        try await fixture.backend.connect()
        #expect(fixture.watchers.watchers.count == 2)
        #expect(fixture.watchers.watchers[0].isRunning == false)
        #expect(fixture.watchers.watchers[1].isRunning == true)
        #expect(await fixture.backend.root == other.standardizedFileURL.resolvingSymlinksInPath())
        #expect(FolderIndexCache.load(for: other, in: fixture.cache) != nil)
        #expect(try await fixture.backend.artists(page: .first).items.map(\.name) == ["Solo"])
    }

    @Test func artistsArePagedAndSortedIgnoringLeadingThe() async throws {
        let fixture = try BackendFixture(root: makeTempDir())
        defer { fixture.cleanup() }
        try await fixture.backend.connect()
        let backend = fixture.backend

        let first = try await backend.artists(page: PageRequest(offset: 0, limit: 2))
        #expect(first.items.map(\.name) == ["10,000 Maniacs", "The Beatles"])
        #expect(first.total == 3)
        #expect(first.nextOffset == 2)
        let second = try await backend.artists(page: PageRequest(offset: 2, limit: 2))
        #expect(second.items.map(\.name) == ["Unknown Artist"])
        #expect(second.nextOffset == nil)
        let beyond = try await backend.artists(page: PageRequest(offset: 10, limit: 2))
        #expect(beyond.items.isEmpty)
        #expect(beyond.nextOffset == nil)
    }

    @Test func albumsOfAnArtistAndOfEveryone() async throws {
        let fixture = try BackendFixture(root: makeTempDir())
        defer { fixture.cleanup() }
        try await fixture.backend.connect()
        let backend = fixture.backend

        #expect(try await backend.albums(of: artistID("The Beatles"), page: .first).items.map(\.title) == ["The White Album"])
        #expect(try await backend.albums(of: nil, page: .first).items.map(\.title)
            == ["Our Time in Eden", "Singles", "The White Album", "Unknown Album"])
        #expect(await thrown { try await backend.albums(of: albumID(white), page: .first) } == .notFound(albumID(white)))
        #expect(await thrown { try await backend.albums(of: artistID("Nobody"), page: .first) } == .notFound(artistID("Nobody")))
    }

    @Test func tracksOfAnAlbumAreInDiscAndTrackOrder() async throws {
        let fixture = try BackendFixture(root: makeTempDir())
        defer { fixture.cleanup() }
        try await fixture.backend.connect()
        let titles = try await fixture.backend.tracks(of: albumID(white)).map(\.title)
        #expect(titles == ["Back in the U.S.S.R.", "Dear Prudence", "Birthday"])
        #expect(await thrown { try await fixture.backend.tracks(of: albumID("Nope")) } == .notFound(albumID("Nope")))
    }

    @Test func searchMatchesCaseAndDiacriticInsensitivelyAcrossAllThree() async throws {
        let root = makeTempDir()
        let fixture = try BackendFixture(root: root)
        defer { fixture.cleanup() }
        try writeWAV(to: root.appending(path: "Caf\u{65}\u{301}/Album/01 Song.wav"))
        try await fixture.backend.connect()
        let backend = fixture.backend

        let prudence = try await backend.search("PRUDENCE", limit: 10)
        #expect(prudence.tracks.map(\.title) == ["Dear Prudence"])
        #expect(prudence.artists.isEmpty && prudence.albums.isEmpty)
        let beatles = try await backend.search("beatles", limit: 10)
        #expect(beatles.artists.map(\.name) == ["The Beatles"])
        let edenResults = try await backend.search("eden", limit: 10)
        #expect(edenResults.albums.map(\.title) == ["Our Time in Eden"])
        let cafe = try await backend.search("cafe", limit: 10)
        #expect(cafe.artists.count == 1)
        #expect(try await backend.search("   ", limit: 10) == .empty)
        let limited = try await backend.search("e", limit: 1)
        #expect(limited.artists.count <= 1 && limited.albums.count <= 1 && limited.tracks.count <= 1)
    }

    @Test func playlistsAreUnsupported() async throws {
        let fixture = try BackendFixture(root: makeTempDir())
        defer { fixture.cleanup() }
        #expect(!fixture.backend.capabilities.contains(.playlists))
        try await fixture.backend.connect()
        #expect(await thrown { try await fixture.backend.playlists(page: .first) } == .unsupported(.playlists))
        #expect(await thrown { try await fixture.backend.tracks(ofPlaylist: MediaID(.playlist, "x")) } == .unsupported(.playlists))
    }

    @Test func artworkReturnsTheAlbumImageScaledToMaxPixels() async throws {
        let fixture = try BackendFixture(root: makeTempDir())
        defer { fixture.cleanup() }
        try await fixture.backend.connect()
        let backend = fixture.backend
        let ref = ArtworkRef(rawValue: "file:\(eden)/cover.jpg")

        let small = try await backend.artwork(ref, maxPixels: 16)
        let source = try #require(CGImageSourceCreateWithData(small as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)
        #expect(width <= 16 && height <= 16)

        let original = try Data(contentsOf: fixture.url("\(eden)/cover.jpg"))
        #expect(try await backend.artwork(ref, maxPixels: 200) == original)

        try FileManager.default.removeItem(at: fixture.url("\(eden)/cover.jpg"))
        let missing = await thrown { try await backend.artwork(ref, maxPixels: 200) }
        guard case .backend = missing else {
            Issue.record("expected backend error, got \(String(describing: missing))")
            return
        }
        let outside = await thrown { try await backend.artwork(ArtworkRef(rawValue: "file:../outside.jpg"), maxPixels: 200) }
        guard case .backend = outside else {
            Issue.record("expected backend error, got \(String(describing: outside))")
            return
        }
    }

    // MARK: Playback

    @Test func playAlbumQueuesItsTracksInOrderWithMediaIDs() async throws {
        let fixture = try BackendFixture(root: makeTempDir())
        defer { fixture.cleanup() }
        try await fixture.backend.connect()
        var iterator = await fixture.backend.nowPlaying(on: OutputDevice.thisMacID).makeAsyncIterator()
        let idle = await iterator.next()
        #expect(idle?.state == .stopped)

        try await fixture.backend.play([albumID(white)], on: OutputDevice.thisMacID, mode: .replace())
        let queue = fixture.player.queue
        #expect(queue.tracks.map(\.title) == ["Back in the U.S.S.R.", "Dear Prudence", "Birthday"])
        #expect(queue.tracks.map(\.source) == [
            .file(fixture.url(backDisc1)),
            .file(fixture.url("\(white)/Disc 1/02 Dear Prudence.wav")),
            .file(fixture.url("\(white)/Disc 2/01 Birthday.wav")),
        ])
        #expect(queue.currentIndex == 0)
        // The missing-file resolver: the player errors and stops, and no audio device is opened.
        #expect(await waitFor { fixture.player.state == .stopped && fixture.player.errorMessage != nil })
        let snapshot = fixture.output.snapshot()
        #expect(snapshot.title != nil)
        var sawItem = false
        for _ in 0..<20 {
            guard let next = await iterator.next() else { break }
            if next.item == trackID(backDisc1) { sawItem = true; break }
        }
        #expect(sawItem)
    }

    @Test func playArtistQueuesEveryAlbumInOrder() async throws {
        let fixture = try BackendFixture(root: makeTempDir())
        defer { fixture.cleanup() }
        try await fixture.backend.connect()
        try await fixture.backend.play([artistID("10,000 Maniacs")], on: OutputDevice.thisMacID, mode: .replace())
        #expect(fixture.player.queue.tracks.map(\.title) == ["Noah's Dove", "These Are Days", "Loose Single"])
    }

    @Test func playTrackByIdAndAppend() async throws {
        let fixture = try BackendFixture(root: makeTempDir())
        defer { fixture.cleanup() }
        try await fixture.backend.connect()
        try await fixture.backend.play([trackID(backDisc1)], on: OutputDevice.thisMacID, mode: .replace())
        #expect(fixture.player.queue.tracks.count == 1)
        let index = fixture.player.queue.currentIndex
        try await fixture.backend.play([albumID(eden)], on: OutputDevice.thisMacID, mode: .append)
        #expect(fixture.player.queue.tracks.count == 3)
        #expect(fixture.player.queue.currentIndex == index)
    }

    @Test func playUnknownTrackThrowsNotFound() async throws {
        let fixture = try BackendFixture(root: makeTempDir())
        defer { fixture.cleanup() }
        try await fixture.backend.connect()
        let id = trackID("Nobody/Nothing/01 Nope.wav")
        #expect(await thrown { try await fixture.backend.play([id], on: OutputDevice.thisMacID, mode: .replace()) } == .notFound(id))
        #expect(fixture.player.queue.tracks.isEmpty)
    }

    @Test func playSkipsTracksMissingOnDiskAndThrowsWhenNoneRemain() async throws {
        let fixture = try BackendFixture(root: makeTempDir())
        defer { fixture.cleanup() }
        try await fixture.backend.connect()
        try FileManager.default.removeItem(at: fixture.url("\(white)/Disc 2/01 Birthday.wav"))
        try await fixture.backend.play([albumID(white)], on: OutputDevice.thisMacID, mode: .replace())
        #expect(fixture.player.queue.tracks.map(\.title) == ["Back in the U.S.S.R.", "Dear Prudence"])

        try FileManager.default.removeItem(at: fixture.url("\(eden)/01 Noah's Dove.wav"))
        try FileManager.default.removeItem(at: fixture.url("\(eden)/02 These Are Days.wav"))
        let error = await thrown { try await fixture.backend.play([albumID(eden)], on: OutputDevice.thisMacID, mode: .replace()) }
        guard case .backend = error else {
            Issue.record("expected backend error, got \(String(describing: error))")
            return
        }
    }

    @Test func playAndTransportOnAnUnknownOutputThrow() async throws {
        let fixture = try BackendFixture(root: makeTempDir())
        defer { fixture.cleanup() }
        try await fixture.backend.connect()
        let homepod = OutputDevice.ID(rawValue: "homepod")
        #expect(await thrown { try await fixture.backend.play([albumID(white)], on: homepod, mode: .replace()) } == .unknownOutput(homepod))
        #expect(fixture.player.queue.tracks.isEmpty)
        #expect(await thrown { try await fixture.backend.transport(.play, on: homepod) } == .unknownOutput(homepod))
        var iterator = await fixture.backend.nowPlaying(on: homepod).makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    // MARK: Changes

    @Test func folderChangesTriggerADebouncedRescan() async throws {
        let root = makeTempDir()
        let fixture = try BackendFixture(root: root)
        defer { fixture.cleanup() }
        try await fixture.backend.connect()
        let before = await fixture.counter.count
        let watcher = try #require(fixture.watchers.last)

        try writeWAV(to: root.appending(path: "The Beatles/Abbey Road/01 Come Together.wav"))
        watcher.fire()
        watcher.fire()
        watcher.fire()
        let beatles = artistID("The Beatles")
        #expect(await waitFor { (try? await fixture.backend.albums(of: beatles, page: .first).items.count) == 2 })
        await fixture.backend.waitForIndexing()
        #expect(await fixture.counter.count - before == 1)
        #expect(await waitFor { if case .ready(let summary) = await fixture.backend.status { summary.tracks == 8 } else { false } })
    }

    @Test func changesDuringAScanQueueOneMoreScan() async throws {
        let root = makeTempDir()
        let fixture = try BackendFixture(root: root)
        defer { fixture.cleanup() }
        try await fixture.backend.connect()
        let before = await fixture.counter.count
        let watcher = try #require(fixture.watchers.last)
        let statuses = StatusCollector(await fixture.backend.statusUpdates())
        defer { statuses.stop() }

        await fixture.gate.arm()
        try writeWAV(to: root.appending(path: "The Beatles/Abbey Road/01 Come Together.wav"))
        watcher.fire()
        #expect(await waitFor { await fixture.gate.waiting == 1 })
        #expect(await waitFor { statuses.sawIndexing })

        try writeWAV(to: root.appending(path: "The Beatles/Abbey Road/02 Something.wav"))
        watcher.fire()
        #expect(await waitFor { await fixture.backend.rescanIsQueued })
        await fixture.gate.open()
        await fixture.backend.waitForIndexing()

        let titles = try await fixture.backend.tracks(of: albumID("The Beatles/Abbey Road")).map(\.title)
        #expect(titles == ["Come Together", "Something"])
        #expect(await fixture.counter.count - before == 2)
        #expect(await waitFor { statuses.sawReady })
    }

    @Test func anUnchangedRescanDoesNotRewriteTheCache() async throws {
        let root = makeTempDir()
        let fixture = try BackendFixture(root: root)
        defer { fixture.cleanup() }
        try await fixture.backend.connect()
        let file = FolderIndexCache.fileURL(for: root, in: fixture.cache)
        func modified() throws -> Date? {
            try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        func builtAt() async -> Date? {
            if case .ready(let summary) = await fixture.backend.status { summary.builtAt } else { nil }
        }
        let firstWrite = try modified()
        let firstBuilt = await builtAt()
        #expect(firstWrite != nil)
        let watcher = try #require(fixture.watchers.last)

        // A change event with nothing changed: a scan runs, the cache file is left alone.
        watcher.fire()
        #expect(await waitFor { let now = await builtAt(); return now != nil && now != firstBuilt })
        await fixture.backend.waitForIndexing()
        #expect(try modified() == firstWrite)

        // A real change rewrites it.
        try writeWAV(to: root.appending(path: "The Beatles/Abbey Road/01 Come Together.wav"))
        watcher.fire()
        #expect(await waitFor { if case .ready(let summary) = await fixture.backend.status { summary.tracks == 8 } else { false } })
        await fixture.backend.waitForIndexing()
        #expect(try modified() != firstWrite)
        #expect(FolderIndexCache.load(for: root, in: fixture.cache)?.summary.tracks == 8)
    }

    @Test func reindexRereadsEveryFile() async throws {
        let fixture = try BackendFixture(root: makeTempDir())
        defer { fixture.cleanup() }
        try await fixture.backend.connect()
        let before = try await fixture.backend.artists(page: .first)
        let count = await fixture.counter.count
        try await fixture.backend.reindex()
        #expect(await fixture.counter.count - count == 8)
        #expect(try await fixture.backend.artists(page: .first) == before)
    }

    @Test func aFailedCacheSaveStillServesTheIndex() async throws {
        let root = makeTempDir()
        let cache = makeTempDir("FolderBackendKitTests-cache")
        // The cache "directory" is a regular file, so saving cannot create it.
        let blocked = cache.appending(path: "blocked")
        try Data("file".utf8).write(to: blocked)
        let fixture = try BackendFixture(root: root, cache: blocked)
        defer {
            fixture.cleanup()
            try? FileManager.default.removeItem(at: cache)
        }
        try await fixture.backend.connect()
        guard case .ready = await fixture.backend.status else {
            Issue.record("expected ready")
            return
        }
        #expect(try await fixture.backend.artists(page: .first).items.count == 3)
    }

    @Test func disconnectStopsTheWatcherAndForgetsTheIndex() async throws {
        let fixture = try BackendFixture(root: makeTempDir())
        defer { fixture.cleanup() }
        try await fixture.backend.connect()
        await fixture.backend.disconnect()
        #expect(fixture.watchers.last?.isRunning == false)
        #expect(await fixture.backend.isConnected == false)
        #expect(await fixture.backend.status == .notConnected)
        #expect(await thrown { try await fixture.backend.artists(page: .first) } == .notConnected)
        try await fixture.backend.connect()
        #expect(try await fixture.backend.artists(page: .first).items.count == 3)
    }

    @Test func statusStreamEndsWhenTheSubscriberCancels() async throws {
        let fixture = try BackendFixture(root: makeTempDir())
        defer { fixture.cleanup() }
        let stream = await fixture.backend.statusUpdates()
        let task = Task { for await _ in stream {} }
        #expect(await waitFor { await fixture.backend.statusSubscriberCount == 1 })
        task.cancel()
        #expect(await waitFor { await fixture.backend.statusSubscriberCount == 0 })
    }
}

/// A URL a `@Sendable` settings closure can read while a test changes it.
final class OSLockedURL: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL
    init(_ url: URL) { self.url = url }
    var value: URL {
        get { lock.lock(); defer { lock.unlock() }; return url }
        set { lock.lock(); defer { lock.unlock() }; url = newValue }
    }
}
