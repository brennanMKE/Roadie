import Foundation
import MusicBackendKit
import Testing
@testable import LibraryBrowser

struct PlaylistPositionsTests {
    private func rows(_ count: Int, positioned: Bool = true) -> [LibraryTrack] {
        (1...count).map { number -> LibraryTrack in
            var track = LibraryTrack(id: MediaID(.track, "t\(number)"), title: "T\(number)", artistName: "A")
            track.playlistPosition = positioned ? number : nil
            return track
        }
    }

    @Test func selectionBecomesOneBasedPositions() {
        let all = rows(5)
        let selected: Set<MediaID> = [MediaID(.track, "t1"), MediaID(.track, "t4")]
        #expect(PlaylistPositions.positions(of: selected, in: all) == [4, 1])
        // Without positions from the backend, the index + 1.
        #expect(PlaylistPositions.positions(of: selected, in: rows(5, positioned: false)) == [4, 1])
        #expect(PlaylistPositions.positions(of: [MediaID(.track, "nope")], in: all).isEmpty)
    }

    @Test func positionsAreInDescendingOrder() {
        let all = rows(6)
        let selected = Set(all.map(\.id))
        #expect(PlaylistPositions.positions(of: selected, in: all) == [6, 5, 4, 3, 2, 1])
    }

    @Test func renumbersAfterRemove() {
        let left = PlaylistPositions.renumber(rows(5), afterRemoving: [2, 4])
        #expect(left.map(\.id.rawValue) == ["t1", "t3", "t5"])
        #expect(left.map(\.playlistPosition) == [1, 2, 3])
        // A second remove before the refetch hits the right track.
        let selected: Set<MediaID> = [MediaID(.track, "t5")]
        #expect(PlaylistPositions.positions(of: selected, in: left) == [3])
    }

    @Test func movingRenumbers() {
        let moved = PlaylistPositions.moving(rows(4), from: 3, to: 0)
        #expect(moved.map(\.id.rawValue) == ["t4", "t1", "t2", "t3"])
        #expect(moved.map(\.playlistPosition) == [1, 2, 3, 4])
        #expect(PlaylistPositions.finalIndex(from: 0, onMoveDestination: 3) == 2)
        #expect(PlaylistPositions.finalIndex(from: 3, onMoveDestination: 0) == 0)
    }
}
