import Foundation
import MusicBackendKit
import Observation

/// The kinds the Favorites section lists (#0142), in sidebar order. Radio joined with W12 (#0147).
public enum FavoriteKind: String, Hashable, Sendable, CaseIterable, Identifiable {
    case tracks, albums, artists, playlists, radios
    public var id: Self { self }

    public var mediaKind: MediaKind {
        switch self {
        case .tracks: .track
        case .albums: .album
        case .artists: .artist
        case .playlists: .playlist
        case .radios: .radio
        }
    }

    public init?(_ kind: MediaKind) {
        switch kind {
        case .track: self = .tracks
        case .album: self = .albums
        case .artist: self = .artists
        case .playlist: self = .playlists
        case .radio: self = .radios
        }
    }
}

/// Favorites in the Library (#0141): an optimistic flip per item, kept in `overrides` until the server answers.
/// A successful command confirms it (until live change events land, #0139, the answer is the refetch-free
/// confirmation): the value moves to `confirmed`, the cached lists are patched, and the override is cleared.
@MainActor @Observable
public final class FavoritesModel {
    public let backend: any MusicBackend
    /// In-flight flips, which the rows show over the item's own `isFavorite`.
    public private(set) var overrides: [MediaID: Bool] = [:]
    /// Values the server confirmed (or reported) this session; outlive the lists they were patched into.
    public private(set) var confirmed: [MediaID: Bool] = [:]
    /// Called with every confirmed value so the owner can patch its cached lists.
    @ObservationIgnored public var onConfirmed: (@MainActor (MediaID, Bool) -> Void)?
    @ObservationIgnored private var generations: [MediaID: Int] = [:]

    // MARK: Favorites section (#0142)

    /// Per kind, from `favoriteCount`; missing until loaded or when the server has no count.
    public private(set) var counts: [FavoriteKind: Int] = [:]
    /// The kind the Favorites detail shows.
    public var selectedKind: FavoriteKind = .tracks {
        didSet { if selectedKind != oldValue { loadListIfNeeded(selectedKind) } }
    }
    public let tracks: PagedList<LibraryTrack>
    public let albums: PagedList<LibraryAlbum>
    public let artists: PagedList<LibraryArtist>
    public let playlists: PagedList<LibraryPlaylist>
    public let radios: PagedList<LibraryRadio>
    @ObservationIgnored private var countsTask: Task<Void, Never>?
    @ObservationIgnored private var countsGeneration = 0

    public init(backend: any MusicBackend, pageSize: Int = 100) {
        self.backend = backend
        tracks = PagedList(pageSize: pageSize)
        albums = PagedList(pageSize: pageSize)
        artists = PagedList(pageSize: pageSize)
        playlists = PagedList(pageSize: pageSize)
        radios = PagedList(pageSize: pageSize)
    }

    /// Loads every kind's count at once; one failing kind leaves the others.
    public func loadCounts() async {
        countsGeneration += 1
        let generation = countsGeneration
        let backend = backend
        let loaded = await withTaskGroup(of: (FavoriteKind, Int?).self) { group in
            for kind in FavoriteKind.allCases {
                group.addTask { (kind, (try? await backend.favoriteCount(kind.mediaKind)) ?? nil) }
            }
            var result: [FavoriteKind: Int] = [:]
            for await (kind, count) in group { if let count { result[kind] = count } }
            return result
        }
        guard generation == countsGeneration else { return }
        counts = loaded
    }

    /// Opening the section: counts and the selected kind's list, once each.
    public func sectionAppeared(reloading: Bool = false) {
        guard isAvailable else { return }
        if reloading || counts.isEmpty, countsTask == nil {
            countsTask = Task { [weak self] in
                await self?.loadCounts()
                self?.countsTask = nil
            }
        }
        if reloading { reloadList(selectedKind) } else { loadListIfNeeded(selectedKind) }
    }

    public func cancelLists() {
        countsTask?.cancel()
        countsTask = nil
        tracks.cancel()
        albums.cancel()
        artists.cancel()
        playlists.cancel()
        radios.cancel()
    }

    private func loadListIfNeeded(_ kind: FavoriteKind) {
        if phase(of: kind) == .idle { reloadList(kind) }
    }

    func phase(of kind: FavoriteKind) -> ListPhase {
        switch kind {
        case .tracks: tracks.phase
        case .albums: albums.phase
        case .artists: artists.phase
        case .playlists: playlists.phase
        case .radios: radios.phase
        }
    }

    private func reloadList(_ kind: FavoriteKind) {
        guard isAvailable else { return }
        let backend = backend
        switch kind {
        case .tracks: tracks.reload(with: { try await backend.favoriteTracks(page: $0) })
        case .albums: albums.reload(with: { try await backend.favoriteAlbums(page: $0) })
        case .artists: artists.reload(with: { try await backend.favoriteArtists(page: $0) })
        case .playlists: playlists.reload(with: { try await backend.favoritePlaylists(page: $0) })
        case .radios: radios.reload(with: { try await backend.favoriteRadios(page: $0) })
        }
    }

    /// A confirmed change: hearts in the lists flip at once; a loaded list of that kind and the counts refetch, so an
    /// unfavorited row leaves the list and a newly favorited one joins it.
    func favoritesChanged(_ id: MediaID, _ on: Bool) {
        switch id.kind {
        case .track: tracks.update(id: id) { $0.isFavorite = on }
        case .album: albums.update(id: id) { $0.isFavorite = on }
        case .artist: artists.update(id: id) { $0.isFavorite = on }
        case .playlist: playlists.update(id: id) { $0.isFavorite = on }
        case .radio: radios.update(id: id) { $0.isFavorite = on }
        }
        guard let kind = FavoriteKind(id.kind) else { return }
        if phase(of: kind) != .idle { reloadList(kind) }
        if !counts.isEmpty, countsTask == nil {
            countsTask = Task { [weak self] in
                await self?.loadCounts()
                self?.countsTask = nil
            }
        }
    }

    public var isAvailable: Bool { backend.capabilities.contains(.favorites) }

    /// What a row shows: the pending flip, else the confirmed value, else the item's own field.
    public func isFavorite(_ id: MediaID, stored: Bool?) -> Bool {
        overrides[id] ?? confirmed[id] ?? stored ?? false
    }

    /// Several rows at once (Music.app's rule): favorite all unless every one already is.
    public static func target(for states: [Bool]) -> Bool {
        !states.allSatisfy { $0 }
    }

    /// Flips one item. Returns the failure text, nil on success.
    @discardableResult
    public func toggle(_ id: MediaID, stored: Bool?) async -> String? {
        await set(id, to: !isFavorite(id, stored: stored))
    }

    /// Shows `on` at once, sends it, confirms or restores. Returns the failure text, nil on success.
    @discardableResult
    public func set(_ id: MediaID, to on: Bool) async -> String? {
        let generation = (generations[id] ?? 0) + 1
        generations[id] = generation
        overrides[id] = on
        do {
            try await backend.setFavorite(id, on)
        } catch {
            guard generations[id] == generation else { return nil }
            overrides[id] = nil
            return userMessage(for: error)
        }
        guard generations[id] == generation else { return nil }
        apply(favorite: on, for: id)
        return nil
    }

    /// A confirmed value, from this model's own command or a change made elsewhere. `nil` (unknown) or `false`
    /// (a dislike on newer servers) both read as not favorited.
    public func apply(favorite: Bool?, for id: MediaID) {
        let on = favorite ?? false
        if let pending = overrides[id], pending == on { overrides[id] = nil }
        confirmed[id] = on
        onConfirmed?(id, on)
    }

    /// Forgets everything (a source switch or disconnect).
    public func reset() {
        overrides = [:]
        confirmed = [:]
        generations = [:]
        cancelLists()
        counts = [:]
        tracks.reset()
        albums.reset()
        artists.reset()
        playlists.reset()
        radios.reset()
    }
}

extension LibraryBrowserModel {
    /// Patches the cached paged lists with a confirmed favorite.
    func patchFavorite(_ id: MediaID, _ on: Bool) {
        switch id.kind {
        case .artist: artists.update(id: id) { $0.isFavorite = on }
        case .album:
            allAlbums.update(id: id) { $0.isFavorite = on }
            artistAlbums.update(id: id) { $0.isFavorite = on }
        case .playlist: playlists.update(id: id) { $0.isFavorite = on }
        case .radio: radios.update(id: id) { $0.isFavorite = on }
        case .track: break
        }
        favorites.favoritesChanged(id, on)
    }
}
