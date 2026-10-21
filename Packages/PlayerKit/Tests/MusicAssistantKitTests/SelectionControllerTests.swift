import Foundation
import Testing
@testable import MusicAssistantKit

@MainActor
final class SelectionRig {
    let suite = "ma-selection-" + UUID().uuidString
    let defaults: UserDefaults
    let store: MusicAssistantServerStore
    let active = MusicAssistantActiveServer()
    let fake = FakeInfo()
    let clock = ManualClock()
    let wifi: StubWiFi
    let network = StubNetworkChanges()
    let controller: MusicAssistantSelectionController
    var changes: [(MusicAssistantServerConfiguration?, MusicAssistantServerConfiguration?)] = []

    init(_ servers: [MusicAssistantServerConfiguration], wifi: StubWiFi = StubWiFi()) {
        defaults = UserDefaults(suiteName: suite)!
        store = MusicAssistantServerStore(defaults: defaults)
        store.save(servers)
        self.wifi = wifi
        controller = MusicAssistantSelectionController(
            store: store, active: active, selector: MusicAssistantServerSelector(fetch: fake.fetcher, clock: clock),
            wifi: wifi, network: network, clock: clock)
        controller.onChange = { [unowned self] old, new in changes.append((old, new)) }
    }

    func cleanUp() {
        controller.stop()
        defaults.removePersistentDomain(forName: suite)
    }

    /// Sends `count` network changes and waits until the controller has seen them and armed its debounce.
    func networkChanges(_ count: Int = 1) async -> Bool {
        let before = controller.networkChangesSeen
        for _ in 0..<count { network.change() }
        return await pollUntil { self.controller.networkChangesSeen == before + count }
    }
}

@MainActor
struct SelectionControllerTests {
    private let a = makeServer("http://a.local:8095", id: "id-a", name: "A")
    private let b = makeServer("http://b.local:8095", id: "id-b", name: "B")

    @Test func startDoesNoIO() async throws {
        let rig = SelectionRig([a, b])
        defer { rig.cleanUp() }
        rig.controller.start()
        try await Task.sleep(for: .milliseconds(20))
        #expect(rig.fake.calls.isEmpty)
        #expect(rig.wifi.ssidCalls == 0)
        #expect(rig.wifi.authorizationRequests == 0)
        #expect(rig.controller.resolutionCount == 0)
        #expect(rig.controller.reasonText == MusicAssistantServerRanking.notCheckedText)
        #expect(rig.controller.statusText == nil)
    }

    @Test func networkChangeBeforeFirstUseDoesNothing() async throws {
        let rig = SelectionRig([a])
        defer { rig.cleanUp() }
        rig.controller.start()
        #expect(await rig.networkChanges())
        try await Task.sleep(for: .milliseconds(20))
        #expect(rig.clock.sleeperCount == 0)
        rig.clock.advance(by: .seconds(5))
        await rig.controller.waitForPending()
        #expect(rig.controller.resolutionCount == 0)
        #expect(rig.fake.calls.isEmpty)
    }

    @Test func networkChangesAreDebounced() async throws {
        let rig = SelectionRig([a])
        defer { rig.cleanUp() }
        rig.fake.set("http://a.local:8095", .answer("id-a"))
        rig.controller.start()
        await rig.controller.resolveNow()
        #expect(rig.controller.resolutionCount == 1)
        #expect(await rig.networkChanges(3))
        #expect(await pollUntil { rig.clock.sleeperCount == 1 })
        rig.clock.advance(by: .seconds(1))
        try await Task.sleep(for: .milliseconds(20))
        #expect(rig.controller.resolutionCount == 1)
        rig.clock.advance(by: .seconds(1))
        await rig.controller.waitForPending()
        #expect(rig.controller.resolutionCount == 2)
        #expect(rig.fake.calls.count == 2)
    }

    @Test func currentOrResolveIsCachedUntilInvalidated() async {
        let rig = SelectionRig([a])
        defer { rig.cleanUp() }
        rig.fake.set("http://a.local:8095", .answer("id-a"))
        #expect(await rig.controller.currentOrResolve()?.id == a.id)
        #expect(await rig.controller.currentOrResolve()?.id == a.id)
        #expect(rig.fake.calls.count == 1)
        rig.controller.serversChanged()
        await rig.controller.waitForPending()
        #expect(rig.fake.calls.count == 2)
        #expect(await rig.controller.currentOrResolve()?.id == a.id)
        #expect(rig.fake.calls.count == 2)
    }

    @Test func ssidIsReadOnlyWhenAuthorized() async {
        let home = makeServer("http://a.local:8095", id: "id-a", name: "A", networks: ["X"])
        let denied = SelectionRig([b, home], wifi: StubWiFi(.denied, ssid: "X"))
        defer { denied.cleanUp() }
        denied.fake.set("http://a.local:8095", .answer("id-a"))
        denied.fake.set("http://b.local:8095", .answer("id-b"))
        await denied.controller.resolveNow()
        #expect(denied.wifi.ssidCalls == 0)
        #expect(denied.controller.current?.server.id == b.id)
        #expect(denied.controller.current?.basis == .listOrder)

        let allowed = SelectionRig([b, home], wifi: StubWiFi(.authorized, ssid: "X"))
        defer { allowed.cleanUp() }
        allowed.fake.set("http://a.local:8095", .answer("id-a"))
        allowed.fake.set("http://b.local:8095", .answer("id-b"))
        await allowed.controller.resolveNow()
        #expect(allowed.wifi.ssidCalls == 1)
        #expect(allowed.wifi.authorizationRequests == 0)
        #expect(allowed.controller.current?.server.id == home.id)
        #expect(allowed.controller.reasonText == "A \u{2014} on network X")
    }

    @Test func winnerChangeCallsOnChangeOnceWithOldAndNew() async {
        let rig = SelectionRig([a, b])
        defer { rig.cleanUp() }
        rig.fake.set("http://a.local:8095", .answer("id-a"))
        rig.fake.set("http://b.local:8095", .answer("id-b"))
        await rig.controller.resolveNow()
        #expect(rig.changes.count == 1)
        #expect(rig.changes[0].0 == nil && rig.changes[0].1?.id == a.id)
        rig.fake.set("http://a.local:8095", .fail)
        rig.controller.activeServerDropped()
        await rig.controller.waitForPending()
        #expect(rig.changes.count == 2)
        #expect(rig.changes[1].0?.id == a.id && rig.changes[1].1?.id == b.id)
    }

    @Test func sameWinnerAfterANetworkChangeDoesNotCallOnChange() async {
        let rig = SelectionRig([a])
        defer { rig.cleanUp() }
        rig.fake.set("http://a.local:8095", .answer("id-a"))
        rig.controller.start()
        await rig.controller.resolveNow()
        #expect(await rig.networkChanges())
        #expect(await pollUntil { rig.clock.sleeperCount == 1 })
        rig.clock.advance(by: .seconds(2))
        await rig.controller.waitForPending()
        #expect(rig.controller.resolutionCount == 2)
        #expect(rig.changes.count == 1)
    }

    @Test func stickyCurrentServer() async {
        let rig = SelectionRig([a, b])
        defer { rig.cleanUp() }
        rig.fake.set("http://a.local:8095", .fail)
        rig.fake.set("http://b.local:8095", .answer("id-b"))
        await rig.controller.resolveNow()
        #expect(rig.controller.current?.server.id == b.id)
        await rig.controller.resolveNow()
        #expect(rig.controller.current?.server.id == b.id)
        #expect(rig.changes.count == 1)
        #expect(rig.controller.lastOutcomes == [a.id: .unreachable, b.id: .reachable])
    }

    @Test func noneReachableSetsActiveNilAndReason() async {
        let rig = SelectionRig([a])
        defer { rig.cleanUp() }
        rig.fake.set("http://a.local:8095", .answer("id-a"))
        await rig.controller.resolveNow()
        #expect(rig.active.current?.id == a.id)
        rig.fake.set("http://a.local:8095", .fail)
        #expect(await rig.controller.resolveNow() == nil)
        #expect(rig.active.current == nil)
        #expect(rig.controller.reasonText == "No Music Assistant server reachable")
        #expect(rig.changes.last?.1 == nil)

        let empty = SelectionRig([makeServer(id: nil, name: "Untested")])
        defer { empty.cleanUp() }
        #expect(await empty.controller.resolveNow() == nil)
        #expect(empty.controller.reasonText == "No Music Assistant server tested yet")
        #expect(empty.fake.calls.isEmpty)
        #expect(empty.changes.isEmpty)
    }

    @Test func droppedServerResolvesWithoutDebounce() async {
        let rig = SelectionRig([a])
        defer { rig.cleanUp() }
        rig.fake.set("http://a.local:8095", .answer("id-a"))
        rig.controller.activeServerDropped()
        await rig.controller.waitForPending()
        #expect(rig.controller.resolutionCount == 1)
        #expect(rig.controller.current?.server.id == a.id)
    }

    @Test func serversChangedReResolvesOnlyAfterFirstUse() async {
        let rig = SelectionRig([a])
        defer { rig.cleanUp() }
        rig.fake.set("http://a.local:8095", .answer("id-a"))
        rig.controller.serversChanged()
        await rig.controller.waitForPending()
        #expect(rig.controller.resolutionCount == 0)
        await rig.controller.resolveNow()
        rig.controller.serversChanged()
        await rig.controller.waitForPending()
        #expect(rig.controller.resolutionCount == 2)
    }

    @Test func activeBoxFollowsTheDecision() async {
        let rig = SelectionRig([a, b])
        defer { rig.cleanUp() }
        rig.fake.set("http://a.local:8095", .fail)
        rig.fake.set("http://b.local:8095", .answer("id-b"))
        await rig.controller.resolveNow()
        #expect(rig.active.current == b)
        rig.fake.set("http://a.local:8095", .answer("id-a"))
        await rig.controller.resolveNow()
        #expect(rig.active.current == a)
        #expect(rig.controller.reasonText == "A \u{2014} first reachable")
    }

    // MARK: Renames (#0092)

    private func renamed(_ server: MusicAssistantServerConfiguration, _ name: String) -> MusicAssistantServerConfiguration {
        var copy = server
        copy.name = name
        return copy
    }

    @Test func renameAfterFirstUseRelabelsWithoutProbing() async {
        let rig = SelectionRig([a])
        defer { rig.cleanUp() }
        rig.fake.set("http://a.local:8095", .answer("id-a"))
        await rig.controller.resolveNow()
        rig.changes.removeAll()
        for name in ["At", "Att", "Attic"] {
            rig.store.save([renamed(a, name)])
            rig.controller.serversEdited()
        }
        await rig.controller.waitForPending()
        #expect(rig.fake.calls.count == 1)
        #expect(rig.controller.resolutionCount == 1)
        #expect(rig.controller.current?.server.name == "Attic")
        #expect(rig.controller.reasonText == "Attic \u{2014} first reachable")
        #expect(rig.active.current?.name == "Attic")
        #expect(rig.changes.isEmpty)
        #expect(await rig.controller.currentOrResolve()?.name == "Attic")
        #expect(rig.fake.calls.count == 1)
    }

    @Test func libraryNameFollowsTheWinner() async {
        let rig = SelectionRig([a, b])
        defer { rig.cleanUp() }
        rig.fake.set("http://a.local:8095", .answer("id-a"))
        await rig.controller.resolveNow()
        #expect(rig.controller.libraryName == "A")
        #expect(rig.controller.reasonText == "A \u{2014} first reachable")
        rig.store.save([renamed(a, "Attic"), b])
        rig.controller.serversEdited()
        await rig.controller.waitForPending()
        #expect(rig.controller.libraryName == "Attic")

        let single = SelectionRig([a])
        defer { single.cleanUp() }
        single.fake.set("http://a.local:8095", .answer("id-a"))
        await single.controller.resolveNow()
        #expect(single.controller.current?.server.name == "A")
        #expect(single.controller.libraryName == nil)
    }

    @Test func renameBeforeFirstUseDoesNothing() async {
        let rig = SelectionRig([a])
        defer { rig.cleanUp() }
        rig.store.save([renamed(a, "Attic")])
        rig.controller.serversEdited()
        await rig.controller.waitForPending()
        #expect(rig.fake.calls.isEmpty)
        #expect(rig.controller.resolutionCount == 0)
        #expect(rig.controller.statusText == nil)
    }

    @Test func nonNameEditStillReResolves() async {
        let rig = SelectionRig([a, b])
        defer { rig.cleanUp() }
        rig.fake.set("http://a.local:8095", .answer("id-a"))
        rig.fake.set("http://b.local:8095", .answer("id-b"))
        await rig.controller.resolveNow()
        var tied = a
        tied.networks = ["X"]
        rig.store.save([tied, b])
        rig.controller.serversEdited()
        await rig.controller.waitForPending()
        #expect(rig.controller.resolutionCount == 2)
        rig.store.save([b, tied])
        rig.controller.serversEdited()
        await rig.controller.waitForPending()
        #expect(rig.controller.resolutionCount == 3)
    }

    @Test func renameDuringAProbeEndsWithTheNewName() async {
        let rig = SelectionRig([a])
        defer { rig.cleanUp() }
        rig.fake.set("http://a.local:8095", .answer("id-a"))
        await rig.controller.resolveNow()
        rig.fake.set("http://a.local:8095", .gated("id-a"))
        rig.controller.activeServerDropped()
        #expect(await pollUntil { rig.controller.isResolving })
        rig.store.save([renamed(a, "Attic")])
        rig.controller.serversEdited()
        rig.fake.release()
        await rig.controller.waitForPending()
        #expect(rig.controller.reasonText == "Attic \u{2014} first reachable")
        #expect(rig.controller.current?.server.name == "Attic")
    }

    @Test func renameKeepsAPendingNetworkRecheck() async {
        let rig = SelectionRig([a])
        defer { rig.cleanUp() }
        rig.fake.set("http://a.local:8095", .answer("id-a"))
        rig.controller.start()
        await rig.controller.resolveNow()
        #expect(await rig.networkChanges())
        #expect(await pollUntil { rig.clock.sleeperCount == 1 })
        rig.store.save([renamed(a, "Attic")])
        rig.controller.serversEdited()
        rig.clock.advance(by: .seconds(2))
        await rig.controller.waitForPending()
        #expect(rig.controller.resolutionCount == 2)
    }

    @Test func statusTextIsNilUntilTheFirstDecision() async {
        let rig = SelectionRig([a])
        defer { rig.cleanUp() }
        #expect(rig.controller.statusText == nil)
        rig.fake.set("http://a.local:8095", .gated("id-a"))
        let task = Task { await rig.controller.resolveNow() }
        #expect(await pollUntil { rig.controller.isResolving })
        #expect(rig.controller.statusText == MusicAssistantServerRanking.checkingText)
        rig.fake.release()
        _ = await task.value
        #expect(rig.controller.statusText == rig.controller.reasonText)
        #expect(rig.controller.statusText == "A \u{2014} first reachable")
    }
}
