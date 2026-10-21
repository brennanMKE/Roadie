import Foundation
import MusicBackendKit
import MusicBackendStub
import Testing
@testable import LibraryBrowser

@MainActor
struct LibraryBrowserModelTests {
    private func id(_ kind: MediaKind, _ raw: String) -> MediaID { MediaID(kind, raw) }

    private func isLoaded(_ phase: LibraryBrowserModel.SearchPhase) -> Bool {
        if case .loaded = phase { return true }
        return false
    }

    private func loadedResults(_ phase: LibraryBrowserModel.SearchPhase) -> SearchResults? {
        if case .loaded(let results) = phase { return results }
        return nil
    }

    /// A model that has connected and loaded the artists.
    private func connected(
        library: StubLibrary = .sample(), capabilities: BackendCapabilities = [.search, .artwork, .localOutput]
    ) async -> (StubMusicBackend, LibraryBrowserModel) {
        let (backend, model) = makeModel(library: library, capabilities: capabilities)
        model.appeared()
        #expect(await waitFor { model.connection == .connected && model.artists.phase == .loaded })
        return (backend, model)
    }

    // MARK: Connecting

    @Test func appearedConnectsThenLoadsArtists() async {
        let (backend, model) = makeModel()
        model.appeared()
        #expect(await waitFor { model.artists.phase == .loaded })
        #expect(await backend.calls == [.connect, .artists(PageRequest(offset: 0, limit: 100))])
        #expect(model.connection == .connected)
        #expect(model.artists.items.count == 25)
        #expect(model.artistRows.count == 25)
        #expect(model.artistRows.flatMap(\.members) == model.artists.items)
    }

    @Test func appearedTwiceConnectsOnce() async {
        let (backend, model) = await connected()
        model.appeared()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await backend.count(.connect) == 1)
        #expect(await backend.count(.artists) == 1)
    }

    @Test func notConfiguredShowsTheMessageWithSettings() async {
        let (backend, model) = makeModel()
        let message = "Add a Music Assistant server under Settings \u{203A} Music Assistant."
        await backend.setError(.notConfigured(message), for: .connect)
        model.appeared()
        #expect(await waitFor { model.connection == .failed(message: message, needsSettings: true) })
        #expect(await backend.count(.artists) == 0)
    }

    @Test func unreachableShowsTheMessageWithRetry() async {
        let (backend, model) = makeModel()
        await backend.setError(.unreachable("Can't reach the server."), for: .connect)
        model.appeared()
        #expect(await waitFor { model.connection == .failed(message: "Can't reach the server.", needsSettings: false) })
        await backend.setError(nil, for: .connect)
        model.retryConnection()
        #expect(await waitFor { model.connection == .connected && model.artists.phase == .loaded })
    }

    @Test func messagesComeFromTheBackendUnchanged() async {
        let errors: [MusicBackendError] = [
            .notConfigured("Set it up."), .unreachable("Can't reach the server."), .unauthorized,
            .backend("The server answered with status 500."),
        ]
        for error in errors {
            let (backend, model) = makeModel()
            await backend.setError(error, for: .connect)
            model.appeared()
            let expected = error.errorDescription ?? ""
            var needsSettings = false
            if case .notConfigured = error { needsSettings = true }
            #expect(await waitFor { model.connection == .failed(message: expected, needsSettings: needsSettings) })
        }
    }

    @Test func disappearedWhileConnectingGoesBackToIdle() async {
        let (backend, model) = makeModel()
        await backend.gate(.connect)
        model.appeared()
        #expect(await waitFor { await backend.suspendedCount == 1 })
        #expect(model.connection == .connecting)
        model.disappeared()
        #expect(model.connection == .idle)
        await backend.release(.connect)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(model.connection == .idle)
        model.appeared()
        #expect(await waitFor { model.connection == .connected })
        #expect(await backend.count(.connect) == 2)
    }

    // MARK: Sections

    @Test func sectionIdentityIsTheSectionItself() {
        #expect(LibrarySection.allCases.map(\.id) == LibrarySection.allCases)
    }

    @Test func sectionSurvivesDisappearAndAppear() async {
        let (backend, model) = await connected(capabilities: [.search, .playlists])
        model.section = .playlists
        #expect(await waitFor { model.playlists.phase == .loaded })
        let artistCalls = await backend.count(.artists)
        model.disappeared()
        model.appeared()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(model.section == .playlists)
        #expect(model.playlists.phase == .loaded)
        #expect(await backend.count(.playlists) == 1)
        #expect(await backend.count(.artists) == artistCalls)
    }

    @Test func sectionsHidePlaylistsWithoutTheCapability() {
        let (_, plain) = makeModel()
        #expect(plain.sections == [.artists, .albums])
        let (_, withPlaylists) = makeModel(capabilities: [.search, .playlists])
        #expect(withPlaylists.sections == [.artists, .albums, .playlists])
    }

    @Test func favoritesSectionNeedsTheCapability() {
        let (_, plain) = makeModel(capabilities: [.search, .playlists])
        #expect(!plain.sections.contains(.favorites))
        let (_, withFavorites) = makeModel(capabilities: [.search, .playlists, .favorites])
        #expect(withFavorites.sections == [.artists, .albums, .playlists, .favorites])
    }

    @Test func switchingSectionsLoadsEachListOnce() async {
        let (backend, model) = await connected()
        model.section = .albums
        #expect(await waitFor { model.allAlbums.phase == .loaded })
        #expect(await backend.calls(.albums) == [.albums(nil, PageRequest(offset: 0, limit: 100))])
        model.section = .artists
        model.section = .albums
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await backend.count(.albums) == 1)
        #expect(await backend.count(.artists) == 1)
        model.refresh()
        #expect(await waitFor { await backend.count(.albums) == 2 })
        #expect(await backend.count(.artists) == 1)
    }

    @Test func playlistsLoadWhenTheBackendHasThem() async {
        let (backend, model) = await connected(
            library: .sample(playlistCount: 2), capabilities: [.search, .playlists])
        model.section = .playlists
        #expect(await waitFor { model.playlists.phase == .loaded })
        #expect(model.playlists.items.count == 2)
        model.select(model.playlists.items[0])
        #expect(await waitFor { model.tracks != .loading && model.tracks != .idle })
        guard case .loaded(let tracks) = model.tracks else {
            Issue.record("expected tracks, got \(model.tracks)")
            return
        }
        #expect(tracks.count == 3)
        #expect(await backend.count(.playlistTracks) == 1)
    }

    // MARK: Selection

    @Test func selectingAnArtistLoadsItsAlbumsAndClearsTheAlbum() async {
        let (backend, model) = await connected()
        model.select(model.artists.items[0])
        #expect(await waitFor { model.artistAlbums.phase == .loaded })
        #expect(await backend.calls(.albums) == [.albums(id(.artist, "a01"), PageRequest(offset: 0, limit: 100))])
        #expect(model.artistAlbums.items.count == 2)
        #expect(model.selectedAlbum == nil)
        #expect(model.tracks == .idle)
    }

    @Test func selectingAnAlbumLoadsItsTracksInOrder() async {
        let (backend, model) = await connected()
        model.select(model.artists.items[0])
        #expect(await waitFor { model.artistAlbums.phase == .loaded })
        model.select(model.artistAlbums.items[0])
        #expect(await waitFor { if case .loaded = model.tracks { true } else { false } })
        #expect(await backend.calls(.tracks) == [.tracks(id(.album, "a01-b1"))])
        guard case .loaded(let tracks) = model.tracks else { return }
        #expect(tracks.map(\.id.rawValue) == (1...5).map { String(format: "a01-b1-t%02d", $0) })
        #expect(model.selectedArtist?.id == id(.artist, "a01"))
    }

    @Test func selectingAnAlbumFromAllAlbumsSetsItsArtistWhenLoaded() async {
        // Artists not loaded: the artist stays unset and the tracks still load.
        let (_, model) = makeModel()
        model.section = .albums
        model.appeared()
        #expect(await waitFor { model.allAlbums.phase == .loaded })
        model.select(model.allAlbums.items[0])
        #expect(await waitFor { if case .loaded = model.tracks { true } else { false } })
        #expect(model.selectedArtist == nil)

        // Artists loaded: the album's artist is looked up.
        let (_, loaded) = await connected()
        loaded.section = .albums
        #expect(await waitFor { loaded.allAlbums.phase == .loaded })
        let album = loaded.allAlbums.items[2]
        loaded.select(album)
        #expect(loaded.selectedArtist?.id == album.artistID)
        #expect(loaded.selectedAlbum == album)
        #expect(await waitFor { if case .loaded = loaded.tracks { true } else { false } })
    }

    @Test func changingTheArtistDropsThePreviousAlbumAnswer() async {
        let (backend, model) = await connected()
        await backend.gate(.albums)
        model.select(model.artists.items[0])
        #expect(await waitFor { await backend.suspendedCount == 1 })
        model.select(model.artists.items[1])
        await backend.release(.albums)
        #expect(await waitFor { model.artistAlbums.phase == .loaded })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(model.artistAlbums.items.count == 2)
        #expect(model.artistAlbums.items.allSatisfy { $0.artistID == id(.artist, "a02") })
    }

    @Test func changingTheAlbumCancelsThePreviousTrackLoad() async {
        let (backend, model) = await connected()
        model.select(model.artists.items[0])
        #expect(await waitFor { model.artistAlbums.phase == .loaded })
        let albums = model.artistAlbums.items
        await backend.gate(.tracks)
        model.select(albums[0])
        #expect(await waitFor { await backend.suspendedCount == 1 })
        model.select(albums[1])
        #expect(await waitFor { await backend.cancelledCount == 1 })
        await backend.release(.tracks)
        #expect(await waitFor { if case .loaded = model.tracks { true } else { false } })
        guard case .loaded(let tracks) = model.tracks else { return }
        #expect(tracks.allSatisfy { $0.albumID == albums[1].id })
        #expect(await backend.suspendedCount == 0)
    }

    @Test func anEmptyAlbumIsLoadedNotFailed() async {
        var library = StubLibrary.sample(artistCount: 1, albumsPerArtist: 1, tracksPerAlbum: 1)
        library.tracks = []
        let (_, model) = await connected(library: library)
        model.select(model.artists.items[0])
        #expect(await waitFor { model.artistAlbums.phase == .loaded })
        model.select(model.artistAlbums.items[0])
        #expect(await waitFor { model.tracks == .loaded([]) })
    }

    @Test func trackLoadFailureShowsTheMessage() async {
        let (backend, model) = await connected()
        await backend.setError(.backend("The server answered with status 500."), for: .tracks)
        model.select(model.artists.items[0])
        #expect(await waitFor { model.artistAlbums.phase == .loaded })
        model.select(model.artistAlbums.items[0])
        #expect(await waitFor { model.tracks == .failed("The server answered with status 500.") })
        await backend.setError(nil, for: .tracks)
        model.retryTracks()
        #expect(await waitFor { if case .loaded = model.tracks { true } else { false } })
    }

    // MARK: Search

    @Test func searchIsDebouncedToOneRequest() async {
        let (backend, model) = await connected()
        for text in ["e", "ed", "ede", "eden"] { model.searchText = text }
        #expect(await waitFor { isLoaded(model.search) })
        #expect(await backend.calls(.search) == [.search("eden", 50)])
    }

    @Test func searchSendsAgainAfterAPause() async {
        let (backend, model) = await connected()
        model.searchText = "art"
        #expect(await waitFor { isLoaded(model.search) })
        model.searchText = "artist 0"
        #expect(await waitFor { await backend.count(.search) == 2 })
        #expect(await waitFor { loadedResults(model.search)?.artists.count == 9 })
        #expect(await backend.calls(.search) == [.search("art", 50), .search("artist 0", 50)])
    }

    @Test func returnSearchesAtOnce() async {
        let backend = StubMusicBackend()
        let model = LibraryBrowserModel(backend: backend, searchDelay: .seconds(5))
        model.appeared()
        #expect(await waitFor { model.connection == .connected })
        let started = Date()
        model.searchText = "artist"
        model.searchNow()
        #expect(await waitFor(timeout: 2) { isLoaded(model.search) })
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(await backend.count(.search) == 1)
        model.disappeared()
    }

    @Test func whitespaceSendsNothing() async {
        let (backend, model) = await connected()
        model.searchText = "   "
        try? await Task.sleep(for: .milliseconds(80))
        #expect(model.search == .idle)
        #expect(await backend.count(.search) == 0)
        #expect(!model.isSearching)
    }

    @Test func clearingTheFieldDropsTheInFlightSearch() async {
        let (backend, model) = await connected()
        await backend.gate(.search)
        model.searchText = "a"
        #expect(await waitFor { model.search == .searching })
        model.searchText = ""
        #expect(model.search == .idle)
        #expect(await waitFor { await backend.cancelledCount == 1 })
        await backend.release(.search)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(model.search == .idle)
    }

    @Test func aNewerQueryWinsOverAnOlderAnswer() async {
        let (backend, model) = await connected()
        await backend.gate(.search)
        model.searchText = "artist 1"
        #expect(await waitFor { await backend.suspendedCount == 1 })
        model.searchText = "artist 10"
        #expect(await waitFor { await backend.suspendedCount == 1 && model.search == .searching })
        await backend.release(.search)
        #expect(await waitFor { isLoaded(model.search) })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(loadedResults(model.search)?.artists.map(\.name) == ["Artist 10"])
    }

    @Test func searchFailureShowsTheMessage() async {
        let (backend, model) = await connected()
        await backend.setError(.unreachable("Can't reach the server."), for: .search)
        model.searchText = "artist"
        #expect(await waitFor { model.search == .failed("Can't reach the server.") })
        await backend.setError(nil, for: .search)
        model.searchNow()
        #expect(await waitFor { isLoaded(model.search) })
    }

    @Test func selectingASearchedArtistKeepsTheQuery() async {
        let (_, model) = await connected()
        model.searchText = "artist 07"
        #expect(await waitFor { isLoaded(model.search) })
        guard let artist = loadedResults(model.search)?.artists.first else {
            Issue.record("no artist in the results")
            return
        }
        model.select(artist)
        #expect(model.selectedArtist == artist)
        #expect(await waitFor { model.artistAlbums.phase == .loaded })
        #expect(model.searchText == "artist 07")
        #expect(model.isSearching)
    }

    // MARK: Lifecycle

    @Test func disappearedCancelsWorkAndKeepsData() async {
        let (backend, model) = await connected()
        await backend.gate(.albums)
        model.select(model.artists.items[0])
        #expect(await waitFor { await backend.suspendedCount == 1 })
        model.disappeared()
        #expect(await waitFor { await backend.cancelledCount == 1 })
        #expect(model.artists.items.count == 25)
        #expect(model.connection == .connected)
        await backend.release(.albums)
        model.appeared()
        #expect(await waitFor { model.artistAlbums.phase == .loaded })
        #expect(await backend.count(.connect) == 1)
    }

    // MARK: Failure hook (#0067)

    private final class FailureLog {
        var entries: [String] = []
    }

    private func log(_ model: LibraryBrowserModel) -> FailureLog {
        let log = FailureLog()
        model.onBackendFailure = { error, phase in log.entries.append("\(error)|\(phase)") }
        return log
    }

    @Test func connectFailuresReachTheFailureHook() async {
        let (backend, model) = makeModel()
        let failures = log(model)
        await backend.setError(.notConfigured("Set it up."), for: .connect)
        model.appeared()
        #expect(await waitFor { failures.entries.count == 1 })
        #expect(failures.entries == ["notConfigured(\"Set it up.\")|connect"])
        await backend.setError(.unreachable("down"), for: .connect)
        model.retryConnection()
        #expect(await waitFor { failures.entries.count == 2 })
        #expect(failures.entries.last == "unreachable(\"down\")|connect")
        // A cancelled connect is not a failure.
        await backend.setError(nil, for: .connect)
        await backend.gate(.connect)
        model.retryConnection()
        #expect(await waitFor { await backend.suspendedCount == 1 })
        model.disappeared()
        #expect(await waitFor { await backend.cancelledCount == 1 })
        #expect(failures.entries.count == 2)
    }

    @Test func listTrackAndSearchFailuresReachTheFailureHook() async {
        let (backend, model) = makeModel()
        let failures = log(model)
        await backend.setError(.unreachable("a"), for: .artists)
        model.appeared()
        #expect(await waitFor { failures.entries == ["unreachable(\"a\")|browse"] })
        await backend.setError(.notConnected, for: .artists)
        model.section = .albums
        model.section = .artists
        #expect(await waitFor { if case .failed = model.artists.phase { true } else { false } })
        await backend.setError(nil, for: .artists)
        model.refresh()
        #expect(await waitFor { model.artists.phase == .loaded })
        await backend.setError(.backend("t"), for: .tracks)
        model.select(model.artists.items[0])
        #expect(await waitFor { model.artistAlbums.phase == .loaded })
        model.select(model.artistAlbums.items[0])
        #expect(await waitFor { failures.entries.count == 2 })
        await backend.setError(.notFound(id(.track, "x")), for: .tracks)
        model.retryTracks()
        #expect(await waitFor { if case .failed = model.tracks { true } else { false } })
        await backend.setError(.unreachable("s"), for: .search)
        model.searchText = "artist"
        #expect(await waitFor { failures.entries.count == 3 })
        #expect(failures.entries == ["unreachable(\"a\")|browse", "backend(\"t\")|browse", "unreachable(\"s\")|browse"])
    }

    // MARK: Library changes (#0139)

    @Test func playlistAddedElsewhereReloadsTheList() async {
        let (backend, model) = await connected(
            library: .sample(playlistCount: 2), capabilities: [.search, .playlists])
        model.section = .playlists
        #expect(await waitFor { model.playlists.phase == .loaded && model.playlists.items.count == 2 })
        #expect(await waitFor { await backend.changeSubscriberCount == 1 })
        var forwarded: [LibraryChange] = []
        model.onLibraryChange = { forwarded.append($0) }
        await backend.setLibrary(.sample(playlistCount: 3))
        let added = LibraryChange.playlistAdded(MediaID(.playlist, "elsewhere"))
        await backend.pushChange(added)
        #expect(await waitFor { model.playlists.phase == .loaded && model.playlists.items.count == 3 })
        #expect(forwarded == [added])
        model.disappeared()
        #expect(await waitFor { await backend.changeSubscriberCount == 0 })
    }
}
