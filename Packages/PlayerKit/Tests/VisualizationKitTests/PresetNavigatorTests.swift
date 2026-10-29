import Foundation
import Testing
@testable import VisualizationKit

struct PresetNavigatorTests {
    private func presets(_ count: Int) -> [VisualizationPreset] {
        (0..<count).map { i in
            .milk(url: URL(fileURLWithPath: "/tmp/p\(i).milk"), relativePath: "p\(i).milk", source: .user)
        }
    }

    private func navigator(_ count: Int, order: PresetNavigator.Order = .sequential, locked: Bool = false,
                           start: String? = nil, seed: UInt64 = 1) -> PresetNavigator {
        PresetNavigator(presets: presets(count), order: order, isLocked: locked, startingAt: start, seed: seed)
    }

    @Test func sequentialNextWrapsInListOrder() {
        var nav = navigator(3)
        #expect(nav.current?.id == "user:p0.milk")
        do { let moved = nav.next(); #expect(moved?.id == "user:p1.milk") }
        do { let moved = nav.next(); #expect(moved?.id == "user:p2.milk") }
        do { let moved = nav.next(); #expect(moved?.id == "user:p0.milk") }
    }

    @Test func previousWithEmptyHistoryStepsBackInListOrder() {
        var nav = navigator(3)
        do { let moved = nav.previous(); #expect(moved?.id == "user:p2.milk") }
        do { let moved = nav.previous(); #expect(moved?.id == "user:p1.milk") }
        do { let moved = nav.previous(); #expect(moved?.id == "user:p0.milk") }
    }

    @Test func previousThenNextReplaysForwardHistory() {
        var nav = navigator(5, order: .random, seed: 3)
        let start = nav.current?.id
        let first = nav.next()?.id
        let second = nav.next()?.id
        do { let moved = nav.previous(); #expect(moved?.id == first) }
        do { let moved = nav.previous(); #expect(moved?.id == start) }
        do { let moved = nav.next(); #expect(moved?.id == first) }
        do { let moved = nav.next(); #expect(moved?.id == second) }
    }

    @Test func randomNeverRepeatsCurrentOrRecent() throws {
        var nav = navigator(20, order: .random, seed: 1)
        var shown = [nav.current!.id]
        for _ in 0..<500 {
            let moved = nav.next()
            let id = try #require(moved).id
            #expect(!shown.suffix(min(8, 10)).contains(id))
            shown.append(id)
        }
    }

    @Test func randomIsDeterministicForASeed() {
        var a = navigator(30, order: .random, seed: 7)
        var b = navigator(30, order: .random, seed: 7)
        let idsA = (0..<50).compactMap { _ in a.next()?.id }
        let idsB = (0..<50).compactMap { _ in b.next()?.id }
        #expect(idsA.count == 50)
        #expect(idsA == idsB)
    }

    @Test func lockStopsOnlyAutomaticChanges() {
        var nav = navigator(3, locked: true)
        do { let moved = nav.advanceAutomatically(); #expect(moved == nil) }
        #expect(nav.current?.id == "user:p0.milk")
        do { let moved = nav.next(); #expect(moved?.id == "user:p1.milk") }
        nav.isLocked = false
        do { let moved = nav.advanceAutomatically(); #expect(moved?.id == "user:p2.milk") }
    }

    @Test func selectClearsForwardHistory() {
        var nav = navigator(5)
        _ = nav.next()   // p1
        _ = nav.next()   // p2
        _ = nav.previous()   // p1, forward = [p2]
        do { let moved = nav.select(id: "user:p4.milk"); #expect(moved?.id == "user:p4.milk") }
        // Forward history is gone: next goes by order (wraps to p0), not back to p2.
        do { let moved = nav.next(); #expect(moved?.id == "user:p0.milk") }
        do { let moved = nav.previous(); #expect(moved?.id == "user:p4.milk") }
        do { let moved = nav.previous(); #expect(moved?.id == "user:p1.milk") }
    }

    @Test func failedPresetsAreSkipped() {
        var nav = navigator(4)
        nav.markFailed(id: "user:p1.milk")
        do { let moved = nav.next(); #expect(moved?.id == "user:p2.milk") }
        do { let moved = nav.select(id: "user:p1.milk"); #expect(moved == nil) }
        #expect(nav.usable.count == 3)
        do { let moved = nav.previous(); #expect(moved?.id == "user:p0.milk") }
        do { let moved = nav.previous(); #expect(moved?.id == "user:p3.milk") }
    }

    @Test func replaceKeepsCurrentAndPrunesHistory() {
        var nav = navigator(4)
        _ = nav.next()   // p1, back = [p0]
        _ = nav.next()   // p2, back = [p0, p1]
        let all = presets(4)
        nav.replacePresets(all.filter { $0.id != "user:p1.milk" })
        #expect(nav.current?.id == "user:p2.milk")
        do { let moved = nav.previous(); #expect(moved?.id == "user:p0.milk") }   // p1 pruned from history

        nav.replacePresets([all[2], all[3]])   // current p0 removed
        #expect(nav.current?.id == "user:p2.milk")
        #expect(nav.presets.count == 2)
    }

    @Test func singlePresetHasNowhereToGo() {
        var one = navigator(1)
        do { let moved = one.next(); #expect(moved == nil) }
        do { let moved = one.previous(); #expect(moved == nil) }

        var two = navigator(2)
        two.markFailed(id: "user:p1.milk")
        do { let moved = two.next(); #expect(moved == nil) }
        do { let moved = two.previous(); #expect(moved == nil) }
        #expect(two.current?.id == "user:p0.milk")
    }

    @Test func startsAtTheRememberedPresetOrTheFirst() {
        #expect(navigator(4, start: "user:p2.milk").current?.id == "user:p2.milk")
        #expect(navigator(4, start: "user:gone.milk").current?.id == "user:p0.milk")
        #expect(navigator(4, start: nil).current?.id == "user:p0.milk")
    }
}
