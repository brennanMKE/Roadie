import Foundation
import Testing
@testable import AudioCore

/// The play-next queue (#0177). Rows t0–t5 stand for A–F.
@Suite struct UpNextTests {
    private func ids(_ q: PlayQueue, _ rows: Int...) -> [Track.ID] { rows.map { q.tracks[$0].id } }

    @Test func upNextPlaysBeforeListOrderAndEmpties() {
        var q = queue(6)
        q.select(1)
        q.appendUpNext(ids(q, 4, 2))
        #expect(q.advanceAfterTrackEnd()?.title == "t4")
        #expect(q.advanceAfterTrackEnd()?.title == "t2")
        #expect(q.upNext.isEmpty)
        #expect(q.advanceAfterTrackEnd()?.title == "t3")
    }

    @Test func upNextPositionIsOneBasedAndRenumbersOnRemoval() {
        var q = queue(6)
        let e = q.tracks[4].id, c = q.tracks[2].id, f = q.tracks[5].id
        q.appendUpNext([e, c, f])
        #expect(q.upNextPosition(of: e) == 1)
        #expect(q.upNextPosition(of: c) == 2)
        #expect(q.upNextPosition(of: f) == 3)
        q.remove(at: 2)
        #expect(q.upNextPosition(of: e) == 1)
        #expect(q.upNextPosition(of: f) == 2)
        #expect(q.upNextPosition(of: c) == nil)
    }

    @Test func toggleUpNextAppendsTheUnqueuedOrDequeuesWhenAllAreQueued() {
        var q = queue(6)
        q.appendUpNext(ids(q, 2))
        q.toggleUpNext(ids(q, 4, 2, 3))
        #expect(q.upNext == ids(q, 2, 4, 3))
        q.toggleUpNext(ids(q, 2, 4))
        #expect(q.upNext == ids(q, 3))
        q.toggleUpNext([])
        #expect(q.upNext == ids(q, 3))
    }

    @Test func prependUpNextPutsIdsAtTheFrontInOrder() {
        var q = queue(6)
        q.appendUpNext(ids(q, 4))
        q.prependUpNext(ids(q, 2, 3))
        #expect(q.upNext == ids(q, 2, 3, 4))
        q.prependUpNext(ids(q, 4))
        #expect(q.upNext == ids(q, 4, 2, 3))
    }

    @Test func unknownIdsAreIgnored() {
        var q = queue(3)
        let stranger = UUID()
        q.appendUpNext([stranger])
        q.prependUpNext([stranger])
        q.toggleUpNext([stranger])
        #expect(q.upNext.isEmpty)
        q.appendUpNext([stranger] + ids(q, 1))
        #expect(q.upNext == ids(q, 1))
    }

    @Test func cropAndRemoveAllDropRemovedIdsFromUpNext() {
        var q = queue(6)
        q.appendUpNext(ids(q, 1, 3, 5))
        let keep = q.tracks[3].id
        q.crop(keeping: [0, 3])
        #expect(q.upNext == [keep])
        q.removeAll()
        #expect(q.upNext.isEmpty)
    }

    @Test func indexAfterCurrentEndsReturnsTheQueuedEntry() {
        var q = queue(6)
        q.select(0)
        q.appendUpNext(ids(q, 4))
        #expect(q.indexAfterCurrentEnds() == 4)
        #expect(q.upNext.count == 1)   // peeking doesn't dequeue
    }

    @Test func repeatOneRepeatsAtTrackEndButNextHonorsUpNext() {
        var q = queue(6)
        q.select(1)
        q.repeatMode = .one
        q.appendUpNext(ids(q, 4))
        #expect(q.indexAfterCurrentEnds() == 1)
        #expect(q.next()?.title == "t4")
        #expect(q.upNext.isEmpty)
    }

    @Test func repeatAllWrapsAfterAQueuedLastRow() {
        var q = queue(6)
        q.repeatMode = .all
        q.select(2)
        q.appendUpNext(ids(q, 5))
        #expect(q.advanceAfterTrackEnd()?.title == "t5")
        #expect(q.advanceAfterTrackEnd()?.title == "t0")
    }

    @Test func afterTheQueueShuffledResumesFromWhereTheQueueBegan() throws {
        var q = queue(8)
        var rng = SplitMix64(seed: 21)
        q.select(0)
        q.setShuffle(true, using: &rng)
        q.next()
        q.next()
        var peek = q
        let expected = try #require(peek.next()?.id)
        let current = try #require(q.currentIndex)
        let queued = Array(q.tracks.indices.filter { $0 != current && q.tracks[$0].id != expected }.prefix(2))
        q.appendUpNext(queued.map { q.tracks[$0].id })
        #expect(q.advanceAfterTrackEnd()?.id == q.tracks[queued[0]].id)
        #expect(q.advanceAfterTrackEnd()?.id == q.tracks[queued[1]].id)
        #expect(q.advanceAfterTrackEnd()?.id == expected)
    }

    @Test func shuffleBookkeepingStaysAPermutationThroughTheQueue() {
        var q = queue(10)
        var rng = SplitMix64(seed: 77)
        q.repeatMode = .all
        q.select(0)
        q.setShuffle(true, using: &rng)
        for _ in 0..<50 {
            let row = Int.random(in: 0..<q.tracks.count, using: &rng)
            switch Int.random(in: 0..<7, using: &rng) {
            case 0: q.appendUpNext([q.tracks[row].id])
            case 1: q.advanceAfterTrackEnd()
            case 2: q.next()
            case 3: q.previous()
            case 4 where q.tracks.count > 3: q.remove(at: row)
            case 5: q.move([row], by: Int.random(in: -2...2, using: &rng))
            default: q.prependUpNext([q.tracks[row].id])
            }
            let known = Set(q.tracks.map(\.id))
            #expect(q.upNext.allSatisfy { known.contains($0) })
            #expect(q.currentIndex.map { q.tracks.indices.contains($0) } ?? true)
            var probe = q
            for _ in 0..<q.tracks.count {
                if let i = probe.indexAfterCurrentEnds() { #expect(probe.tracks.indices.contains(i)) }
                #expect(probe.next() != nil)   // repeat all never runs out
            }
        }
    }

    @Test func previousIgnoresUpNext() throws {
        var q = queue(6)
        q.select(1)
        q.appendUpNext(ids(q, 4))
        q.next()
        #expect(q.current?.title == "t4")
        #expect(q.previous()?.title == "t3")

        var s = queue(8)
        var rng = SplitMix64(seed: 5)
        s.select(0)
        s.setShuffle(true, using: &rng)
        s.next()
        let anchor = try #require(s.current?.id)
        let other = try #require(s.tracks.first { $0.id != anchor }?.id)
        s.appendUpNext([other])
        #expect(s.next()?.id == other)
        #expect(s.previous()?.id == anchor)
    }

    @Test func selectingAQueuedRowDequeuesIt() {
        var q = queue(6)
        q.appendUpNext(ids(q, 2, 4))
        q.select(4)
        #expect(q.upNext == ids(q, 2))
    }

    @Test func removingTheCurrentEntryPlaysTheHeadOfUpNext() {
        var q = queue(6)
        q.select(1)
        let five = q.tracks[5].id
        q.appendUpNext(ids(q, 4, 5))
        q.remove(at: 1)
        #expect(q.current?.title == "t4")
        #expect(q.upNext == [five])
        #expect(q.advanceAfterTrackEnd()?.title == "t5")
    }

    @Test func removingAQueuedCurrentWhileShuffledDoesNotReplayTheAnchor() throws {
        var q = queue(8)
        var rng = SplitMix64(seed: 13)
        q.select(0)
        q.setShuffle(true, using: &rng)
        q.next()
        let anchor = try #require(q.current?.id)
        var peek = q
        let after = try #require(peek.next()?.id)
        let other = try #require(q.tracks.first { $0.id != anchor && $0.id != after }?.id)
        q.appendUpNext([other])
        q.next()
        #expect(q.current?.id == other)
        q.remove(at: try #require(q.currentIndex))
        #expect(q.current?.id != anchor)
        #expect(q.current?.id == after)
    }

    @Test func reorderKeepsUpNextByIdentity() {
        var q = queue(6)
        let first = q.tracks[4].id
        q.appendUpNext(ids(q, 4, 1))
        let before = q.upNext
        q.move([4], by: -3)
        #expect(q.upNext == before)
        q.reverse()
        #expect(q.upNext == before)
        q.sort { $0.title }
        #expect(q.upNext == before)
        #expect(q.upNextPosition(of: first) == 1)
    }

    @Test func theCurrentEntryMayBeQueued() {
        var q = queue(6)
        q.select(2)
        q.appendUpNext(ids(q, 2))
        #expect(q.indexAfterCurrentEnds() == 2)
        #expect(q.advanceAfterTrackEnd()?.title == "t2")
        #expect(q.advanceAfterTrackEnd()?.title == "t3")
    }
}
