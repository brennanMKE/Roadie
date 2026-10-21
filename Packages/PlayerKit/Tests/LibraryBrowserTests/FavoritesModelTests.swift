import Foundation
import MusicBackendKit
import MusicBackendStub
import Testing
@testable import LibraryBrowser

@MainActor
struct FavoritesModelTests {
    private let album = MediaID(.album, "library://album/1")

    private func makeFavorites() -> (StubMusicBackend, LibraryBrowserModel) {
        makeModel(capabilities: [.search, .artwork, .localOutput, .favorites])
    }

    @Test func toggleFlipsAtOnce() async {
        let (backend, model) = makeFavorites()
        let favorites = model.favorites
        #expect(favorites.isAvailable)
        await backend.gate(.setFavorite)
        let album = album
        let task = Task { await favorites.toggle(album, stored: false) }
        #expect(await waitFor { await backend.suspendedCount == 1 })
        #expect(favorites.isFavorite(album, stored: false))
        #expect(favorites.overrides[album] == true)
        await backend.release(.setFavorite)
        #expect(await task.value == nil)
        #expect(await backend.calls(.setFavorite) == [.setFavorite(album, true)])
    }

    @Test func failureRestores() async {
        let (backend, model) = makeFavorites()
        await backend.setError(.backend("Nope"), for: .setFavorite)
        let message = await model.favorites.toggle(album, stored: true)
        #expect(message == "Nope")
        #expect(model.favorites.overrides.isEmpty)
        #expect(model.favorites.isFavorite(album, stored: true))
    }

    @Test func confirmationClearsOverride() async {
        let (_, model) = makeFavorites()
        model.section = .albums
        model.appeared()
        #expect(await waitFor { model.allAlbums.phase == .loaded })
        let first = model.allAlbums.items[0]
        #expect(await model.favorites.set(first.id, to: true) == nil)
        #expect(model.favorites.overrides.isEmpty)
        #expect(model.favorites.isFavorite(first.id, stored: nil))
        #expect(model.allAlbums.items[0].isFavorite == true)
    }

    @Test func changeFromElsewhereUpdatesRows() async {
        let (_, model) = makeFavorites()
        model.section = .albums
        model.appeared()
        #expect(await waitFor { model.allAlbums.phase == .loaded })
        let first = model.allAlbums.items[0]
        model.favorites.apply(favorite: true, for: first.id)
        #expect(model.allAlbums.items[0].isFavorite == true)
        #expect(model.favorites.isFavorite(first.id, stored: false))
        // A dislike (`false`) and an unknown value read as not favorited.
        model.favorites.apply(favorite: nil, for: first.id)
        #expect(model.allAlbums.items[0].isFavorite == false)
        #expect(!model.favorites.isFavorite(first.id, stored: true))
    }

    @Test func severalRowsFavoriteUnlessAllAre() {
        #expect(FavoritesModel.target(for: [true, false]))
        #expect(!FavoritesModel.target(for: [true, true]))
    }
}
