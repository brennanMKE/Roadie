import Foundation
import MusicBackendKit
import Observation

/// State behind Settings › Library › Music Folder: the chosen folder, the index status and the actions.
/// Lives here so it is unit-tested; the view is thin.
@MainActor
@Observable
public final class FolderSettingsModel {
    private let backend: FolderBackend
    private let defaults: UserDefaults
    private let cacheDirectory: URL

    public private(set) var folderURL: URL?
    public private(set) var status: FolderIndexStatus = .notConnected
    public private(set) var errorMessage: String?

    @ObservationIgnored private var subscription: Task<Void, Never>?
    @ObservationIgnored private var pending: [Task<Void, Never>] = []

    public init(
        backend: FolderBackend, defaults: UserDefaults = .standard,
        cacheDirectory: URL = FolderIndexCache.defaultDirectory()
    ) {
        self.backend = backend
        self.defaults = defaults
        self.cacheDirectory = cacheDirectory
        self.folderURL = FolderBackend.storedFolder(in: defaults)
    }

    public var hasFolder: Bool { folderURL != nil }
    public var pathText: String { folderURL?.path(percentEncoded: false) ?? "No folder chosen" }

    public var statusText: String {
        switch status {
        case .notConnected: "Not indexed"
        case .indexing(let previous?): "Updating\u{2026} (\(previous.text))"
        case .indexing(nil): "Indexing\u{2026}"
        case .ready(let summary): summary.text
        case .failed(let message): message
        }
    }

    public var isIndexing: Bool {
        if case .indexing = status { return true }
        return false
    }

    public var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    /// Follows the backend's status, and connects when a folder is stored.
    public func appeared() {
        subscription?.cancel()
        let backend = self.backend
        subscription = Task { [weak self] in
            for await status in await backend.statusUpdates() {
                guard let self else { return }
                self.status = status
            }
        }
        if hasFolder { connect(disconnectFirst: false) }
    }

    public func disappeared() {
        subscription?.cancel()
        subscription = nil
    }

    /// Stores the folder and (re)connects. The path is kept even when it can't be read, so a drive can come back.
    public func choose(_ url: URL) {
        if let old = folderURL, old.standardizedFileURL != url.standardizedFileURL {
            FolderIndexCache.remove(for: old, in: cacheDirectory)
        }
        defaults.set(url.path, forKey: FolderBackend.folderDefaultsKey)
        folderURL = url
        errorMessage = nil
        connect(disconnectFirst: true)
    }

    public func clear() {
        if let old = folderURL { FolderIndexCache.remove(for: old, in: cacheDirectory) }
        defaults.removeObject(forKey: FolderBackend.folderDefaultsKey)
        folderURL = nil
        errorMessage = nil
        let backend = self.backend
        track(Task { await backend.disconnect() })
    }

    public func reindex() {
        let backend = self.backend
        track(Task { [weak self] in
            do { try await backend.reindex() } catch { self?.show(error) }
        })
    }

    /// Waits for the connects, reindexes and disconnects started so far (tests).
    public func waitForPending() async {
        while let task = pending.first {
            pending.removeFirst()
            await task.value
        }
    }

    private func connect(disconnectFirst: Bool) {
        let backend = self.backend
        track(Task { [weak self] in
            if disconnectFirst { await backend.disconnect() }
            do { try await backend.connect() } catch { self?.show(error) }
        })
    }

    private func show(_ error: any Error) {
        guard !(error is CancellationError) else { return }
        errorMessage = (error as? MusicBackendError)?.errorDescription ?? error.localizedDescription
    }

    private func track(_ task: Task<Void, Never>) {
        pending.append(task)
    }
}
