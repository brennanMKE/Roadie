import Foundation
import Testing
@testable import AudioCore

@Suite struct PlaylistSelectionTests {
    private let tracks = makeTracks(6)

    @Test func clickSelectsOnlyThatRowAndSetsTheAnchor() {
        var s = PlaylistSelection()
        s.click(2, in: tracks)
        s.click(4, in: tracks)
        #expect(s.indices(in: tracks) == [4])
        #expect(s.anchor == 4)
        s.click(99, in: tracks)
        #expect(s.indices(in: tracks) == [4])
    }

    @Test func commandClickTogglesAndMovesTheAnchorEvenWhenUnselecting() {
        var s = PlaylistSelection()
        s.commandClick(1, in: tracks)
        s.commandClick(3, in: tracks)
        #expect(s.indices(in: tracks) == [1, 3])
        s.commandClick(1, in: tracks)
        #expect(s.indices(in: tracks) == [3])
        #expect(s.anchor == 1)
    }

    @Test func shiftClickSelectsTheRangeFromTheAnchor() {
        var s = PlaylistSelection()
        s.shiftClick(3, in: tracks)
        #expect(s.indices(in: tracks).isEmpty)
        s.click(1, in: tracks)
        s.shiftClick(3, in: tracks)
        #expect(s.indices(in: tracks) == [1, 2, 3])
        s.shiftClick(0, in: tracks)
        #expect(s.indices(in: tracks) == [0, 1])
    }

    @Test func allNoneInvert() {
        var s = PlaylistSelection()
        s.selectAll(in: tracks)
        #expect(s.indices(in: tracks).count == 6)
        s.selectNone()
        #expect(s.indices(in: tracks).isEmpty)
        s.click(2, in: tracks)
        s.invert(in: tracks)
        #expect(s.indices(in: tracks) == [0, 1, 3, 4, 5])
        #expect(!s.contains(tracks[2]))
        #expect(s.contains(tracks[0]))
    }

    @Test func selectionFollowsTracksAcrossMoveAndRemove() {
        var q = PlayQueue(tracks: tracks)
        var s = PlaylistSelection()
        s.click(1, in: q.tracks)
        s.commandClick(2, in: q.tracks)
        let moved1 = q.move([1, 2], by: 2)
        #expect(moved1)
        #expect(s.indices(in: q.tracks) == [3, 4])
        q.remove(at: 3)
        s.prune(to: q.tracks)
        #expect(s.indices(in: q.tracks) == [3])
        #expect(s.anchor == nil)
    }
}
