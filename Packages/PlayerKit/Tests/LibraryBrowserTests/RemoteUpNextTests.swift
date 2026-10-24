import MusicBackendKit
import Testing
@testable import LibraryBrowser

/// Queue (Q) on a remote queue moves rows to after the current item (#0182).
struct RemoteUpNextTests {
    static func snapshot(current: Int? = 3) -> RemoteQueueSnapshot { QueueEditPlanTests.snapshot(10, current: current) }

    static func applying(_ edits: [QueueEdit], to snapshot: RemoteQueueSnapshot) -> RemoteQueueSnapshot {
        edits.reduce(snapshot) { QueueEditPlan.apply($1, to: $0) }
    }

    @Test func queuingARowBelowTheCurrentMovesItRightBehindIt() {
        var upNext = RemoteUpNext()
        #expect(upNext.plan(queueing: [7], in: Self.snapshot()) == [.move(itemID: "qi7", shift: -3)])
    }

    @Test func queuingARowAboveTheCurrentAccountsForTheShift() {
        var upNext = RemoteUpNext()
        let edits = upNext.plan(queueing: [1], in: Self.snapshot())
        #expect(edits == [.move(itemID: "qi1", shift: 2)])
        let after = Self.applying(edits, to: Self.snapshot())
        #expect(after.currentIndex == 2)
        #expect(after.items[3].id == "qi1")
    }

    @Test func successiveQueuesGoAfterThePreviouslyQueued() {
        var upNext = RemoteUpNext()
        let first = Self.applying(upNext.plan(queueing: [7], in: Self.snapshot()), to: Self.snapshot())
        let second = upNext.plan(queueing: [8], in: first)
        #expect(second == [.move(itemID: "qi8", shift: -3)])
        #expect(Self.applying(second, to: first).items[5].id == "qi8")
    }

    @Test func multipleRowsKeepTheChosenOrder() {
        var upNext = RemoteUpNext()
        let edits = upNext.plan(queueing: [8, 6], in: Self.snapshot())
        #expect(edits.count == 2)
        let ids = Self.applying(edits, to: Self.snapshot()).items.map(\.id)
        #expect(ids == ["qi0", "qi1", "qi2", "qi3", "qi8", "qi6", "qi4", "qi5", "qi7", "qi9"])
    }

    @Test func theCountResetsWhenTheCurrentItemChanges() {
        var upNext = RemoteUpNext()
        _ = upNext.plan(queueing: [7], in: Self.snapshot())
        #expect(upNext.count == 1)
        let moved = Self.snapshot(current: 5)
        upNext.sync(to: moved)
        #expect(upNext.count == 0)
        #expect(upNext.plan(queueing: [8], in: moved) == [.move(itemID: "qi8", shift: -2)])
    }

    @Test func theCurrentRowIsSkipped() {
        var upNext = RemoteUpNext()
        #expect(upNext.plan(queueing: [3], in: Self.snapshot()).isEmpty)
        #expect(upNext.count == 0)
    }

    @Test func aRowAlreadyInPlaceCountsWithoutAMove() {
        var upNext = RemoteUpNext()
        #expect(upNext.plan(queueing: [4], in: Self.snapshot()).isEmpty)
        #expect(upNext.plan(queueing: [7], in: Self.snapshot()) == [.move(itemID: "qi7", shift: -2)])
    }

    @Test func nothingPlayingPlansNothing() {
        var upNext = RemoteUpNext()
        #expect(upNext.plan(queueing: [7], in: Self.snapshot(current: nil)).isEmpty)
    }

    @Test func aRefusedMoveIsNotCounted() {
        var upNext = RemoteUpNext()
        let batch = upNext.batch(queueing: [7, 8], in: Self.snapshot())
        #expect(batch.counted == [2, 1])
        upNext.uncount(batch.counted[0], anchor: batch.anchorItemID)
        #expect(upNext.count == 0)
        #expect(upNext.plan(queueing: [8], in: Self.snapshot()) == [.move(itemID: "qi8", shift: -4)])
    }

    @Test func aRefusalRestoresTheSnapshotJustBeforeIt() {
        var upNext = RemoteUpNext()
        let batch = upNext.batch(queueing: [7, 8], in: Self.snapshot())
        #expect(batch.before.count == 2)
        #expect(batch.before[0] == Self.snapshot())
        #expect(batch.before[1] == Self.applying([batch.edits[0]], to: Self.snapshot()))
        #expect(batch.after == Self.applying(batch.edits, to: Self.snapshot()))
    }

    @Test func aRowInPlaceBeforeTheRefusalStillCounts() {
        var upNext = RemoteUpNext()
        let batch = upNext.batch(queueing: [4, 7], in: Self.snapshot())
        #expect(batch.edits == [.move(itemID: "qi7", shift: -2)])
        #expect(batch.counted == [1])
        upNext.uncount(batch.counted[0], anchor: batch.anchorItemID)
        #expect(upNext.count == 1)
        #expect(upNext.plan(queueing: [7], in: Self.snapshot()) == [.move(itemID: "qi7", shift: -2)])
    }

    @Test func uncountIgnoresAStaleAnchor() {
        var upNext = RemoteUpNext()
        let batch = upNext.batch(queueing: [7], in: Self.snapshot())
        upNext.sync(to: Self.snapshot(current: 5))
        _ = upNext.plan(queueing: [8], in: Self.snapshot(current: 5))
        upNext.uncount(batch.counted[0], anchor: batch.anchorItemID)
        #expect(upNext.count == 1)
    }
}
