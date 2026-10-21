import Foundation
import MusicBackendKit

/// An in-memory `MusicBackend` for tests: records every call, answers from `library`, can fail a method
/// on demand, and can hold a method's calls in flight (a gate) so a test can observe a loading state.
public actor StubMusicBackend: MusicBackend {
    public enum Method: Hashable, Sendable, CaseIterable {
        case connect, artists, albums, tracks, playlists, playlistTracks, search, artwork, outputs, play, transport, transfer, setGroupMembers
        case setFavorite, favoriteCurrentTrack
        case createPlaylist, renamePlaylist, deletePlaylist
    }

    public enum Call: Hashable, Sendable {
        case connect, disconnect
        case artists(PageRequest), albums(MediaID?, PageRequest), tracks(MediaID), playlists(PageRequest)
        case playlistTracks(MediaID)
        case search(String, Int), artwork(ArtworkRef, Int), outputs
        case play([MediaID], OutputDevice.ID, PlayMode), transport(TransportCommand, OutputDevice.ID)
        case transfer(OutputDevice.ID, OutputDevice.ID, autoPlay: Bool)
        case setGroupMembers(OutputDevice.ID, [OutputDevice.ID], [OutputDevice.ID])
        case setFavorite(MediaID, Bool), favoriteCurrentTrack(OutputDevice.ID)
        case createPlaylist(String), renamePlaylist(MediaID, String), deletePlaylist(MediaID)

        /// The method a call belongs to; `disconnect` has none.
        public var method: Method? {
            switch self {
            case .connect: .connect
            case .disconnect: nil
            case .artists: .artists
            case .albums: .albums
            case .tracks: .tracks
            case .playlists: .playlists
            case .playlistTracks: .playlistTracks
            case .search: .search
            case .artwork: .artwork
            case .outputs: .outputs
            case .play: .play
            case .transport: .transport
            case .transfer: .transfer
            case .setGroupMembers: .setGroupMembers
            case .setFavorite: .setFavorite
            case .favoriteCurrentTrack: .favoriteCurrentTrack
            case .createPlaylist: .createPlaylist
            case .renamePlaylist: .renamePlaylist
            case .deletePlaylist: .deletePlaylist
            }
        }
    }

    public nonisolated let sourceID: String
    public nonisolated let displayName: String
    public nonisolated let capabilities: BackendCapabilities

    public var library: StubLibrary
    public private(set) var isConnected = false
    public private(set) var calls: [Call] = []
    /// Currently suspended calls.
    public private(set) var suspendedCount = 0
    /// Suspended calls that were cancelled.
    public private(set) var cancelledCount = 0
    public var artworkBytes: [ArtworkRef: Data] = [:]
    /// What `outputs()` lists.
    public var outputDevices: [OutputDevice] = [OutputDevice.thisMac]

    private let reportsTotals: Bool
    private var errors: [Method: MusicBackendError] = [:]
    private var gated: Set<Method> = []
    private var waiting: [UUID: (method: Method, continuation: CheckedContinuation<Void, any Error>)] = [:]
    private var streams: [UUID: AsyncStream<NowPlaying>.Continuation] = [:]
    private var latest: NowPlaying?
    private var createdPlaylists = 0

    public init(
        library: StubLibrary = .sample(),
        capabilities: BackendCapabilities = [.search, .artwork, .localOutput],
        reportsTotals: Bool = true,
        sourceID: String = "stub",
        displayName: String = "Stub"
    ) {
        self.sourceID = sourceID
        self.displayName = displayName
        self.library = library
        self.capabilities = capabilities
        self.reportsTotals = reportsTotals
    }

    // MARK: Test controls

    public func calls(_ method: Method) -> [Call] { calls.filter { $0.method == method } }
    public func count(_ method: Method) -> Int { calls(method).count }

    /// Thrown by every later call of `method` until cleared with nil.
    public func setError(_ error: MusicBackendError?, for method: Method) { errors[method] = error }

    /// Later calls of `method` suspend until `release` or `fail`; a cancelled suspended call throws `CancellationError`.
    public func gate(_ method: Method) { gated.insert(method) }

    /// Removes the gate and resumes every suspended call of `method`.
    public func release(_ method: Method) {
        gated.remove(method)
        for (id, entry) in waiting where entry.method == method {
            waiting[id] = nil
            suspendedCount -= 1
            entry.continuation.resume()
        }
    }

    /// Removes the gate and resumes every suspended call of `method` by throwing `error`.
    public func fail(_ method: Method, with error: any Error) {
        gated.remove(method)
        for (id, entry) in waiting where entry.method == method {
            waiting[id] = nil
            suspendedCount -= 1
            entry.continuation.resume(throwing: error)
        }
    }

    public func setLibrary(_ library: StubLibrary) { self.library = library }
    public func setArtwork(_ data: Data, for ref: ArtworkRef) { artworkBytes[ref] = data }
    public func setOutputs(_ devices: [OutputDevice]) { outputDevices = devices }

    /// Feeds every live `nowPlaying` stream.
    public func emit(_ snapshot: NowPlaying) {
        latest = snapshot
        for continuation in streams.values { continuation.yield(snapshot) }
    }

    // MARK: Entry gate

    /// Records the call, then applies the injected error and the gate.
    private func enter(_ call: Call) async throws {
        calls.append(call)
        guard let method = call.method else { return }
        if let error = errors[method] { throw error }
        guard gated.contains(method) else { return }
        if Task.isCancelled {
            cancelledCount += 1
            throw CancellationError()
        }
        let id = UUID()
        suspendedCount += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                waiting[id] = (method, continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let entry = waiting.removeValue(forKey: id) else { return }
        suspendedCount -= 1
        cancelledCount += 1
        entry.continuation.resume(throwing: CancellationError())
    }

    private func page<Item: Hashable & Sendable>(_ items: [Item], _ request: PageRequest) -> Page<Item> {
        let start = min(max(0, request.offset), items.count)
        let end = min(items.count, start + max(0, request.limit))
        return Page.make(items: Array(items[start..<end]), request: request, total: reportsTotals ? items.count : nil)
    }

    // MARK: MusicBackend

    public func connect() async throws {
        try await enter(.connect)
        isConnected = true
    }

    public func disconnect() async {
        calls.append(.disconnect)
        isConnected = false
    }

    public func artists(page request: PageRequest) async throws -> Page<LibraryArtist> {
        try await enter(.artists(request))
        return page(library.artists, request)
    }

    public func albums(of artist: MediaID?, page request: PageRequest) async throws -> Page<LibraryAlbum> {
        try await enter(.albums(artist, request))
        if let artist, artist.kind != .artist { throw MusicBackendError.notFound(artist) }
        return page(library.albums(of: artist), request)
    }

    public func tracks(of album: MediaID) async throws -> [LibraryTrack] {
        try await enter(.tracks(album))
        guard library.albums.contains(where: { $0.id == album }) else { throw MusicBackendError.notFound(album) }
        return library.tracks(of: album)
    }

    public func playlists(page request: PageRequest) async throws -> Page<LibraryPlaylist> {
        try await enter(.playlists(request))
        guard capabilities.contains(.playlists) else { throw MusicBackendError.unsupported(.playlists) }
        return page(library.playlists, request)
    }

    public func tracks(ofPlaylist playlist: MediaID) async throws -> [LibraryTrack] {
        try await enter(.playlistTracks(playlist))
        guard capabilities.contains(.playlists) else { throw MusicBackendError.unsupported(.playlists) }
        guard let ids = library.playlistTracks[playlist] else { throw MusicBackendError.notFound(playlist) }
        return ids.compactMap { id in library.tracks.first { $0.id == id } }
    }

    public func search(_ query: String, limit: Int) async throws -> SearchResults {
        try await enter(.search(query, limit))
        return library.search(query, limit: limit)
    }

    public func artwork(_ ref: ArtworkRef, maxPixels: Int) async throws -> Data {
        try await enter(.artwork(ref, maxPixels))
        guard let data = artworkBytes[ref] else { throw MusicBackendError.backend("No artwork.") }
        return data
    }

    public func outputs() async throws -> [OutputDevice] {
        try await enter(.outputs)
        return outputDevices
    }

    public func play(_ items: [MediaID], on output: OutputDevice.ID, mode: PlayMode) async throws {
        try await enter(.play(items, output, mode))
    }

    public func transport(_ command: TransportCommand, on output: OutputDevice.ID) async throws {
        try await enter(.transport(command, output))
    }

    public func transfer(from source: OutputDevice.ID, to target: OutputDevice.ID, autoPlay: Bool) async throws {
        try await enter(.transfer(source, target, autoPlay: autoPlay))
    }

    public func setGroupMembers(
        of leader: OutputDevice.ID, adding: [OutputDevice.ID], removing: [OutputDevice.ID]
    ) async throws {
        try await enter(.setGroupMembers(leader, adding, removing))
    }

    public func setFavorite(_ id: MediaID, _ on: Bool) async throws {
        try await enter(.setFavorite(id, on))
    }

    public func favoriteCurrentTrack(on output: OutputDevice.ID) async throws {
        try await enter(.favoriteCurrentTrack(output))
    }

    /// Favorites listing (#0142): the library's items whose `isFavorite` is true. Not recorded as calls.
    public func favoriteCount(_ kind: MediaKind) async throws -> Int? {
        guard capabilities.contains(.favorites) else { throw MusicBackendError.unsupported(.favorites) }
        switch kind {
        case .track: return library.tracks.filter { $0.isFavorite == true }.count
        case .album: return library.albums.filter { $0.isFavorite == true }.count
        case .artist: return library.artists.filter { $0.isFavorite == true }.count
        case .playlist: return library.playlists.filter { $0.isFavorite == true }.count
        case .radio: return 0
        }
    }

    public func favoriteTracks(page request: PageRequest) async throws -> Page<LibraryTrack> {
        guard capabilities.contains(.favorites) else { throw MusicBackendError.unsupported(.favorites) }
        return page(library.tracks.filter { $0.isFavorite == true }, request)
    }

    public func favoriteAlbums(page request: PageRequest) async throws -> Page<LibraryAlbum> {
        guard capabilities.contains(.favorites) else { throw MusicBackendError.unsupported(.favorites) }
        return page(library.albums.filter { $0.isFavorite == true }, request)
    }

    public func favoriteArtists(page request: PageRequest) async throws -> Page<LibraryArtist> {
        guard capabilities.contains(.favorites) else { throw MusicBackendError.unsupported(.favorites) }
        return page(library.artists.filter { $0.isFavorite == true }, request)
    }

    public func favoritePlaylists(page request: PageRequest) async throws -> Page<LibraryPlaylist> {
        guard capabilities.contains(.favorites) else { throw MusicBackendError.unsupported(.favorites) }
        return page(library.playlists.filter { $0.isFavorite == true }, request)
    }

    public func nowPlaying(on output: OutputDevice.ID) async -> AsyncStream<NowPlaying> {
        let (stream, continuation) = AsyncStream<NowPlaying>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        streams[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStream(id) }
        }
        continuation.yield(latest ?? .idle(on: output))
        return stream
    }

    private func removeStream(_ id: UUID) { streams[id] = nil }

    // MARK: Library changes (#0139)

    private var changeStreams: [UUID: AsyncStream<LibraryChange>.Continuation] = [:]

    /// Live `libraryChanges()` subscribers.
    public var changeSubscriberCount: Int { changeStreams.count }

    /// Feeds every live `libraryChanges()` stream, as a change made elsewhere would.
    public func pushChange(_ change: LibraryChange) {
        for continuation in changeStreams.values { continuation.yield(change) }
    }

    public func libraryChanges() async -> AsyncStream<LibraryChange> {
        let (stream, continuation) = AsyncStream<LibraryChange>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let id = UUID()
        changeStreams[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeChangeStream(id) }
        }
        return stream
    }

    private func removeChangeStream(_ id: UUID) { changeStreams[id] = nil }
    // MARK: Playlist editing (#0135)

    public func createPlaylist(named name: String) async throws -> LibraryPlaylist {
        try await enter(.createPlaylist(name))
        createdPlaylists += 1
        let playlist = LibraryPlaylist(
            id: MediaID(.playlist, "new\(createdPlaylists)"), name: name, isEditable: true, owner: "you",
            source: .user, editing: [.addRemove, .rename, .delete], libraryID: "new\(createdPlaylists)")
        library.playlists.append(playlist)
        library.playlistTracks[playlist.id] = []
        return playlist
    }

    public func renamePlaylist(_ id: MediaID, to name: String) async throws {
        try await enter(.renamePlaylist(id, name))
        guard let index = library.playlists.firstIndex(where: { $0.id == id }) else { throw MusicBackendError.notFound(id) }
        library.playlists[index].name = name
    }

    public func deletePlaylist(_ id: MediaID) async throws {
        try await enter(.deletePlaylist(id))
        guard let index = library.playlists.firstIndex(where: { $0.id == id }) else { throw MusicBackendError.notFound(id) }
        library.playlists.remove(at: index)
        library.playlistTracks[id] = nil
    }
}
