import AVFoundation
import AudioCore
import Foundation
import MusicBackendKit
import os

private let log = Logger(subsystem: "com.brennanmke.SkinAmp", category: "FolderIndexer")

/// Scans `Artist/Album/<tracks>` into a `FolderIndex`. A pure async function of the tree (and of the
/// previous index, which only saves work): the folder structure decides artists and albums, tags only
/// refine titles and numbers. Runs off the main actor (it is `nonisolated` and `async`).
public struct FolderIndexer: Sendable {
    public typealias Loader = @Sendable (URL) async throws -> Track

    public var loader: Loader
    public var maxConcurrent: Int

    public init(loader: @escaping Loader = { try await LocalTrackLoader.loadTrack(at: $0) }, maxConcurrent: Int = 4) {
        self.loader = loader
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// Walks `root`, reuses unchanged entries of `previous`, reads the rest. Throws only CancellationError
    /// or an unreadable root.
    public func build(root: URL, previous: FolderIndex?) async throws -> FolderIndex {
        let started = Date()
        let resolved = root.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = FolderIndexCache.standardizedPath(root)
        let previousIndex = previous?.root == rootPath ? previous : nil

        // Phase 1: the walk.
        var walk = FolderWalk()
        try walk.run(root: resolved)
        try Task.checkCancellation()

        // Phase 2: metadata, four files at a time, reusing what has not changed.
        let outcomes = try await readJobs(walk.jobs, root: resolved, previous: previousIndex)
        try Task.checkCancellation()

        // Phase 3: assembly.
        var skipped = walk.skipped
        var reused = 0, read = 0
        var fileTracks: [Int: FolderTrack] = [:]
        for (index, outcome) in outcomes.enumerated() {
            switch outcome {
            case .reused(let track): fileTracks[index] = track; reused += 1
            case .loaded(let track): fileTracks[index] = track; read += 1
            case .skipped(let file, let wasRead):
                skipped.append(file)
                if wasRead { read += 1 } else { reused += 1 }
            }
        }
        var index = try await assemble(
            walk: walk, tracks: fileTracks, skipped: skipped, root: resolved, rootPath: rootPath, previous: previousIndex)
        index.builtAt = Date()
        index.summary.builtAt = index.builtAt
        let seconds = Date().timeIntervalSince(started)
        log.info("counts: \(index.artists.count, privacy: .public)/\(index.albums.count, privacy: .public)/\(index.tracks.count, privacy: .public), skipped \(index.skipped.count, privacy: .public), reused \(reused, privacy: .public), read \(read, privacy: .public), \(seconds, format: .fixed(precision: 2), privacy: .public) s")
        return index
    }

    // MARK: Phase 2

    private enum Outcome: Sendable {
        case reused(FolderTrack)
        case loaded(FolderTrack)
        /// `wasRead`: false when the skip came from the previous index.
        case skipped(FolderSkippedFile, wasRead: Bool)
    }

    private func readJobs(_ jobs: [FolderWalk.Job], root: URL, previous: FolderIndex?) async throws -> [Outcome] {
        let previousTracks = Dictionary(
            (previous?.tracks ?? []).map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        let previousSkipped = Dictionary(
            (previous?.skipped ?? []).map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        let loader = self.loader
        var outcomes: [Outcome?] = Array(repeating: nil, count: jobs.count)
        var pending: [Int] = []
        for (index, job) in jobs.enumerated() {
            if let old = previousTracks[job.relativePath],
               old.matches(relativePath: job.relativePath, fileSize: job.fileSize, modified: job.modified) {
                outcomes[index] = .reused(old)
            } else if let old = previousSkipped[job.relativePath], old.fileSize == job.fileSize,
                      let modified = old.modified, abs(modified.timeIntervalSince(job.modified)) < 0.001 {
                outcomes[index] = .skipped(old, wasRead: false)
            } else {
                pending.append(index)
            }
        }

        try await withThrowingTaskGroup(of: (Int, Outcome).self) { group in
            var next = 0
            func addNext() {
                guard next < pending.count else { return }
                let index = pending[next]
                let job = jobs[index]
                next += 1
                group.addTask {
                    try Task.checkCancellation()
                    return (index, await Self.read(job, root: root, loader: loader))
                }
            }
            for _ in 0..<maxConcurrent { addNext() }
            while let (index, outcome) = try await group.next() {
                outcomes[index] = outcome
                addNext()
            }
        }
        return outcomes.compactMap { $0 }
    }

    /// Cancellation is reported as a skip with an empty reason; the caller's `checkCancellation` throws it.
    private static func read(_ job: FolderWalk.Job, root: URL, loader: Loader) async -> Outcome {
        let url = URL(fileURLWithPath: root.path + "/" + job.relativePath)
        do {
            let track = try await loader(url)
            let numbers = await FolderTrackNumbers.read(url: url)
            return .loaded(makeTrack(job, track: track, numbers: numbers))
        } catch {
            if !(error is CancellationError) {
                log.warning("Skipping \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            return .skipped(
                FolderSkippedFile(
                    relativePath: job.relativePath, reason: error.localizedDescription, fileSize: job.fileSize,
                    modified: job.modified),
                wasRead: true)
        }
    }

    private static func makeTrack(
        _ job: FolderWalk.Job, track: Track, numbers: (track: Int?, disc: Int?)
    ) -> FolderTrack {
        let stem = ((job.relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
        var title = track.title
        var prefixNumber: Int?
        if title == stem, let match = title.wholeMatch(of: #/(\d{1,3})[\s._-]+(.+)/#),
           !match.output.2.trimmingCharacters(in: .whitespaces).isEmpty {
            title = String(match.output.2)
            prefixNumber = Int(match.output.1)
        }
        let artistName = track.artist.isEmpty ? job.artistName : track.artist
        let library = LibraryTrack(
            id: MediaID(.track, nfc(job.relativePath)), title: title, artistID: job.artistID, artistName: artistName,
            albumID: job.albumID, albumName: job.albumTitle, trackNumber: numbers.track ?? prefixNumber,
            discNumber: job.disc ?? numbers.disc, duration: track.duration, bitrate: track.bitrate,
            sampleRate: track.sampleRate, channels: track.channels, artwork: nil)
        return FolderTrack(
            library: library, relativePath: job.relativePath, fileSize: job.fileSize, modified: job.modified,
            album: track.album ?? job.albumTitle)
    }

    // MARK: Phase 3

    private struct BuiltAlbum {
        var album: LibraryAlbum
        var tracks: [FolderTrack]
        var artistOrder: Int
        var synthetic: Bool
    }

    private func assemble(
        walk: FolderWalk, tracks: [Int: FolderTrack], skipped: [FolderSkippedFile], root: URL, rootPath: String,
        previous: FolderIndex?
    ) async throws -> FolderIndex {
        // Group the readable tracks by album.
        var byAlbum: [Int: [FolderTrack]] = [:]
        for (jobIndex, job) in walk.jobs.enumerated() {
            if let track = tracks[jobIndex] { byAlbum[job.albumKey, default: []].append(track) }
        }
        let previousAlbums = Dictionary(
            (previous?.albums ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let previousTracks = Set((previous?.tracks ?? []).map(\.relativePath))

        var built: [BuiltAlbum] = []
        var artistsWithAlbums: [Int: [Int]] = [:]  // artist key to index into `built`
        for (albumKey, album) in walk.albums.enumerated() {
            guard var albumTracks = byAlbum[albumKey], !albumTracks.isEmpty else { continue }
            albumTracks.sort { a, b in
                let ka = (a.library.discNumber ?? 0, a.library.trackNumber ?? Int.max)
                let kb = (b.library.discNumber ?? 0, b.library.trackNumber ?? Int.max)
                if ka != kb { return ka < kb }
                return a.relativePath.localizedStandardCompare(b.relativePath) == .orderedAscending
            }
            try Task.checkCancellation()
            let artwork = await artworkRef(
                for: album, first: albumTracks[0], root: root, previous: previousAlbums[album.id],
                firstWasReused: previousTracks.contains(albumTracks[0].relativePath))
            for index in albumTracks.indices { albumTracks[index].library.artwork = artwork }
            let libraryAlbum = LibraryAlbum(
                id: album.id, title: album.title, artistID: walk.artists[album.artistKey].id,
                artistName: walk.artists[album.artistKey].name, year: album.year, trackCount: albumTracks.count,
                artwork: artwork)
            artistsWithAlbums[album.artistKey, default: []].append(built.count)
            built.append(BuiltAlbum(album: libraryAlbum, tracks: albumTracks, artistOrder: 0, synthetic: album.synthetic))
        }

        // Artists: only those with an album, sorted by sort name, Unknown Artist last.
        struct ArtistEntry { var key: Int; var artist: LibraryArtist }
        var entries: [ArtistEntry] = []
        for (key, source) in walk.artists.enumerated() where artistsWithAlbums[key] != nil {
            entries.append(ArtistEntry(
                key: key,
                artist: LibraryArtist(
                    id: source.id, name: source.name, sortName: source.sortName, artwork: nil)))
        }
        entries.sort { a, b in
            let ua = a.artist.id.rawValue == ".", ub = b.artist.id.rawValue == "."
            if ua != ub { return ub }
            return (a.artist.sortName ?? a.artist.name).localizedStandardCompare(b.artist.sortName ?? b.artist.name)
                == .orderedAscending
        }
        var order: [Int: Int] = [:]
        for (position, entry) in entries.enumerated() { order[entry.key] = position }
        for (key, indices) in artistsWithAlbums {
            for index in indices { built[index].artistOrder = order[key] ?? Int.max }
        }
        built.sort { a, b in
            if a.artistOrder != b.artistOrder { return a.artistOrder < b.artistOrder }
            if a.synthetic != b.synthetic { return b.synthetic }
            let ya = a.album.year ?? Int.max, yb = b.album.year ?? Int.max
            if ya != yb { return ya < yb }
            return a.album.title.localizedStandardCompare(b.album.title) == .orderedAscending
        }
        for position in entries.indices {
            // The first album's artwork, or nil when it has none (not a later album's).
            let first = built.first { $0.album.artistID == entries[position].artist.id }
            entries[position].artist.artwork = first?.album.artwork
        }

        let sortedSkipped = skipped.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        return FolderIndex(
            root: rootPath, builtAt: Date(), artists: entries.map(\.artist), albums: built.map(\.album),
            tracks: built.flatMap(\.tracks), skipped: sortedSkipped)
    }

    private func artworkRef(
        for album: FolderWalk.Album, first: FolderTrack, root: URL, previous: LibraryAlbum?, firstWasReused: Bool
    ) async -> ArtworkRef? {
        if let ref = FolderArtwork.imageRef(in: album) { return ref }
        if firstWasReused, let previous { return previous.artwork }
        let url = first.url(root: root)
        if await EmbeddedArtworkLoader.artworkData(for: url) != nil {
            return ArtworkRef(rawValue: "embedded:\(first.relativePath)")
        }
        return nil
    }
}

func nfc(_ text: String) -> String { text.precomposedStringWithCanonicalMapping }

// MARK: Phase 1

/// The synchronous directory walk. Decides artists, albums and which files are tracks.
struct FolderWalk {
    struct Artist {
        var id: MediaID
        var name: String
        var sortName: String
    }

    struct Album {
        var id: MediaID
        var title: String
        var year: Int?
        var artistKey: Int
        var synthetic: Bool
        /// On-disk relative path of the album folder; nil for Singles and Unknown Album.
        var folderPath: String?
        /// Image files directly in the album folder (names), and the first one found in a subfolder.
        var images: [String] = []
        var nestedImage: String?
    }

    struct Job {
        var relativePath: String
        var albumKey: Int
        var artistID: MediaID
        var artistName: String
        var albumID: MediaID
        var albumTitle: String
        var disc: Int?
        var fileSize: Int64
        var modified: Date
    }

    private struct Entry {
        var url: URL
        var name: String
        var isDirectory: Bool
        var isSymlink: Bool
        var size: Int64
        var modified: Date
    }

    var artists: [Artist] = []
    var albums: [Album] = []
    var jobs: [Job] = []
    var skipped: [FolderSkippedFile] = []

    static let sidecarExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "bmp", "tif", "tiff", "txt", "nfo", "cue", "log", "m3u", "m3u8", "pls",
        "pdf", "sfv", "md5", "ini", "url", "db",
    ]

    private var unknownArtistKey: Int?
    private var unknownAlbumKey: Int?

    mutating func run(root: URL) throws {
        guard FileManager.default.isReadableFile(atPath: root.path) else {
            throw MusicBackendError.unreachable("The music folder “\(root.lastPathComponent)” can't be read.")
        }
        for entry in try list(root, strict: true) {
            if entry.isDirectory {
                try walkArtist(entry)
            } else if entry.isSymlink && !LocalTrackLoader.isAudio(entry.url) {
                continue
            } else if !Self.isSidecar(entry.name), LocalTrackLoader.isAudio(entry.url) {
                let artistKey = unknownArtist()
                let albumKey = unknownAlbum(artistKey: artistKey)
                addJob(entry, relativePath: entry.name, albumKey: albumKey, disc: nil)
            } else {
                noteOther(entry, relativePath: entry.name)
            }
        }
    }

    // MARK: Artist and album folders

    private mutating func walkArtist(_ folder: Entry) throws {
        try Task.checkCancellation()
        let artistKey = artists.count
        artists.append(Artist(
            id: MediaID(.artist, nfc(folder.name)), name: folder.name, sortName: Self.sortName(folder.name)))
        var singlesKey: Int?
        for entry in try list(folder.url) {
            if entry.isDirectory {
                let rel = folder.name + "/" + entry.name
                let (title, year) = Self.parseAlbumFolder(entry.name)
                let key = albums.count
                albums.append(Album(
                    id: MediaID(.album, nfc(rel)), title: title, year: year, artistKey: artistKey, synthetic: false,
                    folderPath: rel))
                try walkAlbum(entry, rel: rel, disc: nil, albumKey: key, top: true)
            } else if entry.isSymlink && !LocalTrackLoader.isAudio(entry.url) {
                continue
            } else if !Self.isSidecar(entry.name), LocalTrackLoader.isAudio(entry.url) {
                let key: Int
                if let singlesKey { key = singlesKey } else {
                    key = albums.count
                    albums.append(Album(
                        id: MediaID(.album, nfc(folder.name)), title: "Singles", year: nil, artistKey: artistKey,
                        synthetic: true, folderPath: nil))
                    singlesKey = key
                }
                addJob(entry, relativePath: folder.name + "/" + entry.name, albumKey: key, disc: nil)
            } else {
                noteOther(entry, relativePath: folder.name + "/" + entry.name)
            }
        }
    }

    private mutating func walkAlbum(_ folder: Entry, rel: String, disc: Int?, albumKey: Int, top: Bool) throws {
        try Task.checkCancellation()
        var subfolders: [Entry] = []
        for entry in try list(folder.url) {
            let entryRel = rel + "/" + entry.name
            if entry.isDirectory {
                subfolders.append(entry)
            } else if entry.isSymlink && !LocalTrackLoader.isAudio(entry.url) {
                continue
            } else if !Self.isSidecar(entry.name), LocalTrackLoader.isAudio(entry.url) {
                addJob(entry, relativePath: entryRel, albumKey: albumKey, disc: disc)
            } else {
                if FolderArtwork.isImageName(entry.name) {
                    if top { albums[albumKey].images.append(entry.name) } else if albums[albumKey].nestedImage == nil {
                        albums[albumKey].nestedImage = entryRel
                    }
                }
                noteOther(entry, relativePath: entryRel)
            }
        }
        for sub in subfolders {
            try walkAlbum(
                sub, rel: rel + "/" + sub.name, disc: Self.discNumber(sub.name) ?? disc, albumKey: albumKey, top: false)
        }
    }

    // MARK: Helpers

    private mutating func addJob(_ entry: Entry, relativePath: String, albumKey: Int, disc: Int?) {
        let album = albums[albumKey]
        let artist = artists[album.artistKey]
        jobs.append(Job(
            relativePath: relativePath, albumKey: albumKey, artistID: artist.id, artistName: artist.name,
            albumID: album.id, albumTitle: album.title, disc: disc, fileSize: entry.size, modified: entry.modified))
    }

    /// A non-audio file: sidecars are ignored silently, everything else is reported.
    private mutating func noteOther(_ entry: Entry, relativePath: String) {
        if Self.isSidecar(entry.name) { return }
        skipped.append(FolderSkippedFile(relativePath: relativePath, reason: "not an audio file"))
    }

    private mutating func unknownArtist() -> Int {
        if let unknownArtistKey { return unknownArtistKey }
        let key = artists.count
        artists.append(Artist(
            id: MediaID(.artist, "."), name: ArtistName.unknown, sortName: ArtistName.unknown))
        unknownArtistKey = key
        return key
    }

    private mutating func unknownAlbum(artistKey: Int) -> Int {
        if let unknownAlbumKey { return unknownAlbumKey }
        let key = albums.count
        albums.append(Album(
            id: MediaID(.album, "."), title: "Unknown Album", year: nil, artistKey: artistKey, synthetic: true,
            folderPath: nil))
        unknownAlbumKey = key
        return key
    }

    private func list(_ directory: URL, strict: Bool = false) throws -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        } catch {
            if strict { throw error }
            log.warning("Cannot read folder \(directory.lastPathComponent, privacy: .public)")
            return []
        }
        let entries = urls.map { url -> Entry in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isSymlink = values?.isSymbolicLink == true
            var size = Int64(values?.fileSize ?? 0)
            var modified = values?.contentModificationDate ?? .distantPast
            if isSymlink, let target = try? url.resolvingSymlinksInPath().resourceValues(forKeys: Set(keys)) {
                size = Int64(target.fileSize ?? 0)
                modified = target.contentModificationDate ?? modified
            }
            return Entry(
                url: url, name: url.lastPathComponent, isDirectory: values?.isDirectory == true && !isSymlink,
                isSymlink: isSymlink, size: size, modified: modified)
        }
        // Files before folders, each in Finder order.
        return entries.sorted {
            if $0.isDirectory != $1.isDirectory { return !$0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func isSidecar(_ name: String) -> Bool {
        sidecarExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    static func sortName(_ name: String) -> String {
        if name.range(of: "the ", options: [.caseInsensitive, .anchored]) != nil, name.count > 4 {
            return String(name.dropFirst(4))
        }
        return name
    }

    /// `1999 - Nine` and `Ten (2010)` give a year in 1900...2100; anything else keeps the folder name.
    static func parseAlbumFolder(_ name: String) -> (title: String, year: Int?) {
        if let match = name.wholeMatch(of: #/(\d{4})\s*[-–]\s*(.+)/#), let year = Int(match.output.1),
           (1900...2100).contains(year) {
            return (String(match.output.2), year)
        }
        if let match = name.wholeMatch(of: #/(.+?)\s*\((\d{4})\)/#), let year = Int(match.output.2),
           (1900...2100).contains(year) {
            return (String(match.output.1), year)
        }
        return (name, nil)
    }

    static func discNumber(_ folderName: String) -> Int? {
        guard let match = folderName.wholeMatch(of: #/(?i:disc|disk|cd)\s*0*(\d{1,3})/#) else { return nil }
        return Int(match.output.1)
    }
}

// MARK: Track and disc numbers

/// Best-effort track and disc numbers from ID3 and iTunes tags. Never throws.
enum FolderTrackNumbers {
    static func read(url: URL) async -> (track: Int?, disc: Int?) {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.metadata), !items.isEmpty else { return (nil, nil) }
        let track = await number(in: items, identifiers: [.iTunesMetadataTrackNumber, .id3MetadataTrackNumber])
        let disc = await number(in: items, identifiers: [.iTunesMetadataDiscNumber, .id3MetadataPartOfASet])
        return (track, disc)
    }

    private static func number(in items: [AVMetadataItem], identifiers: [AVMetadataIdentifier]) async -> Int? {
        for identifier in identifiers {
            guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier).first else { continue }
            if let text = try? await item.load(.stringValue), let value = parse(text) { return value }
            if let data = try? await item.load(.dataValue), data.count >= 4 {
                let value = Int(data[data.startIndex + 2]) << 8 | Int(data[data.startIndex + 3])
                if value > 0 { return value }
            }
        }
        return nil
    }

    /// "3" or "3/12" gives 3.
    static func parse(_ text: String) -> Int? {
        let head = text.split(separator: "/").first.map(String.init) ?? text
        guard let value = Int(head.trimmingCharacters(in: .whitespaces)), value > 0 else { return nil }
        return value
    }
}
