import Foundation
import MusicAssistantKitStub
import MusicBackendKit
import Testing
@testable import MusicAssistantKit

private final class IDLog: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [UUID] = []
    var seen: [UUID] { lock.withLock { ids } }
    func add(_ id: UUID) { lock.withLock { ids.append(id) } }
}

private final class Holder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MusicAssistantServerConfiguration?
    var current: MusicAssistantServerConfiguration? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private struct ProviderRig {
    var backend: MusicAssistantBackend
    var factory: StubTransportFactory
    var http: StubHTTPTransport
    var holder: Holder
    var tokenIDs: IDLog
}

private func makeProviderBackend(_ server: MusicAssistantServerConfiguration?) throws -> ProviderRig {
    let script = try FixtureScript.recorded(token: testToken)
    let factory = StubTransportFactory(script: script)
    let http = StubHTTPTransport()
    let holder = Holder()
    holder.current = server
    let ids = IDLog()
    let backend = MusicAssistantBackend(
        server: { holder.current }, token: { ids.add($0.id); return testToken }, transports: factory, http: http,
        clock: ManualClock())
    return ProviderRig(backend: backend, factory: factory, http: http, holder: holder, tokenIDs: ids)
}

struct BackendServerProviderTests {
    @Test func connectRefusesAnUnverifiedConfiguration() async throws {
        let rig = try makeProviderBackend(makeServer(id: nil, name: "Home"))
        let expected = MusicBackendError.notConfigured("Test the connection to Home under Settings \u{203A} Music Assistant.")
        await #expect(throws: expected) { try await rig.backend.connect() }
        #expect(rig.tokenIDs.seen.isEmpty)
        #expect(rig.factory.made == 0)
        #expect(rig.http.requests.isEmpty)
    }

    @Test func noConfigurationIsNotConfigured() async throws {
        let rig = try makeProviderBackend(nil)
        let expected = MusicBackendError.notConfigured("Add a Music Assistant server under Settings \u{203A} Music Assistant.")
        await #expect(throws: expected) { try await rig.backend.connect() }
        await #expect(throws: expected) { try await rig.backend.probe() }
        #expect(rig.tokenIDs.seen.isEmpty)
        #expect(rig.factory.made == 0)
    }

    @Test func connectReadsTheTokenForTheActiveConfiguration() async throws {
        let server = makeServer()
        let rig = try makeProviderBackend(server)
        try await rig.backend.connect()
        #expect(rig.tokenIDs.seen == [server.id])
        #expect(rig.factory.made == 1)
        // Already connected to the same server: nothing is read or made again.
        try await rig.backend.connect()
        #expect(rig.tokenIDs.seen == [server.id])
        #expect(rig.factory.made == 1)
        await rig.backend.disconnect()
    }

    @Test func changingConfigurationAtTheSameBaseURLReconnects() async throws {
        let first = makeServer("http://homeassistant.local:8095", name: "Home")
        let second = makeServer("http://homeassistant.local:8095", name: "Office")
        let rig = try makeProviderBackend(first)
        try await rig.backend.connect()
        #expect(rig.factory.made == 1)
        rig.holder.current = second
        try await rig.backend.connect()
        #expect(rig.factory.made == 2)
        #expect(rig.tokenIDs.seen == [first.id, second.id])
        await rig.backend.disconnect()
    }

    @Test func probeUsesTheActiveConfigurationWithoutAToken() async throws {
        let rig = try makeProviderBackend(makeServer("https://music.example.test/ma"))
        rig.http.setResponse(
            pathPrefix: "/ma/info", MAHTTPResponse(status: 200, contentType: "application/json", body: try MAFixture.infoHTTP.data))
        try await rig.backend.probe()
        #expect(rig.tokenIDs.seen.isEmpty)
        #expect(rig.factory.made == 0)
        #expect(rig.http.requests.map(\.url.absoluteString) == ["https://music.example.test/ma/info"])
        #expect(rig.http.requests[0].headers.isEmpty)
    }

    @Test func probeRefusesADifferentServerAtTheAddress() async throws {
        let rig = try makeProviderBackend(makeServer(id: "someone-else"))
        await #expect(throws: MusicBackendError.self) { try await rig.backend.probe() }
    }

    @Test func connectionStatesFollowAReplacedClient() async throws {
        let first = makeServer("http://homeassistant.local:8095", name: "Home")
        let second = makeServer("http://homeassistant.local:8095", name: "Office")
        let rig = try makeProviderBackend(first)
        let states = Collector(await rig.backend.connectionStates())
        defer { states.stop() }
        #expect(await waitFor { states.items == [.disconnected] })
        try await rig.backend.connect()
        #expect(await waitFor { states.items.filter { $0 == .connected }.count == 1 })
        rig.holder.current = second
        try await rig.backend.connect()
        #expect(await waitFor { states.items.filter { $0 == .connected }.count == 2 })
        await rig.backend.disconnect()
        #expect(await waitFor { states.items.last == .disconnected })
    }

    @Test func noReachableServerIsUnreachableWhenOneIsConfigured() async throws {
        let backend = MusicAssistantBackend(
            server: { nil }, token: { _ in testToken }, hasVerifiedServer: { true }, transports: StubTransportFactory(script: try FixtureScript.recorded(token: testToken)),
            http: StubHTTPTransport(), clock: ManualClock())
        await #expect(throws: MusicBackendError.unreachable("No Music Assistant server reachable")) { try await backend.connect() }
    }

    @Test func httpsAddressesReachTheSocketAsWSSAndHTTPAsWS() {
        func socket(_ text: String) -> String? { URLSessionWebSocketTransport.socketURL(for: URL(string: text)!)?.absoluteString }
        #expect(socket("https://box.tail1234.ts.net") == "wss://box.tail1234.ts.net/ws")
        #expect(socket("https://music.example.test:8443/ma/") == "wss://music.example.test:8443/ma/ws")
        #expect(socket("http://100.101.102.103:8095") == "ws://100.101.102.103:8095/ws")
        #expect(socket("http://ma.local:8095") == "ws://ma.local:8095/ws")
    }
}
