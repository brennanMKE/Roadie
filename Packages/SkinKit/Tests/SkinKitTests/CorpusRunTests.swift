import Foundation
import Testing
import ZIPFoundation
@testable import SkinKit

/// Thread-safe cell for closures the runner calls from its watchdog thread.
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    func update<R>(_ body: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&stored) }
    var value: T { update { $0 } }
}

private enum CorpusFixtures {
    static func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skinamp-corpus-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func writeZip(_ files: [(String, Data)], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in files {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
    }

    /// A complete synthetic skin; `tag` makes the bytes (and md5) differ between skins.
    static func skin(_ tag: String, omitting: Set<String> = ["NUMS_EX"]) -> [(String, Data)] {
        ZipFixtures.skinFiles(omitting: omitting, extra: [("readme.txt", Data(tag.utf8))])
    }

    static func config(timeout: Double = 10, sample: Int? = nil, resume: Bool = false) -> CorpusRunner.Config {
        var config = CorpusRunner.Config()
        config.timeout = timeout
        config.sample = sample
        config.resume = resume
        config.pollInterval = 0.02
        return config
    }

    static func hooks(
        process: @escaping @Sendable (URL) -> CorpusOutcome = CorpusRunner.processSkin,
        footprint: @escaping @Sendable () -> (current: Int, lifetimeMax: Int) = { (1, 1) },
        abort: @escaping @Sendable (Int32) -> Void = { _ in }
    ) -> CorpusRunner.Hooks {
        CorpusRunner.Hooks(process: process, footprint: footprint, abort: abort)
    }

    static func runner(
        _ corpus: URL, _ out: URL, config: CorpusRunner.Config = config(), hooks: CorpusRunner.Hooks = hooks()
    ) -> CorpusRunner {
        CorpusRunner(corpus: corpus, out: out, config: config, hooks: hooks, progress: { _ in })
    }

    static func results(_ out: URL) -> [CorpusRecord] {
        CorpusRunner.readRecords(out.appending(path: "results.jsonl"))
    }

    static let okOutcome = CorpusOutcome(status: "ok", entries: 3, mainWindowComplete: true, parseMs: 1, renderMs: 1)
}

@Suite struct CorpusRunTests {
    @Test func corpusRunRecordsEveryFileOnce() throws {
        let corpus = CorpusFixtures.tempDirectory(), out = CorpusFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: corpus); try? FileManager.default.removeItem(at: out) }
        try CorpusFixtures.writeZip(CorpusFixtures.skin("one"), to: corpus.appending(path: "a_one.wsz"))
        try CorpusFixtures.writeZip(CorpusFixtures.skin("two"), to: corpus.appending(path: "sub/b_two.wsz"))
        try CorpusFixtures.writeZip(
            CorpusFixtures.skin("three", omitting: ["NUMS_EX", "PLEDIT"]), to: corpus.appending(path: "c_three.wsz"))
        try CorpusFixtures.writeZip([("skin.xml", Data("<skin/>".utf8))], to: corpus.appending(path: "d_modern.wsz"))
        try Data("not a zip".utf8).write(to: corpus.appending(path: "e_garbage.wsz"))
        try FileManager.default.copyItem(at: corpus.appending(path: "a_one.wsz"), to: corpus.appending(path: "z_copy.wsz"))
        try Data("ignored".utf8).write(to: corpus.appending(path: "notes.txt"))

        let totals = try CorpusFixtures.runner(corpus, out).run()
        let records = CorpusFixtures.results(out)
        let starts = records.filter { $0.event == "start" }
        let results = records.filter { $0.event == "result" }
        #expect(totals.files == 6 && totals.unique == 5 && totals.attempted == 5)
        #expect(starts.count == 5)
        #expect(results.count == 6)
        let status = Dictionary(uniqueKeysWithValues: results.map { ($0.path ?? "", $0) })
        #expect(status["a_one.wsz"]?.status == "ok")
        #expect(status["sub/b_two.wsz"]?.status == "ok")
        #expect(status["c_three.wsz"]?.status == "partial")
        #expect(status["d_modern.wsz"]?.status == "modern")
        #expect(status["e_garbage.wsz"]?.status == "failed")
        #expect(status["z_copy.wsz"]?.status == "duplicate")
        #expect(status["z_copy.wsz"]?.of == "a_one.wsz")
        #expect(!starts.contains { $0.path == "z_copy.wsz" })
        for path in ["a_one.wsz", "sub/b_two.wsz", "c_three.wsz"] {
            #expect(status[path]?.mainWindowComplete == true)
            #expect((status[path]?.ms ?? 0) > 0)
            #expect((status[path]?.entries ?? 0) > 0)
        }
        #expect(status["e_garbage.wsz"]?.error?.hasPrefix("Unreadable archive") == true)
        // A finished run ends with an `end` line, and every line decodes (readRecords drops the ones that do not).
        #expect(records.last?.event == "end")
        let lines = try String(contentsOf: out.appending(path: "results.jsonl"), encoding: .utf8).split(separator: "\n")
        #expect(lines.count == records.count)
    }

    @Test func mainWindowCompleteFollowsRequiredSprites() throws {
        let corpus = CorpusFixtures.tempDirectory(), out = CorpusFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: corpus); try? FileManager.default.removeItem(at: out) }
        try CorpusFixtures.writeZip(
            CorpusFixtures.skin("x", omitting: ["NUMS_EX", "CBUTTONS"]), to: corpus.appending(path: "no_cbuttons.wsz"))
        try CorpusFixtures.writeZip(
            CorpusFixtures.skin("y", omitting: ["NUMS_EX", "PLEDIT"]), to: corpus.appending(path: "no_pledit.wsz"))
        _ = try CorpusFixtures.runner(corpus, out).run()
        let results = Dictionary(uniqueKeysWithValues: CorpusFixtures.results(out).filter { $0.event == "result" }.map { ($0.path ?? "", $0) })
        #expect(results["no_cbuttons.wsz"]?.status == "partial")
        #expect(results["no_cbuttons.wsz"]?.mainWindowComplete == false)
        #expect(results["no_pledit.wsz"]?.status == "partial")
        #expect(results["no_pledit.wsz"]?.mainWindowComplete == true)
    }

    @Test func watchdogTimesOutASlowSkin() throws {
        let corpus = CorpusFixtures.tempDirectory(), out = CorpusFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: corpus); try? FileManager.default.removeItem(at: out) }
        try Data("slow".utf8).write(to: corpus.appending(path: "slow.wsz"))
        let aborts = Box<[Int32]>([])
        let inFileAtAbort = Box(false)
        let hooks = CorpusFixtures.hooks(
            process: { _ in Thread.sleep(forTimeInterval: 1); return CorpusFixtures.okOutcome },
            abort: { code in
                aborts.update { $0.append(code) }
                inFileAtAbort.update { $0 = CorpusFixtures.results(out).contains { $0.status == "timeout" } }
            })
        let totals = try CorpusFixtures.runner(corpus, out, config: CorpusFixtures.config(timeout: 0.1), hooks: hooks).run()
        #expect(aborts.value == [124])
        #expect(inFileAtAbort.value)
        #expect(totals.aborted)
        let results = CorpusFixtures.results(out).filter { $0.event == "result" }
        #expect(results.count == 1)
        #expect(results.first?.status == "timeout")
        #expect(results.first?.path == "slow.wsz")
    }

    @Test func watchdogAbortsOverMemory() throws {
        let corpus = CorpusFixtures.tempDirectory(), out = CorpusFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: corpus); try? FileManager.default.removeItem(at: out) }
        try Data("big".utf8).write(to: corpus.appending(path: "big.wsz"))
        let aborts = Box<[Int32]>([])
        var config = CorpusFixtures.config()
        config.maxMemoryMiB = 100
        let hooks = CorpusFixtures.hooks(
            process: { _ in Thread.sleep(forTimeInterval: 0.5); return CorpusFixtures.okOutcome },
            footprint: { (101, 101) },
            abort: { code in aborts.update { $0.append(code) } })
        _ = try CorpusFixtures.runner(corpus, out, config: config, hooks: hooks).run()
        #expect(aborts.value == [125])
        let results = CorpusFixtures.results(out).filter { $0.event == "result" }
        #expect(results.map(\.status) == ["memory"])
    }

    @Test func resumeMarksTheInterruptedSkinCrashedAndSkipsFinishedOnes() throws {
        let corpus = CorpusFixtures.tempDirectory(), out = CorpusFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: corpus); try? FileManager.default.removeItem(at: out) }
        for name in ["a", "b", "c"] { try Data(name.utf8).write(to: corpus.appending(path: "\(name).wsz")) }
        var done = CorpusRecord(event: "result")
        done.path = "a.wsz"; done.status = "ok"
        var startB = CorpusRecord(event: "start")
        startB.path = "b.wsz"; startB.i = 1
        let encoder = JSONEncoder()
        var journal = Data()
        for record in [done, startB] { journal.append(try encoder.encode(record)); journal.append(0x0A) }
        try journal.write(to: out.appending(path: "results.jsonl"))

        let parsed = Box<[String]>([])
        let hooks = CorpusFixtures.hooks(process: { url in
            parsed.update { $0.append(url.lastPathComponent) }
            return CorpusFixtures.okOutcome
        })
        _ = try CorpusFixtures.runner(corpus, out, config: CorpusFixtures.config(resume: true), hooks: hooks).run()
        #expect(parsed.value == ["c.wsz"])
        let results = CorpusFixtures.results(out).filter { $0.event == "result" }
        let b = results.first { $0.path == "b.wsz" }
        #expect(b?.status == "crashed")
        #expect(b?.restart == 1)
        #expect(results.contains { $0.path == "c.wsz" && $0.status == "ok" })
        #expect(results.filter { $0.path == "a.wsz" }.count == 1)
    }

    @Test func resumeAfterATornLastLineKeepsTheNextRecord() throws {
        let corpus = CorpusFixtures.tempDirectory(), out = CorpusFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: corpus); try? FileManager.default.removeItem(at: out) }
        for name in ["a", "b"] { try Data(name.utf8).write(to: corpus.appending(path: "\(name).wsz")) }
        var startA = CorpusRecord(event: "start")
        startA.path = "a.wsz"; startA.i = 0
        var journal = try JSONEncoder().encode(startA)
        journal.append(0x0A)
        journal.append(Data(#"{"event":"start","path":"b.ws"#.utf8))  // killed mid-write, no newline
        try journal.write(to: out.appending(path: "results.jsonl"))

        let hooks = CorpusFixtures.hooks(process: { _ in CorpusFixtures.okOutcome })
        _ = try CorpusFixtures.runner(corpus, out, config: CorpusFixtures.config(resume: true), hooks: hooks).run()
        let results = CorpusFixtures.results(out).filter { $0.event == "result" }
        #expect(results.first { $0.path == "a.wsz" }?.status == "crashed")
        #expect(results.first { $0.path == "b.wsz" }?.status == "ok")
    }

    @Test func sampleIsDeterministic() {
        let names = (0..<5000).map { "skin\($0)" }
        let first = CorpusSample.pick(names, n: 1000, seed: 1)
        #expect(first.count == 1000)
        #expect(first == CorpusSample.pick(names, n: 1000, seed: 1))
        #expect(Set(first) != Set(CorpusSample.pick(names, n: 1000, seed: 2)))
        #expect(first == first.sorted { names.firstIndex(of: $0)! < names.firstIndex(of: $1)! })
        #expect(CorpusSample.pick(names, n: 5000, seed: 1) == names)
        #expect(CorpusSample.pick(names, n: 9999, seed: 1) == names)
    }

    @Test func summaryComputesRatesAndPercentiles() {
        var records: [CorpusRecord] = []
        func add(_ i: Int, _ status: String, ms: Double?, warnings: [String]? = nil, error: String? = nil, complete: Bool? = nil) {
            var r = CorpusRecord(event: "result")
            r.path = "skin\(String(format: "%02d", i)).wsz"; r.name = "skin\(i)"; r.md5 = String(format: "%032d", i)
            r.size = 1000 + i; r.entries = 10; r.status = status; r.ms = ms
            r.warnings = warnings; r.error = error; r.mainWindowComplete = complete
            records.append(r)
        }
        for i in 1...9 { add(i, "ok", ms: Double(i), complete: true) }
        for i in 10...16 { add(i, "partial", ms: Double(i), warnings: ["Missing cbuttons.bmp"], complete: i > 12) }
        add(17, "failed", ms: 17, error: "No classic skin bitmaps found")
        add(18, "modern", ms: 18)
        add(19, "modern", ms: 19)
        add(20, "duplicate", ms: nil)

        let summary = CorpusReport.summarize(records: records, sample: 1000)
        #expect(summary.files == 20 && summary.unique == 19 && summary.duplicates == 1)
        #expect(summary.modern == 2 && summary.classic == 17)
        #expect(summary.counts.ok == 9 && summary.counts.partial == 7 && summary.counts.failed == 1)
        #expect(abs(summary.okRate - 9.0 / 17) < 1e-9)
        #expect(summary.counts.mainWindowComplete == 13)
        // 19 timed parses (ok, partial, failed, modern): nearest rank 10, 19, 19.
        #expect(summary.timing.count == 19)
        #expect(summary.timing.medianMs == 10)
        #expect(summary.timing.p95Ms == 19)
        #expect(summary.timing.p99Ms == 19)
        let missing = summary.failureClasses.first { $0.key == "missing cbuttons" }
        #expect(missing?.count == 7)
        #expect(missing?.examples.count == 5)
        #expect(summary.failureClasses.contains { $0.key == "noBitmaps" && $0.count == 1 })
        #expect(summary.failureClasses.contains { $0.key == "modern" && $0.issue == "accepted" })
        #expect(summary.slowest.count == 19)
        #expect(summary.slowest.first?.ms == 19)
        #expect(summary.slowest.map(\.ms) == summary.slowest.map(\.ms).sorted(by: >))
        #expect(!summary.gatePass)
        #expect(summary.gate.hasPrefix("gate: FAIL (crashes=0, sample complete="))
        #expect(CorpusReport.percentile([1, 2, 3, 4], 50) == 2)
        #expect(CorpusReport.classKey(warning: "Undecodable main.bmp") == "undecodable main")
        #expect(CorpusReport.classKey(warning: "Missing numbers.bmp and nums_ex.bmp") == "missing numbers and nums_ex")
    }

    @Test func sampleSectionUsesTheSameSeed() throws {
        let corpus = CorpusFixtures.tempDirectory(), full = CorpusFixtures.tempDirectory(), sampled = CorpusFixtures.tempDirectory()
        defer { for url in [corpus, full, sampled] { try? FileManager.default.removeItem(at: url) } }
        for i in 0..<12 { try Data("skin \(i)".utf8).write(to: corpus.appending(path: String(format: "s%02d.wsz", i))) }
        let hooks = CorpusFixtures.hooks(process: { _ in CorpusFixtures.okOutcome })
        _ = try CorpusFixtures.runner(corpus, full, hooks: hooks).run()
        _ = try CorpusFixtures.runner(corpus, sampled, config: CorpusFixtures.config(sample: 5), hooks: hooks).run()

        let fullResults = CorpusFixtures.results(full).filter { $0.event == "result" }
        let expected = CorpusSample.pick(fullResults.compactMap(\.path).sorted(), n: 5, seed: 1)
        let actual = CorpusFixtures.results(sampled).filter { $0.event == "result" }.compactMap(\.path)
        #expect(actual == expected)
        let section = CorpusReport.summarize(records: CorpusFixtures.results(full), sample: 5, seed: 1).sample
        #expect(section.skins == 5 && section.requested == 5)
    }

    @Test func markdownReportIsPathFree() throws {
        let corpus = CorpusFixtures.tempDirectory(), out = CorpusFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: corpus); try? FileManager.default.removeItem(at: out) }
        try FileManager.default.createDirectory(at: corpus.appending(path: "deep/folder"), withIntermediateDirectories: true)
        try Data("one".utf8).write(to: corpus.appending(path: "deep/folder/Nice Skin.wsz"))
        try Data("two".utf8).write(to: corpus.appending(path: "deep/Naughty Name.wsz"))
        let manifest = out.appending(path: "manifest.jsonl")
        let naughtyMD5 = CorpusListing.md5Hex(of: corpus.appending(path: "deep/Naughty Name.wsz")) ?? ""
        try Data("{\"md5\":\"\(naughtyMD5)\",\"nsfw\":true}\n".utf8).write(to: manifest)
        var config = CorpusFixtures.config()
        config.manifest = manifest
        let hooks = CorpusFixtures.hooks(process: { _ in
            var outcome = CorpusFixtures.okOutcome
            outcome.status = "partial"; outcome.warnings = ["Missing pledit.bmp"]
            return outcome
        })
        _ = try CorpusFixtures.runner(corpus, out, config: config, hooks: hooks).run()
        let summary = CorpusReport.summarize(records: CorpusFixtures.results(out), environment: ["macOS": "26.6"])
        let markdown = CorpusReport.markdown(summary)
        #expect(markdown.contains("Skin corpus report"))
        #expect(markdown.contains("Unique classic skins"))
        #expect(markdown.contains("Nice Skin"))
        #expect(!markdown.contains("/Users/") && !markdown.contains("/Volumes/"))
        #expect(!markdown.contains(corpus.path) && !markdown.contains("deep/") && !markdown.contains("folder"))
        #expect(!markdown.contains("Naughty"))
        #expect(markdown.contains(naughtyMD5))
    }

    @Test func corpusOptionsParse() throws {
        let ok = try CorpusOptions.parse(["skins", "--out", "o", "--resume", "--timeout", "5", "--max-memory", "2048", "--sample", "7", "--seed", "3"]).get()
        #expect(ok.input == "skins" && ok.out == "o" && ok.resume && ok.timeout == 5 && ok.maxMemoryMiB == 2048)
        #expect(ok.sample == 7 && ok.seed == 3)
        #expect(throws: CorpusOptions.UsageError.self) { try CorpusOptions.parse(["skins", "--out", "o", "--timeout", "x"]).get() }
        #expect(throws: CorpusOptions.UsageError.self) { try CorpusOptions.parse(["skins"]).get() }
        #expect(throws: CorpusOptions.UsageError.self) { try CorpusOptions.parse(["--out", "o"]).get() }
        #expect(throws: CorpusOptions.UsageError.self) { try CorpusOptions.parse(["skins", "--out", "o", "--bogus"]).get() }
        let report = try CorpusReportOptions.parse(["r.jsonl", "--markdown", "m.md", "--json", "s.json", "--sample", "9"]).get()
        #expect(report.input == "r.jsonl" && report.markdown == "m.md" && report.json == "s.json" && report.sample == 9)
        #expect(throws: CorpusOptions.UsageError.self) { try CorpusReportOptions.parse(["r.jsonl", "--markdown", "m.md"]).get() }
        #expect(throws: CorpusOptions.UsageError.self) { try CorpusReportOptions.parse(["--json", "s", "--markdown", "m"]).get() }
    }
}
