import Foundation
import Testing

@testable import SkinLibrary

/// Opt-in: the 100k scale checks (`SkinIndexScaleTests`, `SkinSearchBudgetTests`) run only in the VM's full tier (`scripts/run-tests-vm.sh --full`, #0085).
enum SlowTests { static let isEnabled = ProcessInfo.processInfo.environment["ROADIE_SLOW_TESTS"] == "1" }

/// Scale checks, opt-in with `ROADIE_SLOW_TESTS=1` (the VM's full tier, `--full`); plain `swift test` skips them.
/// Wall-clock numbers are printed for the log, never asserted tightly: the VM may be loaded.
@Suite struct SkinIndexScaleTests {
    static let scale = 100_000

    @Test(.enabled(if: SlowTests.isEnabled), .timeLimit(.minutes(5)))
    func hundredThousandStubFilesIndexAndReindexIncrementally() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let folder = try dir.skinsFolder()
        let created = ContinuousClock().measure { try? makeStubFiles(count: Self.scale, in: folder, perFolder: 1000) }
        print("SCALE create \(Self.scale) files: \(created)")

        let scanStart = ContinuousClock.now
        _ = try FolderScanner.list(folder: folder)
        print("SCALE scan \(Self.scale) files: \(scanStart.duration(to: .now))")

        let store = try await dir.makeStore()
        let ingester = StubIngester()
        let indexer = SkinIndexer(folder: folder, store: store, ingester: ingester, concurrency: 4)

        let first = try await indexer.run()
        print("SCALE pass 1 (index): \(first.duration) s, added \(first.added)")
        #expect(first.added == Self.scale)
        let counts = try await store.counts()
        #expect(counts.skins == Self.scale && counts.files == Self.scale)

        let hashesAfterFirst = ingester.hashes
        let second = try await indexer.run()
        print("SCALE pass 2 (unchanged): \(second.duration) s")
        #expect(second.unchanged == Self.scale)
        #expect(ingester.hashes == hashesAfterFirst)

        // Touch 10, delete 10, add 10 (one a byte-identical twin of an existing skin).
        let fm = FileManager.default
        func path(_ index: Int) -> URL {
            folder.appending(path: String(format: "d%03d/%05d.wsz", index / 1000, index))
        }
        for index in 0..<10 { try touch(path(50_000 + index), mtime: Date().addingTimeInterval(3600)) }
        for index in 0..<10 { try fm.removeItem(at: path(70_000 + index)) }
        try fm.createDirectory(at: folder.appending(path: "new"), withIntermediateDirectories: true)
        for index in 0..<10 { fm.createFile(atPath: folder.appending(path: "new/n\(index).wsz").path, contents: nil) }
        ingester.override(path: "new/n0.wsz", hash: "stub:d005/05000.wsz")
        let third = try await indexer.run()
        print("SCALE pass 3 (10 touched, 10 removed, 10 added): \(third.duration) s")
        #expect(third.updated == 10)
        #expect(third.removed == 10)
        #expect(third.added == 9)
        #expect(third.linked == 1)
        #expect(third.unchanged == Self.scale - 10 - 10)
        #expect(try await store.counts().files == Self.scale)
        #expect(ingester.hashes - hashesAfterFirst == 20)

        let searchStart = ContinuousClock.now
        let found = try await store.search("00042")
        print("SCALE search over \(Self.scale) skins: \(searchStart.duration(to: .now))")
        #expect(found.map(\.name) == ["00042"])
    }

    @Test(.enabled(if: SlowTests.isEnabled), .timeLimit(.minutes(5)))
    func ftsSearchOnHundredThousandRowsIsFast() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let store = try await dir.makeStore()
        let words = (0..<200).map { "word\($0)" } + ["dragon", "matrix", "trinity", "neon", "sunset"]
        var seed: UInt64 = 12345
        func next() -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(seed >> 33)
        }
        let insertStart = ContinuousClock.now
        for start in stride(from: 0, to: Self.scale, by: 1000) {
            let batch = (start..<start + 1000).map { n -> IngestOutcome in
                let readme = (0..<4).map { _ in words[next() % words.count] }.joined(separator: " ")
                return parsedOutcome(
                    "d\(n / 1000)/\(n).wsz", hash: "hash\(n)", name: "skin-\(n)", readme: readme,
                    status: n % 7 == 0 ? .partial : .ok)
            }
            _ = try await store.apply(batch)
        }
        print("SCALE insert \(Self.scale) rows with FTS: \(insertStart.duration(to: .now))")

        var searchTimes: [Double] = [], pageTimes: [Double] = []
        var matches = 0
        for _ in 0..<5 {
            var start = ContinuousClock.now
            matches = try await store.search("dragon").count
            searchTimes.append(start.duration(to: .now).seconds)
            start = ContinuousClock.now
            let page = try await store.skins(status: .partial, limit: 200)
            pageTimes.append(start.duration(to: .now).seconds)
            #expect(page.count == 200)
        }
        let searchMedian = searchTimes.sorted()[2], pageMedian = pageTimes.sorted()[2]
        print("SCALE search 'dragon' median \(searchMedian) s (\(matches) rows), partial page median \(pageMedian) s")
        #expect(matches > 0 && matches <= 200)
        #expect(searchMedian < 1.0)
        #expect(pageMedian < 1.0)
    }
}

extension Duration {
    fileprivate var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
