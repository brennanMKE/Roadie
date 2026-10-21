import Foundation
import MusicBackendKit
import Observation

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

    public init(backend: any MusicBackend) {
        self.backend = backend
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
        case .track, .radio: break
        }
    }
}
