import Foundation
import MusicBackendKit
import os
import Testing
@testable import LibraryBrowser

private func row(_ id: String, enabled: Bool = true) -> RecommendationRow {
    RecommendationRow(provider: "recommendations", itemID: id, name: id, isEnabledByDefault: enabled)
}

private func item(_ name: String) -> RecommendationItem {
    .other(uri: "library://track/\(name)", kind: .track, name: name, subtitle: nil, artwork: nil)
}

struct DiscoverRowsTests {
    let rows = [row("a"), row("b", enabled: false), row("c"), row("d", enabled: false)]

    @Test func hiddenByDefault() {
        #expect(DiscoverRows.visible(rows, showAll: false).map(\.itemID) == ["a", "c"])
        #expect(DiscoverRows.hiddenCount(rows) == 2)
    }

    @Test func showAll() {
        #expect(DiscoverRows.visible(rows, showAll: true).count == 4)
    }

    @Test func orderPreserved() {
        let reversed = Array(rows.reversed())
        #expect(DiscoverRows.visible(reversed, showAll: true).map(\.itemID) == ["d", "c", "b", "a"])
        #expect(DiscoverRows.visible(reversed, showAll: false).map(\.itemID) == ["c", "a"])
    }
}

struct MDIIconTests {
    @Test func unknownIconFallsBack() {
        #expect(MDIIcon.symbol("mdi-album") == "square.stack")
        #expect(MDIIcon.symbol("motion-play") == "play.circle")
        #expect(MDIIcon.symbol("mdi-not-a-real-icon") == MDIIcon.fallback)
        #expect(MDIIcon.symbol(nil) == MDIIcon.fallback)
        #expect(MDIIcon.symbol("") == MDIIcon.fallback)
    }
}

/// Item loads the test answers by hand: each call waits until `answer` resolves it.
private final class ItemGate: @unchecked Sendable {
    private struct Pending { var rowID: String; var continuation: CheckedContinuation<[RecommendationItem], any Error> }
    private let state = OSAllocatedUnfairLock(initialState: (pending: [Pending](), calls: [String]()))

    func load(_ row: RecommendationRow) async throws -> [RecommendationItem] {
        try await withCheckedThrowingContinuation { continuation in
            state.withLock {
                $0.pending.append(Pending(rowID: row.id, continuation: continuation))
                $0.calls.append(row.id)
            }
        }
    }

    var calls: [String] { state.withLock { $0.calls } }
    var pendingCount: Int { state.withLock { $0.pending.count } }

    /// Resolves the oldest pending call for `rowID`.
    func answer(_ rowID: String, with result: Result<[RecommendationItem], any Error>) {
        let pending: Pending? = state.withLock { state in
            guard let index = state.pending.firstIndex(where: { $0.rowID == rowID }) else { return nil }
            return state.pending.remove(at: index)
        }
        pending?.continuation.resume(with: result)
    }
}

@MainActor
struct DiscoverModelTests {
    let rows = [row("a"), row("b"), row("c", enabled: false)]

    private func makeModel(_ gate: ItemGate, delay: Duration = .milliseconds(1500)) -> DiscoverModel {
        let rows = rows
        return DiscoverModel(rows: { rows }, items: { try await gate.load($0) }, defaults: nil, refreshDelay: delay)
    }

    @Test func rowFailureLeavesOthersLoaded() async {
        let gate = ItemGate()
        let model = makeModel(gate)
        model.loadRowsIfNeeded()
        #expect(await waitFor { model.visibleRows.count == 2 })
        #expect(model.showAll == false)
        for row in rows { model.loadItemsIfNeeded(row) }
        #expect(await waitFor { gate.pendingCount == 3 })
        gate.answer("recommendations/a", with: .success([item("x")]))
        gate.answer("recommendations/b", with: .failure(MusicBackendError.backend("nope")))
        gate.answer("recommendations/c", with: .success([]))
        #expect(await waitFor { model.state(of: "recommendations/c") == .loaded([]) })
        #expect(model.state(of: "recommendations/a") == .loaded([item("x")]))
        #expect(model.state(of: "recommendations/b") == .failed("nope"))

        // Retrying the failed row touches no other.
        model.loadItemsIfNeeded(rows[1])
        #expect(await waitFor { gate.pendingCount == 1 })
        gate.answer("recommendations/b", with: .success([item("y")]))
        #expect(await waitFor { model.state(of: "recommendations/b") == .loaded([item("y")]) })
        #expect(model.state(of: "recommendations/a") == .loaded([item("x")]))
        #expect(gate.calls.count == 4)
    }

    @Test func staleRowResultDropped() async {
        let gate = ItemGate()
        let model = makeModel(gate)
        model.loadRowsIfNeeded()
        #expect(await waitFor { model.visibleRows.count == 2 })
        model.refresh(rows[0])
        #expect(await waitFor { gate.pendingCount == 1 })
        model.refresh(rows[0])
        #expect(await waitFor { gate.pendingCount == 2 })
        // The replaced request answers first; its result is dropped.
        gate.answer("recommendations/a", with: .success([item("old")]))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.state(of: "recommendations/a") == .loading)
        gate.answer("recommendations/a", with: .success([item("new")]))
        #expect(await waitFor { model.state(of: "recommendations/a") == .loaded([item("new")]) })
    }

    @Test func playedRefreshIsDebounced() async {
        let gate = ItemGate()
        let model = makeModel(gate, delay: .milliseconds(100))
        model.loadRowsIfNeeded()
        #expect(await waitFor { model.visibleRows.count == 2 })
        model.loadItemsIfNeeded(rows[0])
        #expect(await waitFor { gate.pendingCount == 1 })
        gate.answer("recommendations/a", with: .success([item("x")]))
        #expect(await waitFor { model.state(of: "recommendations/a") == .loaded([item("x")]) })

        for _ in 0..<5 {
            model.scheduleRefresh()
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await waitFor { gate.pendingCount == 1 })
        try? await Task.sleep(for: .milliseconds(300))
        // One refresh for the burst, only for the row that had items; the row keeps its items meanwhile.
        #expect(gate.calls == ["recommendations/a", "recommendations/a"])
        #expect(model.state(of: "recommendations/a") == .loaded([item("x")]))
        gate.answer("recommendations/a", with: .success([item("z")]))
        #expect(await waitFor { model.state(of: "recommendations/a") == .loaded([item("z")]) })
    }
}
