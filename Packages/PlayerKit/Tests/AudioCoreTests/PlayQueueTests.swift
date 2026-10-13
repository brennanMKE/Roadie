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
}
