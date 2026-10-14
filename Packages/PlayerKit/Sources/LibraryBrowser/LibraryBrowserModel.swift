import Foundation
import MusicBackendKit
import Observation
import os

public enum LibrarySection: String, Hashable, Sendable, CaseIterable, Identifiable {
    case artists, albums, playlists
    public var id: String { rawValue }
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

    public let backend: any MusicBackend
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
    /// Albums of `selectedArtist`.
    public let artistAlbums: PagedList<LibraryAlbum>
    /// Of `selectedAlbum` or `selectedPlaylist`.
    public private(set) var tracks: LoadState<[LibraryTrack]> = .idle

    public var selectedArtist: LibraryArtist? {
        didSet {
            guard selectedArtist != oldValue else { return }
            if let artist = selectedArtist {
                let backend = backend
                let id = artist.id
                artistAlbums.reload(with: { try await backend.albums(of: id, page: $0) })
            } else {
                artistAlbums.reset()
            }
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

    /// Rows the artists column draws. #0017 replaces the identity mapping with its grouping.
    public var artistRows: [LibraryArtist] { artists.items }

    public var searchText: String = "" {
        didSet { if searchText != oldValue { scheduleSearch(immediate: false) } }
    }

    public private(set) var search: SearchPhase = .idle
    public var isSearching: Bool { !trimmedQuery.isEmpty }
    public let searchDelay: Duration
    public let searchLimit: Int

    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var connectGeneration = 0
    @ObservationIgnored private var tracksTask: Task<Void, Never>?
    @ObservationIgnored private var tracksGeneration = 0
    @ObservationIgnored private var trackLoader: (@Sendable () async throws -> [LibraryTrack])?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration = 0
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
    }

    private var trimmedQuery: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Lifecycle

    /// Connects unless already connected or connecting, then loads the current section if it is still idle.
    public func appeared() {
        switch connection {
        case .connected: resumeSelection()
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
        artists.cancel()
        allAlbums.cancel()
        playlists.cancel()
        artistAlbums.cancel()
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

    public func retryTracks() {
        if let trackLoader { loadTracks(trackLoader) }
    }

    // MARK: Search

    /// Return in the field: skips the delay.
    public func searchNow() { scheduleSearch(immediate: true) }

    public func clearSearch() { searchText = "" }

    // MARK: Selection

    public func select(_ artist: LibraryArtist) {
        if section != .artists { section = .artists }
        selectedArtist = artist
    }

    public func select(_ album: LibraryAlbum) {
        if section == .playlists { section = .albums }
        if let artistID = album.artistID, selectedArtist?.id != artistID {
            if let known = artists.items.first(where: { $0.id == artistID }) {
                selectedArtist = known
            } else if section == .artists {
                selectedArtist = LibraryArtist(id: artistID, name: album.artistName ?? "")
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
