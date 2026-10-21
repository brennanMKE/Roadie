import AudioCore
import LibraryBrowser
import MusicBackendKit

/// Favorites from the Library and the Playback menu (#0141).
extension PlayerModel {
    /// Sets every item to `on`, optimistically; a failure restores the heart and shows in the marquee.
    func setFavorite(_ items: [MediaID: Bool?], to on: Bool) {
        let favorites = library.favorites
        for id in items.keys {
            Task {
                if let message = await favorites.set(id, to: on) {
                    post(StatusNotice(text: on ? "Couldn't favorite" : "Couldn't unfavorite", detail: message))
                }
            }
        }
    }

    /// ⌘L on the selection: favorite all unless every one already is.
    func toggleFavorite(_ items: [MediaID: Bool?]) {
        guard !items.isEmpty else { return }
        let favorites = library.favorites
        setFavorite(items, to: FavoritesModel.target(for: items.map { favorites.isFavorite($0.key, stored: $0.value) }))
    }

    /// Playback › Favorite Current Track: a speaker, or This Mac fed by Music Assistant. The local queue's tracks
    /// can't say they came from Music Assistant, so it stays disabled there (#0132 decision 8).
    var canFavoriteCurrentTrack: Bool {
        backend.capabilities.contains(.favorites) && !playsLocalQueue
    }

    func favoriteCurrentTrack() {
        guard canFavoriteCurrentTrack else { return }
        let backend = backend
        let output = selectedOutput
        Task {
            do {
                try await backend.favoriteCurrentTrack(on: output)
                post(StatusNotice(text: "Added to favorites"))
            } catch {
                let message = (error as? MusicBackendError)?.errorDescription ?? error.localizedDescription
                post(StatusNotice(text: "Couldn't favorite", detail: message))
            }
        }
    }
}
