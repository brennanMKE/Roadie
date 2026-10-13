import Foundation
import Testing
@testable import TrackCache

struct TrackCacheTests {
    // MARK: Download and hit

    @Test func missDownloadsOnceAndStoresTheFile() async throws {
        let h = Harness(); defer { h.cleanup() }
        let url = try await h.get("k1", bytes: 1234)
        #expect(url.lastPathComponent == "k1.m4a")
        #expect(url.deletingLastPathComponent().standardizedFileURL == h.dir.standardizedFileURL)
        #expect(try Data(contentsOf: url).count == 1234)
        #expect(h.stub.calls(Harness.partKey("k1")) == 1)
        #expect(await h.cache.entries().map(\.key) == ["k1"])
        #expect(FileManager.default.fileExists(atPath: h.dir.appendingPathComponent("index.json").path))
    }

    @Test func hitSkipsTheDownloaderAndTouchesLastAccess() async throws {
        let h = Harness(); defer { h.cleanup() }
        try await h.get("k1", bytes: 100)
        h.clock.advance(seconds: 60)
        try await h.get("k1")
        #expect(h.stub.calls(Harness.partKey("k1")) == 1)
        let entry = try #require(await h.cache.entries().first)
        #expect(entry.lastAccess == h.clock.now)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: h.dir.appendingPathComponent("index.json"))) as? [String: Any]
        let stored = try #require((json?["entries"] as? [[String: Any]])?.first?["lastAccess"] as? Double)
        #expect(abs(stored - h.clock.now.timeIntervalSince1970) < 0.001)
    }

    @Test func concurrentRequestsForOneKeyShareOneDownload() async throws {
        let h = Harness(); defer { h.cleanup() }
        let part = Harness.partKey("k1")
        h.stub.setBody(randomBytes(500), for: part)
        h.stub.gate(part)
        let a = Task { try await h.get("k1") }
        let b = Task { try await h.get("k1") }
        #expect(await waitFor { h.stub.calls(part) >= 1 })
        try await Task.sleep(for: .milliseconds(50))
        h.stub.release(part)
        let urls = try await [a.value, b.value]
        #expect(urls[0] == urls[1])
        #expect(h.stub.calls(part) == 1)
    }

    @Test func differentKeysDownloadConcurrently() async throws {
        let h = Harness(); defer { h.cleanup() }
        let (p1, p2) = (Harness.partKey("a"), Harness.partKey("b"))
        h.stub.gate(p1); h.stub.gate(p2)
        let a = Task { try await h.get("a", bytes: 10) }
        let b = Task { try await h.get("b", bytes: 10) }
        #expect(await waitFor { h.stub.calls(p1) == 1 && h.stub.calls(p2) == 1 })
        #expect(await h.cache.stats().inFlight == 2)
        h.stub.release(p1); h.stub.release(p2)
        _ = try await (a.value, b.value)
        #expect(await h.cache.stats().inFlight == 0)
    }

    // MARK: Validation and failure

    @Test func sizeMismatchStoresNothing() async throws {
        let h = Harness(); defer { h.cleanup() }
        await #expect(throws: TrackCacheError.sizeMismatch(expected: 100, actual: 200)) {
            try await h.get("k1", bytes: 200, expected: 100)
        }
        #expect(filesOnDisk(h.dir).isEmpty)
        #expect(await h.cache.entries().isEmpty)
        #expect(tempContents(h.dir).isEmpty)
    }

    @Test func emptyBodyIsRejected() async throws {
        let h = Harness(); defer { h.cleanup() }
        await #expect(throws: TrackCacheError.sizeMismatch(expected: nil, actual: 0)) {
            try await h.get("k1", bytes: 0)
        }
        #expect(filesOnDisk(h.dir).isEmpty)
    }

    @Test func downloadFailureReachesEveryWaiterAndLeavesNoTemp() async throws {
        let h = Harness(); defer { h.cleanup() }
        let part = Harness.partKey("k1")
        h.stub.gate(part)
        let a = Task { try await h.get("k1") }
        let b = Task { try await h.get("k1") }
        #expect(await waitFor { h.stub.calls(part) >= 1 })
        try await Task.sleep(for: .milliseconds(50))
        let failure = TrackCacheError.download(.httpStatus(500))
        h.stub.fail(part, with: failure)
        for task in [a, b] {
            await #expect(throws: failure) { try await task.value }
        }
        #expect(tempContents(h.dir).isEmpty)
        #expect(await h.cache.stats().inFlight == 0)
        try await h.get("k1", bytes: 50)
        #expect(h.stub.calls(part) == 2)
    }

    // MARK: Cancellation

    @Test func cancellingTheLastWaiterCancelsTheDownload() async throws {
        let h = Harness(); defer { h.cleanup() }
        let part = Harness.partKey("k1")
        h.stub.gate(part)
        let task = Task { try await h.get("k1", bytes: 40) }
        #expect(await waitFor { h.stub.calls(part) == 1 })
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await waitFor { h.stub.cancelCount == 1 })
        #expect(await waitFor { tempContents(h.dir).isEmpty })
        #expect(await h.cache.stats().inFlight == 0)
        // A new request starts a fresh download instead of inheriting the cancelled one.
        let again = Task { try await h.get("k1") }
        #expect(await waitFor { h.stub.calls(part) == 2 })
        h.stub.release(part)
        _ = try await again.value
    }

    @Test func cancellingOneOfTwoWaitersKeepsTheDownload() async throws {
        let h = Harness(); defer { h.cleanup() }
        let part = Harness.partKey("k1")
        h.stub.gate(part)
        h.stub.setBody(randomBytes(64), for: part)
        let a = Task { try await h.get("k1") }
        let b = Task { try await h.get("k1") }
        #expect(await waitFor { h.stub.calls(part) >= 1 })
        // Let both register before cancelling one.
        #expect(await waitFor { await h.cache.stats().inFlight == 1 })
        try await Task.sleep(for: .milliseconds(50))
        a.cancel()
        await #expect(throws: CancellationError.self) { try await a.value }
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.stub.cancelCount == 0)
        h.stub.release(part)
        let url = try await b.value
        #expect(try Data(contentsOf: url).count == 64)
    }

    @Test func pinnedDownloadOutlivesItsWaiters() async throws {
        let h = Harness(); defer { h.cleanup() }
        let part = Harness.partKey("k1")
        h.stub.gate(part)
        h.stub.setBody(randomBytes(64), for: part)
        await h.cache.setPinned(["k1"])
        let task = Task { try await h.get("k1") }
        #expect(await waitFor { h.stub.calls(part) == 1 })
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.stub.cancelCount == 0)
        h.stub.release(part)
        #expect(await waitFor { await h.cache.stats().fileCount == 1 })
        try await h.get("k1")
        #expect(h.stub.calls(part) == 1)
    }

    @Test func skipToPrefetchedTrackJoinsTheRunningDownload() async throws {
        let h = Harness(); defer { h.cleanup() }
        let part = Harness.partKey("B")
        h.stub.gate(part)
        h.stub.setBody(randomBytes(64), for: part)
        await h.cache.setPinned(["A", "B"])
        let prefetch = Task { try await h.get("B") }
        #expect(await waitFor { h.stub.calls(part) == 1 })
        prefetch.cancel()   // the Player cancels the preload on skip
        await #expect(throws: CancellationError.self) { try await prefetch.value }
        let playing = Task { try await h.get("B") }   // then asks for the same key
        try await Task.sleep(for: .milliseconds(50))
        h.stub.release(part)
        let url = try await playing.value
        #expect(try Data(contentsOf: url).count == 64)
        #expect(h.stub.calls(part) == 1)
        #expect(h.stub.cancelCount == 0)
    }

    // MARK: Eviction

    @Test func lruEvictsTheOldestFirst() async throws {
        let h = Harness(limit: 300); defer { h.cleanup() }
        for key in ["A", "B", "C"] {
            try await h.get(key, bytes: 100)
            h.clock.advance(seconds: 10)
        }
        try await h.get("A")   // touch
        h.clock.advance(seconds: 10)
        try await h.get("D", bytes: 100)
        #expect(Set(filesOnDisk(h.dir).keys) == ["A.m4a", "C.m4a", "D.m4a"])
        #expect(await h.cache.stats().totalBytes == 300)
    }

    @Test func pinnedFilesAreNeverEvicted() async throws {
        let h = Harness(limit: 300); defer { h.cleanup() }
        for key in ["A", "B", "C"] {
            try await h.get(key, bytes: 100)
            h.clock.advance(seconds: 10)
        }
        await h.cache.setPinned(["A"])
        try await h.get("D", bytes: 100)
        #expect(Set(filesOnDisk(h.dir).keys) == ["A.m4a", "C.m4a", "D.m4a"])
        h.clock.advance(seconds: 10)
        await h.cache.setPinned(["A", "C", "D"])
        try await h.get("E", bytes: 100)
        #expect(Set(filesOnDisk(h.dir).keys) == ["A.m4a", "C.m4a", "D.m4a", "E.m4a"])
        let stats = await h.cache.stats()
        #expect(stats.totalBytes > stats.limitBytes)
    }

    @Test func theInsertedFileSurvivesItsOwnInsert() async throws {
        let h = Harness(limit: 300); defer { h.cleanup() }
        try await h.get("big", bytes: 500)
        #expect(filesOnDisk(h.dir)["big.m4a"] == 500)
        h.clock.advance(seconds: 10)
        try await h.get("small", bytes: 100)
        #expect(Set(filesOnDisk(h.dir).keys) == ["small.m4a"])
    }

    @Test func loweringTheLimitEvictsAtOnce() async throws {
        let h = Harness(limit: 1000); defer { h.cleanup() }
        for key in ["A", "B", "C"] {
            try await h.get(key, bytes: 100)
            h.clock.advance(seconds: 10)
        }
        await h.cache.setLimit(150)
        #expect(Set(filesOnDisk(h.dir).keys) == ["C.m4a"])
        #expect(await h.cache.stats().limitBytes == 150)
    }

    @Test func sizeAccountingMatchesDisk() async throws {
        let h = Harness(limit: 450); defer { h.cleanup() }
        for (i, key) in ["A", "B", "C", "D", "E", "F"].enumerated() {
            try await h.get(key, bytes: 100 + i * 10)
            h.clock.advance(seconds: 10)
            if i % 2 == 1 { try await h.get("A") }
        }
        let stats = await h.cache.stats()
        let disk = filesOnDisk(h.dir)
        #expect(stats.totalBytes == disk.values.reduce(0, +))
        #expect(stats.fileCount == disk.count)
        #expect(stats.totalBytes <= 450)
    }

    // MARK: Index

    @Test func indexIsRebuiltWhenMissing() async throws {
        let h = Harness(); defer { h.cleanup() }
        try await h.get("A", bytes: 100)
        try await h.get("B", bytes: 200)
        try FileManager.default.removeItem(at: h.dir.appendingPathComponent("index.json"))
        let reopened = h.reopen()
        let entries = await reopened.entries()
        #expect(Set(entries.map(\.key)) == ["A", "B"])
        #expect(Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.size) }) == ["A": 100, "B": 200])
        for entry in entries {
            let modified = try #require(try FileManager.default.attributesOfItem(
                atPath: h.dir.appendingPathComponent(entry.fileName).path)[.modificationDate] as? Date)
            #expect(abs(entry.lastAccess.timeIntervalSince(modified)) < 2)
        }
        #expect(FileManager.default.fileExists(atPath: h.dir.appendingPathComponent("index.json").path))
    }

    @Test func corruptIndexIsReplaced() async throws {
        let h = Harness(); defer { h.cleanup() }
        try await h.get("A", bytes: 100)
        let index = h.dir.appendingPathComponent("index.json")
        try Data("not json".utf8).write(to: index)
        let reopened = h.reopen()
        try await reopened.prepare()
        #expect(await reopened.entries().map(\.key) == ["A"])
        #expect((try? JSONSerialization.jsonObject(with: Data(contentsOf: index))) != nil)
    }

    @Test func staleEntriesAndWrongSizedFilesAreDropped() async throws {
        let h = Harness(); defer { h.cleanup() }
        try await h.get("gone", bytes: 100)
        try await h.get("short", bytes: 100)
        try FileManager.default.removeItem(at: h.dir.appendingPathComponent("gone.m4a"))
        try Data(repeating: 1, count: 10).write(to: h.dir.appendingPathComponent("short.m4a"))
        let reopened = h.reopen()
        #expect(await reopened.entries().isEmpty)
        #expect(filesOnDisk(h.dir).isEmpty)
        try await h.get("gone", cache: reopened)
        try await h.get("short", cache: reopened)
        #expect(h.stub.calls(Harness.partKey("gone")) == 2)
        #expect(h.stub.calls(Harness.partKey("short")) == 2)
    }

    @Test func partialTempFilesAreRemovedOnPrepare() async throws {
        let h = Harness(); defer { h.cleanup() }
        try await h.get("A", bytes: 100)
        let tmp = h.dir.appendingPathComponent("tmp")
        try Data("half".utf8).write(to: tmp.appendingPathComponent("x-y.part"))
        #expect(tempContents(h.dir) == ["x-y.part"])
        let reopened = h.reopen()
        try await reopened.prepare()
        #expect(tempContents(h.dir).isEmpty)
        #expect(filesOnDisk(h.dir) == ["A.m4a": 100])
    }

    @Test func clearRemovesEverything() async throws {
        let h = Harness(); defer { h.cleanup() }
        try await h.get("A", bytes: 100)
        try await h.get("B", bytes: 100)
        try await h.cache.clear()
        #expect(filesOnDisk(h.dir).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: h.dir.appendingPathComponent("index.json").path))
        let stats = await h.cache.stats()
        #expect(stats.totalBytes == 0 && stats.fileCount == 0)
        try await h.get("A")
        #expect(h.stub.calls(Harness.partKey("A")) == 2)
        let empty = Harness(); defer { empty.cleanup() }
        try await empty.cache.clear()
    }

    @Test func lastAccessSurvivesRestart() async throws {
        let h = Harness(limit: 200); defer { h.cleanup() }
        try await h.get("A", bytes: 100)
        h.clock.advance(seconds: 10)
        try await h.get("B", bytes: 100)
        h.clock.advance(seconds: 10)
        try await h.get("A")   // A is now newer than B, though B's file is newer on disk
        h.clock.advance(seconds: 10)
        let reopened = h.reopen(limit: 200)
        try await h.get("C", bytes: 100, cache: reopened)
        #expect(Set(filesOnDisk(h.dir).keys) == ["A.m4a", "C.m4a"])
    }

    @Test func fileNamesUseTheKeyAndTheSanitizedExtension() async throws {
        let h = Harness(); defer { h.cleanup() }
        let cases: [(String, String)] = [
            ("/library/parts/1/2/file.m4a", "k1.m4a"),
            ("/library/parts/1/2/file.MP3", "k2.mp3"),
            ("/library/parts/1/2/file.weird-ext!", "k3.audio"),
            ("/library/parts/1/2/file", "k4.audio"),
        ]
        for (i, (partKey, expected)) in cases.enumerated() {
            h.stub.setBody(randomBytes(10), for: partKey)
            let url = try await h.cache.file(forKey: "k\(i + 1)", partKey: partKey, expectedSize: nil)
            #expect(url.lastPathComponent == expected)
        }
    }

    @Test func indexHoldsOnlyKeysNamesSizesAndDates() async throws {
        let h = Harness(); defer { h.cleanup() }
        try await h.get("A", bytes: 100)
        let data = try Data(contentsOf: h.dir.appendingPathComponent("index.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["version", "entries"])
        let entries = try #require(json["entries"] as? [[String: Any]])
        #expect(entries.count == 1)
        for entry in entries { #expect(Set(entry.keys) == ["key", "fileName", "size", "lastAccess"]) }
    }

    @Test func missingCachedFileIsDownloadedAgain() async throws {
        let h = Harness(); defer { h.cleanup() }
        let url = try await h.get("A", bytes: 100)
        try FileManager.default.removeItem(at: url)   // a purge behind the cache's back
        let again = try await h.get("A")
        #expect(h.stub.calls(Harness.partKey("A")) == 2)
        #expect(FileManager.default.fileExists(atPath: again.path))
    }

    // MARK: Folders removed while running

    @Test func deletedCacheFolderIsRecreatedOnTheNextDownload() async throws {
        let h = Harness(); defer { h.cleanup() }
        try await h.get("A", bytes: 100)
        try FileManager.default.removeItem(at: h.dir)
        #expect(!FileManager.default.fileExists(atPath: h.dir.path))
        let url = try await h.get("B", bytes: 100)
        #expect(try Data(contentsOf: url).count == 100)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: h.dir.appendingPathComponent("tmp").path, isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(filesOnDisk(h.dir) == ["B.m4a": 100])
        #expect(await h.cache.entries().map(\.key) == ["B"])
        #expect(await h.cache.stats().totalBytes == 100)
        #expect(tempContents(h.dir).isEmpty)
        #expect(await h.reopen().entries().map(\.key) == ["B"])
        try await h.get("A")
        #expect(h.stub.calls(Harness.partKey("A")) == 2)
    }

    @Test func deletedTempFolderIsRecreatedOnTheNextDownload() async throws {
        let h = Harness(); defer { h.cleanup() }
        try await h.get("A", bytes: 100)
        try FileManager.default.removeItem(at: h.dir.appendingPathComponent("tmp"))
        try await h.get("B", bytes: 100)
        #expect(filesOnDisk(h.dir) == ["A.m4a": 100, "B.m4a": 100])
        #expect(Set(await h.cache.entries().map(\.key)) == ["A", "B"])
        try await h.get("A")
        #expect(h.stub.calls(Harness.partKey("A")) == 1)
        #expect(tempContents(h.dir).isEmpty)
    }

    // MARK: Unpin and Clear

    @Test func unpinningAWaiterlessDownloadCancelsIt() async throws {
        let h = Harness(); defer { h.cleanup() }
        let part = Harness.partKey("k1")
        h.stub.gate(part)
        h.stub.setBody(randomBytes(64), for: part)
        await h.cache.setPinned(["k1"])
        let task = Task { try await h.get("k1") }
        #expect(await waitFor { h.stub.calls(part) == 1 })
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.stub.cancelCount == 0)
        #expect(await h.cache.stats().inFlight == 1)
        await h.cache.setPinned([])
        #expect(await waitFor { h.stub.cancelCount == 1 })
        #expect(await waitFor { tempContents(h.dir).isEmpty })
        let stats = await h.cache.stats()
        #expect(stats.inFlight == 0)
        #expect(stats.fileCount == 0)
        h.stub.release(part)
        let url = try await h.get("k1")
        #expect(try Data(contentsOf: url).count == 64)
        #expect(h.stub.calls(part) == 2)
    }

    @Test func clearDuringADownloadLeavesItAndTempAlone() async throws {
        let h = Harness(); defer { h.cleanup() }
        try await h.get("A", bytes: 100)
        let partB = Harness.partKey("B")
        h.stub.gate(partB)
        h.stub.setBody(randomBytes(64), for: partB)
        let task = Task { try await h.get("B") }
        #expect(await waitFor { h.stub.calls(partB) == 1 })
        #expect(await waitFor { await h.cache.stats().inFlight == 1 })
        try await h.cache.clear()
        #expect(filesOnDisk(h.dir).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: h.dir.appendingPathComponent("index.json").path))
        #expect(tempContents(h.dir).count == 1)
        #expect(tempContents(h.dir).allSatisfy { $0.hasSuffix(".part") })
        #expect(await h.cache.stats().inFlight == 1)
        #expect(h.stub.cancelCount == 0)
        h.stub.release(partB)
        let url = try await task.value
        #expect(try Data(contentsOf: url).count == 64)
        #expect(filesOnDisk(h.dir) == ["B.m4a": 64])
        #expect(await h.cache.entries().map(\.key) == ["B"])
        #expect(tempContents(h.dir).isEmpty)
        #expect(FileManager.default.fileExists(atPath: h.dir.appendingPathComponent("index.json").path))
        #expect(await h.reopen().entries().map(\.key) == ["B"])
    }
}
