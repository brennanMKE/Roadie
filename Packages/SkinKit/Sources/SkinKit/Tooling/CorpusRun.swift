import CoreGraphics
import CryptoKit
import Darwin
import Foundation

/// One line of `results.jsonl`: a `start`, a `result`, or the closing `end` of a corpus run (#0038).
public struct CorpusRecord: Codable, Equatable, Sendable {
    public var event: String
    public var i: Int?
    public var path: String?
    public var name: String?
    public var md5: String?
    public var size: Int?
    /// Files extracted from the archive (entries over `SkinArchive.Limits` are not counted).
    public var entries: Int?
    /// ok, partial, failed, modern, duplicate, crashed, timeout or memory.
    public var status: String?
    public var mainWindowComplete: Bool?
    public var warnings: [String]?
    public var fallbacks: [String]?
    public var error: String?
    public var parseMs: Double?
    public var renderMs: Double?
    public var ms: Double?
    /// For `duplicate`: the first path with the same md5.
    public var of: String?
    public var restart: Int?
    /// The driver's lifetime peak physical footprint when the record was written.
    public var footprintMiB: Int?
    /// Seconds since the epoch.
    public var t: Double?
    public var museumUrl: String?
    public var nsfw: Bool?

    public init(event: String) { self.event = event }
}

/// A corpus file with its content hash.
public struct CorpusFile: Codable, Equatable, Sendable {
    public var path: String
    public var md5: String
    public var size: Int
}

/// What one skin produced; `CorpusRunner` turns it into a `result` record.
public struct CorpusOutcome: Sendable {
    public var status: String
    public var entries: Int?
    public var mainWindowComplete: Bool?
    public var warnings: [String] = []
    public var fallbacks: [String] = []
    public var error: String?
    public var parseMs: Double?
    public var renderMs: Double?
}

public enum CorpusListing {
    /// Recursive, regular `.wsz`/`.zip` files (hidden files, such as `._foo.wsz`, are skipped), sorted by relative path.
    public static func scan(_ root: URL) -> [(path: String, url: URL)] {
        var found: [(path: String, url: URL)] = []
        let resolved = root.resolvingSymlinksInPath().path
        let prefix = resolved.hasSuffix("/") ? resolved : resolved + "/"
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        while let url = enumerator?.nextObject() as? URL {
            guard ["wsz", "zip"].contains(url.pathExtension.lowercased()),
                (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            let full = url.resolvingSymlinksInPath().path
            let path = full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : url.lastPathComponent
            found.append((path, url))
        }
        return found.sorted { $0.path < $1.path }
    }

    public static func md5Hex(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum CorpusSample {
    /// SplitMix64-seeded Fisher-Yates over `0..<count`; the first `n` indices, ascending. `n >= count` keeps all.
    public static func indices(count: Int, n: Int, seed: UInt64) -> [Int] {
        guard n < count else { return Array(0..<count) }
        var state = seed
        func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        var all = Array(0..<count)
        if count > 1 {
            for i in stride(from: count - 1, to: 0, by: -1) {
                let j = Int(next() % UInt64(i + 1))
                all.swapAt(i, j)
            }
        }
        return Array(all.prefix(max(0, n))).sorted()
    }

    public static func pick<T>(_ items: [T], n: Int, seed: UInt64) -> [T] {
        indices(count: items.count, n: n, seed: seed).map { items[$0] }
    }
}

/// Physical footprint of this process in MiB (`proc_pid_rusage`).
public enum ProcessFootprint {
    public static func mebibytes() -> (current: Int, lifetimeMax: Int) {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return (0, 0) }
        return (Int(info.ri_phys_footprint >> 20), Int(info.ri_lifetime_max_phys_footprint >> 20))
    }
}

/// Runs every skin of a folder through the parser and the main-window renderer, one at a time, journaling
/// `start`/`result` lines so a crash costs one skin and `resume` carries on after it (#0038).
public final class CorpusRunner: @unchecked Sendable {
    public struct Config: Sendable {
        public var timeout: Double = 10
        public var maxMemoryMiB = 4096
        public var sample: Int?
        public var seed: UInt64 = 1
        public var resume = false
        public var manifest: URL?
        /// How often the watchdog looks at the current skin.
        public var pollInterval: Double = 0.25
        public init() {}
    }

    public struct Hooks: @unchecked Sendable {
        public var process: @Sendable (URL) -> CorpusOutcome
        public var footprint: @Sendable () -> (current: Int, lifetimeMax: Int)
        public var abort: @Sendable (Int32) -> Void
        public static let live = Hooks(process: CorpusRunner.processSkin, footprint: ProcessFootprint.mebibytes, abort: { exit($0) })
    }

    public struct Totals: Equatable, Sendable {
        public var files = 0
        public var unique = 0
        public var attempted = 0
        public var aborted = false
    }

    private let corpus: URL
    private let out: URL
    private let config: Config
    private let hooks: Hooks
    private let progress: @Sendable (String) -> Void
    private let lock = NSLock()
    private var current: (record: CorpusRecord, began: Double)?
    private var finished = false
    private var aborted = false
    private var handle: FileHandle?

    public var resultsURL: URL { out.appending(path: "results.jsonl") }

    public init(
        corpus: URL, out: URL, config: Config = Config(), hooks: Hooks = .live,
        progress: @escaping @Sendable (String) -> Void = { print($0) }
    ) {
        self.corpus = corpus
        self.out = out
        self.config = config
        self.hooks = hooks
        self.progress = progress
    }

    // MARK: Running

    public func run() throws -> Totals {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let previous = config.resume ? Self.readRecords(resultsURL) : []
        // A first run under the wrapper (which always passes --resume) has no journal yet.
        if !config.resume || !FileManager.default.fileExists(atPath: resultsURL.path) { try Data().write(to: resultsURL) }
        handle = try FileHandle(forWritingTo: resultsURL)
        try handle?.seekToEnd()
        defer { try? handle?.close() }

        var totals = Totals()
        let files = try listing()
        totals.files = files.count

        // First path per md5 is the skin; the rest are duplicates and never parsed.
        var firstByMD5: [String: String] = [:]
        var unique: [CorpusFile] = []
        var duplicates: [(file: CorpusFile, of: String)] = []
        for file in files {
            if let first = firstByMD5[file.md5] { duplicates.append((file, first)) } else {
                firstByMD5[file.md5] = file.path
                unique.append(file)
            }
        }
        if let n = config.sample { unique = CorpusSample.pick(unique, n: n, seed: config.seed) }
        totals.unique = unique.count
        let keptPaths = Set(unique.map(\.path))
        let manifest = config.manifest.map(Self.readManifest) ?? [:]

        // Resume: finished paths are skipped; a start without a result is the skin that killed the last process.
        var finishedPaths = Set(previous.filter { $0.event == "result" }.compactMap(\.path))
        var restarts = previous.filter { ["crashed", "timeout", "memory"].contains($0.status ?? "") }.count
        if config.resume {
            let started = previous.filter { $0.event == "start" }
            for start in started where start.path != nil && !finishedPaths.contains(start.path!) {
                restarts += 1
                var record = CorpusRecord(event: "result")
                record.i = start.i; record.path = start.path; record.name = start.name; record.md5 = start.md5
                record.size = start.size; record.status = "crashed"; record.restart = restarts
                record.t = Date().timeIntervalSince1970
                write(decorate(record, manifest))
                finishedPaths.insert(start.path!)
            }
        }

        let watchdog = Thread { [self] in watch() }
        watchdog.name = "corpus-watchdog"
        watchdog.start()
        defer { lock.lock(); finished = true; lock.unlock() }

        let index = Dictionary(uniqueKeysWithValues: files.enumerated().map { ($1.path, $0) })
        var done = 0
        var lastProgress = Date()
        var tally: [String: Int] = [:]
        for file in unique {
            if isAborted { totals.aborted = true; return totals }
            guard !finishedPaths.contains(file.path) else { continue }
            let url = corpus.appending(path: file.path)
            var start = CorpusRecord(event: "start")
            start.i = index[file.path]; start.path = file.path; start.name = Self.skinName(file.path); start.md5 = file.md5; start.size = file.size
            start.t = Date().timeIntervalSince1970
            lock.lock()
            current = (start, ProcessInfo.processInfo.systemUptime)
            lock.unlock()
            write(start)

            let began = ProcessInfo.processInfo.systemUptime
            let outcome = hooks.process(url)
            let elapsed = (ProcessInfo.processInfo.systemUptime - began) * 1000

            var result = CorpusRecord(event: "result")
            result.i = start.i; result.path = file.path; result.md5 = file.md5; result.size = file.size
            result.name = Self.skinName(file.path)
            result.status = outcome.status; result.entries = outcome.entries
            result.mainWindowComplete = outcome.mainWindowComplete
            result.warnings = outcome.warnings.isEmpty ? nil : outcome.warnings
            result.fallbacks = outcome.fallbacks.isEmpty ? nil : outcome.fallbacks
            result.error = outcome.error
            result.parseMs = outcome.parseMs; result.renderMs = outcome.renderMs
            result.ms = (outcome.parseMs ?? 0) + (outcome.renderMs ?? 0)
            if result.ms == 0 { result.ms = elapsed }
            result.t = Date().timeIntervalSince1970
            result.footprintMiB = hooks.footprint().lifetimeMax
            // Write-and-clear under the lock the watchdog uses: a result and an abort never both exist for one skin.
            lock.lock()
            if current != nil {
                current = nil
                writeLocked(decorate(result, manifest))
                lock.unlock()
            } else {
                lock.unlock()
                totals.aborted = true
                return totals
            }
            totals.attempted += 1
            done += 1
            tally[outcome.status, default: 0] += 1
            if done % 1000 == 0 || Date().timeIntervalSince(lastProgress) >= 5 {
                lastProgress = Date()
                progress(Self.progressLine(done: done, total: unique.count - finishedPaths.count, tally: tally))
            }
        }

        for (file, first) in duplicates where config.sample == nil || keptPaths.contains(first) {
            guard !finishedPaths.contains(file.path) else { continue }
            var record = CorpusRecord(event: "result")
            record.i = index[file.path]; record.path = file.path; record.name = Self.skinName(file.path)
            record.md5 = file.md5; record.size = file.size; record.status = "duplicate"; record.of = first
            record.t = Date().timeIntervalSince1970
            write(record)
        }
        var end = CorpusRecord(event: "end")
        end.t = Date().timeIntervalSince1970
        end.footprintMiB = hooks.footprint().lifetimeMax
        write(end)
        progress(Self.progressLine(done: done, total: unique.count - finishedPaths.count, tally: tally))
        return totals
    }

    // MARK: Pieces

    private var isAborted: Bool { lock.lock(); defer { lock.unlock() }; return aborted }

    /// The listing with md5s; cached next to the journal so a restart after a crash does not re-hash the corpus.
    private func listing() throws -> [CorpusFile] {
        let cache = out.appending(path: "listing.json")
        if config.resume, let data = try? Data(contentsOf: cache),
            let cached = try? JSONDecoder().decode([CorpusFile].self, from: data)
        {
            return cached
        }
        var files: [CorpusFile] = []
        for entry in CorpusListing.scan(corpus) {
            let size = (try? entry.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            // An unreadable file still gets a record: hash its path so it stays unique.
            let md5 = CorpusListing.md5Hex(of: entry.url) ?? Insecure.MD5.hash(data: Data(entry.path.utf8)).map { String(format: "%02x", $0) }.joined()
            files.append(CorpusFile(path: entry.path, md5: md5, size: size))
        }
        try JSONEncoder().encode(files).write(to: cache)
        return files
    }

    private func decorate(_ record: CorpusRecord, _ manifest: [String: (url: String, nsfw: Bool)]) -> CorpusRecord {
        var record = record
        guard let md5 = record.md5 else { return record }
        if let entry = manifest[md5] {
            record.museumUrl = entry.url
            record.nsfw = entry.nsfw
        } else if record.status != "modern" {
            record.museumUrl = "https://skins.webamp.org/skin/\(md5)"
        }
        return record
    }

    private func write(_ record: CorpusRecord) {
        lock.lock()
        writeLocked(record)
        lock.unlock()
    }

    private func writeLocked(_ record: CorpusRecord) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(record) else { return }
        data.append(0x0A)
        try? handle?.write(contentsOf: data)
        try? handle?.synchronize()
    }

    /// Polls the skin in flight; a hang or a runaway footprint becomes a record and an abort (exit 124/125).
    private func watch() {
        while true {
            Thread.sleep(forTimeInterval: config.pollInterval)
            lock.lock()
            if finished || aborted { lock.unlock(); return }
            guard let (start, began) = current else { lock.unlock(); continue }
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            var status: String?
            var code: Int32 = 0
            var message: String?
            if elapsed > config.timeout {
                status = "timeout"; code = 124; message = "no result after \(config.timeout) s"
            } else if hooks.footprint().current > config.maxMemoryMiB {
                status = "memory"; code = 125; message = "footprint over \(config.maxMemoryMiB) MiB"
            }
            guard let status else { lock.unlock(); continue }
            var record = CorpusRecord(event: "result")
            record.i = start.i; record.path = start.path; record.md5 = start.md5; record.size = start.size
            record.name = start.path.map(Self.skinName)
            record.status = status; record.error = message; record.ms = elapsed * 1000
            record.t = Date().timeIntervalSince1970
            record.footprintMiB = hooks.footprint().lifetimeMax
            writeLocked(record)
            current = nil
            aborted = true
            lock.unlock()
            hooks.abort(code)
            return
        }
    }

    // MARK: Static helpers

    public static func skinName(_ path: String) -> String {
        URL(filePath: path).deletingPathExtension().lastPathComponent
    }

    public static func readRecords(_ url: URL) -> [CorpusRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(CorpusRecord.self, from: Data($0)) }
    }

    static func readManifest(_ url: URL) -> [String: (url: String, nsfw: Bool)] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        var result: [String: (url: String, nsfw: Bool)] = [:]
        for line in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                let md5 = object["md5"] as? String
            else { continue }
            let link = object["museum_url"] as? String ?? "https://skins.webamp.org/skin/\(md5)"
            result[md5.lowercased()] = (link, object["nsfw"] as? Bool ?? false)
        }
        return result
    }

    static func progressLine(done: Int, total: Int, tally: [String: Int]) -> String {
        func pct(_ key: String) -> String { String(format: "%.1f%%", done == 0 ? 0 : Double(tally[key] ?? 0) * 100 / Double(done)) }
        return "[\(done)/\(total)] ok \(pct("ok")) partial \(pct("partial")) failed \(pct("failed")) modern \(pct("modern"))"
    }

    /// One representative sprite per sheet the main window draws.
    public static let requiredSprites = [
        "MAIN_WINDOW_BACKGROUND", "MAIN_TITLE_BAR", "MAIN_PLAY_BUTTON", "MAIN_STEREO", "DIGIT_0",
        "MAIN_PLAYING_INDICATOR", "MAIN_POSITION_SLIDER_BACKGROUND", "MAIN_SHUFFLE_BUTTON",
        "MAIN_VOLUME_BACKGROUND", "MAIN_BALANCE_BACKGROUND",
    ]

    /// Parse (archive read, every sheet decoded) timed; then render timed; then check the required sprites.
    @Sendable public static func processSkin(_ url: URL) -> CorpusOutcome {
        let clock = ContinuousClock()
        func millis(_ d: Duration) -> Double {
            Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }
        var outcome = CorpusOutcome(status: "failed")
        let begin = clock.now
        do {
            let archive = try SkinArchive(url: url)
            outcome.entries = archive.files.count
            let skin = try SkinParser.parse(archive: archive)
            outcome.parseMs = millis(clock.now - begin)
            outcome.warnings = skin.warnings
            outcome.fallbacks = skin.fallbacks
            outcome.status = skin.warnings.isEmpty ? "ok" : "partial"
            let renderBegin = clock.now
            _ = MainWindowRenderer.render(skin: skin, state: .webampScreenshot)
            outcome.renderMs = millis(clock.now - renderBegin)
            outcome.mainWindowComplete = requiredSprites.allSatisfy { skin.image(for: $0) != nil }
        } catch {
            outcome.parseMs = millis(clock.now - begin)
            if let skinError = error as? SkinError, case .modernSkin = skinError { outcome.status = "modern" } else {
                outcome.status = "failed"
                outcome.error = "\(error)"
            }
        }
        return outcome
    }
}
