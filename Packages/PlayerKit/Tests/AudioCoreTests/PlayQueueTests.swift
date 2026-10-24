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

extension PlayQueueTests {

    @Test func reorderRejectsNonPermutations() {
        var q = queue(3)
        q.select(1)
        let before = q
        let ok1 = q.reorder([0, 1])
        #expect(!ok1)
        let ok2 = q.reorder([0, 0, 1])
        #expect(!ok2)
        let ok3 = q.reorder([0, 1, 3])
        #expect(!ok3)
        let ok4 = q.reorder([0, 1, 2])
        #expect(!ok4)
        #expect(q == before)
        let ok5 = q.reorder([2, 0, 1])
        #expect(ok5)
        #expect(titles(q) == ["t2", "t0", "t1"])
    }

    @Test func sortByKeyIsStableAndFinderOrdered() {
        let names = ["t10", "c", "t2", "a", "B", "a"]
        var q = PlayQueue(tracks: names.enumerated().map {
            Track(title: $0.element, artist: "", duration: 1, source: .file(URL(filePath: "/tmp/\($0.offset).wav")))
        })
        let firstA = q.tracks[3].id, secondA = q.tracks[5].id
        let ok6 = q.sort { $0.title }
        #expect(ok6)
        #expect(titles(q) == ["a", "a", "B", "c", "t2", "t10"])
        #expect(q.tracks[0].id == firstA)
        #expect(q.tracks[1].id == secondA)
    }

    @Test func sortKeepsTheCurrentTrack() {
        var q = PlayQueue(tracks: makeTracks(4).reversed())
        q.select(1)
        let id = q.current?.id
        let ok7 = q.sort { $0.title }
        #expect(ok7)
        #expect(titles(q) == ["t0", "t1", "t2", "t3"])
        #expect(q.current?.id == id)
        #expect(q.currentIndex == 2)
    }

    @Test func reverseReversesAndKeepsTheCurrentTrack() {
        var q = queue(4)
        q.select(0)
        let ok8 = q.reverse()
        #expect(ok8)
        #expect(titles(q) == ["t3", "t2", "t1", "t0"])
        #expect(q.current?.title == "t0")
        #expect(q.currentIndex == 3)
    }

    @Test func randomizeIsASeededPermutation() {
        var a = queue(8), b = queue(8)
        a.select(3); b.select(3)
        var r1 = SplitMix64(seed: 42), r2 = SplitMix64(seed: 42)
        let ok9 = a.randomize(using: &r1)
        #expect(ok9)
        b.randomize(using: &r2)
        #expect(titles(a) == titles(b))
        #expect(Set(titles(a)) == Set(titles(queue(8))))
        #expect(a.current?.title == "t3")
    }

    @Test func reorderWhileShuffledKeepsThePlayOrder() {
        var rng = SplitMix64(seed: 7)
        var q = queue(6)
        q.select(0)
        q.setShuffle(true, using: &rng)
        q.repeatMode = .all
        var probe = q
        let expected = (0..<10).compactMap { _ in probe.next()?.id }
        let ok10 = q.sort { $0.title == "t0" ? "z" : $0.title }
        #expect(ok10) // moves t0 to the end
        q.reverse()
        let actual = (0..<10).compactMap { _ in q.next()?.id }
        #expect(actual.count == 10)
        #expect(Array(actual.prefix(5)) == Array(expected.prefix(5)))
    }

    @Test func reorderUpdatesIndexAfterCurrentEnds() {
        var q = queue(3)
        q.select(2)
        #expect(q.indexAfterCurrentEnds() == nil)
        q.reverse()
        #expect(q.currentIndex == 0)
        #expect(q.indexAfterCurrentEnds() == 1)
        #expect(q.tracks[1].title == "t1")
    }

    // MARK: Insert (#0183)

    @Test func insertPlacesTracksBeforeTheRowAndKeepsTheCurrentIdentity() {
        var q = queue(4)
        q.select(2)
        let currentID = q.current!.id
        q.insert(makeTracks(2, from: 10), at: 1)
        #expect(q.tracks.map(\.title) == ["t0", "t10", "t11", "t1", "t2", "t3"])
        #expect(q.currentIndex == 4)
        #expect(q.current?.id == currentID)
    }

    @Test func insertAtTheEndAppends() {
        var q = queue(2)
        q.select(0)
        q.insert(makeTracks(1, from: 5), at: 2)
        #expect(q.tracks.map(\.title) == ["t0", "t1", "t5"])
        #expect(q.currentIndex == 0)
    }

    @Test func insertClampsTheIndex() {
        var q = queue(2)
        q.insert(makeTracks(1, from: 5), at: -3)
        #expect(q.tracks.map(\.title) == ["t5", "t0", "t1"])
        q.insert(makeTracks(1, from: 6), at: 99)
        #expect(q.tracks.map(\.title) == ["t5", "t0", "t1", "t6"])
    }

    @Test func insertWhileShuffledKeepsTheShuffleBookkeepingAPermutation() {
        var q = queue(20)
        var rng = SplitMix64(seed: 3)
        q.select(0)
        q.setShuffle(true, using: &rng)
        var played: Set<Track.ID> = [q.current!.id]
        for _ in 0..<7 { played.insert(q.next()!.id) }
        let currentID = q.current!.id
        q.insert(makeTracks(3, from: 100), at: 5)
        #expect(q.current?.id == currentID)
        #expect(q.tracks[q.currentIndex!].id == currentID)
        var rest: [Track.ID] = []
        while let t = q.next() { rest.append(t.id) }
        let expected = Set(q.tracks.map(\.id)).subtracting(played)
        #expect(rest.count == expected.count)
        #expect(Set(rest) == expected)
        #expect(expected.count == 15)
    }

    @Test func insertKeepsUpNextByIdentity() {
        var q = queue(4)
        q.select(0)
        let queued = [q.tracks[3].id, q.tracks[1].id]
        q.appendUpNext(queued)
        q.insert(makeTracks(2, from: 10), at: 1)
        #expect(q.upNext == queued)
        #expect(q.indexAfterCurrentEnds() == 5)
        #expect(q.tracks[5].id == queued[0])
    }
}
