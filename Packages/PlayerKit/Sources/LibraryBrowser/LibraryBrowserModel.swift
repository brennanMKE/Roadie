import Foundation
import MusicBackendKit
import Observation
import os

public enum LibrarySection: String, Hashable, Sendable, CaseIterable, Identifiable {
    case artists, albums, playlists
    /// A Discover row (#0143); which one is `discover.selectedRowID`. Not in `sections`: the sidebar lists the rows.
    case discover
    public var id: Self { self }
}

/// State behind the Library window. Talks only to `MusicBackend`; the views draw what it publishes.
@MainActor @Observable
public final class LibraryBrowserModel {
    public enum Connection: Hashable, Sendable {
        case idle, connecting, connected
        /// `needsSettings` is true for `.notConfigured`.
        case failed(message: String, needsSettings: Bool)
    }

    public enum LoadState<Value: Hashable & Sendable>: Hashable, Sendable {
        case idle, loading, loaded(Value), failed(String)
    }

    public enum SearchPhase: Hashable, Sendable {
        case idle, searching, loaded(SearchResults), failed(String)
    }

    /// Where a reported failure happened: the connect, or a later list, track or search load.
    public enum FailurePhase: Hashable, Sendable { case connect, browse }

    public let backend: any MusicBackend
    /// Every `MusicBackendError` a connect, page, track or search load throws, as it happens. For the fallback (#0067).
    /// `.notConnected` (a stale task after a switch), `.notFound` and `.unsupported` are not reachability and are not reported.
    @ObservationIgnored public var onBackendFailure: (@MainActor (MusicBackendError, FailurePhase) -> Void)?
    public private(set) var connection: Connection = .idle
    /// `.playlists` only when the backend has the capability.
    public let sections: [LibrarySection]
    public var section: LibrarySection = .artists {
        didSet {
            guard section != oldValue else { return }
            clearSelection()
            loadSectionIfNeeded()
        }
    }

    public let artists: PagedList<LibraryArtist>
    public let allAlbums: PagedList<LibraryAlbum>
    public let playlists: PagedList<LibraryPlaylist>
    /// Discover rows (#0143); nil without `.recommendations`.
    public let discover: DiscoverModel?
    /// Albums of `selectedArtist`.
    public let artistAlbums: PagedList<LibraryAlbum>
    /// Hearts and their optimistic state (#0141).
    public let favorites: FavoritesModel
    /// Of `selectedAlbum` or `selectedPlaylist`.
    public private(set) var tracks: LoadState<[LibraryTrack]> = .idle

    /// The artist group the user picked (several spellings of one artist), when one was.
    public private(set) var selectedArtistGroup: ArtistGroup?

    /// The picked artist, or the first member of the picked group.
    public var selectedArtist: LibraryArtist? {
        didSet {
            guard selectedArtist != oldValue else { return }
            if let artist = selectedArtist {
                if selectedArtistGroup?.members.contains(where: { $0.id == artist.id }) != true {
                    selectedArtistGroup = nil
                }
            } else {
                selectedArtistGroup = nil
            }
            loadArtistAlbums()
            selectedAlbum = nil
        }
    }

    public var selectedAlbum: LibraryAlbum? {
        didSet {
            guard selectedAlbum != oldValue else { return }
            if let album = selectedAlbum {
                let backend = backend
                let id = album.id
                loadTracks { try await backend.tracks(of: id) }
            } else if selectedPlaylist == nil {
                dropTracks()
            }
        }
    }

    public var selectedPlaylist: LibraryPlaylist? {
        didSet {
            guard selectedPlaylist != oldValue else { return }
            if let playlist = selectedPlaylist {
                let backend = backend
                let id = playlist.id
                loadTracks { try await backend.tracks(ofPlaylist: id) }
            } else if selectedAlbum == nil {
                dropTracks()
            }
        }
    }

    /// Rows the artists column draws: loaded artists grouped by `ArtistName.key`, in first-seen order.
    /// Every group's members are ids in `artists.items`, which is how paging finds the row.
    public var artistRows: [ArtistGroup] {
        syncGrouper()
        return grouper.groups
    }

    public var searchText: String = "" {
        didSet { if searchText != oldValue { scheduleSearch(immediate: false) } }
    }

    public private(set) var search: SearchPhase = .idle
    public var isSearching: Bool { !trimmedQuery.isEmpty }
    public let searchDelay: Duration
    public let searchLimit: Int

    @ObservationIgnored private var grouper = ArtistGrouper()
    @ObservationIgnored private var groupedCount = 0
    @ObservationIgnored private var lastGroupedID: MediaID?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var connectGeneration = 0
    @ObservationIgnored private var tracksTask: Task<Void, Never>?
    @ObservationIgnored private var tracksGeneration = 0
    @ObservationIgnored private var trackLoader: (@Sendable () async throws -> [LibraryTrack])?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration = 0
    /// Follows `backend.libraryChanges()` while connected and shown (#0139).
    @ObservationIgnored private var changesTask: Task<Void, Never>?
    /// Every library change after the model's own handling: the seam for `PlaylistsModel`, `PlaylistEditor`,
    /// and `FavoritesModel.apply(_:)` until they are owned here (#0139).
    @ObservationIgnored public var onLibraryChange: (@MainActor (LibraryChange) -> Void)?
    private static let log = Logger(subsystem: "com.brennanmke.SkinAmp", category: "LibraryBrowser")

    public init(
        backend: any MusicBackend, pageSize: Int = 100,
        searchDelay: Duration = .milliseconds(300), searchLimit: Int = 50
    ) {
        self.backend = backend
        self.searchDelay = searchDelay
        self.searchLimit = searchLimit
        sections = backend.capabilities.contains(.playlists) ? [.artists, .albums, .playlists] : [.artists, .albums]
        artists = PagedList(pageSize: pageSize)
        allAlbums = PagedList(pageSize: pageSize)
        playlists = PagedList(pageSize: pageSize)
        artistAlbums = PagedList(pageSize: pageSize)
        discover = backend.capabilities.contains(.recommendations) ? DiscoverModel(backend: backend) : nil
        favorites = FavoritesModel(backend: backend)
        artists.onFailure = { [weak self] in self?.reportFailure($0, .browse) }
        allAlbums.onFailure = { [weak self] in self?.reportFailure($0, .browse) }
        playlists.onFailure = { [weak self] in self?.reportFailure($0, .browse) }
        artistAlbums.onFailure = { [weak self] in self?.reportFailure($0, .browse) }
        favorites.onConfirmed = { [weak self] id, on in self?.patchFavorite(id, on) }
    }

    private func reportFailure(_ error: any Error, _ phase: FailurePhase) {
        guard let error = error as? MusicBackendError else { return }
        switch error {
        case .notConnected, .notFound, .unsupported: return
        default: onBackendFailure?(error, phase)
        }
    }

    private var trimmedQuery: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Lifecycle

    /// Connects unless already connected or connecting, then loads the current section if it is still idle.
    public func appeared() {
        switch connection {
        case .connected:
            startChanges()
            resumeSelection()
        case .connecting: break
        case .idle, .failed: startConnect()
        }
    }

    /// Cancels in-flight loads and the pending search; items and the selection stay.
    public func disappeared() {
        connectGeneration += 1
        connectTask?.cancel()
        connectTask = nil
        if connection == .connecting { connection = .idle }
        stopChanges()
        artists.cancel()
        allAlbums.cancel()
        playlists.cancel()
        artistAlbums.cancel()
        discover?.cancel()
        tracksGeneration += 1
        tracksTask?.cancel()
        tracksTask = nil
        if tracks == .loading { tracks = .idle }
        searchGeneration += 1
        searchTask?.cancel()
        searchTask = nil
        if search == .searching { search = .idle }
    }

    public func retryConnection() { startConnect() }

    /// Reloads the current section's list and the selection's children.
    public func refresh() {
        guard connection == .connected else { return }
        loadSection(reloading: true)
        if selectedArtist != nil { artistAlbums.reload() }
        retryTracks()
    }

    /// Shows a Discover row's items and loads them if needed.
    public func select(discoverRow id: RecommendationRow.ID) {
        guard let discover else { return }
        discover.selectedRowID = id
        if section != .discover { section = .discover } else { loadSectionIfNeeded() }
    }

    public func retryTracks() {
        if let trackLoader { loadTracks(trackLoader) }
    }

    // MARK: Search

    /// Return in the field: skips the delay.
    public func searchNow() { scheduleSearch(immediate: true) }

    public func clearSearch() { searchText = "" }

    // MARK: Selection

    public func select(_ artist: LibraryArtist) {
        select(group(containing: artist.id) ?? ArtistGrouper.group([artist])[0])
    }

    /// Picks an artist group; albums load from every member.
    public func select(_ group: ArtistGroup) {
        if section != .artists { section = .artists }
        applyGroup(group)
    }

    public func select(_ album: LibraryAlbum) {
        if section == .playlists { section = .albums }
        if let artistID = album.artistID, selectedArtist?.id != artistID,
           selectedArtistGroup?.members.contains(where: { $0.id == artistID }) != true {
            if let known = group(containing: artistID) {
                applyGroup(known)
            } else if section == .artists {
                applyGroup(ArtistGrouper.group([LibraryArtist(id: artistID, name: album.artistName ?? "")])[0])
            } else {
                selectedArtist = nil
            }
        }
        selectedAlbum = album
    }

    public func select(_ playlist: LibraryPlaylist) {
        if section != .playlists { section = .playlists }
        selectedPlaylist = playlist
    }

    // MARK: Library changes (#0139)

    private func startChanges() {
        guard changesTask == nil else { return }
        let backend = backend
        changesTask = Task { [weak self] in
            for await change in await backend.libraryChanges() {
                guard !Task.isCancelled else { return }
                self?.apply(change)
            }
        }
    }

    private func stopChanges() {
        changesTask?.cancel()
        changesTask = nil
    }

    /// Every change is a refetch hint (design §3.4). Favorites and Discover go to `onLibraryChange` only.
    public func apply(_ change: LibraryChange) {
        switch change {
        case .playlistAdded, .playlistDeleted:
            if case .playlistDeleted(let id) = change, selectedPlaylist?.id == id { selectedPlaylist = nil }
            if playlists.phase != .idle { playlists.reload() }
        case .playlistUpdated(let id):
            // Stand-in for `PlaylistEditor.reloadIfOpen(id)` until it lands.
            if selectedPlaylist?.id == id { retryTracks() }
            if playlists.phase != .idle { playlists.reload() }
        case .played:
            discover?.scheduleRefresh()
        case .favoriteChanged:
            break
        }
        onLibraryChange?(change)
    }

    // MARK: Connection

    private func startConnect() {
        connectTask?.cancel()
        connectGeneration += 1
        let generation = connectGeneration
        connection = .connecting
        let backend = backend
        connectTask = Task { [weak self] in
            do {
                try await backend.connect()
                self?.connectFinished(.connected, generation: generation)
            } catch is CancellationError {
                self?.connectFinished(.idle, generation: generation)
            } catch {
                var needsSettings = false
                if let backendError = error as? MusicBackendError, case .notConfigured = backendError { needsSettings = true }
                self?.reportFailure(error, .connect)
                self?.connectFinished(
                    .failed(message: userMessage(for: error), needsSettings: needsSettings), generation: generation)
            }
        }
    }

    private func connectFinished(_ result: Connection, generation: Int) {
        guard generation == connectGeneration else { return }
        connection = result
        switch result {
        case .connected:
            Self.log.info("connected")
            startChanges()
            resumeSelection()
            if isSearching { scheduleSearch(immediate: true) }
        case .failed(_, let needsSettings):
            Self.log.info("connect failed, needsSettings \(needsSettings, privacy: .public)")
        case .idle, .connecting:
            break
        }
    }

    // MARK: Lists

    /// Loads the current section if idle, and whatever the selection needs after a cancel.
    private func resumeSelection() {
        discover?.loadRowsIfNeeded()
        loadSectionIfNeeded()
        if selectedArtist != nil, artistAlbums.phase == .idle { artistAlbums.reload() }
        if tracks == .idle { retryTracks() }
    }

    private func loadSectionIfNeeded() {
        guard connection == .connected else { return }
        loadSection(reloading: false)
    }

    private func loadSection(reloading: Bool) {
        let backend = backend
        switch section {
        case .artists:
            if reloading || artists.phase == .idle {
                artists.reload(with: { try await backend.artists(page: $0) })
            }
        case .albums:
            if reloading || allAlbums.phase == .idle {
                allAlbums.reload(with: { try await backend.albums(of: nil, page: $0) })
            }
        case .playlists:
            if reloading || playlists.phase == .idle {
                playlists.reload(with: { try await backend.playlists(page: $0) })
            }
        case .discover:
            guard let discover else { return }
            discover.loadRowsIfNeeded()
            if let id = discover.selectedRowID, let row = discover.row(id: id) {
                if reloading { discover.refresh(row) } else { discover.loadItemsIfNeeded(row) }
            }
        }
    }

    /// Makes `group` the selected artist without touching the section.
    private func applyGroup(_ group: ArtistGroup) {
        let previous = selectedArtist
        let oldIDs = selectedArtistGroup?.memberIDs ?? previous.map { [$0.id] } ?? []
        selectedArtistGroup = group
        if previous == group.members[0] {
            // `selectedArtist` will not change, so its observer will not run.
            if oldIDs != group.memberIDs {
                loadArtistAlbums()
                selectedAlbum = nil
            }
        } else {
            selectedArtist = group.members[0]
        }
    }

    /// Albums of the selected artist: one paged list, or every member's albums when the group has several spellings.
    private func loadArtistAlbums() {
        guard let artist = selectedArtist else {
            artistAlbums.reset()
            return
        }
        let backend = backend
        if let group = selectedArtistGroup, group.isMerged {
            artistAlbums.reload(with: { _ in Page.last(try await backend.albums(of: group)) })
        } else {
            let id = artist.id
            artistAlbums.reload(with: { try await backend.albums(of: id, page: $0) })
        }
    }

    private func group(containing id: MediaID) -> ArtistGroup? {
        syncGrouper()
        return grouper.group(containing: id)
    }

    /// Feeds artists loaded since the last call to the grouper; starts over when the list was reset or reloaded.
    private func syncGrouper() {
        let items = artists.items
        if groupedCount > items.count || (groupedCount > 0 && items[groupedCount - 1].id != lastGroupedID) {
            grouper.removeAll()
            groupedCount = 0
        }
        if groupedCount < items.count {
            grouper.add(Array(items[groupedCount...]))
            groupedCount = items.count
            lastGroupedID = items.last?.id
        }
    }

    private func clearSelection() {
        selectedPlaylist = nil
        selectedArtist = nil
        selectedAlbum = nil
    }

    // MARK: Tracks

    private func loadTracks(_ load: @escaping @Sendable () async throws -> [LibraryTrack]) {
        trackLoader = load
        tracksTask?.cancel()
        tracksGeneration += 1
        let generation = tracksGeneration
        tracks = .loading
        tracksTask = Task { [weak self] in
            do {
                let result = try await load()
                self?.tracksFinished(.loaded(result), generation: generation)
            } catch is CancellationError {
                return
            } catch {
                self?.reportFailure(error, .browse)
                self?.tracksFinished(.failed(userMessage(for: error)), generation: generation)
            }
        }
    }

    private func tracksFinished(_ state: LoadState<[LibraryTrack]>, generation: Int) {
        guard generation == tracksGeneration else { return }
        tracks = state
    }

    private func dropTracks() {
        tracksTask?.cancel()
        tracksTask = nil
        tracksGeneration += 1
        trackLoader = nil
        tracks = .idle
    }

    // MARK: Search

    private func scheduleSearch(immediate: Bool) {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration += 1
        let query = trimmedQuery
        guard !query.isEmpty else {
            search = .idle
            return
        }
        let generation = searchGeneration
        let delay = searchDelay
        let limit = searchLimit
        let backend = backend
        searchTask = Task { [weak self] in
            do {
                if !immediate { try await Task.sleep(for: delay) }
                guard let self, self.beginSearch(generation: generation) else { return }
                let results = try await backend.search(query, limit: limit)
                self.searchFinished(.loaded(results), generation: generation)
            } catch is CancellationError {
                return
            } catch {
                self?.reportFailure(error, .browse)
                self?.searchFinished(.failed(userMessage(for: error)), generation: generation)
            }
        }
    }

    private func beginSearch(generation: Int) -> Bool {
        guard generation == searchGeneration else { return false }
        search = .searching
        Self.log.debug("search, \(self.trimmedQuery.count, privacy: .public) characters")
        return true
    }

    private func searchFinished(_ state: SearchPhase, generation: Int) {
        guard generation == searchGeneration else { return }
        search = state
    }
}
