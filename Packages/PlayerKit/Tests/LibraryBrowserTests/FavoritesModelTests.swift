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

    @Test func countsLoadPerKind() async {
        var library = StubLibrary.sample(playlistCount: 3)
        for i in 0..<3 { library.tracks[i].isFavorite = true }
        library.albums[0].isFavorite = true
        library.playlists[1].isFavorite = true
        let (_, model) = makeModel(library: library, capabilities: [.search, .playlists, .favorites])
        await model.favorites.loadCounts()
        #expect(model.favorites.counts == [.tracks: 3, .albums: 1, .artists: 0, .playlists: 1, .radios: 0])
        // The section loads the selected kind; unfavoriting a row removes it after the refetch.
        model.section = .favorites
        model.appeared()
        #expect(await waitFor { model.favorites.tracks.phase == .loaded })
        #expect(model.favorites.tracks.items.count == 3)
        let first = model.favorites.tracks.items[0].id
        await StubFavoriteEdit.unfavorite(first, in: model)
        #expect(await waitFor { model.favorites.tracks.items.count == 2 })
        #expect(await waitFor { model.favorites.counts[.tracks] == 2 })
    }

    @Test func severalRowsFavoriteUnlessAllAre() {
        #expect(FavoritesModel.target(for: [true, false]))
        #expect(!FavoritesModel.target(for: [true, true]))
    }
}

/// Unfavorites in the stub's library too, so the refetch sees it.
@MainActor
enum StubFavoriteEdit {
    static func unfavorite(_ id: MediaID, in model: LibraryBrowserModel) async {
        guard let backend = model.backend as? StubMusicBackend else { return }
        var library = await backend.library
        if let index = library.tracks.firstIndex(where: { $0.id == id }) { library.tracks[index].isFavorite = false }
        await backend.setLibrary(library)
        #expect(await model.favorites.set(id, to: false) == nil)
    }
}
