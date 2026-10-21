import Foundation

public enum SkinStatus: String, Sendable, Codable, CaseIterable {
    case ok, partial, failed
}

public struct SkinRecord: Identifiable, Hashable, Sendable {
    public var id: Int64
    /// SHA-256 hex, 64 characters; #0034 keys thumbnails by it.
    public var hash: String
    /// Stem of the first file seen with this hash (sorted order).
    public var name: String
    public var readme: String?
    public var status: SkinStatus
    /// Parser warnings, or `[reason]` when failed.
    public var warnings: [String]
    public var size: Int64
    /// Copies on disk.
    public var fileCount: Int
    /// The smallest path of its files, relative to the folder.
    public var primaryPath: String
    /// MD5 hex, 32 characters; the Skin Museum's key (#0126). Nil until computed (rows from schema v1) or when the
    /// file could not be read.
    public var md5: String?

    public init(
        id: Int64, hash: String, name: String, readme: String? = nil, status: SkinStatus, warnings: [String] = [],
        size: Int64 = 0, fileCount: Int = 1, primaryPath: String = "", md5: String? = nil
    ) {
        self.id = id
        self.hash = hash
        self.name = name
        self.readme = readme
        self.status = status
        self.warnings = warnings
        self.size = size
        self.fileCount = fileCount
        self.primaryPath = primaryPath
        self.md5 = md5
    }
}

/// What the scanner sees and what `files` stores. Equality is the change test.
public struct FileStamp: Hashable, Sendable {
    /// Relative to the folder, as enumerated.
    public var path: String
    public var size: Int64
    /// `contentModificationDate.timeIntervalSince1970`, stored as REAL.
    public var mtime: TimeInterval

    public init(path: String, size: Int64, mtime: TimeInterval) {
        self.path = path
        self.size = size
        self.mtime = mtime
    }
}

public struct SkinIndexProgress: Hashable, Sendable {
    public enum Phase: String, Sendable { case scanning, indexing, pruning, hashing, done }
    public var phase: Phase
    /// Files this pass has to ingest.
    public var changed: Int
    /// Of `changed`.
    public var processed: Int
    /// On disk.
    public var totalFiles: Int

    public init(phase: Phase, changed: Int = 0, processed: Int = 0, totalFiles: Int = 0) {
        self.phase = phase
        self.changed = changed
        self.processed = processed
        self.totalFiles = totalFiles
    }
}

public struct SkinIndexSummary: Hashable, Sendable {
    public var totalFiles = 0, totalSkins = 0
    public var added = 0, updated = 0, linked = 0, removed = 0, failed = 0, unchanged = 0
    public var duration: TimeInterval = 0
    public var cancelled = false

    public init() {}
}

public struct SkinIndexCounts: Hashable, Sendable {
    public var files: Int
    public var skins: Int
    public var byStatus: [SkinStatus: Int]

    public init(files: Int, skins: Int, byStatus: [SkinStatus: Int]) {
        self.files = files
        self.skins = skins
        self.byStatus = byStatus
    }
}

public enum SkinLibraryError: Error, Sendable, LocalizedError {
    case sqlite(code: Int32, message: String)
    case incompatibleDatabase(found: Int32, supported: Int32)
    case folderUnreadable(String)
    case passAlreadyRunning

    public var errorDescription: String? {
        switch self {
        case .sqlite(let code, let message): "The skin index failed (SQLite \(code)): \(message)"
        case .incompatibleDatabase(let found, let supported):
            "The skin index is from a newer version (\(found), this build reads \(supported)). Reset it to rebuild."
        case .folderUnreadable(let reason): "The skins folder cannot be read: \(reason)"
        case .passAlreadyRunning: "An index pass is already running."
        }
    }
}
