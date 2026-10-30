import Foundation
import Testing
@testable import MusicBackendKit

/// Implements only the required members, so every optional one runs its default (#0214).
private final class MinimalBackend: MusicBackend {
    let sourceID = "minimal"
    let displayName = "Minimal"
    let capabilities: BackendCapabilities = []

    func connect() async throws {}
    func disconnect() async {}
    func artists(page: PageRequest) async throws -> Page<LibraryArtist> { Page(items: [], offset: 0, total: 0, nextOffset: nil) }
    func albums(of artist: MediaID?, page: PageRequest) async throws -> Page<LibraryAlbum> {
        Page(items: [], offset: 0, total: 0, nextOffset: nil)
    }
    func tracks(of album: MediaID) async throws -> [LibraryTrack] { [] }
    func playlists(page: PageRequest) async throws -> Page<LibraryPlaylist> { Page(items: [], offset: 0, total: 0, nextOffset: nil) }
    func tracks(ofPlaylist playlist: MediaID) async throws -> [LibraryTrack] { [] }
    func search(_ query: String, limit: Int) async throws -> SearchResults { SearchResults() }
    func artwork(_ ref: ArtworkRef, maxPixels: Int) async throws -> Data { Data() }
    func outputs() async throws -> [OutputDevice] { [.thisMac] }
    func play(_ items: [MediaID], on output: OutputDevice.ID, mode: PlayMode) async throws {}
    func transport(_ command: TransportCommand, on output: OutputDevice.ID) async throws {}
    func nowPlaying(on output: OutputDevice.ID) async -> AsyncStream<NowPlaying> { AsyncStream { $0.finish() } }
}

private func expectUnsupported(
    _ capability: BackendCapabilities, sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        Issue.record("expected unsupported(\(capability.rawValue))", sourceLocation: sourceLocation)
    } catch {
        #expect(error as? MusicBackendError == .unsupported(capability), sourceLocation: sourceLocation)
    }
}

struct DefaultBackendTests {
    private let backend = MinimalBackend()
    private let page = PageRequest()
    private let id = MediaID(.playlist, "p/1")
    private let output = OutputDevice.ID(rawValue: "kitchen")

    @Test func defaultFavoritesThrowUnsupported() async {
        await expectUnsupported(.favorites) { _ = try await backend.favoriteCount(.track) }
        await expectUnsupported(.favorites) { _ = try await backend.favoriteTracks(page: page) }
        await expectUnsupported(.favorites) { _ = try await backend.favoriteAlbums(page: page) }
        await expectUnsupported(.favorites) { _ = try await backend.favoriteArtists(page: page) }
        await expectUnsupported(.favorites) { _ = try await backend.favoritePlaylists(page: page) }
        await expectUnsupported(.favorites) { _ = try await backend.favoriteRadios(page: page) }
        await expectUnsupported(.favorites) { try await backend.setFavorite(id, true) }
        await expectUnsupported(.favorites) { try await backend.favoriteCurrentTrack(on: output) }
        await expectUnsupported(.radio) { _ = try await backend.radios(page: page) }
        await expectUnsupported(.radio) { _ = try await backend.addRadio(url: "https://a.example", name: "A") }
        await expectUnsupported(.recommendations) { _ = try await backend.recommendationRows() }
        let row = RecommendationRow(provider: "library", itemID: "recent", name: "Recent")
        await expectUnsupported(.recommendations) { _ = try await backend.recommendationItems(row) }
        await expectUnsupported(.remoteOutputs) { try await backend.transfer(from: output, to: output, autoPlay: true) }
        await expectUnsupported(.remoteOutputs) {
            try await backend.setGroupMembers(of: output, adding: [], removing: [])
        }
        let item = RecommendationItem.other(uri: "x://1", kind: nil, name: "X", subtitle: nil, artwork: nil)
        let resolved = try? await backend.resolve(item)
        #expect(resolved == item)
        var changes = 0
        for await _ in await backend.libraryChanges() { changes += 1 }
        #expect(changes == 0)
    }

    @Test func defaultPlaylistEditingThrowsUnsupported() async {
        await expectUnsupported(.playlistEditing) { _ = try await backend.createPlaylist(named: "New") }
        await expectUnsupported(.playlistEditing) { try await backend.renamePlaylist(id, to: "Renamed") }
        await expectUnsupported(.playlistEditing) { try await backend.deletePlaylist(id) }
        await expectUnsupported(.playlistEditing) { try await backend.add([MediaID(.track, "t/1")], toPlaylist: id) }
        await expectUnsupported(.playlistEditing) { _ = try await backend.exportPlaylist(id) }
        await expectUnsupported(.playlistEditing) { _ = try await backend.importPlaylist(m3u: "#EXTM3U") }
        await expectUnsupported(.playlistEditing) { try await backend.remove(positions: [1], fromPlaylist: id) }
        await expectUnsupported(.playlistEditing) { try await backend.movePlaylistTrack(id, from: 1, to: 2) }
    }

    @Test func defaultQueueIsEmpty() async {
        var snapshots: [RemoteQueueSnapshot] = []
        for await snapshot in await backend.queue(on: output) { snapshots.append(snapshot) }
        #expect(snapshots == [.empty(on: output)])
        await expectUnsupported(.queueEditing) { try await backend.edit(.clear, on: output) }
        await expectUnsupported(.queueEditing) { try await backend.saveQueueAsPlaylist(on: output, named: "Saved") }
    }
}
