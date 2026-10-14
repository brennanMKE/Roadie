import Foundation
import MusicBackendKit
import MusicBackendStub
import Testing
@testable import LibraryBrowser

/// The browser's use of `ArtistGrouper`: grouped rows, paging by a member id, and merged albums.
@MainActor
struct ArtistGroupingModelTests {
    private func artist(_ n: Int, _ name: String) -> LibraryArtist {
        LibraryArtist(id: MediaID(.artist, "g\(n)"), name: name)
    }

    private func album(_ n: Int, of artist: Int) -> LibraryAlbum {
        LibraryAlbum(id: MediaID(.album, "ga\(n)"), title: "Album \(n)", artistID: MediaID(.artist, "g\(artist)"), artistName: "x")
    }

    private var spellings: StubLibrary {
        StubLibrary(
            artists: [artist(1, "AJ & Jordan"), artist(2, "Aerosmith"), artist(3, "AJ and Jordan;")],
            albums: [album(1, of: 1), album(2, of: 2), album(3, of: 3)])
    }

    private func connected(_ library: StubLibrary, pageSize: Int = 100) async -> (StubMusicBackend, LibraryBrowserModel) {
        let backend = StubMusicBackend(library: library)
        let model = LibraryBrowserModel(backend: backend, pageSize: pageSize, searchDelay: .milliseconds(20))
        model.appeared()
        #expect(await waitFor { model.connection == .connected && model.artists.phase == .loaded })
        return (backend, model)
    }

    @Test func spellingsOfOneArtistShareARow() async {
        let (_, model) = await connected(spellings)
        #expect(model.artistRows.map(\.name) == ["AJ & Jordan", "Aerosmith"])
        #expect(model.artistRows[0].memberIDs.count == 2)
    }

    @Test func everyGroupedRowHasAMemberInTheListSoPagingFindsIt() async {
        let (_, model) = await connected(spellings)
        let loaded = Set(model.artists.items.map(\.id))
        for row in model.artistRows { #expect(row.memberIDs.contains(where: loaded.contains)) }
    }

    @Test func aDuplicateOnALaterPageJoinsTheEarlierRow() async {
        let (backend, model) = await connected(spellings, pageSize: 2)
        #expect(model.artists.items.count == 2)
        #expect(model.artistRows.count == 2)
        #expect(model.artistRows[0].memberIDs.count == 1)
        model.artists.loadMore()
        #expect(await waitFor { model.artists.items.count == 3 })
        #expect(model.artistRows.count == 2)
        #expect(model.artistRows[0].memberIDs.count == 2)
        #expect(model.artistRows[0].id == "aj & jordan")
        #expect(await backend.count(.artists) == 2)
    }

    @Test func selectingAMergedRowLoadsAlbumsFromEveryMember() async {
        let (backend, model) = await connected(spellings)
        model.select(model.artistRows[0])
        #expect(await waitFor { model.artistAlbums.phase == .loaded })
        #expect(model.artistAlbums.items.map(\.id.rawValue) == ["ga1", "ga3"])
        #expect(model.selectedArtistGroup?.id == "aj & jordan")
        #expect(await backend.count(.albums) == 2)
    }

    @Test func selectingAnUnmergedRowStillUsesOnePagedRequest() async {
        let (backend, model) = await connected(spellings)
        model.select(model.artistRows[1])
        #expect(await waitFor { model.artistAlbums.phase == .loaded })
        #expect(model.artistAlbums.items.map(\.id.rawValue) == ["ga2"])
        #expect(await backend.calls(.albums) == [.albums(MediaID(.artist, "g2"), PageRequest(offset: 0, limit: 100))])
        #expect(model.selectedArtistGroup?.id == "aerosmith")
    }

    @Test func anAlbumFromEitherSpellingSelectsTheMergedGroup() async {
        let (_, model) = await connected(spellings)
        model.section = .albums
        #expect(await waitFor { model.allAlbums.phase == .loaded })
        model.select(album(3, of: 3))
        #expect(model.selectedArtistGroup?.id == "aj & jordan")
        #expect(model.section == .albums)
    }

    @Test func reloadingTheArtistsRebuildsTheRows() async {
        let (backend, model) = await connected(spellings)
        #expect(model.artistRows.count == 2)
        await backend.setLibrary(StubLibrary(artists: [artist(9, "Zed")]))
        model.refresh()
        #expect(await waitFor { model.artists.items.map(\.name) == ["Zed"] })
        #expect(model.artistRows.map(\.name) == ["Zed"])
    }
}
