import Testing
@testable import MusicBackendKit

struct PlayRequestTests {
    private static let album = MediaID(.album, "A")

    private static func row(_ id: String) -> LibraryTrack {
        LibraryTrack(id: MediaID(.track, id), title: "T\(id)", artistName: "X", albumID: album)
    }

    private let rows = ["1", "2", "3", "4"].map(PlayRequestTests.row)
    private func ids(_ values: String...) -> Set<MediaID> { Set(values.map { MediaID(.track, $0) }) }
    private func tracks(_ values: String...) -> [MediaID] { values.map { MediaID(.track, $0) } }

    @Test func albumRowsReplaceOrAppendTheAlbum() {
        let play = PlayRequest.play(album: Self.album)
        #expect(play.items == [Self.album])
        #expect(play.mode == .replace(startIndex: 0))
        let append = PlayRequest.append(album: Self.album)
        #expect(append.items == [Self.album])
        #expect(append.mode == .append)
    }

    @Test func oneTrackInAnAlbumPlaysTheAlbumFromThatRow() throws {
        let request = try #require(PlayRequest.play(ids("2"), in: rows, album: Self.album))
        #expect(request.items == tracks("1", "2", "3", "4"))
        #expect(request.mode == .replace(startIndex: 1))
    }

    @Test func severalTracksPlayInDisplayOrder() throws {
        let request = try #require(PlayRequest.play(ids("4", "1"), in: rows, album: Self.album))
        #expect(request.items == tracks("1", "4"))
        #expect(request.mode == .replace(startIndex: 0))
    }

    @Test func aTrackWithoutAnAlbumPlaysAlone() throws {
        let request = try #require(PlayRequest.play(ids("3"), in: rows, album: nil))
        #expect(request.items == tracks("3"))
        #expect(request.mode == .replace())
    }

    @Test func appendKeepsDisplayOrder() throws {
        let request = try #require(PlayRequest.append(ids("4", "1"), in: rows))
        #expect(request.items == tracks("1", "4"))
        #expect(request.mode == .append)
    }

    @Test func nothingSelectedIsNil() {
        #expect(PlayRequest.play([], in: rows, album: Self.album) == nil)
        #expect(PlayRequest.append([], in: rows) == nil)
        #expect(PlayRequest.play(ids("99"), in: rows, album: Self.album) == nil)
        #expect(PlayRequest.append(ids("99"), in: rows) == nil)
    }
}
