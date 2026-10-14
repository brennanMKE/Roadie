import AudioCore
import Foundation
import PlexKit
import Testing
@testable import TrackCache

/// The cache side of #0039: `open` returns a download the player reads while it arrives. The stub downloader
/// writes one chunk per permit the test grants, so every state is reached on purpose, with no sleeps.
struct ProgressiveDownloadTests {
    static let chunk = 1024
    static let body = randomBytes(4 * chunk)
    static let key = "5010-1791856627-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    var partKey: String { Harness.partKey(Self.key) }

    func trickled(_ h: Harness, body: Data = ProgressiveDownloadTests.body) -> String {
        h.stub.setBody(body, for: partKey)
        h.stub.trickle(partKey, chunkSize: Self.chunk)
        return partKey
    }

    /// Runs blocking work on a plain thread, like the player's reader does.
    func onThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            let thread = Thread { continuation.resume(returning: body()) }
            thread.start()
        }
    }

    func download(_ h: Harness, expected: Int64? = Int64(ProgressiveDownloadTests.body.count)) async throws -> ProgressiveDownload {
        guard case .downloading(let d) = try await h.cache.open(forKey: Self.key, partKey: partKey, expectedSize: expected) else {
            throw TrackCacheError.notPlexTrack
        }
        return d
    }

    @Test func missOpensADownloadAndAHitReturnsTheFile() async throws {
        let h = Harness(); defer { h.cleanup() }
        _ = trickled(h)
        let d = try await download(h)
        #expect(d.finalSize == Int64(Self.body.count))
        #expect(d.pathExtension == "m4a")
        #expect(d.description == "ProgressiveDownload(\(Self.key))")
        h.stub.releaseChunks(partKey, count: 4)
        #expect(await waitFor { if case .completed = d.state { true } else { false } })
        let entries = await h.cache.entries()
        #expect(entries.count == 1)
        #expect(entries.first?.size == Int64(Self.body.count))
        guard case .ready(let url) = try await h.cache.open(forKey: Self.key, partKey: partKey, expectedSize: Int64(Self.body.count)) else {
            Issue.record("expected a hit")
            return
        }
        #expect(url.lastPathComponent == "\(Self.key).m4a")
        #expect(try Data(contentsOf: url) == Self.body)
        d.close()
    }

    @Test func frontierAdvancesAsChunksLand() async throws {
        let h = Harness(); defer { h.cleanup() }
        _ = trickled(h)
        let d = try await download(h)
        for k in 1...3 {
            h.stub.releaseChunks(partKey, count: 1)
            #expect(await waitFor { d.availableBytes == Int64(k * Self.chunk) })
        }
        var bytes = [UInt8](repeating: 0, count: Self.chunk)
        let got = try bytes.withUnsafeMutableBytes { try d.read(into: $0.baseAddress!, offset: Int64(Self.chunk), count: Self.chunk) }
        #expect(got == Self.chunk)
        #expect(Data(bytes) == Self.body.subdata(in: Self.chunk..<(2 * Self.chunk)))
        h.stub.releaseChunks(partKey, count: 1)
        d.close()
    }

    @Test func waitForBytesReturnsWhenTheFrontierPasses() async throws {
        let h = Harness(); defer { h.cleanup() }
        _ = trickled(h)
        let d = try await download(h)
        let outcome = Task { await onThread { d.waitForBytes(through: 3072, timeout: 10) } }
        h.stub.releaseChunks(partKey, count: 3)
        guard case .available = await outcome.value else {
            Issue.record("expected .available")
            return
        }
        // Not there yet: the timeout, not a hang.
        guard case .timedOut = await onThread({ d.waitForBytes(through: 4096, timeout: 0.05) }) else {
            Issue.record("expected .timedOut")
            return
        }
        h.stub.releaseChunks(partKey, count: 1)
        d.close()
    }

    @Test func waitForBytesReturnsTheFailure() async throws {
        let h = Harness(); defer { h.cleanup() }
        h.stub.setBody(Self.body, for: partKey)
        h.stub.gate(partKey)
        let d = try await download(h)
        let outcome = Task { await onThread { d.waitForBytes(through: 100, timeout: 10) } }
        #expect(await waitFor { h.stub.calls(partKey) == 1 })
        h.stub.fail(partKey, with: PlexError.notFound)
        guard case .failed(let error) = await outcome.value else {
            Issue.record("expected .failed")
            return
        }
        #expect(error as? TrackCacheError == .download(.notFound))
        guard case .failed = d.state else { Issue.record("state should be failed"); return }
        #expect(tempContents(h.dir).isEmpty)
        #expect(await h.cache.entries().isEmpty)
    }

    @Test func aShortBodyIsStillRejected() async throws {
        let h = Harness(); defer { h.cleanup() }
        h.stub.setBody(randomBytes(2048), for: partKey)
        let d = try await download(h, expected: 4096)
        let outcome = await onThread { d.waitForBytes(through: 4096, timeout: 10) }
        guard case .failed(let error) = outcome else { Issue.record("expected .failed"); return }
        #expect(error as? TrackCacheError == .sizeMismatch(expected: 4096, actual: 2048))
        #expect(await h.cache.entries().isEmpty)
        #expect(filesOnDisk(h.dir).isEmpty)
        #expect(tempContents(h.dir).isEmpty)
    }

    @Test func theFinalFileIsVerifiedAndIndexedWhileAReaderHoldsIt() async throws {
        let h = Harness(); defer { h.cleanup() }
        _ = trickled(h)
        let d = try await download(h)
        h.stub.releaseChunks(partKey, count: 2)
        #expect(await waitFor { d.availableBytes == Int64(2 * Self.chunk) })
        h.stub.releaseChunks(partKey, count: 2)
        let outcome = await onThread { d.waitForBytes(through: Int64(Self.body.count), timeout: 10) }
        guard case .available = outcome else { Issue.record("expected .available"); return }
        #expect(await waitFor { if case .completed = d.state { true } else { false } })
        #expect(filesOnDisk(h.dir) == ["\(Self.key).m4a": Int64(Self.body.count)])
        #expect(tempContents(h.dir).isEmpty)
        // The descriptor still reads the bytes after the file moved into Tracks/.
        var bytes = [UInt8](repeating: 0, count: Self.body.count)
        let got = try bytes.withUnsafeMutableBytes { try d.read(into: $0.baseAddress!, offset: 0, count: Self.body.count) }
        #expect(got == Self.body.count)
        #expect(Data(bytes) == Self.body)
        d.close()
    }

    @Test func closingTheOnlyHolderCancelsAnUnpinnedDownload() async throws {
        let h = Harness(); defer { h.cleanup() }
        _ = trickled(h)
        let d = try await download(h)
        h.stub.releaseChunks(partKey, count: 1)
        #expect(await waitFor { d.availableBytes == Int64(Self.chunk) })
        d.close()
        #expect(await waitFor { h.stub.cancelCount == 1 })
        let settled1 = await waitFor { await h.cache.stats().inFlight == 0 }
        #expect(settled1)
        #expect(tempContents(h.dir).isEmpty)
        #expect(await h.cache.entries().isEmpty)
    }

    @Test func aPinnedDownloadOutlivesItsReader() async throws {
        let h = Harness(); defer { h.cleanup() }
        _ = trickled(h)
        await h.cache.setPinned([Self.key])
        let d = try await download(h)
        d.close()
        // The download keeps going with nobody reading it, and is indexed when it completes.
        h.stub.releaseChunks(partKey, count: 4)
        let settled2 = await waitFor { await h.cache.entries().count == 1 }
        #expect(settled2)
        #expect(h.stub.cancelCount == 0)
    }

    @Test func aWaiterKeepsTheDownloadWhenTheReaderCloses() async throws {
        let h = Harness(); defer { h.cleanup() }
        _ = trickled(h)
        let waiter = Task { try await h.cache.file(forKey: Self.key, partKey: partKey, expectedSize: Int64(Self.body.count)) }
        let settled3 = await waitFor { await h.cache.stats().inFlight == 1 }
        #expect(settled3)
        let d = try await download(h)
        #expect(h.stub.calls(partKey) == 1)
        d.close()
        h.stub.releaseChunks(partKey, count: 4)
        let url = try await waiter.value
        #expect(try Data(contentsOf: url) == Self.body)
        #expect(h.stub.cancelCount == 0)
    }

    @Test func cancelAndCloseAreIdempotent() async throws {
        let h = Harness(); defer { h.cleanup() }
        _ = trickled(h)
        let d = try await download(h)
        d.cancel()
        d.cancel()
        guard case .cancelled = d.waitForBytes(through: 10, timeout: 1) else { Issue.record("expected .cancelled"); return }
        d.close()
        d.close()
        #expect(await waitFor { h.stub.cancelCount == 1 })
        let settled4 = await waitFor { await h.cache.stats().inFlight == 0 }
        #expect(settled4)
        var byte: UInt8 = 0
        #expect(throws: (any Error).self) { try d.read(into: &byte, offset: 0, count: 1) }
    }

    @Test func fetchRangeGoesToTheDownloaderNotTheFile() async throws {
        let h = Harness(); defer { h.cleanup() }
        _ = trickled(h)
        let d = try await download(h)
        let data = try await onThread { try? d.fetchRange(2048..<2560) }
        #expect(data == Self.body.subdata(in: 2048..<2560))
        #expect(h.stub.rangeCalls == [ProgressiveStubRange(partKey: partKey, range: 2048..<2560)])
        let tempSize = try tempContents(h.dir).map {
            try FileManager.default.attributesOfItem(atPath: h.dir.appendingPathComponent("tmp/\($0)").path)[.size] as? Int
        }
        #expect(tempSize == [0])   // nothing was written to the file by the range request
        h.stub.releaseChunks(partKey, count: 1)
        d.close()
    }

    @Test func openWithoutAnExpectedSizeDownloadsFully() async throws {
        let h = Harness(); defer { h.cleanup() }
        h.stub.setBody(Self.body, for: partKey)
        guard case .ready(let url) = try await h.cache.open(forKey: Self.key, partKey: partKey, expectedSize: nil) else {
            Issue.record("expected .ready")
            return
        }
        #expect(try Data(contentsOf: url) == Self.body)
    }

    @Test func prepareWipesTempFilesLeftByAProgressiveDownload() async throws {
        let h = Harness(); defer { h.cleanup() }
        _ = trickled(h)
        let d = try await download(h)
        h.stub.releaseChunks(partKey, count: 1)
        #expect(await waitFor { d.availableBytes == Int64(Self.chunk) })
        #expect(!tempContents(h.dir).isEmpty)
        let relaunched = h.reopen()
        try await relaunched.prepare()
        #expect(tempContents(h.dir).isEmpty)
        d.close()
    }
}

typealias ProgressiveStubRange = StubDownloader.RangeCall
