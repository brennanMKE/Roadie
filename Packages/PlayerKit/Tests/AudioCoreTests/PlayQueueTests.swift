import Foundation
import Testing
@testable import AudioCore

@Suite struct PlayQueueTests {
    @Test func emptyQueue() {
        var q = PlayQueue()
        #expect(q.current == nil)
        #expect(q.next() == nil)
        #expect(q.previous() == nil)
        #expect(q.advanceAfterTrackEnd() == nil)
    }

    @Test func nextAndPrevious() {
        var q = queue(3)
        q.select(1)
        #expect(q.next()?.title == "t2")
        #expect(q.previous()?.title == "t1")
        #expect(q.previous()?.title == "t0")
        #expect(q.previous() == nil)
        #expect(q.currentIndex == 0)
    }

    @Test func selectOutOfRangeIsNoOp() {
        var q = queue(2)
        q.select(5)
        #expect(q.current == nil)
    }

    @Test func repeatOffStopsAtEnd() {
        var q = queue(2)
        q.select(1)
        #expect(q.next() == nil)
        #expect(q.advanceAfterTrackEnd() == nil)
        #expect(q.currentIndex == 1)
    }

    @Test func repeatAllWraps() {
        var q = queue(3)
        q.repeatMode = .all
        q.select(2)
        #expect(q.next()?.title == "t0")
        #expect(q.previous()?.title == "t2")
        #expect(q.advanceAfterTrackEnd()?.title == "t0")
    }

    @Test func repeatOne() {
        var q = queue(3)
        q.repeatMode = .one
        q.select(1)
        #expect(q.advanceAfterTrackEnd()?.title == "t1")
        #expect(q.next()?.title == "t2")
        #expect(q.next() == nil)
    }

    @Test func shuffleVisitsEveryTrackOnceAndRetraces() {
        var q = queue(6)
        q.select(2)
        var rng = SplitMix64(seed: 42)
        q.setShuffle(true, using: &rng)
        var visited = [q.currentIndex!]
        while let t = q.next() { visited.append(q.tracks.firstIndex(of: t)!) }
        #expect(visited.first == 2)
        #expect(visited.sorted() == Array(0..<6))
        var back = [q.currentIndex!]
        while let t = q.previous() { back.append(q.tracks.firstIndex(of: t)!) }
        #expect(back == visited.reversed())
    }

    @Test func shuffleRepeatAllContinuesWithFullPermutation() {
        var q = queue(4)
        q.repeatMode = .all
        var rng = SplitMix64(seed: 7)
        q.setShuffle(true, using: &rng)
        q.select(0)
        var first = [q.currentIndex!]
        for _ in 0..<3 { first.append(q.tracks.firstIndex(of: q.next()!)!) }
        #expect(first.sorted() == [0, 1, 2, 3])
        let peek = q.indexAfterCurrentEnds()
        var second: [Int] = []
        for _ in 0..<4 { second.append(q.tracks.firstIndex(of: q.next()!)!) }
        #expect(second.first == peek)
        #expect(second.sorted() == [0, 1, 2, 3])
    }

    @Test func shuffleOffKeepsCurrent() {
        var q = queue(5)
        var rng = SplitMix64(seed: 3)
        q.setShuffle(true, using: &rng)
        q.select(3)
        let current = q.current
        q.setShuffle(false)
        #expect(q.current == current)
        #expect(q.next()?.title == "t4")
    }

    @Test func appendWhileShuffledIsReachable() {
        var q = queue(3)
        var rng = SplitMix64(seed: 9)
        q.setShuffle(true, using: &rng)
        q.select(0)
        q.append(makeTracks(1, from: 3))
        var titles: [String] = [q.current!.title]
        while let t = q.next() { titles.append(t.title) }
        #expect(titles.contains("t3"))
        #expect(Set(titles).count == 4)
    }

    @Test func removeCurrentMakesNextCurrent() {
        var q = queue(3)
        q.select(1)
        q.remove(at: 1)
        #expect(q.current?.title == "t2")
        q.remove(at: 1)
        #expect(q.current?.title == "t0")
        q.remove(at: 0)
        #expect(q.current == nil)
        #expect(q.tracks.isEmpty)
    }

    @Test func removeBeforeCurrentShiftsIndex() {
        var q = queue(3)
        q.select(2)
        q.remove(at: 0)
        #expect(q.current?.title == "t2")
        #expect(q.currentIndex == 1)
    }

    @Test func removeKeepsShuffleOrderValid() {
        var q = queue(6)
        var rng = SplitMix64(seed: 11)
        q.setShuffle(true, using: &rng)
        q.select(2)
        q.remove(at: 2)
        q.remove(at: 0)
        var count = 1
        while q.next() != nil { count += 1 }
        #expect(count == 4)
        #expect(q.tracks.count == 4)
    }

    @Test func indexAfterCurrentEndsAgreesWithAdvance() {
        for mode in RepeatMode.allCases {
            for shuffled in [false, true] {
                var q = queue(4)
                q.repeatMode = mode
                var rng = SplitMix64(seed: 5)
                if shuffled { q.setShuffle(true, using: &rng) }
                q.select(3)
                for _ in 0..<6 {
                    let peek = q.indexAfterCurrentEnds()
                    let advanced = q.advanceAfterTrackEnd()
                    #expect(peek == advanced.flatMap { q.tracks.firstIndex(of: $0) })
                    if advanced == nil { break }
                }
            }
        }
    }
    // MARK: Reordering and bulk removal (#0029)

    private func titles(_ q: PlayQueue) -> [String] { q.tracks.map(\.title) }

    @Test func moveSelectedMatchesWebampMoveSelected() {
        var q = queue(5)
        let moved1 = q.move([1, 3], by: 1)
        #expect(moved1)
        #expect(titles(q) == ["t0", "t2", "t1", "t4", "t3"])
        var r = queue(5)
        let moved2 = r.move([1, 3], by: -1)
        #expect(moved2)
        #expect(titles(r) == ["t1", "t0", "t3", "t2", "t4"])
    }

    @Test func moveClampsAtTheEnds() {
        var q = queue(5)
        let moved3 = q.move([0], by: -1)
        #expect(!moved3)
        let moved4 = q.move([4], by: 3)
        #expect(!moved4)
        let moved5 = q.move([], by: 1)
        #expect(!moved5)
        #expect(titles(q) == ["t0", "t1", "t2", "t3", "t4"])
        // A block that would overshoot stops at the end.
        let moved6 = q.move([3, 4], by: -10)
        #expect(moved6)
        #expect(titles(q) == ["t3", "t4", "t0", "t1", "t2"])
    }

    @Test func moveKeepsTheCurrentTrack() {
        var q = queue(5)
        q.select(2)
        let current = q.current?.id
        let moved7 = q.move([0], by: 4)
        #expect(moved7)
        #expect(q.current?.id == current)
        #expect(q.currentIndex == 1)
    }

    @Test func moveWhileShuffledKeepsAPermutation() {
        var q = queue(6)
        var rng = SplitMix64(seed: 9)
        q.select(3)
        q.setShuffle(true, using: &rng)
        let current = q.current?.id
        let moved8 = q.move([0, 5], by: 0)
        #expect(moved8 == false)
        let moved9 = q.move([1, 2], by: 2)
        #expect(moved9)
        #expect(q.current?.id == current)
        var visited = [q.current!.id]
        while let t = q.next() { visited.append(t.id) }
        #expect(visited.count == 6)
        #expect(Set(visited).count == 6)
    }

    @Test func removeIndexSetAndCrop() {
        var q = queue(5)
        q.remove(at: IndexSet([0, 2]))
        #expect(titles(q) == ["t1", "t3", "t4"])
        var c = queue(5)
        c.select(2)
        c.crop(keeping: [1, 3])
        #expect(titles(c) == ["t1", "t3"])
        #expect(c.currentIndex != nil)
        var all = queue(3)
        all.crop(keeping: [])
        #expect(all.tracks.isEmpty)
        #expect(all.currentIndex == nil)
    }
}
