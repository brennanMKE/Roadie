import CoreGraphics
import Foundation
import SkinKit
import SkinLibrary

// Usage: skintool [-v|--verbose] [--png <out> [--state webamp|idle] [--scale N] [--compare <refdir>] [--no-region]]
//                 <skin.wsz | folder>
// Prints one line per skin: ok / partial (warnings) / failed (reason). -v adds the fallbacks used.
// --png also renders the main window headless (no AppKit, no window) to <out> (a file for one skin, a folder
// for a folder, <basename>.png each); --compare diffs each render against <refdir>/<basename>.png and writes
// <out>/<basename>.diff.png. Comparison numbers are reported, never gated.
//        skintool index <folder> [--db <file>] [--full]
// `index` runs the incremental SQLite index pass (#0033) over a folder; without --db it writes the file the app reads.
//        skintool corpus <dir> --out <dir> [--resume] [--timeout s] [--max-memory MiB] [--sample N] [--seed n] [--manifest f]
//        skintool corpus-report <results.jsonl> --markdown <report.md> --json <summary.json> [--env f] [--sample N] [--seed n] [--crashes dir]
// `corpus` runs every skin of a folder through parse plus render, journaling results.jsonl so a crash can be resumed;
// `corpus-report` turns that journal into numbers (#0038). Exit status: 0 only if every skin is ok and every render succeeded, 1 otherwise (64 usage, 66 no such file).

func standardError(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

/// `skintool index <folder> [--db <file>] [--full]`: one incremental index pass, progress on stderr.
func runIndex(_ arguments: [String]) async -> Int32 {
    var folder: String?
    var dbPath: String?
    var full = false
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--db": dbPath = iterator.next()
        case "--full": full = true
        default: folder = argument
        }
    }
    guard let folder else {
        standardError("usage: skintool index <folder> [--db <file>] [--full]")
        return 64
    }
    do {
        let store = try await SkinIndexStore.open(at: dbPath.map { URL(filePath: $0) } ?? SkinIndexStore.defaultURL)
        let indexer = SkinIndexer(folder: URL(filePath: folder), store: store)
        let summary = try await indexer.run(full: full) { progress in
            standardError("\(progress.phase.rawValue) \(progress.processed)/\(progress.changed) of \(progress.totalFiles) files")
        }
        let counts = try await store.counts()
        print("\(summary.totalFiles) files, \(summary.totalSkins) skins in \(String(format: "%.2f", summary.duration)) s")
        print("added \(summary.added), updated \(summary.updated), linked \(summary.linked), removed \(summary.removed), "
            + "failed \(summary.failed), unchanged \(summary.unchanged)")
        print("ok \(counts.byStatus[.ok] ?? 0), partial \(counts.byStatus[.partial] ?? 0), failed \(counts.byStatus[.failed] ?? 0)")
        return 0
    } catch {
        standardError("skintool: \(error.localizedDescription)")
        return 1
    }
}

/// `skintool corpus <dir> --out <dir> ...`: 0 when the loop finished (124/125 come from the watchdog), 64/66 usage.
func runCorpus(_ arguments: [String]) -> Int32 {
    let options: CorpusOptions
    switch CorpusOptions.parse(arguments) {
    case .success(let parsed): options = parsed
    case .failure(let error):
        standardError("skintool: \(error)\n\(CorpusOptions.usage)")
        return 64
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: options.input, isDirectory: &isDirectory), isDirectory.boolValue else {
        standardError("skintool: no such folder: \(options.input)")
        return 66
    }
    var config = CorpusRunner.Config()
    config.timeout = options.timeout
    config.maxMemoryMiB = options.maxMemoryMiB
    config.sample = options.sample
    config.seed = options.seed
    config.resume = options.resume
    config.manifest = options.manifest.map { URL(filePath: $0) }
    let runner = CorpusRunner(corpus: URL(filePath: options.input), out: URL(filePath: options.out), config: config)
    do {
        let totals = try runner.run()
        print("corpus run finished: \(totals.unique) unique of \(totals.files) files, \(totals.attempted) attempted in this process")
        return 0
    } catch {
        standardError("skintool: \(error.localizedDescription)")
        return 1
    }
}

/// `skintool corpus-report <results.jsonl> ...`: writes the markdown and JSON; exit 1 when the gate fails.
func runCorpusReport(_ arguments: [String]) -> Int32 {
    let options: CorpusReportOptions
    switch CorpusReportOptions.parse(arguments) {
    case .success(let parsed): options = parsed
    case .failure(let error):
        standardError("skintool: \(error)\n\(CorpusReportOptions.usage)")
        return 64
    }
    guard FileManager.default.fileExists(atPath: options.input) else {
        standardError("skintool: no such file: \(options.input)")
        return 66
    }
    var environment: [String: String] = [:]
    if let path = options.env, let data = FileManager.default.contents(atPath: path),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
        environment = object.mapValues { "\($0)" }
    }
    let crashLogs = options.crashes.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0).count } ?? 0
    let records = CorpusRunner.readRecords(URL(filePath: options.input))
    let summary = CorpusReport.summarize(
        records: records, environment: environment, sample: options.sample, seed: options.seed, crashLogs: crashLogs)
    do {
        try CorpusReport.markdown(summary).write(toFile: options.markdown, atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(summary).write(to: URL(filePath: options.json))
    } catch {
        standardError("skintool: \(error.localizedDescription)")
        return 1
    }
    let c = summary.counts
    print("corpus: \(summary.unique) unique of \(summary.files) files, \(summary.classic) classic, \(c.ok) ok, \(c.partial) partial, \(c.failed) failed, "
        + "\(c.crashed) crashed, \(c.timeout) timed out, \(c.memory) over memory")
    print(String(format: "main window complete %.1f%%, median %.1f ms, p95 %.1f ms, p99 %.1f ms, peak %d MiB, wall %.1f s",
        summary.completeRate * 100, summary.timing.medianMs, summary.timing.p95Ms, summary.timing.p99Ms,
        summary.timing.peakFootprintMiB, summary.timing.wallSeconds))
    print(summary.gate)
    return summary.gatePass ? 0 : 1
}

let rawArguments = Array(CommandLine.arguments.dropFirst())
if rawArguments.first == "corpus" { exit(runCorpus(Array(rawArguments.dropFirst()))) }
if rawArguments.first == "corpus-report" { exit(runCorpusReport(Array(rawArguments.dropFirst()))) }
if rawArguments.first == "index" { exit(await runIndex(Array(rawArguments.dropFirst()))) }

let options: SkintoolOptions
switch SkintoolOptions.parse(Array(CommandLine.arguments.dropFirst())) {
case .success(let parsed): options = parsed
case .failure(let error):
    standardError("skintool: \(error)\n\(SkintoolOptions.usage)")
    exit(64)
}

let root = URL(filePath: options.input)
var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
    standardError("skintool: no such file: \(options.input)")
    exit(66)
}

let isDir = isDirectory.boolValue
var skins: [URL] = []
if isDir {
    let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    while let url = enumerator?.nextObject() as? URL {
        if ["wsz", "zip"].contains(url.pathExtension.lowercased()) { skins.append(url) }
    }
    skins.sort { $0.path < $1.path }
} else {
    skins = [root]
}

if let out = options.png, isDir {
    try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
}

func render(_ skin: Skin, name: String, url: URL) -> Bool {
    guard let out = options.png else { return true }
    let target = isDir ? URL(filePath: out).appending(path: "\(name).png") : URL(filePath: out)
    let state: MainWindowState = options.state == .idle ? .idle : .webampScreenshot
    let image = MainWindowRenderer.render(skin: skin, state: state, scale: options.scale, clipToRegion: !options.noRegion)
    do {
        try PNGWriter.write(image, to: target)
    } catch {
        print("failed   \(url.lastPathComponent): PNG write to \(target.path): \(error)")
        return false
    }
    print("png      \(name) -> \(target.path)")
    if let refdir = options.compare {
        let referenceURL = URL(filePath: refdir).appending(path: "\(name).png")
        guard let reference = PNGWriter.read(referenceURL) else {
            print("noref    \(name)")
            return true
        }
        let vis = MainWindowLayout.visualizer
        let result = ImageDiff.compare(ours: image, reference: reference, tolerance: 2, ignoring: [vis])
        let diffName = isDir ? target.deletingLastPathComponent().appending(path: "\(name).diff.png")
            : target.deletingPathExtension().appendingPathExtension("diff.png")
        try? PNGWriter.write(ImageDiff.diffImage(ours: image, reference: reference), to: diffName)
        print(
            "diff     \(name): exact \(result.differing)/\(result.compared) px differ, ±2 \(result.beyondTolerance); "
                + "excluding vis \(result.differingOutsideIgnored) / \(result.beyondToleranceOutsideIgnored); "
                + "\(result.skippedTransparent) skipped transparent")
    }
    return true
}

var counts = (ok: 0, partial: 0, failed: 0)
var renderFailed = false
for url in skins {
    do {
        let skin = try SkinParser.parse(url: url)
        let notes = options.verbose && !skin.fallbacks.isEmpty ? "\n         fallbacks: \(skin.fallbacks.joined(separator: "; "))" : ""
        if skin.warnings.isEmpty {
            counts.ok += 1
            print("ok       \(url.lastPathComponent)\(notes)")
        } else {
            counts.partial += 1
            print("partial  \(url.lastPathComponent): \(skin.warnings.joined(separator: "; "))\(notes)")
        }
        if !render(skin, name: url.deletingPathExtension().lastPathComponent, url: url) { renderFailed = true }
    } catch {
        counts.failed += 1
        print("failed   \(url.lastPathComponent): \(error)")
    }
}
print("\n\(skins.count) skins: \(counts.ok) ok, \(counts.partial) partial, \(counts.failed) failed")
exit(counts.ok == skins.count && !renderFailed ? 0 : 1)
