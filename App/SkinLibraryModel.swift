import AppKit
import Foundation
import Observation
import SkinLibrary
import os

/// Settings › Skins: the skins folder (a `UserDefaults` setting, never a path in code) and its background index.
/// With no folder set it opens no database and does no I/O.
@MainActor
@Observable
final class SkinLibraryModel {
    static let folderKey = "skinsFolderPath"

    private(set) var folderPath: String?
    private(set) var counts: SkinIndexCounts?
    private(set) var lastScan: Date?
    private(set) var progress: SkinIndexProgress?
    private(set) var summary: SkinIndexSummary?
    private(set) var errorMessage: String?
    private(set) var isIndexing = false
    /// Called after a pass finishes (completed, cancelled or failed); the skin browser (#0035) refreshes from it.
    @ObservationIgnored var passFinished: (@MainActor () -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let databaseURL: URL
    @ObservationIgnored private var store: SkinIndexStore?
    @ObservationIgnored private var opening: Task<SkinIndexStore, Error>?
    @ObservationIgnored private var indexer: SkinIndexer?
    @ObservationIgnored private var indexedPath: String?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// A Museum download arrived while a pass ran: run an incremental pass after it (#0126).
    @ObservationIgnored private var rescanAfterPass = false
    @ObservationIgnored private static let logger = Logger(subsystem: "com.brennanmke.SkinAmp", category: "SkinLibrary")

    init(
        defaults: UserDefaults = .standard, databaseURL: URL = SkinIndexStore.defaultURL,
        startupDelay: Duration = .seconds(2)
    ) {
        self.defaults = defaults
        self.databaseURL = databaseURL
        folderPath = defaults.string(forKey: Self.folderKey)
        // The window comes up first; with no folder set nothing opens.
        if folderPath != nil {
            scanTask = Task { [weak self] in
                try? await Task.sleep(for: startupDelay)
                guard !Task.isCancelled else { return }
                self?.scan()
            }
        }
    }

    var hasFolder: Bool { folderPath != nil }
    var folderURL: URL? { folderPath.map { URL(filePath: $0, directoryHint: .isDirectory) } }

    var folderText: String { folderPath ?? "No folder chosen" }

    var countsText: String {
        guard let counts else { return hasFolder ? "Not indexed yet" : "No folder chosen" }
        return "\(counts.skins) skins in \(counts.files) files"
    }

    var statusText: String? {
        guard let counts else { return nil }
        let by = counts.byStatus
        return "\(by[.ok] ?? 0) ok, \(by[.partial] ?? 0) partial, \(by[.failed] ?? 0) failed"
    }

    var progressText: String? {
        guard isIndexing, let progress else { return isIndexing ? "Scanning…" : nil }
        switch progress.phase {
        case .scanning: return "Scanning the folder…"
        case .indexing: return "Indexing \(progress.processed) of \(progress.changed) changed files (\(progress.totalFiles) in the folder)"
        case .pruning: return "Cleaning up…"
        case .hashing: return "Checksumming \(progress.processed) older skins…"
        case .done: return "Done"
        }
    }

    var progressFraction: Double? {
        guard isIndexing, let progress, progress.phase == .indexing, progress.changed > 0 else { return nil }
        return Double(progress.processed) / Double(progress.changed)
    }

    /// The open store, creating it on first use; nil with no folder set.
    func openStoreIfNeeded() async throws -> SkinIndexStore? {
        guard folderPath != nil else { return nil }
        if let store { return store }
        // The browser (#0035, e.g. resolving the restored skin at launch) and the first index pass can both ask
        // before the open finishes; share one open so there is never a second connection or a racing migration.
        if let opening { return try await opening.value }
        let url = databaseURL
        let task = Task { try await SkinIndexStore.open(at: url) }
        opening = task
        do {
            let opened = try await task.value
            store = opened
            opening = nil
            return opened
        } catch {
            opening = nil
            throw error
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder of Winamp skins (.wsz) to index."
        if let folderURL { panel.directoryURL = folderURL }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setFolder(url.path)
    }

    func setFolder(_ path: String?) {
        guard path != folderPath else { return }
        scanTask?.cancel()
        indexer?.cancel()
        folderPath = path
        defaults.set(path, forKey: Self.folderKey)
        indexer = nil
        indexedPath = nil
        summary = nil
        errorMessage = nil
        if path != nil { scan() }
    }

    func scan(full: Bool = false) {
        guard let path = folderPath, !isIndexing else { return }
        isIndexing = true
        errorMessage = nil
        progress = SkinIndexProgress(phase: .scanning)
        scanTask = Task(priority: .utility) { [weak self] in
            await self?.runPass(path: path, full: full)
        }
    }

    func cancel() {
        indexer?.cancel()
    }

    func resetIndex() {
        guard !isIndexing else { return }
        isIndexing = true
        errorMessage = nil
        scanTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let store = try await self.openStoreIfNeeded()
                try await store?.reset()
                self.counts = nil
                self.lastScan = nil
                self.summary = nil
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isIndexing = false
            self.scan()
        }
    }

    func refreshCounts() async {
        guard let store else { return }
        counts = try? await store.counts()
        if let text = try? await store.meta("last_scan") { lastScan = ISO8601DateFormatter().date(from: text) }
    }

    /// Indexes one skin the Museum just downloaded into the skins folder, without walking the folder (#0126).
    /// While a pass runs, an incremental pass is queued after it instead.
    func addDownloaded(_ url: URL) async {
        guard let path = folderPath else { return }
        let root = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL.path
        let file = url.standardizedFileURL.path
        guard file.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { return }
        let relative = String(file.dropFirst(root.hasSuffix("/") ? root.count : root.count + 1))
        if isIndexing {
            rescanAfterPass = true
            return
        }
        do {
            guard let store = try await openStoreIfNeeded() else { return }
            if indexer == nil || indexedPath != path {
                indexer = SkinIndexer(folder: URL(filePath: path, directoryHint: .isDirectory), store: store)
                indexedPath = path
            }
            guard let indexer else { return }
            _ = try await indexer.add(paths: [relative])
            await refreshCounts()
        } catch SkinLibraryError.passAlreadyRunning {
            if isIndexing { rescanAfterPass = true } else { scan() }
        } catch {
            Self.logger.error("adding a downloaded skin failed: \(error.localizedDescription, privacy: .public)")
            scan()
        }
    }

    private func runPass(path: String, full: Bool) async {
        defer {
            isIndexing = false
            progress = nil
            passFinished?()
            // The folder changed while this pass ran (setFolder cancelled it, and its scan() was skipped): index the new one.
            if let current = folderPath, current != path {
                scan()
            } else if rescanAfterPass {
                rescanAfterPass = false
                scan()
            }
        }
        do {
            guard let store = try await openStoreIfNeeded() else { return }
            if indexer == nil || indexedPath != path {
                indexer = SkinIndexer(folder: URL(filePath: path, directoryHint: .isDirectory), store: store)
                indexedPath = path
            }
            guard let indexer else { return }
            let result = try await indexer.run(full: full) { [weak self] value in
                Task { @MainActor in self?.progress = value }
            }
            summary = result
            await refreshCounts()
        } catch {
            Self.logger.error("index pass failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
            await refreshCounts()
        }
    }
}
