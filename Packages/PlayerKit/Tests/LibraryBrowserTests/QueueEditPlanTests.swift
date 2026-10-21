import MusicBackendKit
import Testing
@testable import LibraryBrowser

/// Which deletes and moves a selection becomes on a remote queue (#0145).
struct QueueEditPlanTests {
    static let output = OutputDevice.ID(rawValue: "speaker")

    static func snapshot(_ count: Int, current: Int? = nil) -> RemoteQueueSnapshot {
        RemoteQueueSnapshot(
            output: output, items: (0..<count).map { RemoteQueueItem(id: "qi\($0)", index: $0, title: "Song \($0)") },
            currentIndex: current)
    }

    @Test func removeSendsHighestIndexFirst() {
        let removal = QueueEditPlan.remove(selected: [1, 4, 2], in: Self.snapshot(5))
        #expect(removal.items.map(\.id) == ["qi4", "qi2", "qi1"])
        #expect(!removal.skippedCurrent)
    }

    @Test func cropRemovesTheComplementHighestFirst() {
        let removal = QueueEditPlan.crop(selected: [1, 3], in: Self.snapshot(5))
        #expect(removal.items.map(\.id) == ["qi4", "qi2", "qi0"])
        #expect(QueueEditPlan.crop(selected: [], in: Self.snapshot(5)).items.isEmpty)
    }

    @Test func currentRowIsExcluded() {
        let removal = QueueEditPlan.remove(selected: [1, 2], in: Self.snapshot(4, current: 2))
        #expect(removal.items.map(\.id) == ["qi1"])
        #expect(removal.skippedCurrent)
        let crop = QueueEditPlan.crop(selected: [0], in: Self.snapshot(3, current: 1))
        #expect(crop.items.map(\.id) == ["qi2"])
        #expect(!crop.skippedCurrent)
    }

    @Test func multiRowMoveIsRefused() {
        #expect(QueueEditPlan.move(selected: [1, 2], by: 1, in: Self.snapshot(5)) == .refusedMultiple)
        #expect(QueueEditPlan.move(selected: [1], by: 2, in: Self.snapshot(5)) == .move(itemID: "qi1", shift: 2))
        #expect(QueueEditPlan.move(selected: [4], by: 3, in: Self.snapshot(5)) == QueueEditPlan.Move.none)
        #expect(QueueEditPlan.move(selected: [1], by: -5, in: Self.snapshot(5)) == .move(itemID: "qi1", shift: -1))
    }

    @Test func applyShowsTheEditAndKeepsTheCurrentItem() {
        let first = RemoteQueueItem(id: "qi0", index: 0, title: "Song 0")
        let removed = QueueEditPlan.apply(.remove(items: [first]), to: Self.snapshot(3, current: 2))
        #expect(removed.items.map(\.id) == ["qi1", "qi2"])
        #expect(removed.items.map(\.index) == [0, 1])
        #expect(removed.currentIndex == 1)
        #expect(removed.total == 2)
        let moved = QueueEditPlan.apply(.move(itemID: "qi0", shift: 2), to: Self.snapshot(3, current: 1))
        #expect(moved.items.map(\.id) == ["qi1", "qi2", "qi0"])
        #expect(moved.currentIndex == 0)
        #expect(QueueEditPlan.apply(.clear, to: Self.snapshot(3, current: 1)).items.isEmpty)
    }
}
