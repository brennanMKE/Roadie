import AudioCore
import Foundation
import MusicBackendKit

/// The "This Mac" queue as saved to disk. Value type, `Sendable`, equatable; the file format is the private
/// mirror below, not `Track`'s layout.
public struct QueueSnapshot: Equatable, Sendable {
    public static let currentVersion = 1
    public var items: [LocalQueueItem]
    public var currentIndex: Int?
    public var repeatMode: RepeatMode
    public var isShuffled: Bool

    public init(items: [LocalQueueItem], currentIndex: Int?, repeatMode: RepeatMode, isShuffled: Bool) {
        self.items = items
        self.currentIndex = currentIndex
        self.repeatMode = repeatMode
        self.isShuffled = isShuffled
    }
}

/// One JSON file, written atomically. nil from `load()` when the file is missing, corrupt or from a newer version.
public struct QueueStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/<bundle id>/queue.json`.
    public static func defaultURL(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> URL {
        URL.applicationSupportDirectory
            .appending(path: bundleIdentifier ?? "SkinAmp", directoryHint: .isDirectory)
            .appending(path: "queue.json", directoryHint: .notDirectory)
    }

    public func load() -> QueueSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
            let stored = try? JSONDecoder().decode(Stored.self, from: data),
            stored.version == QueueSnapshot.currentVersion
        else { return nil }
        var seen = Set<UUID>()
        let items = stored.items.map { item -> LocalQueueItem in
            // A missing or duplicated id gets a fresh one rather than failing the whole file.
            var id = item.id ?? UUID()
            if !seen.insert(id).inserted {
                id = UUID()
                seen.insert(id)
            }
            let source: Track.Source
            switch item.source {
            case .file(let path): source = .file(URL(fileURLWithPath: path))
            case .plex(let partKey, let cacheKey, let size): source = .plex(partKey: partKey, cacheKey: cacheKey, size: size)
            }
            let track = Track(
                id: id, title: item.title, artist: item.artist, album: item.album, duration: item.duration,
                bitrate: item.bitrate, sampleRate: item.sampleRate, channels: item.channels, source: source)
            return LocalQueueItem(track: track, id: item.mediaID)
        }
        return QueueSnapshot(
            items: items, currentIndex: stored.currentIndex,
            repeatMode: RepeatMode(storedName: stored.repeatName), isShuffled: stored.shuffle)
    }

    /// Creates the directory, encodes with sorted keys, `Data.write(options: .atomic)`.
    public func save(_ snapshot: QueueSnapshot) throws {
        let stored = Stored(
            version: QueueSnapshot.currentVersion,
            currentIndex: snapshot.currentIndex,
            repeatName: snapshot.repeatMode.storedName,
            shuffle: snapshot.isShuffled,
            items: snapshot.items.map { item in
                let track = item.track
                let source: StoredSource
                switch track.source {
                case .file(let url): source = .file(path: url.path)
                case .plex(let partKey, let cacheKey, let size): source = .plex(partKey: partKey, cacheKey: cacheKey, size: size)
                }
                return StoredItem(
                    id: track.id, title: track.title, artist: track.artist, album: track.album,
                    duration: track.duration, bitrate: track.bitrate, sampleRate: track.sampleRate,
                    channels: track.channels, source: source, mediaID: item.id)
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(stored)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}

// MARK: File format (private mirrors; the key set is pinned by a test)

private struct Stored: Codable {
    var version: Int
    var currentIndex: Int?
    var repeatName: String
    var shuffle: Bool
    var items: [StoredItem]

    enum CodingKeys: String, CodingKey {
        case version, currentIndex, shuffle, items
        case repeatName = "repeat"
    }
}

private struct StoredItem: Codable {
    var id: UUID?
    var title: String
    var artist: String
    var album: String?
    var duration: TimeInterval
    var bitrate: Int?
    var sampleRate: Double?
    var channels: Int?
    var source: StoredSource
    var mediaID: MediaID?
}

private enum StoredSource: Codable {
    case file(path: String)
    case plex(partKey: String, cacheKey: String, size: Int64?)

    enum CodingKeys: String, CodingKey { case kind, path, partKey, cacheKey, size }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "file":
            self = .file(path: try c.decode(String.self, forKey: .path))
        case "plex":
            self = .plex(
                partKey: try c.decode(String.self, forKey: .partKey),
                cacheKey: try c.decode(String.self, forKey: .cacheKey),
                size: try c.decodeIfPresent(Int64.self, forKey: .size))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown source kind")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .file(let path):
            try c.encode("file", forKey: .kind)
            try c.encode(path, forKey: .path)
        case .plex(let partKey, let cacheKey, let size):
            try c.encode("plex", forKey: .kind)
            try c.encode(partKey, forKey: .partKey)
            try c.encode(cacheKey, forKey: .cacheKey)
            try c.encodeIfPresent(size, forKey: .size)
        }
    }
}

extension RepeatMode {
    fileprivate var storedName: String {
        switch self {
        case .off: "off"
        case .all: "all"
        case .one: "one"
        }
    }

    fileprivate init(storedName: String) {
        switch storedName {
        case "all": self = .all
        case "one": self = .one
        default: self = .off
        }
    }
}
