import AudioCore
import Foundation
import MusicBackendKit
import os

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
            .appending(path: bundleIdentifier ?? "co.sstools.roadie", directoryHint: .isDirectory)
            .appending(path: "queue.json", directoryHint: .notDirectory)
    }

    /// What `loadQueue()` found: the queue minus items of kinds this build cannot play.
    public struct LoadedQueue: Equatable, Sendable {
        public var snapshot: QueueSnapshot
        /// Items dropped because their source kind is unknown (a queue saved with a source kind this build removed).
        public var droppedItems: Int
    }

    /// `loadQueue()?.snapshot`.
    public func load() -> QueueSnapshot? {
        loadQueue()?.snapshot
    }

    /// nil when the file is missing, corrupt or from a newer version; otherwise the surviving items in order,
    /// `currentIndex` remapped to the same item (nil when it was dropped). Never writes.
    public func loadQueue() -> LoadedQueue? {
        guard let data = try? Data(contentsOf: fileURL),
            let stored = try? JSONDecoder().decode(Stored.self, from: data),
            stored.version == QueueSnapshot.currentVersion
        else { return nil }
        var seen = Set<UUID>()
        var items: [LocalQueueItem] = []
        var currentIndex: Int?
        var dropped = 0
        for (index, item) in stored.items.enumerated() {
            guard let storedSource = item.source else {
                dropped += 1
                continue
            }
            // A missing or duplicated id gets a fresh one rather than failing the whole file.
            var id = item.id ?? UUID()
            if !seen.insert(id).inserted {
                id = UUID()
                seen.insert(id)
            }
            let source: Track.Source
            switch storedSource {
            case .file(let path): source = .file(URL(fileURLWithPath: path))
            }
            let track = Track(
                id: id, title: item.title, artist: item.artist, album: item.album, duration: item.duration,
                bitrate: item.bitrate, sampleRate: item.sampleRate, channels: item.channels, source: source)
            if index == stored.currentIndex { currentIndex = items.count }
            items.append(LocalQueueItem(track: track, id: item.mediaID))
        }
        if dropped > 0 {
            Logger(subsystem: "co.sstools.roadie", category: "QueueStore")
                .info("queue restore dropped \(dropped) item(s) of an unknown kind")
        }
        let snapshot = QueueSnapshot(
            items: items, currentIndex: currentIndex,
            repeatMode: RepeatMode(storedName: stored.repeatName), isShuffled: stored.shuffle)
        return LoadedQueue(snapshot: snapshot, droppedItems: dropped)
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
    var source: StoredSource?
    var mediaID: MediaID?

    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, duration, bitrate, sampleRate, channels, source, mediaID
    }

    init(
        id: UUID?, title: String, artist: String, album: String?, duration: TimeInterval, bitrate: Int?,
        sampleRate: Double?, channels: Int?, source: StoredSource?, mediaID: MediaID?
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.channels = channels
        self.source = source
        self.mediaID = mediaID
    }

    /// An unknown or malformed source (a kind this build removed) decodes as nil, so the item is dropped
    /// instead of failing the whole file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        artist = try c.decode(String.self, forKey: .artist)
        album = try c.decodeIfPresent(String.self, forKey: .album)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        bitrate = try c.decodeIfPresent(Int.self, forKey: .bitrate)
        sampleRate = try c.decodeIfPresent(Double.self, forKey: .sampleRate)
        channels = try c.decodeIfPresent(Int.self, forKey: .channels)
        source = try? c.decodeIfPresent(StoredSource.self, forKey: .source)
        mediaID = try c.decodeIfPresent(MediaID.self, forKey: .mediaID)
    }
}

private enum StoredSource: Codable {
    case file(path: String)

    enum CodingKeys: String, CodingKey { case kind, path }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "file":
            self = .file(path: try c.decode(String.self, forKey: .path))
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
