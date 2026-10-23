import AudioCore
import CryptoKit
import Foundation
import MusicBackendKit

/// Everything the backend serves, as a value. Codable so it is the cache file too.
/// The `Library*` models are not Codable, so the cache goes through private mirror structs below.
public struct FolderIndex: Codable, Hashable, Sendable {
    public static let formatVersion = 1
    public var version: Int
    /// `root.standardizedFileURL.path`
    public var root: String
    public var builtAt: Date
    /// Sorted by sort name.
    public var artists: [LibraryArtist]
    /// Sorted by artist, year, title.
    public var albums: [LibraryAlbum]
    /// In album order (disc, number, name).
    public var tracks: [FolderTrack]
    public var skipped: [FolderSkippedFile]
    public var summary: FolderIndexSummary

    public init(
        version: Int = FolderIndex.formatVersion, root: String, builtAt: Date = Date(),
        artists: [LibraryArtist] = [], albums: [LibraryAlbum] = [], tracks: [FolderTrack] = [],
        skipped: [FolderSkippedFile] = []
    ) {
        self.version = version
        self.root = root
        self.builtAt = builtAt
        self.artists = artists
        self.albums = albums
        self.tracks = tracks
        self.skipped = skipped
        self.summary = FolderIndexSummary(
            artists: artists.count, albums: albums.count, tracks: tracks.count, skipped: skipped.count, builtAt: builtAt)
    }

    /// Equal apart from when it was built.
    public func hasSameContent(as other: FolderIndex) -> Bool {
        version == other.version && root == other.root && artists == other.artists && albums == other.albums
            && tracks == other.tracks && skipped == other.skipped
    }

    public static func empty(root: URL) -> FolderIndex {
        FolderIndex(root: FolderIndexCache.standardizedPath(root))
    }

    private struct Stored: Codable {
        var version: Int
        var root: String
        var builtAt: Date
        var artists: [StoredArtist]
        var albums: [StoredAlbum]
        var tracks: [FolderTrack]
        var skipped: [FolderSkippedFile]
    }

    public init(from decoder: any Decoder) throws {
        let stored = try Stored(from: decoder)
        self.init(
            version: stored.version, root: stored.root, builtAt: stored.builtAt,
            artists: stored.artists.map(\.model), albums: stored.albums.map(\.model),
            tracks: stored.tracks, skipped: stored.skipped)
    }

    public func encode(to encoder: any Encoder) throws {
        try Stored(
            version: version, root: root, builtAt: builtAt, artists: artists.map(StoredArtist.init),
            albums: albums.map(StoredAlbum.init), tracks: tracks, skipped: skipped
        ).encode(to: encoder)
    }
}

/// A LibraryTrack plus what the player and the cache need.
public struct FolderTrack: Codable, Hashable, Sendable {
    public var library: LibraryTrack
    /// As the file system spelled it (not NFC-normalized).
    public var relativePath: String
    public var fileSize: Int64
    public var modified: Date
    /// For `AudioCore.Track.album`: the tag, else the album folder's title.
    public var album: String?

    public init(library: LibraryTrack, relativePath: String, fileSize: Int64, modified: Date, album: String?) {
        self.library = library
        self.relativePath = relativePath
        self.fileSize = fileSize
        self.modified = modified
        self.album = album
    }

    /// The same file on disk: path, size and modification time all match.
    func matches(relativePath: String, fileSize: Int64, modified: Date) -> Bool {
        self.relativePath == relativePath && self.fileSize == fileSize
            && abs(self.modified.timeIntervalSince(modified)) < 0.001
    }

    public func url(root: URL) -> URL {
        URL(fileURLWithPath: root.path + "/" + relativePath)
    }

    public func audioTrack(root: URL) -> Track {
        Track(
            title: library.title, artist: library.artistName, album: album, duration: library.duration ?? 0,
            bitrate: library.bitrate, sampleRate: library.sampleRate, channels: library.channels,
            source: .file(url(root: root)))
    }

    private struct Stored: Codable {
        var library: StoredTrack
        var relativePath: String
        var fileSize: Int64
        var modified: Date
        var album: String?
    }

    public init(from decoder: any Decoder) throws {
        let stored = try Stored(from: decoder)
        self.init(
            library: stored.library.model, relativePath: stored.relativePath, fileSize: stored.fileSize,
            modified: stored.modified, album: stored.album)
    }

    public func encode(to encoder: any Encoder) throws {
        try Stored(library: StoredTrack(library), relativePath: relativePath, fileSize: fileSize, modified: modified, album: album)
            .encode(to: encoder)
    }
}

public struct FolderSkippedFile: Codable, Hashable, Sendable {
    public var relativePath: String
    public var reason: String
    /// Set for files that could not be read, so an unchanged one is not read again on the next scan.
    public var fileSize: Int64?
    public var modified: Date?

    public init(relativePath: String, reason: String, fileSize: Int64? = nil, modified: Date? = nil) {
        self.relativePath = relativePath
        self.reason = reason
        self.fileSize = fileSize
        self.modified = modified
    }
}

public struct FolderIndexSummary: Codable, Hashable, Sendable {
    public var artists: Int
    public var albums: Int
    public var tracks: Int
    public var skipped: Int
    public var builtAt: Date

    public init(artists: Int, albums: Int, tracks: Int, skipped: Int, builtAt: Date) {
        self.artists = artists
        self.albums = albums
        self.tracks = tracks
        self.skipped = skipped
        self.builtAt = builtAt
    }

    /// "12 artists, 30 albums, 412 tracks", plus ", 3 files skipped" when any were.
    public var text: String {
        func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        var parts = [count(artists, "artist", "artists"), count(albums, "album", "albums"), count(tracks, "track", "tracks")]
        if skipped > 0 { parts.append(count(skipped, "file skipped", "files skipped")) }
        return parts.joined(separator: ", ")
    }
}

public enum FolderIndexStatus: Hashable, Sendable {
    case notConnected
    /// `previous` is the cached summary being served meanwhile.
    case indexing(previous: FolderIndexSummary?)
    case ready(FolderIndexSummary)
    case failed(String)
}

/// One JSON file per root under Caches.
public enum FolderIndexCache {
    /// `~/Library/Caches/<bundle id or co.sstools.roadie>/FolderIndex/`
    public static func defaultDirectory(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appending(path: bundleIdentifier ?? "co.sstools.roadie", directoryHint: .isDirectory)
            .appending(path: "FolderIndex", directoryHint: .isDirectory)
    }

    /// `directory/index-<first 16 hex of SHA-256 of the standardized root path>.json`
    public static func fileURL(for root: URL, in directory: URL) -> URL {
        let path = standardizedPath(root)
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        return directory.appending(path: "index-\(hex).json", directoryHint: .notDirectory)
    }

    /// nil when missing, undecodable, of another version or for another root (then the file is deleted).
    public static func load(for root: URL, in directory: URL) -> FolderIndex? {
        let file = fileURL(for: root, in: directory)
        guard let data = try? Data(contentsOf: file) else { return nil }
        guard let index = try? JSONDecoder().decode(FolderIndex.self, from: data),
              index.version == FolderIndex.formatVersion, index.root == standardizedPath(root) else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return index
    }

    public static func save(_ index: FolderIndex, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(index)
        try data.write(to: fileURL(for: URL(fileURLWithPath: index.root), in: directory), options: .atomic)
    }

    public static func exists(for root: URL, in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: root, in: directory).path)
    }

    public static func remove(for root: URL, in directory: URL) {
        try? FileManager.default.removeItem(at: fileURL(for: root, in: directory))
    }

    /// `/var` and `/private/var` spell the same folder; hash and compare one spelling.
    static func standardizedPath(_ root: URL) -> String {
        root.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

// MARK: Codable mirrors of the MusicBackendKit models

private struct StoredArtist: Codable {
    var id: MediaID
    var name: String
    var sortName: String?
    var artwork: ArtworkRef?

    init(_ model: LibraryArtist) {
        id = model.id
        name = model.name
        sortName = model.sortName
        artwork = model.artwork
    }

    var model: LibraryArtist { LibraryArtist(id: id, name: name, sortName: sortName, artwork: artwork) }
}

private struct StoredAlbum: Codable {
    var id: MediaID
    var title: String
    var artistID: MediaID?
    var artistName: String?
    var year: Int?
    var trackCount: Int?
    var artwork: ArtworkRef?

    init(_ model: LibraryAlbum) {
        id = model.id
        title = model.title
        artistID = model.artistID
        artistName = model.artistName
        year = model.year
        trackCount = model.trackCount
        artwork = model.artwork
    }

    var model: LibraryAlbum {
        LibraryAlbum(
            id: id, title: title, artistID: artistID, artistName: artistName, year: year, trackCount: trackCount,
            artwork: artwork)
    }
}

private struct StoredTrack: Codable {
    var id: MediaID
    var title: String
    var artistID: MediaID?
    var artistName: String
    var albumID: MediaID?
    var albumName: String?
    var trackNumber: Int?
    var discNumber: Int?
    var duration: TimeInterval?
    var bitrate: Int?
    var sampleRate: Double?
    var channels: Int?
    var artwork: ArtworkRef?

    init(_ model: LibraryTrack) {
        id = model.id
        title = model.title
        artistID = model.artistID
        artistName = model.artistName
        albumID = model.albumID
        albumName = model.albumName
        trackNumber = model.trackNumber
        discNumber = model.discNumber
        duration = model.duration
        bitrate = model.bitrate
        sampleRate = model.sampleRate
        channels = model.channels
        artwork = model.artwork
    }

    var model: LibraryTrack {
        LibraryTrack(
            id: id, title: title, artistID: artistID, artistName: artistName, albumID: albumID, albumName: albumName,
            trackNumber: trackNumber, discNumber: discNumber, duration: duration, bitrate: bitrate,
            sampleRate: sampleRate, channels: channels, artwork: artwork)
    }
}
