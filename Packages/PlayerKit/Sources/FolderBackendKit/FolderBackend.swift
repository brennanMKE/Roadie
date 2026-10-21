import AudioCore
import Foundation
import LocalPlayback
import MusicBackendKit
import os

private let log = Logger(subsystem: "com.brennanmke.SkinAmp", category: "FolderBackend")

/// A local folder, organized `Artist/Album/<tracks>`, behind `MusicBackend`. Browsing is answered from an
/// in-memory `FolderIndex` (cached on disk, rescanned in the background when the folder changes);
/// playback hands `Track`s with `.file` sources to the shared "This Mac" output.
public actor FolderBackend: MusicBackend {
    public typealias SettingsProvider = @Sendable () -> URL?
    public typealias WatcherFactory = @Sendable (URL, @escaping @Sendable () -> Void) -> any FolderWatching

    public nonisolated let sourceID = "folder"
    public nonisolated let displayName = "Local Folder"
    public nonisolated let capabilities: BackendCapabilities = [.search, .artwork, .localOutput]

    /// Settings key; the path of the chosen folder. #0063 and #0067 read it through `storedFolder`.
    public static let folderDefaultsKey = "LibraryFolderPath"

    /// The chosen folder, nil when none is stored.
    public static func storedFolder(in defaults: UserDefaults = .standard) -> URL? {
        guard let path = defaults.string(forKey: folderDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    public static func settingsProvider(defaults: UserDefaults = .standard) -> SettingsProvider {
        nonisolated(unsafe) let defaults = defaults
        return { storedFolder(in: defaults) }
    }

    private let settings: SettingsProvider
    private let output: LocalPlayerOutput
    private let cacheDirectory: URL
    private let indexer: FolderIndexer
    private let makeWatcher: WatcherFactory
    private let rescanDelay: Duration

    private var index: FolderIndex?
    private var lookup = Lookup(FolderIndex.empty(root: URL(fileURLWithPath: "/")))
    public private(set) var root: URL?
    public private(set) var status: FolderIndexStatus = .notConnected
    private var watcher: (any FolderWatching)?
    private var scanTask: Task<Void, Never>?
    private var scanToken = UUID()
    private var rescanRequested = false
    private var fullRequested = false
    private var debounceTask: Task<Void, Never>?
    private var debounceGeneration = 0
    private var continuations: [UUID: AsyncStream<FolderIndexStatus>.Continuation] = [:]

    /// True as soon as an index, cached or fresh, is in place.
    public var isConnected: Bool { index != nil }

    /// A change arrived while a scan was running (tests).
    var rescanIsQueued: Bool { rescanRequested }

    /// Live `statusUpdates()` subscriptions (tests).
    public var statusSubscriberCount: Int { continuations.count }

    public init(
        settings: @escaping SettingsProvider, output: LocalPlayerOutput,
        cacheDirectory: URL = FolderIndexCache.defaultDirectory(), indexer: FolderIndexer = FolderIndexer(),
        makeWatcher: @escaping WatcherFactory = FSEventsFolderWatcher.make(url:onChange:),
        rescanDelay: Duration = .seconds(2)
    ) {
        self.settings = settings
        self.output = output
        self.cacheDirectory = cacheDirectory
        self.indexer = indexer
        self.makeWatcher = makeWatcher
        self.rescanDelay = rescanDelay
    }

    // MARK: Status

    /// The current status first, then every change. The newest is kept if the subscriber is slow.
    public func statusUpdates() -> AsyncStream<FolderIndexStatus> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: FolderIndexStatus.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.endSubscription(id) }
        }
        continuation.yield(status)
        return stream
    }

    private func endSubscription(_ id: UUID) {
        continuations[id] = nil
    }

    private func setStatus(_ new: FolderIndexStatus) {
        guard new != status else { return }
        status = new
        for continuation in continuations.values { continuation.yield(new) }
    }

    // MARK: Connection

    /// The fallback's probe: the stored folder exists, is a directory and is readable. No index, no scan, no watcher.
    /// Throws the same `.notConfigured` / `.unreachable` `connect()` would.
    public nonisolated static func checkReachable(in defaults: UserDefaults = .standard) throws(MusicBackendError) {
        _ = try validate(storedFolder(in: defaults))
    }

    private nonisolated static func validate(_ folder: URL?) throws(MusicBackendError) -> URL {
        guard let folder else {
            throw MusicBackendError.notConfigured("Choose a music folder under Settings \u{203A} Library.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: folder.path) else {
            throw MusicBackendError.unreachable("The music folder \u{201C}\(folder.lastPathComponent)\u{201D} can't be read.")
        }
        return folder
    }

    public func connect() async throws {
        let configured: URL
        do { configured = try Self.validate(settings()) } catch {
            await disconnect()
            log.info("connect: not available")
            throw error
        }
        let name = configured.lastPathComponent
        let resolved = configured.standardizedFileURL.resolvingSymlinksInPath()
        if let current = root, current == resolved {
            // Already connected to this folder; wait for a first scan that is still running.
            if index == nil, let task = scanTask { await task.value }
            return
        }
        await disconnect()
        root = resolved
        let directory = cacheDirectory
        let cached = await Self.loadCache(for: resolved, in: directory)
        guard root == resolved else { return }  // disconnected or switched while the cache loaded
        if let cached {
            index = cached
            lookup = Lookup(cached)
            setStatus(.indexing(previous: cached.summary))
            startWatching(resolved)
            requestScan(full: false)
            log.info("connect: ok, cached index for \(name, privacy: .public)")
        } else {
            setStatus(.indexing(previous: nil))
            requestScan(full: false)
            startWatching(resolved)
            if let task = scanTask { await task.value }
            if index == nil {
                let message: String
                if case .failed(let text) = status { message = text } else { message = "The music folder \u{201C}\(name)\u{201D} can't be read." }
                log.info("connect: failed")
                throw MusicBackendError.unreachable(message)
            }
            log.info("connect: ok, scanned \(name, privacy: .public)")
        }
    }

    public func disconnect() async {
        watcher?.stop()
        watcher = nil
        scanTask?.cancel()
        scanTask = nil
        scanToken = UUID()
        debounceTask?.cancel()
        debounceTask = nil
        debounceGeneration += 1
        rescanRequested = false
        fullRequested = false
        index = nil
        lookup = Lookup(FolderIndex.empty(root: URL(fileURLWithPath: "/")))
        root = nil
        setStatus(.notConnected)
    }

    private func startWatching(_ url: URL) {
        watcher = makeWatcher(url) { [weak self] in
            Task { await self?.folderChanged() }
        }
    }

    // MARK: Scanning

    /// Rescans from scratch, ignoring the cached entries.
    public func reindex() async throws {
        guard index != nil || root != nil else { throw MusicBackendError.notConnected }
        requestScan(full: true)
        await waitForIndexing()
    }

    /// Awaits the in-flight scan and any requested follow-up, including one still in its debounce.
    public func waitForIndexing() async {
        while debounceTask != nil || scanTask != nil {
            if let task = debounceTask {
                await task.value
            } else if let task = scanTask {
                await task.value
            }
        }
    }

    private func folderChanged() {
        guard root != nil else { return }
        debounceTask?.cancel()
        debounceGeneration += 1
        let generation = debounceGeneration
        let delay = rescanDelay
        debounceTask = Task {
            try? await Task.sleep(for: delay)
            self.debounceFired(generation)
        }
    }

    private func debounceFired(_ generation: Int) {
        guard generation == debounceGeneration else { return }
        debounceTask = nil
        requestScan(full: false)
    }

    private func requestScan(full: Bool) {
        guard root != nil else { return }
        if scanTask != nil {
            rescanRequested = true
            fullRequested = fullRequested || full
            return
        }
        let token = scanToken
        scanTask = Task { await self.scanLoop(full: full, token: token) }
    }

    private func scanLoop(full: Bool, token: UUID) async {
        var full = full
        repeat {
            rescanRequested = false
            await performScan(full: full, token: token)
            full = fullRequested
            fullRequested = false
        } while rescanRequested && !Task.isCancelled && token == scanToken
        if token == scanToken { scanTask = nil }
    }

    private func performScan(full: Bool, token: UUID) async {
        guard let root, token == scanToken else { return }
        setStatus(.indexing(previous: index?.summary))
        do {
            let fresh = try await indexer.build(root: root, previous: full ? nil : index)
            guard token == scanToken, self.root == root else { return }
            // Rewrite the cache only when something changed (or it is missing). Without IgnoreSelf, a cache
            // write inside a watched root (a music folder that contains ~/Library/Caches) would otherwise
            // trigger another scan, and another write, forever.
            let changed = index.map { !$0.hasSameContent(as: fresh) } ?? true
            index = fresh
            lookup = Lookup(fresh)
            if changed || !FolderIndexCache.exists(for: root, in: cacheDirectory) {
                do {
                    try await Self.saveCache(fresh, in: cacheDirectory)
                } catch {
                    log.warning("could not save the index: \(error.localizedDescription, privacy: .public)")
                }
            }
            guard token == scanToken else { return }
            setStatus(.ready(fresh.summary))
        } catch is CancellationError {
            return
        } catch {
            guard token == scanToken else { return }
            let message = (error as? MusicBackendError)?.errorDescription ?? error.localizedDescription
            log.error("scan failed: \(message, privacy: .public)")
            setStatus(.failed(message))
        }
    }

    private static func loadCache(for root: URL, in directory: URL) async -> FolderIndex? {
        FolderIndexCache.load(for: root, in: directory)
    }

    private static func saveCache(_ index: FolderIndex, in directory: URL) async throws {
        try FolderIndexCache.save(index, in: directory)
    }

    // MARK: Library

    private func current() throws -> FolderIndex {
        guard let index else { throw MusicBackendError.notConnected }
        return index
    }

    private static func slice<Item>(_ items: [Item], _ page: PageRequest) -> [Item] {
        let start = max(0, page.offset)
        guard start < items.count else { return [] }
        return Array(items[start..<min(items.count, start + max(0, page.limit))])
    }

    public func artists(page: PageRequest) async throws -> Page<LibraryArtist> {
        let index = try current()
        log.debug("artists: \(index.artists.count, privacy: .public)")
        return Page.make(items: Self.slice(index.artists, page), request: page, total: index.artists.count)
    }

    public func albums(of artist: MediaID?, page: PageRequest) async throws -> Page<LibraryAlbum> {
        let index = try current()
        guard let artist else {
            return Page.make(items: Self.slice(index.albums, page), request: page, total: index.albums.count)
        }
        guard artist.kind == .artist, let positions = lookup.albumsByArtist[artist] else {
            throw MusicBackendError.notFound(artist)
        }
        let albums = positions.map { index.albums[$0] }
        return Page.make(items: Self.slice(albums, page), request: page, total: albums.count)
    }

    public func tracks(of album: MediaID) async throws -> [LibraryTrack] {
        let index = try current()
        guard album.kind == .album, let positions = lookup.tracksByAlbum[album] else {
            throw MusicBackendError.notFound(album)
        }
        return positions.map { index.tracks[$0].library }
    }

    public func playlists(page: PageRequest) async throws -> Page<LibraryPlaylist> {
        throw MusicBackendError.unsupported(.playlists)
    }

    public func tracks(ofPlaylist playlist: MediaID) async throws -> [LibraryTrack] {
        throw MusicBackendError.unsupported(.playlists)
    }

    public func search(_ query: String, limit: Int) async throws -> SearchResults {
        let index = try current()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .empty }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        func matches(_ value: String) -> Bool { value.range(of: text, options: options) != nil }
        let count = max(0, limit)
        return SearchResults(
            artists: Array(index.artists.lazy.filter { matches($0.name) }.prefix(count)),
            albums: Array(index.albums.lazy.filter { matches($0.title) }.prefix(count)),
            tracks: Array(index.tracks.lazy.map(\.library).filter { matches($0.title) }.prefix(count)))
    }

    public func artwork(_ ref: ArtworkRef, maxPixels: Int) async throws -> Data {
        guard let root else { throw MusicBackendError.notConnected }
        return try await FolderArtwork.data(for: ref, root: root, maxPixels: maxPixels)
    }

    // MARK: Playback

    public func outputs() async throws -> [OutputDevice] {
        [LocalPlayerOutput.device]
    }

    public func play(_ items: [MediaID], on output: OutputDevice.ID, mode: PlayMode) async throws {
        guard output == OutputDevice.thisMacID else { throw MusicBackendError.unknownOutput(output) }
        let index = try current()
        guard let root else { throw MusicBackendError.notConnected }
        var positions: [Int] = []
        for item in items {
            switch item.kind {
            case .track:
                guard let position = lookup.trackIndex[item] else { throw MusicBackendError.notFound(item) }
                positions.append(position)
            case .album:
                guard let tracks = lookup.tracksByAlbum[item] else { throw MusicBackendError.notFound(item) }
                positions.append(contentsOf: tracks)
            case .artist:
                guard let albums = lookup.albumsByArtist[item] else { throw MusicBackendError.notFound(item) }
                for album in albums { positions.append(contentsOf: lookup.tracksByAlbum[index.albums[album].id] ?? []) }
            case .playlist, .radio:
                throw MusicBackendError.unsupported(.playlists)
            }
        }
        var queue: [LocalQueueItem] = []
        for position in positions {
            let entry = index.tracks[position]
            guard FileManager.default.fileExists(atPath: entry.url(root: root).path) else {
                log.info("skipped a track that is no longer on disk")
                continue
            }
            queue.append(LocalQueueItem(track: entry.audioTrack(root: root), id: entry.library.id))
        }
        guard !queue.isEmpty else {
            throw MusicBackendError.backend("None of these tracks is on disk any more.")
        }
        await self.output.play(queue, mode: mode)
    }

    public func transport(_ command: TransportCommand, on output: OutputDevice.ID) async throws {
        guard output == OutputDevice.thisMacID else { throw MusicBackendError.unknownOutput(output) }
        await self.output.perform(command)
    }

    public func nowPlaying(on output: OutputDevice.ID) async -> AsyncStream<NowPlaying> {
        guard output == OutputDevice.thisMacID else {
            return AsyncStream { $0.finish() }
        }
        return await self.output.nowPlaying()
    }

    // MARK: Lookup

    /// Positions into the index arrays, so a call is a dictionary read.
    private struct Lookup {
        var albumsByArtist: [MediaID: [Int]] = [:]
        var tracksByAlbum: [MediaID: [Int]] = [:]
        var trackIndex: [MediaID: Int] = [:]

        init(_ index: FolderIndex) {
            for artist in index.artists { albumsByArtist[artist.id] = [] }
            for (position, album) in index.albums.enumerated() {
                tracksByAlbum[album.id] = []
                if let artist = album.artistID { albumsByArtist[artist, default: []].append(position) }
            }
            for (position, track) in index.tracks.enumerated() {
                trackIndex[track.library.id] = trackIndex[track.library.id] ?? position
                if let album = track.library.albumID { tracksByAlbum[album, default: []].append(position) }
            }
        }
    }
}
