import Foundation
import os
import Testing
@testable import MusicAssistantKit

/// Bonjour on demand: the test yields hosts and counts browses started and terminated.
final class StubServiceBrowser: MusicAssistantServiceBrowser, @unchecked Sendable {
    private struct State {
        var continuations: [AsyncStream<MusicAssistantDiscoveredHost>.Continuation] = []
        var started = 0
        var terminated = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    var started: Int { state.withLock { $0.started } }
    var terminated: Int { state.withLock { $0.terminated } }

    func hosts() -> AsyncStream<MusicAssistantDiscoveredHost> {
        let (stream, continuation) = AsyncStream<MusicAssistantDiscoveredHost>.makeStream()
        continuation.onTermination = { [self] _ in state.withLock { $0.terminated += 1 } }
        state.withLock {
            $0.started += 1
            $0.continuations.append(continuation)
        }
        return stream
    }

    func yield(_ host: String, port: Int? = nil) {
        for continuation in state.withLock({ $0.continuations }) {
            continuation.yield(MusicAssistantDiscoveredHost(host: host, port: port))
        }
    }
}

private func discovered(_ host: String, port: Int? = nil) -> String? {
    MusicAssistantDiscovery.baseURL(for: MusicAssistantDiscoveredHost(host: host, port: port))?.absoluteString
}

struct DiscoveryTests {
    @Test func baseURLUsesHTTPAndPort8095ForLocalHosts() {
        #expect(discovered("homeassistant.local") == "http://homeassistant.local:8095")
        #expect(discovered("homeassistant.local.") == "http://homeassistant.local:8095")
        #expect(discovered("192.168.1.10") == "http://192.168.1.10:8095")
        #expect(discovered("HA") == "http://ha:8095")
        #expect(discovered("192.168.1.10", port: 9000) == "http://192.168.1.10:9000")
    }

    @Test func baseURLBracketsIPv6AndRejectsNonLocalOrScopedHosts() {
        #expect(discovered("fd00::5") == "http://[fd00::5]:8095")
        #expect(discovered("ha.example.com") == nil)
        #expect(discovered("fe80::1%en0") == nil)
        #expect(discovered("") == nil)
    }

    @Test func hostFromTXTPrefersInternalURLThenBaseURL() {
        let both = ["internal_url": "http://192.168.1.10:8123", "base_url": "http://homeassistant.local:8123"]
        #expect(MusicAssistantDiscovery.host(fromTXT: both) == "192.168.1.10")
        #expect(MusicAssistantDiscovery.host(fromTXT: ["base_url": "http://homeassistant.local:8123"]) == "homeassistant.local")
        #expect(MusicAssistantDiscovery.host(fromTXT: ["internal_url": "https://ha.example.com"]) == nil)
        #expect(MusicAssistantDiscovery.host(fromTXT: ["version": "2026.10"]) == nil)
    }

    @Test func sendspinIsBrowsedAndUsesTheMusicAssistantPort() {
        #expect(MusicAssistantDiscovery.serviceTypes.contains("_sendspin-server._tcp"))
        #expect(MusicAssistantDiscovery.port(forServiceType: "_sendspin-server._tcp", advertised: 8927) == nil)
        #expect(MusicAssistantDiscovery.port(forServiceType: "_home-assistant._tcp", advertised: 8123) == nil)
        #expect(MusicAssistantDiscovery.port(forServiceType: "_music-assistant._tcp", advertised: 8095) == 8095)
        #expect(!MusicAssistantDiscovery.readsHostFromTXT(serviceType: "_sendspin-server._tcp"))
        #expect(MusicAssistantDiscovery.readsHostFromTXT(serviceType: "_home-assistant._tcp"))
    }
}

@MainActor
final class DiscoveryRig {
    let suite = "ma-discovery-" + UUID().uuidString
    let defaults: UserDefaults
    let store: MusicAssistantServerStore
    let fake = FakeInfo()
    let browser = StubServiceBrowser()
    let clock = ManualClock()
    let model: MusicAssistantDiscoveryModel
    var moves: [(UUID, URL)] = []

    static let wellKnown = URL(string: "http://homeassistant.local:8095")!

    init(servers: [MusicAssistantServerConfiguration] = []) {
        defaults = UserDefaults(suiteName: suite)!
        store = MusicAssistantServerStore(defaults: defaults)
        store.save(servers)
        model = MusicAssistantDiscoveryModel(store: store, browser: browser, fetch: fake.fetcher, clock: clock)
        model.onConfiguredServerMoved = { [unowned self] in moves.append(($0, $1)) }
    }

    func cleanUp() { defaults.removePersistentDomain(forName: suite) }

    /// Waits until `count` fetches started, then until every probe is done.
    func settle(calls count: Int) async {
        _ = await pollUntil { self.fake.calls.count >= count }
        await model.waitForIdle()
    }
}

@MainActor
struct DiscoveryModelTests {
    @Test func initAndNoStartDoNoIO() async throws {
        let rig = DiscoveryRig()
        defer { rig.cleanUp() }
        try await Task.sleep(for: .milliseconds(20))
        #expect(rig.fake.calls.isEmpty)
        #expect(rig.browser.started == 0)
        #expect(rig.model.offers.isEmpty)
        #expect(!rig.model.isSearching)
    }

    @Test func wellKnownAndBrowsedHostsAreProbedOnceEach() async throws {
        let rig = DiscoveryRig()
        defer { rig.cleanUp() }
        rig.model.start()
        rig.browser.yield("192.168.1.10")
        rig.browser.yield("192.168.1.10")
        rig.browser.yield("HomeAssistant.local.")
        rig.browser.yield("ha.example.com")
        await rig.settle(calls: 2)
        try await Task.sleep(for: .milliseconds(30))
        await rig.model.waitForIdle()
        #expect(rig.fake.calls.count == 2)
        #expect(Set(rig.fake.calls) == [DiscoveryRig.wellKnown, URL(string: "http://192.168.1.10:8095")!])
        #expect(rig.fake.calls.allSatisfy { $0.path.isEmpty && $0.query == nil })
        rig.model.stop()
    }

    @Test func unconfiguredServerIsOfferedOncePerServerID() async throws {
        let rig = DiscoveryRig()
        defer { rig.cleanUp() }
        rig.fake.set("http://homeassistant.local:8095", .answer("id-x"))
        rig.fake.set("http://192.168.1.10:8095", .answer("id-x"))
        rig.model.start()
        rig.browser.yield("192.168.1.10")
        await rig.settle(calls: 2)
        #expect(rig.model.offers.count == 1)
        #expect(rig.model.offers.first?.id == "id-x")
        #expect(rig.model.offers.first?.url == DiscoveryRig.wellKnown)
        #expect(rig.model.offers.first?.name == "Fake")
        #expect(rig.model.hasSearched)
        rig.model.stop()
    }

    @Test func configuredServerIDIsNotOffered() async throws {
        let rig = DiscoveryRig(servers: [makeServer("https://ma.example.com", id: "id-x")])
        defer { rig.cleanUp() }
        rig.fake.set("http://homeassistant.local:8095", .answer("id-x"))
        rig.model.start()
        await rig.settle(calls: 1)
        #expect(rig.model.offers.isEmpty)
        #expect(rig.moves.isEmpty)
        #expect(rig.fake.calls == [DiscoveryRig.wellKnown])
        rig.model.stop()
    }

    @Test func addedButUntestedAddressIsNotOffered() async throws {
        let rig = DiscoveryRig(servers: [makeServer("http://homeassistant.local:8095", id: nil)])
        defer { rig.cleanUp() }
        rig.fake.set("http://homeassistant.local:8095", .answer("id-x"))
        rig.model.start()
        await rig.settle(calls: 1)
        #expect(rig.model.offers.isEmpty)
        #expect(rig.moves.isEmpty)
        rig.model.stop()
    }

    @Test func failedOrTimedOutProbesOfferNothing() async throws {
        let rig = DiscoveryRig()
        defer { rig.cleanUp() }
        rig.fake.set("http://homeassistant.local:8095", .fail)
        rig.fake.set("http://192.168.1.10:8095", .hang)
        rig.model.start()
        rig.browser.yield("192.168.1.10")
        #expect(await pollUntil { rig.fake.calls.count == 2 && rig.clock.sleeperCount == 1 })
        #expect(rig.model.isSearching)
        rig.clock.advance(by: .seconds(3))
        await rig.model.waitForIdle()
        #expect(rig.model.offers.isEmpty)
        #expect(!rig.model.isSearching)
        #expect(rig.model.hasSearched)
        rig.model.stop()
    }

    @Test func configuredServerAtNewAddressIsReportedWhenItsStoredAddressFails() async throws {
        let server = makeServer("http://10.0.0.5:8095", id: "id-x")
        let rig = DiscoveryRig(servers: [server])
        defer { rig.cleanUp() }
        rig.fake.set("http://homeassistant.local:8095", .answer("id-x"))
        rig.fake.set("http://10.0.0.5:8095", .fail)
        rig.model.start()
        rig.browser.yield("homeassistant.local")
        await rig.settle(calls: 2)
        #expect(rig.moves.count == 1)
        #expect(rig.moves.first?.0 == server.id)
        #expect(rig.moves.first?.1 == DiscoveryRig.wellKnown)
        #expect(rig.model.offers.isEmpty)
        rig.model.stop()
    }

    @Test func configuredServerAtNewAddressIsIgnoredWhenItsStoredAddressAnswers() async throws {
        let rig = DiscoveryRig(servers: [makeServer("http://10.0.0.5:8095", id: "id-x")])
        defer { rig.cleanUp() }
        rig.fake.set("http://homeassistant.local:8095", .answer("id-x"))
        rig.fake.set("http://10.0.0.5:8095", .answer("id-x"))
        rig.model.start()
        await rig.settle(calls: 2)
        #expect(rig.moves.isEmpty)
        #expect(rig.model.offers.isEmpty)
        rig.model.stop()
    }

    @Test func tailscaleOrHTTPSAddressIsNeverReplaced() async throws {
        let rig = DiscoveryRig(servers: [
            makeServer("http://100.101.102.103:8095", id: "id-a"), makeServer("https://ha.tail1234.ts.net", id: "id-b"),
        ])
        defer { rig.cleanUp() }
        rig.fake.set("http://homeassistant.local:8095", .answer("id-a"))
        rig.fake.set("http://192.168.1.10:8095", .answer("id-b"))
        rig.model.start()
        rig.browser.yield("192.168.1.10")
        await rig.settle(calls: 2)
        try await Task.sleep(for: .milliseconds(20))
        await rig.model.waitForIdle()
        #expect(rig.moves.isEmpty)
        #expect(rig.fake.calls.count == 2)
        #expect(rig.model.offers.isEmpty)
        rig.model.stop()
    }

    @Test func stopCancelsProbesAndBrowsingAndIsReferenceCounted() async throws {
        let rig = DiscoveryRig()
        defer { rig.cleanUp() }
        rig.fake.set("http://homeassistant.local:8095", .hang)
        rig.model.start()
        rig.model.start()
        #expect(rig.browser.started == 1)
        #expect(await pollUntil { rig.fake.calls.count == 1 })
        rig.model.stop()
        try await Task.sleep(for: .milliseconds(30))
        #expect(rig.browser.terminated == 0)
        #expect(rig.fake.cancelled.isEmpty)
        #expect(rig.model.isSearching)
        rig.model.stop()
        #expect(await pollUntil { rig.browser.terminated == 1 && rig.fake.cancelled == [DiscoveryRig.wellKnown] })
        #expect(!rig.model.isSearching)
    }
}
