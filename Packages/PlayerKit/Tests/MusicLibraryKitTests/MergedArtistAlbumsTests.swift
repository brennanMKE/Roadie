import MusicBackendKit
import MusicBackendStub
import Testing

@Suite struct MergedArtistAlbumsTests {
    private func artistID(_ n: Int) -> MediaID { MediaID(.artist, "m\(n)") }

    private func album(_ n: Int, of artist: Int) -> LibraryAlbum {
        LibraryAlbum(id: MediaID(.album, "al\(n)"), title: "Album \(n)", artistID: artistID(artist))
    }

    private func group(_ ids: [Int]) -> ArtistGroup {
        ArtistGroup(
            id: "g", name: "G", sortName: nil,
            members: ids.map { LibraryArtist(id: artistID($0), name: "G") }, artwork: nil)
    }

    @Test func albumsOfAGroupFanOutToEveryMember() async throws {
        let backend = StubMusicBackend(library: StubLibrary(albums: [
            album(1, of: 1), album(2, of: 1), album(3, of: 3),
        ]))
        let albums = try await backend.albums(of: group([1, 3]))
        #expect(albums.map(\.id.rawValue) == ["al1", "al2", "al3"])
        let calls = await backend.calls(.albums)
        #expect(calls.count == 2)
    }

    @Test func walksEveryPageOfEachMember() async throws {
        let backend = StubMusicBackend(library: StubLibrary(albums: (1...5).map { album($0, of: 1) }))
        let albums = try await backend.allAlbums(of: artistID(1), pageSize: 2)
        #expect(albums.map(\.id.rawValue) == ["al1", "al2", "al3", "al4", "al5"])
        let calls = await backend.calls(.albums)
        #expect(calls.count == 3)
    }

    @Test func dropsAnAlbumListedUnderTwoMembers() async throws {
        let shared = LibraryAlbum(id: MediaID(.album, "shared"), title: "Shared", artistID: artistID(1))
        var again = shared
        again.artistID = artistID(3)
        let backend = StubMusicBackend(library: StubLibrary(albums: [shared, album(2, of: 1)]))
        // The stub filters by artistID, so list the shared id under both members through two entries.
        await backend.setLibrary(StubLibrary(albums: [shared, album(2, of: 1), again]))
        let albums = try await backend.albums(of: group([1, 3]))
        #expect(albums.map(\.id.rawValue) == ["shared", "al2"])
    }

    @Test func aFailingMemberFailsTheLoad() async throws {
        let backend = StubMusicBackend(library: StubLibrary(albums: [album(1, of: 1)]))
        // The stub answers `.notFound` for an id that is not an artist id.
        let bad = ArtistGroup(
            id: "g", name: "G", sortName: nil,
            members: [LibraryArtist(id: artistID(1), name: "G"), LibraryArtist(id: MediaID(.album, "x"), name: "G")],
            artwork: nil)
        await #expect(throws: MusicBackendError.notFound(MediaID(.album, "x"))) {
            _ = try await backend.albums(of: bad)
        }
    }

    @Test func stopsAtTheLimit() async throws {
        let backend = StubMusicBackend(library: StubLibrary(albums: (1...5).map { album($0, of: 1) }))
        let albums = try await backend.allAlbums(of: artistID(1), pageSize: 2, limit: 3)
        #expect(albums.count == 3)
        let calls = await backend.calls(.albums)
        #expect(calls.count == 2)
    }
}
