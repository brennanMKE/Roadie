import CryptoKit
import Foundation
import Testing

@testable import SkinLibrary

@Suite struct SkinIndexerTests {
    /// Five skins: three ok, one partial, one modern (failed). Distinct bytes and readmes.
    private func makeCorpus(in folder: URL) throws {
        try SyntheticSkins.write(to: folder.appending(path: "alpha.wsz"), shade: 0x10, readme: "zebrafish readme")
        try SyntheticSkins.write(to: folder.appending(path: "beta.wsz"), shade: 0x20, readme: "beta readme")
        try SyntheticSkins.write(to: folder.appending(path: "sub/gamma.wsz"), shade: 0x30, readme: "gamma readme")
        try SyntheticSkins.write(to: folder.appending(path: "delta.wsz"), shade: 0x40, omitting: ["CBUTTONS"], readme: "delta readme")
        try SyntheticSkins.modern(to: folder.appending(path: "epsilon.wsz"), readme: "modern readme")
    }

    @Test func firstPassIndexesEverything() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let folder = try dir.skinsFolder()
        try makeCorpus(in: folder)
        let store = try await dir.makeStore()
        let summary = try await SkinIndexer(folder: folder, store: store).run()
        #expect(summary.added == 5)
        #expect(summary.failed == 1)
        #expect(summary.totalFiles == 5)
        #expect(summary.totalSkins == 5)
        #expect(summary.unchanged == 0)
        #expect(!summary.cancelled)
        let counts = try await store.counts()
        #expect(counts.byStatus == [.ok: 3, .partial: 1, .failed: 1])
        let records = try await store.skins()
        #expect(records.allSatisfy { SkinContentHash.isValid($0.hash) })
        #expect(records.map(\.name) == ["alpha", "beta", "delta", "epsilon", "gamma"])
        #expect(records.first { $0.name == "alpha" }?.readme == "zebrafish readme")
        #expect(records.first { $0.name == "epsilon" }?.readme == "modern readme")
        #expect(try await store.meta("last_scan") != nil)
        #expect(try await store.search("zebrafish").map(\.name) == ["alpha"])
    }

    @Test func secondPassWithNoChangesTouchesNothing() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let folder = try dir.skinsFolder()
        try makeCorpus(in: folder)
        let store = try await dir.makeStore()
        let ingester = CountingIngester()
        let indexer = SkinIndexer(folder: folder, store: store, ingester: ingester)
        _ = try await indexer.run()
        let hashes = ingester.hashes, inspections = ingester.inspections
        let second = try await indexer.run()
        #expect(second.unchanged == 5)
        #expect(second.added == 0 && second.updated == 0 && second.linked == 0 && second.removed == 0)
        #expect(ingester.hashes == hashes)
        #expect(ingester.inspections == inspections)
    }

    @Test func changedMtimeSameBytesRehashesButDoesNotReparse() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let folder = try dir.skinsFolder()
        try makeCorpus(in: folder)
        let store = try await dir.makeStore()
        let ingester = CountingIngester()
        let indexer = SkinIndexer(folder: folder, store: store, ingester: ingester)
        _ = try await indexer.run()
        let idBefore = try await store.skins().first { $0.name == "beta" }?.id
        let hashes = ingester.hashes, inspections = ingester.inspections
        try touch(folder.appending(path: "beta.wsz"), mtime: Date().addingTimeInterval(3600))
        let summary = try await indexer.run()
        #expect(ingester.hashes - hashes == 1)
        #expect(ingester.inspections - inspections == 0)
        #expect(summary.updated == 1 && summary.added == 0 && summary.unchanged == 4)
        #expect(try await store.skins().first { $0.name == "beta" }?.id == idBefore)
    }

    @Test func changedBytesReparsesAndPrunesTheOldSkin() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let folder = try dir.skinsFolder()
        try makeCorpus(in: folder)
        let store = try await dir.makeStore()
        let indexer = SkinIndexer(folder: folder, store: store)
        _ = try await indexer.run()
        let old = try #require(try await store.skins().first { $0.name == "alpha" })
        try SyntheticSkins.write(to: folder.appending(path: "alpha.wsz"), shade: 0x99, readme: "catfish readme")
        try touch(folder.appending(path: "alpha.wsz"), mtime: Date().addingTimeInterval(3600))
        let summary = try await indexer.run()
        #expect(summary.updated == 1)
        #expect(try await store.skin(hash: old.hash) == nil)
        #expect(try await store.search("zebrafish").isEmpty)
        #expect(try await store.search("catfish").map(\.name) == ["alpha"])
        #expect(try await store.counts().skins == 5)
    }

    @Test func duplicatesAreOneSkinWithManyFiles() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let folder = try dir.skinsFolder()
        try SyntheticSkins.write(to: folder.appending(path: "a.wsz"), readme: "dup")
        let store = try await dir.makeStore()
        let ingester = CountingIngester()
        let indexer = SkinIndexer(folder: folder, store: store, ingester: ingester)
        _ = try await indexer.run()
        let inspections = ingester.inspections
        try FileManager.default.createDirectory(at: folder.appending(path: "copy"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: folder.appending(path: "a.wsz"), to: folder.appending(path: "copy/a2.wsz"))
        try FileManager.default.copyItem(at: folder.appending(path: "a.wsz"), to: folder.appending(path: "zz.wsz"))
        let summary = try await indexer.run()
        #expect(summary.linked == 2)
        #expect(summary.added == 0)
        #expect(ingester.inspections == inspections)
        let records = try await store.skins()
        #expect(records.count == 1)
        #expect(records[0].fileCount == 3)
        #expect(records[0].name == "a")
        #expect(records[0].primaryPath == "a.wsz")
    }

    @Test func duplicatesInOneFirstPassAreParsedOnce() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let folder = try dir.skinsFolder()
        try SyntheticSkins.write(to: folder.appending(path: "b.wsz"), readme: "dup")
        try FileManager.default.copyItem(at: folder.appending(path: "b.wsz"), to: folder.appending(path: "a.wsz"))
        try FileManager.default.copyItem(at: folder.appending(path: "b.wsz"), to: folder.appending(path: "c.wsz"))
        let store = try await dir.makeStore()
        let ingester = CountingIngester()
        let summary = try await SkinIndexer(folder: folder, store: store, ingester: ingester).run()
        #expect(summary.added == 1 && summary.linked == 2)
        #expect(ingester.inspections == 1)
        #expect(try await store.skins().map(\.name) == ["a"])
    }

    @Test func removingOneDuplicateKeepsTheSkin_removingTheLastRemovesIt() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let folder = try dir.skinsFolder()
        try SyntheticSkins.write(to: folder.appending(path: "a.wsz"), readme: "dup")
        try FileManager.default.copyItem(at: folder.appending(path: "a.wsz"), to: folder.appending(path: "b.wsz"))
        let store = try await dir.makeStore()
        let indexer = SkinIndexer(folder: folder, store: store)
        _ = try await indexer.run()
        try FileManager.default.removeItem(at: folder.appending(path: "b.wsz"))
        let first = try await indexer.run()
        #expect(first.removed == 1)
        #expect(try await store.skins().first?.fileCount == 1)
        try FileManager.default.removeItem(at: folder.appending(path: "a.wsz"))
        let second = try await indexer.run()
        #expect(second.removed == 1)
        #expect(try await store.counts().skins == 0)
        #expect(second.totalSkins == 0)
    }

    @Test func parserVersionBumpReparsesEveryFileOnce() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let folder = try dir.skinsFolder()
        try SyntheticSkins.write(to: folder.appending(path: "a.wsz"), shade: 1)
        try SyntheticSkins.write(to: folder.appending(path: "b.wsz"), shade: 2)
        try SyntheticSkins.write(to: folder.appending(path: "c.wsz"), shade: 3)
        try FileManager.default.copyItem(at: folder.appending(path: "a.wsz"), to: folder.appending(path: "d.wsz"))
        let store = try await dir.makeStore()
        _ = try await SkinIndexer(folder: folder, store: store, parserVersion: 1).run()
        let idsBefore = Set(try await store.skins().map(\.id))
        let ingester = CountingIngester()
        let bumped = SkinIndexer(folder: folder, store: store, ingester: ingester, parserVersion: 2)
        let summary = try await bumped.run()
        #expect(ingester.inspections == 3)
        #expect(ingester.hashes == 4)
        #expect(summary.updated == 4)
        #expect(Set(try await store.skins().map(\.id)) == idsBefore)
        let third = try await bumped.run()
        #expect(third.unchanged == 4)
    }

    @Test func fullRescanRehashesAllButParsesNothingWhenUnchanged() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let folder = try dir.skinsFolder()
        try makeCorpus(in: folder)
        let store = try await dir.makeStore()
        let ingester = CountingIngester()
        let indexer = SkinIndexer(folder: folder, store: store, ingester: ingester)
        _ = try await indexer.run()
        let hashes = ingester.hashes, inspections = ingester.inspections
        let summary = try await indexer.run(full: true)
        #expect(ingester.hashes - hashes == 5)
        #expect(ingester.inspections == inspections)
        #expect(summary.updated == 5 && summary.unchanged == 0)
    }

    @Test func unreadableFileIsRecordedAsFailedAndNotRetried() async throws {
        if geteuid() == 0 { return }   // root can read a mode 000 file
        let dir = try TempDir()
        defer { dir.cleanup() }
        let folder = try dir.skinsFolder()
        let url = folder.appending(path: "locked.wsz")
        try SyntheticSkins.write(to: url, readme: "secret")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        let store = try await dir.makeStore()
        let ingester = CountingIngester()
        let indexer = SkinIndexer(folder: folder, store: store, ingester: ingester)
        let first = try await indexer.run()
        #expect(first.failed == 1 && first.added == 1)
        let record = try #require(try await store.skins().first)
        #expect(record.status == .failed)
        #expect(record.warnings.first?.hasPrefix("Unreadable file") == true)
        let hashes = ingester.hashes
        let second = try await indexer.run()
        #expect(ingester.hashes == hashes)
        #expect(second.unchanged == 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try touch(url, mtime: Date().addingTimeInterval(3600))
        let third = try await indexer.run()
        #expect(third.updated == 1 || third.added == 1)
        #expect(try await store.skins().first?.status == .ok)
        #expect(try await store.counts().skins == 1)
    }

    @Test func cancelMidPassKeepsCommittedBatchesAndTheNextPassFinishes() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let folder = try dir.skinsFolder()
        try makeStubFiles(count: 60, in: folder)
        let store = try await dir.makeStore()
        let indexer = SkinIndexer(
            folder: folder, store: store, ingester: StubIngester(), concurrency: 4, batchSize: 10,
            progressInterval: .zero)
        // With `progressInterval: .zero` progress fires after every batch, so the cancel lands after batch 2.
        let cancelled = try await indexer.run { progress in
            if progress.phase == .indexing, progress.processed >= 20 { indexer.cancel() }
        }
        #expect(cancelled.cancelled)
        #expect(try await store.counts().files == 20)
        let next = try await indexer.run()
        #expect(!next.cancelled)
        #expect(next.added == 40)
        #expect(next.unchanged == 20)
        #expect(try await store.counts().files == 60)
    }

    @Test func concurrentRunThrowsPassAlreadyRunning() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let folder = try dir.skinsFolder()
        try makeStubFiles(count: 10, in: folder)
        let store = try await dir.makeStore()
        let indexer = SkinIndexer(folder: folder, store: store, ingester: StubIngester(), concurrency: 2, batchSize: 10)
        // The scanning progress fires on the actor inside pass 1, right before it suspends on the folder scan, so a
        // task started here reaches the actor while pass 1 is still running. No thread is blocked and nothing waits
        // on time (a blocking gate starved the cooperative pool alongside the thumbnail tests' latches).
        let probe = LockedBox<Task<(Bool, Error?), Never>?>(nil)
        let summary = try await indexer.run { progress in
            guard progress.phase == .scanning else { return }
            probe.value = Task {
                let wasRunning = await indexer.isRunning
                do { _ = try await indexer.run() } catch { return (wasRunning, error) }
                return (wasRunning, nil)
            }
        }
        let (wasRunning, error) = await (try #require(probe.value)).value
        #expect(wasRunning)
        #expect(error is SkinLibraryError)
        #expect(summary.added == 10)
        #expect(await indexer.isRunning == false)
    }

    @Test func progressIsMonotonicAndEndsInDone() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let folder = try dir.skinsFolder()
        try makeStubFiles(count: 55, in: folder)
        let store = try await dir.makeStore()
        let recorder = Recorder<SkinIndexProgress>()
        let indexer = SkinIndexer(
            folder: folder, store: store, ingester: StubIngester(), concurrency: 2, batchSize: 10, progressInterval: .zero)
        _ = try await indexer.run { recorder.add($0) }
        let all = recorder.all
        let order: [SkinIndexProgress.Phase] = [.scanning, .indexing, .pruning, .hashing, .done]
        let ranks = all.map { order.firstIndex(of: $0.phase)! }
        #expect(ranks == ranks.sorted())
        let processed = all.map(\.processed)
        #expect(processed == processed.sorted())
        let last = try #require(all.last)
        #expect(last.phase == .done)
        #expect(last.changed == 55 && last.processed == 55 && last.totalFiles == 55)
    }

    @Test func nothingRunsOnTheMainThread() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let folder = try dir.skinsFolder()
        try makeStubFiles(count: 40, in: folder)
        let store = try await dir.makeStore()
        let ingester = StubIngester(recordThread: true)
        let onMain = Recorder<Bool>()
        let indexer = SkinIndexer(
            folder: folder, store: store, ingester: ingester, concurrency: 2, batchSize: 10, progressInterval: .zero)
        _ = try await indexer.run { _ in onMain.add(Thread.isMainThread) }
        #expect(ingester.mainThreadCalls == 0)
        #expect(!onMain.all.isEmpty)
        #expect(!onMain.all.contains(true))
    }

    // MARK: MD5 and single-file add (#0126)

    private func md5(of url: URL) throws -> String {
        Insecure.MD5.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    @Test func ingestStoresMD5() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let folder = try dir.skinsFolder()
        try makeCorpus(in: folder)
        let store = try await dir.makeStore()
        _ = try await SkinIndexer(folder: folder, store: store).run()
        let alpha = try md5(of: folder.appending(path: "alpha.wsz"))
        let record = try #require(try await store.skin(atPath: "alpha.wsz"))
        #expect(record.md5 == alpha)
        #expect(try await store.skins(md5s: [alpha])[alpha]?.id == record.id)
        #expect(try await store.skinsMissingMD5(limit: 10).isEmpty)
    }

    @Test func passBackfillsMissingMD5() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let folder = try dir.skinsFolder()
        try makeCorpus(in: folder)
        let store = try await dir.makeStore()
        // Rows as a v1 index left them: current stamps and parser version, no MD5.
        let stamps = try FolderScanner.list(folder: folder)
        _ = try await store.apply(
            try stamps.map { stamp in
                parsedOutcome(
                    stamp.path, hash: try SkinContentHash.hex(of: folder.appending(path: stamp.path)),
                    version: SkinIngester.parserVersion, size: stamp.size, mtime: stamp.mtime)
            })
        #expect(try await store.skinsMissingMD5(limit: 10).count == 5)
        let ingester = CountingIngester()
        let recorder = Recorder<SkinIndexProgress>()
        let indexer = SkinIndexer(folder: folder, store: store, ingester: ingester, batchSize: 2, progressInterval: .zero)
        let summary = try await indexer.run { recorder.add($0) }
        #expect(summary.unchanged == 5)
        #expect(!summary.cancelled)
        #expect(ingester.inspections == 0)
        #expect(ingester.hashes == 5)
        #expect(recorder.all.contains { $0.phase == .hashing })
        #expect(try await store.skinsMissingMD5(limit: 10).isEmpty)
        for stamp in stamps {
            #expect(try await store.skin(atPath: stamp.path)?.md5 == md5(of: folder.appending(path: stamp.path)))
        }
        // It runs once: the next pass reads nothing.
        _ = try await indexer.run()
        #expect(ingester.hashes == 5)
    }

    @Test func addIndexesOneFileWithoutScanning() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let folder = try dir.skinsFolder()
        try makeCorpus(in: folder)
        let store = try await dir.makeStore()
        let ingester = CountingIngester()
        let indexer = SkinIndexer(folder: folder, store: store, ingester: ingester)
        let summary = try await indexer.add(paths: ["sub/gamma.wsz"])
        #expect(summary.added == 1)
        #expect(summary.totalFiles == 1 && summary.totalSkins == 1)
        #expect(ingester.hashes == 1 && ingester.inspections == 1)
        let record = try #require(try await store.skin(atPath: "sub/gamma.wsz"))
        #expect(record.name == "gamma")
        #expect(record.status == .ok)
        #expect(record.md5 == (try md5(of: folder.appending(path: "sub/gamma.wsz"))))
        // A byte-identical copy links to the same skin.
        try FileManager.default.createDirectory(at: folder.appending(path: "Museum"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: folder.appending(path: "alpha.wsz"), to: folder.appending(path: "Museum/alpha.wsz"))
        _ = try await indexer.add(paths: ["alpha.wsz"])
        let linked = try await indexer.add(paths: ["Museum/alpha.wsz"])
        #expect(linked.linked == 1)
        #expect(try await store.counts().skins == 2)
        // The next pass picks the stamps up as unchanged.
        let pass = try await indexer.run()
        #expect(pass.unchanged == 3)
        #expect(pass.added == 3)
    }

    @Test func addDuringPassThrowsAlreadyRunning() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let folder = try dir.skinsFolder()
        try makeStubFiles(count: 10, in: folder)
        let store = try await dir.makeStore()
        let indexer = SkinIndexer(folder: folder, store: store, ingester: StubIngester(), concurrency: 2, batchSize: 10)
        let probe = LockedBox<Task<Error?, Never>?>(nil)
        let summary = try await indexer.run { progress in
            guard progress.phase == .scanning else { return }
            probe.value = Task {
                do { _ = try await indexer.add(paths: ["d000/00000.wsz"]) } catch { return error }
                return nil
            }
        }
        let error = await (try #require(probe.value)).value
        guard case SkinLibraryError.passAlreadyRunning? = error as? SkinLibraryError else {
            Issue.record("expected passAlreadyRunning, got \(String(describing: error))")
            return
        }
        #expect(summary.added == 10)
        #expect(await indexer.isRunning == false)
    }
}

/// `count` empty files `dNNN/NNNNN.wsz` (100 folders); the stub ingester never reads them.
func makeStubFiles(count: Int, in folder: URL, perFolder: Int = 100) throws {
    let fm = FileManager.default
    for index in 0..<count {
        let sub = folder.appending(path: String(format: "d%03d", index / perFolder), directoryHint: .isDirectory)
        if index % perFolder == 0 { try fm.createDirectory(at: sub, withIntermediateDirectories: true) }
        guard fm.createFile(atPath: sub.appending(path: String(format: "%05d.wsz", index)).path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
