import Foundation

/// Numbers computed from a corpus run's `results.jsonl` (#0038). Rates are fractions of unique classic skins.
public struct CorpusSummary: Codable, Equatable, Sendable {
    public struct Example: Codable, Equatable, Sendable {
        public var name: String
        public var md5: String
        public var url: String?
    }
    public struct FailureClass: Codable, Equatable, Sendable {
        public var key: String
        public var count: Int
        public var share: Double
        public var examples: [Example]
        public var issue: String
    }
    public struct Slow: Codable, Equatable, Sendable {
        public var name: String
        public var md5: String
        public var size: Int
        public var entries: Int
        public var ms: Double
        public var status: String
    }
    public struct Timing: Codable, Equatable, Sendable {
        public var count = 0
        public var medianMs = 0.0
        public var p95Ms = 0.0
        public var p99Ms = 0.0
        public var maxMs = 0.0
        public var totalMs = 0.0
        public var wallSeconds = 0.0
        public var peakFootprintMiB = 0
    }
    public struct Counts: Codable, Equatable, Sendable {
        public var ok = 0, partial = 0, failed = 0, crashed = 0, timeout = 0, memory = 0, mainWindowComplete = 0
        public var crashFree: Bool { crashed + timeout + memory == 0 }
    }
    public struct SampleSection: Codable, Equatable, Sendable {
        public var requested: Int
        public var seed: UInt64
        public var skins: Int
        public var classic: Int
        public var counts: Counts
        public var completeRate: Double
    }

    public var environment: [String: String]
    public var files = 0, unique = 0, duplicates = 0, modern = 0, classic = 0
    public var counts = Counts()
    public var okRate = 0.0, partialRate = 0.0, failedRate = 0.0, completeRate = 0.0
    public var timing = Timing()
    public var slowest: [Slow] = []
    public var failureClasses: [FailureClass] = []
    public var crashed: [Example] = []
    public var crashLogs = 0
    public var sample: SampleSection
    public var gatePass = false
    public var gate = ""
}

public enum CorpusReport {
    /// Nearest-rank percentile of an ascending list.
    public static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    /// Warnings and errors normalized to a class key (`Missing cbuttons.bmp` -> `missing cbuttons`).
    public static func classKey(warning: String) -> String {
        let text = warning.lowercased()
        for prefix in ["missing ", "undecodable "] where text.hasPrefix(prefix) {
            let rest = String(text.dropFirst(prefix.count))
            return prefix + rest.replacingOccurrences(of: ".bmp", with: "")
        }
        if text.contains("viscolor") { return "viscolor" }
        return text
    }

    public static func classKey(error: String) -> String {
        if error.hasPrefix("Unreadable archive") { return "unreadableArchive" }
        if error.hasPrefix("No classic skin bitmaps") { return "noBitmaps" }
        return error
    }

    static let knownIssues: [String: String] = [
        "missing balance": "#0020", "missing nums_ex": "#0020", "missing numbers": "#0020", "missing eq_ex": "#0020",
        "missing gen": "#0020", "viscolor": "#0020", "missing numbers and nums_ex": "#0020",
    ]

    /// `results` are the `result` records of a run (any number of restarts); `sample` is the acceptance sample size.
    public static func summarize(
        records: [CorpusRecord], environment: [String: String] = [:], sample sampleSize: Int = 1000, seed: UInt64 = 1,
        crashLogs: Int = 0
    ) -> CorpusSummary {
        let results = records.filter { $0.event == "result" }
        let skins = results.filter { $0.status != "duplicate" }
        let classicSkins = skins.filter { $0.status != "modern" }

        func counts(_ list: [CorpusRecord]) -> CorpusSummary.Counts {
            var c = CorpusSummary.Counts()
            for r in list {
                switch r.status {
                case "ok": c.ok += 1
                case "partial": c.partial += 1
                case "failed": c.failed += 1
                case "crashed": c.crashed += 1
                case "timeout": c.timeout += 1
                case "memory": c.memory += 1
                default: break
                }
                if r.mainWindowComplete == true { c.mainWindowComplete += 1 }
            }
            return c
        }
        func rate(_ n: Int, _ d: Int) -> Double { d == 0 ? 0 : Double(n) / Double(d) }
        func example(_ r: CorpusRecord) -> CorpusSummary.Example {
            .init(name: displayName(r), md5: r.md5 ?? "", url: r.museumUrl)
        }

        let all = counts(classicSkins)
        let sampled = CorpusSample.pick(skins.sorted { ($0.path ?? "") < ($1.path ?? "") }, n: sampleSize, seed: seed)
        let sampledClassic = sampled.filter { $0.status != "modern" }
        let sampledCounts = counts(sampledClassic)
        let sampleSection = CorpusSummary.SampleSection(
            requested: sampleSize, seed: seed, skins: sampled.count, classic: sampledClassic.count, counts: sampledCounts,
            completeRate: rate(sampledCounts.mainWindowComplete, sampledClassic.count))

        var summary = CorpusSummary(environment: environment, sample: sampleSection)
        summary.files = results.count
        summary.unique = skins.count
        summary.duplicates = results.count - skins.count
        summary.modern = skins.count - classicSkins.count
        summary.classic = classicSkins.count
        summary.counts = all
        summary.okRate = rate(all.ok, classicSkins.count)
        summary.partialRate = rate(all.partial, classicSkins.count)
        summary.failedRate = rate(all.failed, classicSkins.count)
        summary.completeRate = rate(all.mainWindowComplete, classicSkins.count)

        // Timing: every attempted parse (ok, partial, failed, modern).
        let attempted = skins.filter { ["ok", "partial", "failed", "modern"].contains($0.status ?? "") }
        let times = attempted.compactMap(\.ms).sorted()
        summary.timing = .init(
            count: times.count, medianMs: percentile(times, 50), p95Ms: percentile(times, 95), p99Ms: percentile(times, 99),
            maxMs: times.last ?? 0, totalMs: times.reduce(0, +),
            wallSeconds: wall(records), peakFootprintMiB: records.compactMap(\.footprintMiB).max() ?? 0)
        summary.slowest = attempted.sorted { ($0.ms ?? 0) > ($1.ms ?? 0) }.prefix(20).map {
            .init(name: displayName($0), md5: $0.md5 ?? "", size: $0.size ?? 0, entries: $0.entries ?? 0, ms: $0.ms ?? 0,
                status: $0.status ?? "")
        }

        // Failure classes over unique classic skins; a skin counts once per class.
        var classes: [String: [CorpusRecord]] = [:]
        for r in classicSkins {
            var keys = Set((r.warnings ?? []).map(classKey(warning:)))
            if let error = r.error, r.status == "failed" { keys.insert(classKey(error: error)) }
            if ["crashed", "timeout", "memory"].contains(r.status ?? "") { keys.insert(r.status!) }
            for key in keys { classes[key, default: []].append(r) }
        }
        var classList = classes.map { key, list in
            CorpusSummary.FailureClass(
                key: key, count: list.count, share: rate(list.count, classicSkins.count),
                examples: list.prefix(5).map(example), issue: knownIssues[key] ?? "")
        }
        if summary.modern > 0 {
            classList.append(.init(
                key: "modern", count: summary.modern, share: 0,
                examples: skins.filter { $0.status == "modern" }.prefix(5).map(example), issue: "accepted"))
        }
        summary.failureClasses = classList.sorted { ($0.count, $1.key) > ($1.count, $0.key) }
        summary.crashed = classicSkins.filter { ["crashed", "timeout", "memory"].contains($0.status ?? "") }.map(example)
        summary.crashLogs = crashLogs

        let crashes = all.crashed + all.timeout + all.memory
        let percent = String(format: "%.1f", sampleSection.completeRate * 100)
        if crashes == 0, sampleSection.completeRate >= 0.95 {
            summary.gatePass = true
            summary.gate = "gate: PASS"
        } else {
            summary.gate = "gate: FAIL (crashes=\(crashes), sample complete=\(percent)% < 95%)"
            if crashes == 0 { summary.gate = "gate: FAIL (crashes=0, sample complete=\(percent)% < 95%)" }
        }
        return summary
    }

    /// First start to last record, in seconds.
    static func wall(_ records: [CorpusRecord]) -> Double {
        let times = records.compactMap(\.t)
        guard let first = times.min(), let last = times.max() else { return 0 }
        return last - first
    }

    /// The md5 stands in for the name when a manifest marks the skin NSFW; `|` would break the tables.
    static func displayName(_ r: CorpusRecord) -> String {
        if r.nsfw == true { return r.md5 ?? "?" }
        let name = r.name ?? r.path.map(CorpusRunner.skinName) ?? r.md5 ?? "?"
        return name.replacingOccurrences(of: "|", with: "\\|")
    }

    // MARK: Markdown

    public static func markdown(_ s: CorpusSummary) -> String {
        func pct(_ v: Double) -> String { String(format: "%.1f%%", v * 100) }
        func ms(_ v: Double) -> String { String(format: "%.1f ms", v) }
        func code(_ v: String) -> String { v.replacingOccurrences(of: "|", with: "\\|") }
        var out = "# Skin corpus report\n\n"
        out += "| | |\n|---|---|\n"
        for key in s.environment.keys.sorted() { out += "| \(code(key)) | \(code(s.environment[key] ?? "")) |\n" }
        out += "\n## Headline\n\n| | |\n|---|---|\n"
        out += "| Files | \(s.files) |\n| Unique skins | \(s.unique) |\n| Duplicates | \(s.duplicates) |\n| Modern (excluded from rates) | \(s.modern) |\n"
        out += "| Unique classic skins | \(s.classic) |\n"
        out += "| ok | \(s.counts.ok) (\(pct(s.okRate))) |\n| partial | \(s.counts.partial) (\(pct(s.partialRate))) |\n"
        out += "| failed | \(s.counts.failed) (\(pct(s.failedRate))) |\n"
        out += "| crashed / timeout / memory | \(s.counts.crashed) / \(s.counts.timeout) / \(s.counts.memory) |\n"
        out += "| Main window complete | \(s.counts.mainWindowComplete) (\(pct(s.completeRate))) |\n"
        out += "\n\(s.gate)\n"
        out += "\n## Timing (parse plus render per skin, one at a time)\n\n| | |\n|---|---|\n"
        out += "| Skins timed | \(s.timing.count) |\n| Median | \(ms(s.timing.medianMs)) |\n| p95 | \(ms(s.timing.p95Ms)) |\n"
        out += "| p99 | \(ms(s.timing.p99Ms)) |\n| Max | \(ms(s.timing.maxMs)) |\n"
        out += "| Total parse plus render | \(String(format: "%.1f", s.timing.totalMs / 1000)) s |\n"
        out += "| Total wall time | \(String(format: "%.1f", s.timing.wallSeconds)) s |\n"
        out += "| Peak footprint | \(s.timing.peakFootprintMiB) MiB |\n"
        out += "\n## Slowest \(s.slowest.count)\n\n| Name | md5 | Size | Entries | ms | Status |\n|---|---|---|---|---|---|\n"
        for r in s.slowest {
            out += "| \(r.name) | \(r.md5) | \(r.size) | \(r.entries) | \(String(format: "%.1f", r.ms)) | \(r.status) |\n"
        }
        out += "\n## Failure classes\n\n| Class | Skins | Share | Issue | Examples |\n|---|---|---|---|---|\n"
        for c in s.failureClasses {
            let examples = c.examples.map { "\($0.name) (\($0.md5.prefix(8)))" }.joined(separator: ", ")
            out += "| \(code(c.key)) | \(c.count) | \(pct(c.share)) | \(c.issue) | \(examples) |\n"
        }
        out += "\n## Crash signatures\n\n"
        if s.crashed.isEmpty { out += "None. Crashed, timed out or over-memory skins: 0 (\(s.crashLogs) crash logs).\n" } else {
            out += "| Skin | md5 | Signature |\n|---|---|---|\n"
            for c in s.crashed { out += "| \(c.name) | \(c.md5) | |\n" }
        }
        let n = s.sample
        out += "\n## Sample of \(n.requested) (seed \(n.seed))\n\n| | |\n|---|---|\n"
        out += "| Skins in sample | \(n.skins) (\(n.classic) classic) |\n"
        out += "| ok / partial / failed | \(n.counts.ok) / \(n.counts.partial) / \(n.counts.failed) |\n"
        out += "| crashed / timeout / memory | \(n.counts.crashed) / \(n.counts.timeout) / \(n.counts.memory) |\n"
        out += "| Main window complete | \(n.counts.mainWindowComplete) (\(pct(n.completeRate))) |\n"
        return out
    }
}
