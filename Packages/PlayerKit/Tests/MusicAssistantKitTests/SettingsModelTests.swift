import Foundation
import MusicAssistantKitStub
import Security
import Testing
@testable import MusicAssistantKit

/// `/info` that waits until the test releases it, so a test can change an input while Test Connection is in flight.
final class GatedHTTP: MAHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var enteredCount = 0
    private let inner = StubHTTPTransport()

    var entered: Int { lock.withLock { enteredCount } }

    func get(_ url: URL, headers: [String: String], timeout: Duration) async throws -> MAHTTPResponse {
        await withCheckedContinuation { continuation in
            lock.withLock {
                enteredCount += 1
                waiters.append(continuation)
            }
        }
        return try await inner.get(url, headers: headers, timeout: timeout)
    }

    func release() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { waiters = [] }
            return waiters
        }
        for waiter in all { waiter.resume() }
    }
}

/// `waitFor` for main-actor tests: the condition runs on the main actor.
@MainActor
func pollUntil(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@MainActor
final class SettingsRig {
    let suite = "ma-settings-" + UUID().uuidString
    let defaults: UserDefaults
    let store: MusicAssistantServerStore
    let stores = InMemoryMusicAssistantTokenStores()
    let stub = StubHTTPTransport()
    let factory: StubTransportFactory
    let active: MusicAssistantActiveServer
    let tokenStoreCalls = CallCounter()
    let model: MusicAssistantSettingsModel
    var hookCalls = 0

    init(
        servers: [MusicAssistantServerConfiguration] = [], http: (any MAHTTPTransport)? = nil, wifi: StubWiFi? = nil
    ) throws {
        defaults = UserDefaults(suiteName: suite)!
        store = MusicAssistantServerStore(defaults: defaults)
        store.save(servers)
        factory = StubTransportFactory(script: try FixtureScript.recorded(token: testToken))
        active = MusicAssistantActiveServer(MusicAssistantActiveServer.firstVerified(in: servers))
        let stores = stores
        let calls = tokenStoreCalls
        model = MusicAssistantSettingsModel(
            store: store,
            tokenStore: { calls.hit(); return stores.store(for: $0) },
            test: MusicAssistantConnectionTest(http: http ?? stub, transports: factory, clock: ManualClock()),
            active: active, wifi: wifi)
        model.onServersChanged = { [unowned self] in hookCalls += 1 }
    }

    func cleanUp() { defaults.removePersistentDomain(forName: suite) }

    func tokens(for server: MusicAssistantServerConfiguration) -> InMemoryMusicAssistantTokenStore {
        stores.store(for: server.keychainAccount)
    }

    /// The test ran to its end.
    func runTest() async {
        model.testConnection()
        await model.waitForTest()
    }

    func renameServerInfo(to name: String) throws {
        guard var object = try JSONSerialization.jsonObject(with: try MAFixture.infoHTTP.data) as? [String: Any] else { return }
        object["name"] = name
        stub.setResponse(
            pathPrefix: "/info",
            MAHTTPResponse(status: 200, contentType: "application/json", body: try JSONSerialization.data(withJSONObject: object)))
    }
}

@MainActor
struct SettingsModelTests {
    @Test func initDoesNoIO() throws {
        let rig = try SettingsRig(servers: [makeServer()])
        defer { rig.cleanUp() }
        #expect(rig.tokenStoreCalls.count == 0)
        #expect(rig.stub.requests.isEmpty)
        #expect(rig.factory.made == 0)
        #expect(rig.model.servers.isEmpty)
        #expect(rig.model.tokenText.isEmpty)
    }

    @Test func appearedChecksExistenceButNeverLoadsTheToken() throws {
        let a = makeServer(name: "A")
        let b = makeServer(name: "B")
        let rig = try SettingsRig(servers: [a, b])
        defer { rig.cleanUp() }
        try rig.tokens(for: a).save(testToken)
        rig.model.appeared()
        #expect(rig.model.servers == [a, b])
        #expect(rig.model.hasStoredToken[a.id] == true)
        #expect(rig.model.hasStoredToken[b.id] == false)
        #expect(rig.tokens(for: a).existsChecks == 1)
        #expect(rig.tokens(for: b).existsChecks == 1)
        #expect(rig.tokens(for: a).loads == 0)
        #expect(rig.tokens(for: b).loads == 0)
        #expect(rig.model.tokenText.isEmpty)
        #expect(rig.model.selectedID == a.id)
        #expect(rig.model.addressText == "http://ma.local:8095")
    }

    @Test func addSelectsANewUnverifiedServer() throws {
        let rig = try SettingsRig()
        defer { rig.cleanUp() }
        rig.model.appeared()
        rig.model.addServer()
        let added = try #require(rig.model.servers.first)
        #expect(rig.model.servers.count == 1)
        #expect(!added.isVerified)
        #expect(added.name == "Music Assistant")
        #expect(rig.model.selectedID == added.id)
        #expect(rig.model.addressText.isEmpty)
        #expect(rig.model.addressProblem == nil)
        #expect(rig.store.load() == [added])
        #expect(rig.active.current == nil)
        #expect(rig.hookCalls == 1)
        #expect(!rig.model.canTest)
    }

    @Test func removeDeletesOnlyThatServersItem() throws {
        let a = makeServer(name: "A")
        let b = makeServer(name: "B")
        let rig = try SettingsRig(servers: [a, b])
        defer { rig.cleanUp() }
        rig.model.appeared()
        rig.model.removeServer(b.id)
        #expect(rig.model.servers == [a])
        #expect(rig.store.load() == [a])
        #expect(rig.tokens(for: b).deletes == 1)
        #expect(rig.tokens(for: a).deletes == 0)
        #expect(rig.model.selectedID == a.id)
    }

    @Test func moveReordersAndPersists() throws {
        let a = makeServer(name: "A")
        let b = makeServer(name: "B")
        let c = makeServer(name: "C")
        let rig = try SettingsRig(servers: [a, b, c])
        defer { rig.cleanUp() }
        rig.model.appeared()
        rig.model.move(fromOffsets: [2], toOffset: 0)
        #expect(rig.model.servers.map(\.name) == ["C", "A", "B"])
        #expect(rig.store.load().map(\.name) == ["C", "A", "B"])
        #expect(rig.active.current?.name == "A")
        rig.model.move(fromOffsets: [0], toOffset: 3)
        #expect(rig.model.servers.map(\.name) == ["A", "B", "C"])
        #expect(rig.store.load().map(\.name) == ["A", "B", "C"])
        #expect(rig.hookCalls == 2)
    }

    @Test func invalidAddressIsNotPersistedAndShowsTheProblem() async throws {
        let server = makeServer()
        let rig = try SettingsRig(servers: [server])
        defer { rig.cleanUp() }
        rig.model.appeared()
        rig.model.addressText = "http://music.example.test"
        #expect(rig.model.addressProblem == .httpsRequired)
        rig.model.disappeared()
        #expect(rig.store.load() == [server])
        rig.model.addressText = "ma local"
        #expect(rig.model.addressProblem == .invalid)
        await rig.runTest()
        #expect(rig.model.selectedStatus == .failed(.invalidAddress(.invalid)))
        #expect(rig.stub.requests.isEmpty)
        #expect(rig.factory.made == 0)
    }

    @Test func editingAddressKeepsServerIDAndCancelsATest() async throws {
        let server = makeServer()
        let gate = GatedHTTP()
        let rig = try SettingsRig(servers: [server], http: gate)
        defer { rig.cleanUp() }
        try rig.tokens(for: server).save(testToken)
        rig.model.appeared()
        rig.model.testConnection()
        #expect(rig.model.selectedStatus == .testing)
        #expect(await pollUntil { gate.entered == 1 })
        rig.model.addressText = "http://other.local:8095"
        #expect(rig.model.selectedStatus == .untested)
        rig.model.disappeared()
        gate.release()
        await rig.model.waitForTest()
        let saved = try #require(rig.store.load().first)
        #expect(saved.address.baseURL == URL(string: "http://other.local:8095"))
        #expect(saved.address.serverID == fixtureServerID)
        #expect(rig.model.selectedStatus == .untested)
        #expect(rig.factory.made == 0)
    }

    @Test func testWithoutTokenStopsAfterInfo() async throws {
        let server = makeServer(id: nil)
        let rig = try SettingsRig(servers: [server])
        defer { rig.cleanUp() }
        rig.model.appeared()
        await rig.runTest()
        // The fixture advertises the generic "Music Assistant", which the message leaves out (#0119).
        #expect(rig.model.selectedStatus == .failed(.needsToken(foundName: nil)))
        #expect(rig.model.statusMessage == "Found a Music Assistant server. Enter a token.")
        #expect(rig.factory.made == 0)
        #expect(rig.stub.requests.count == 1)
        #expect(rig.stub.requests[0].url.path == "/info")
        #expect(rig.stub.requests[0].headers.isEmpty)
        #expect(!rig.model.servers[0].isVerified)
    }

    @Test func testLearnsServerIDAndSavesTheTypedToken() async throws {
        let server = makeServer(id: nil, name: MusicAssistantServerConfiguration.defaultName)
        let rig = try SettingsRig(servers: [server])
        defer { rig.cleanUp() }
        try rig.renameServerInfo(to: "Living Room")
        rig.model.appeared()
        rig.model.tokenText = testToken.rawValue
        await rig.runTest()
        #expect(rig.model.selectedStatus == .connected(name: "Living Room", version: "2.10.6"))
        #expect(rig.model.servers[0].address.serverID == fixtureServerID)
        #expect(rig.model.servers[0].name == "Living Room")
        #expect(rig.store.load() == rig.model.servers)
        #expect(rig.tokens(for: server).saves == 1)
        #expect(rig.tokens(for: server).token == testToken)
        #expect(rig.model.hasStoredToken[server.id] == true)
        #expect(rig.model.tokenText.isEmpty)
        #expect(rig.factory.made == 1)
        #expect(!rig.factory.transports[0].closeCodes.isEmpty)
        #expect(rig.active.current == nil)
        #expect(rig.hookCalls == 1)
    }

    @Test func testUsesTheStoredTokenWhenTheFieldIsEmpty() async throws {
        let server = makeServer()
        let rig = try SettingsRig(servers: [server])
        defer { rig.cleanUp() }
        try rig.tokens(for: server).save(testToken)
        rig.model.appeared()
        await rig.runTest()
        #expect(rig.model.selectedStatus == .connected(name: "Home", version: "2.10.6"))
        #expect(rig.tokens(for: server).loads == 1)
        #expect(rig.tokens(for: server).saves == 1)  // the seeding save only
        #expect(rig.tokens(for: server).deletes == 0)
    }

    @Test func mismatchNeverReadsOrSendsTheToken() async throws {
        let server = makeServer(id: "other-server-id")
        let rig = try SettingsRig(servers: [server])
        defer { rig.cleanUp() }
        try rig.tokens(for: server).save(testToken)
        rig.model.appeared()
        rig.model.tokenText = testToken.rawValue
        await rig.runTest()
        #expect(rig.model.selectedStatus == .failed(.serverMismatch(foundName: nil)))
        #expect(rig.tokens(for: server).loads == 0)
        #expect(rig.factory.made == 0)
        #expect(rig.model.servers[0].address.serverID == "other-server-id")
    }

    @Test func replaceIdentityClearsServerIDAndDeletesTheToken() async throws {
        let server = makeServer(id: "other-server-id")
        let rig = try SettingsRig(servers: [server])
        defer { rig.cleanUp() }
        try rig.tokens(for: server).save(testToken)
        rig.model.appeared()
        #expect(rig.active.current?.id == server.id)
        await rig.runTest()
        rig.model.replaceIdentity()
        #expect(rig.model.servers[0].address.serverID == nil)
        #expect(rig.store.load()[0].address.serverID == nil)
        #expect(rig.tokens(for: server).deletes == 1)
        #expect(rig.tokens(for: server).token == nil)
        #expect(rig.model.hasStoredToken[server.id] == false)
        #expect(rig.model.selectedStatus == .untested)
        #expect(rig.active.current == nil)
        #expect(rig.hookCalls == 1)
    }

    @Test func tokenRejectedKeepsTokenAndIdentity() async throws {
        let server = makeServer()
        let rig = try SettingsRig(servers: [server])
        defer { rig.cleanUp() }
        try rig.tokens(for: server).save(testToken)
        rig.model.appeared()
        rig.model.tokenText = "ma-WRONG-TOKEN"
        await rig.runTest()
        #expect(rig.model.selectedStatus == .failed(.tokenRejected))
        #expect(rig.tokens(for: server).deletes == 0)
        #expect(rig.tokens(for: server).token == testToken)
        #expect(rig.model.servers[0].address.serverID == fixtureServerID)
        #expect(rig.factory.made == 1)
    }

    @Test func keychainReadFailureNeverDeletes() async throws {
        let server = makeServer()
        let rig = try SettingsRig(servers: [server])
        defer { rig.cleanUp() }
        try rig.tokens(for: server).save(testToken)
        rig.tokens(for: server).failLoad = errSecInteractionNotAllowed
        rig.model.appeared()
        await rig.runTest()
        guard case .failed(.keychain(let text)) = rig.model.selectedStatus else {
            Issue.record("expected a keychain failure, got \(rig.model.selectedStatus)")
            return
        }
        #expect(text.contains("\(errSecInteractionNotAllowed)"))
        #expect(rig.tokens(for: server).deletes == 0)
        #expect(rig.tokens(for: server).token == testToken)
        #expect(rig.factory.made == 0)
    }

    @Test func existsFailureLeavesStateUnknown() throws {
        let server = makeServer()
        let rig = try SettingsRig(servers: [server])
        defer { rig.cleanUp() }
        rig.tokens(for: server).failExists = errSecInteractionNotAllowed
        rig.model.appeared()
        #expect(rig.model.hasStoredToken[server.id] == nil)
        #expect(rig.model.selectedHasStoredToken == nil)
        #expect(rig.model.tokenStoreError != nil)
        #expect(rig.tokens(for: server).deletes == 0)
        #expect(rig.tokens(for: server).loads == 0)
    }

    @Test func emptyDirtyFieldKeepsTheStoredToken() throws {
        let a = makeServer(name: "A")
        let b = makeServer(name: "B")
        let rig = try SettingsRig(servers: [a, b])
        defer { rig.cleanUp() }
        try rig.tokens(for: a).save(testToken)
        rig.model.appeared()
        rig.model.tokenText = "typed"
        rig.model.tokenText = ""
        rig.model.disappeared()
        rig.model.tokenText = "typed"
        rig.model.tokenText = ""
        rig.model.selectedID = b.id
        for server in [a, b] {
            #expect(rig.tokens(for: server).deletes == 0)
        }
        #expect(rig.tokens(for: a).saves == 1)  // the seeding save only
        #expect(rig.tokens(for: a).token == testToken)
    }

    @Test func removeTokenDeletes() throws {
        let server = makeServer()
        let rig = try SettingsRig(servers: [server])
        defer { rig.cleanUp() }
        try rig.tokens(for: server).save(testToken)
        rig.model.appeared()
        #expect(rig.model.selectedHasStoredToken == true)
        rig.model.removeToken()
        #expect(rig.tokens(for: server).deletes == 1)
        #expect(rig.tokens(for: server).token == nil)
        #expect(rig.model.selectedHasStoredToken == false)
    }

    @Test func dirtyTokenCommitsOnSelectionChange() throws {
        let a = makeServer(name: "A")
        let b = makeServer(name: "B")
        let rig = try SettingsRig(servers: [a, b])
        defer { rig.cleanUp() }
        rig.model.appeared()
        rig.model.tokenText = "  typed-token  "
        rig.model.selectedID = b.id
        #expect(rig.tokens(for: a).saves == 1)
        #expect(rig.tokens(for: a).token == MusicAssistantToken("typed-token"))
        #expect(rig.tokens(for: b).saves == 0)
        #expect(rig.model.tokenText.isEmpty)
        #expect(rig.model.hasStoredToken[a.id] == true)
    }

    @Test func cancelledTestWritesNothing() async throws {
        let server = makeServer(id: nil)
        let gate = GatedHTTP()
        let rig = try SettingsRig(servers: [server], http: gate)
        defer { rig.cleanUp() }
        rig.model.appeared()
        rig.model.tokenText = testToken.rawValue
        rig.model.testConnection()
        #expect(await pollUntil { gate.entered == 1 })
        rig.model.tokenText = testToken.rawValue + "x"
        gate.release()
        await rig.model.waitForTest()
        #expect(rig.model.selectedStatus == .untested)
        #expect(rig.model.servers[0].address.serverID == nil)
        #expect(rig.store.load() == [server])
        #expect(rig.tokens(for: server).saves == 0)
        #expect(rig.tokens(for: server).loads == 0)
        #expect(rig.factory.made == 0)
        #expect(rig.hookCalls == 0)
    }

    @Test func listMutationsInvalidateTheSelection() async throws {
        let server = makeServer()
        let rig = try SettingsRig(servers: [server])
        defer { rig.cleanUp() }
        // The selection chose this server; the settings model only keeps the copy current.
        rig.active.set(server)
        rig.model.appeared()
        #expect(rig.hookCalls == 0)
        rig.model.name = "Renamed"
        #expect(rig.hookCalls == 1)
        #expect(rig.active.current?.name == "Renamed")
        rig.model.addNetwork("Attic")
        #expect(rig.hookCalls == 2)
        #expect(rig.active.current?.networks == ["Attic"])
        rig.model.addressText = "http://elsewhere.local:8095"
        rig.model.disappeared()
        #expect(rig.hookCalls == 3)
        // An identity change clears the copy until the selection resolves again.
        #expect(rig.active.current == nil)
        rig.model.removeServer(server.id)
        #expect(rig.hookCalls == 4)
    }

    @Test func useCurrentNetworkRequestsAuthorizationOnlyWhenUndetermined() async throws {
        let wifi = StubWiFi(.notDetermined, ssid: "Attic", grant: .authorized)
        let rig = try SettingsRig(servers: [makeServer()], wifi: wifi)
        defer { rig.cleanUp() }
        rig.model.appeared()
        #expect(wifi.authorizationRequests == 0)
        await rig.model.useCurrentNetwork()
        #expect(wifi.authorizationRequests == 1)
        #expect(rig.model.networks == ["Attic"])
        rig.model.removeNetwork("Attic")
        await rig.model.useCurrentNetwork()
        #expect(wifi.authorizationRequests == 1)
        #expect(rig.model.networks == ["Attic"])
    }

    @Test func useCurrentNetworkAddsTheSSIDOnce() async throws {
        let wifi = StubWiFi(.authorized, ssid: "Attic")
        let rig = try SettingsRig(servers: [makeServer()], wifi: wifi)
        defer { rig.cleanUp() }
        rig.model.appeared()
        await rig.model.useCurrentNetwork()
        await rig.model.useCurrentNetwork()
        #expect(rig.model.networks == ["Attic"])
        #expect(rig.store.load()[0].networks == ["Attic"])
        #expect(rig.model.locationMessage == nil)
        #expect(wifi.authorizationRequests == 0)
    }

    @Test func deniedLocationExplainsAndAddsNothing() async throws {
        let wifi = StubWiFi(.notDetermined, ssid: "Attic", grant: .denied)
        let rig = try SettingsRig(servers: [makeServer()], wifi: wifi)
        defer { rig.cleanUp() }
        rig.model.appeared()
        await rig.model.useCurrentNetwork()
        #expect(rig.model.networks.isEmpty)
        #expect(rig.model.locationMessage == .needsLocationAccess)
        #expect(rig.model.locationMessage?.text.contains("Location access") == true)
        #expect(wifi.ssidCalls == 0)
        wifi.authorization = .restricted
        await rig.model.useCurrentNetwork()
        #expect(wifi.authorizationRequests == 1)
        #expect(rig.model.locationMessage == .needsLocationAccess)
    }

    @Test func noWiFiSaysSo() async throws {
        let wifi = StubWiFi(.authorized, ssid: nil)
        let rig = try SettingsRig(servers: [makeServer()], wifi: wifi)
        defer { rig.cleanUp() }
        rig.model.appeared()
        await rig.model.useCurrentNetwork()
        #expect(rig.model.networks.isEmpty)
        #expect(rig.model.locationMessage == .notOnWiFi)
        #expect(rig.model.locationMessage?.text == "Not connected to Wi-Fi.")
    }

    @Test func addAndRemoveNetworkPersist() async throws {
        let rig = try SettingsRig(servers: [makeServer()])
        defer { rig.cleanUp() }
        rig.model.appeared()
        rig.model.addNetwork("  Attic ")
        rig.model.addNetwork("Attic")
        rig.model.addNetwork("")
        rig.model.addNetwork("Studio")
        #expect(rig.store.load()[0].networks == ["Attic", "Studio"])
        rig.model.removeNetwork("Attic")
        #expect(rig.store.load()[0].networks == ["Studio"])
        #expect(rig.model.networks == ["Studio"])
    }

    @Test func aTransportBlockedByATSIsNamedAsSuch() async throws {
        let server = makeServer(id: nil)
        let rig = try SettingsRig(servers: [server])
        defer { rig.cleanUp() }
        rig.stub.setFailure(pathPrefix: "/info", code: .appTransportSecurityRequiresSecureConnection)
        rig.model.appeared()
        await rig.runTest()
        #expect(rig.model.selectedStatus == .failed(.blockedByATS))
        #expect(rig.model.statusMessage?.contains("https") == true)
    }

    @Test func noStatusTextContainsTheTokenHostOrServerID() async throws {
        let secrets = ["ma-UNIT-TEST-TOKEN", "secret-host.local", "srv-UNIT"]
        var messages: [String] = []

        // Unreachable, token rejected, mismatch, keychain failure, needs token, connected.
        let server = makeServer("http://secret-host.local:8095", id: "srv-UNIT")
        let rig = try SettingsRig(servers: [server])
        defer { rig.cleanUp() }
        rig.model.appeared()
        func note() {
            messages.append(rig.model.statusMessage ?? "")
            messages.append(String(describing: rig.model.selectedStatus))
        }
        rig.stub.setFailure(pathPrefix: "/info", code: .cannotConnectToHost)
        rig.model.tokenText = testToken.rawValue
        await rig.runTest()
        note()
        rig.stub.setFailure(pathPrefix: "/info", code: .timedOut)
        await rig.runTest()
        note()
        // The recorded server id differs from "srv-UNIT": a mismatch.
        rig.stub.setResponse(
            pathPrefix: "/info", MAHTTPResponse(status: 200, contentType: "application/json", body: try MAFixture.infoHTTP.data))
        await rig.runTest()
        note()
        rig.tokens(for: server).failLoad = errSecInteractionNotAllowed
        rig.model.replaceIdentity()
        rig.model.tokenText = ""
        await rig.runTest()
        note()
        for failure: MusicAssistantConnectionFailure in [
            .invalidAddress(.httpsRequired), .blockedByATS, .tokenRejected, .needsToken(foundName: nil),
            .serverMismatch(foundName: nil), .schema("This Music Assistant server is too old for SkinAmp (schema 3; needs 28 or later)."),
        ] {
            messages.append(failure.message)
        }
        messages.append(String(reflecting: rig.model))
        messages.append(String(describing: rig.model))
        #expect(messages.count >= 8)
        for text in messages {
            for secret in secrets { #expect(!text.contains(secret), "\(text)") }
        }
    }

    @Test func descriptionIsRedacted() throws {
        let rig = try SettingsRig(servers: [makeServer("http://secret-host.local:8095", id: "srv-UNIT")])
        defer { rig.cleanUp() }
        rig.model.appeared()
        rig.model.tokenText = testToken.rawValue
        for text in [String(describing: rig.model), String(reflecting: rig.model)] {
            #expect(text.contains("redacted"))
            for secret in ["ma-UNIT-TEST-TOKEN", "secret-host.local", "srv-UNIT"] { #expect(!text.contains(secret)) }
        }
        #expect(Mirror(reflecting: rig.model).children.isEmpty)
    }
}

// MARK: Discovery (#0104)

extension SettingsModelTests {
    @Test func addDiscoveredServerAddsAnUntestedRowAndSelectsIt() throws {
        let a = makeServer("http://a.local:8095", name: "A")
        let b = makeServer("http://b.local:8095", name: "B")
        let rig = try SettingsRig(servers: [a, b])
        defer { rig.cleanUp() }
        let offer = MusicAssistantDiscoveredServer(id: "id-new", url: URL(string: "http://192.168.1.20:8095")!, name: "Den")
        rig.model.addDiscoveredServer(offer)
        let stored = rig.store.load()
        #expect(stored.count == 3)
        #expect(Array(stored.prefix(2)) == [a, b])
        let added = try #require(stored.last)
        #expect(added.address.serverID == nil)
        #expect(added.address.baseURL == offer.url)
        #expect(added.name == "Den")
        #expect(rig.model.selectedID == added.id)
        #expect(rig.hookCalls >= 1)
        #expect(rig.tokens(for: added).saves == 0)
        #expect(rig.tokens(for: a).saves == 0)
    }

    @Test func addDiscoveredServerSelectsTheExistingRowForTheSameAddress() throws {
        let a = makeServer("http://a.local:8095", name: "A")
        let b = makeServer("http://192.168.1.20:8095", id: nil, name: "B")
        let rig = try SettingsRig(servers: [a, b])
        defer { rig.cleanUp() }
        rig.model.addDiscoveredServer(
            MusicAssistantDiscoveredServer(id: "id-new", url: URL(string: "http://192.168.1.20:8095")!, name: "Den"))
        #expect(rig.store.load() == [a, b])
        #expect(rig.model.selectedID == b.id)
        #expect(rig.hookCalls == 0)
    }

    @Test func adoptDiscoveredAddressMovesOnlyTheMatchingServer() throws {
        let a = makeServer("http://10.0.0.5:8095", id: "id-a", name: "A", networks: ["Home"])
        let b = makeServer("http://b.local:8095", id: "id-b", name: "B")
        let rig = try SettingsRig(servers: [a, b])
        defer { rig.cleanUp() }
        try rig.tokens(for: a).save(testToken)
        let moved = URL(string: "http://homeassistant.local:8095")!
        rig.model.adoptDiscoveredAddress(moved, for: a.id, serverID: "id-a")
        let stored = rig.store.load()
        #expect(stored.count == 2)
        #expect(stored[0].id == a.id)
        #expect(stored[0].address.baseURL == moved)
        #expect(stored[0].address.serverID == "id-a")
        #expect(stored[0].networks == ["Home"])
        #expect(stored[0].name == "A")
        #expect(stored[1] == b)
        #expect(rig.tokens(for: a).token == testToken)
        #expect(rig.tokens(for: a).deletes == 0)
        #expect(rig.hookCalls == 1)
    }

    @Test func adoptDiscoveredAddressIgnoresAServerIDMismatch() throws {
        let a = makeServer("http://10.0.0.5:8095", id: "id-a", name: "A")
        let b = makeServer("http://192.168.1.20:8095", id: nil, name: "B")
        let rig = try SettingsRig(servers: [a, b])
        defer { rig.cleanUp() }
        let moved = URL(string: "http://homeassistant.local:8095")!
        rig.model.adoptDiscoveredAddress(moved, for: a.id, serverID: "id-other")
        rig.model.adoptDiscoveredAddress(moved, for: b.id, serverID: "id-b")
        #expect(rig.store.load() == [a, b])
        #expect(rig.hookCalls == 0)
    }

    @Test func testDoesNotAdoptAGenericAdvertisedName() async throws {
        let server = makeServer(id: nil, name: MusicAssistantServerConfiguration.defaultName)
        let rig = try SettingsRig(servers: [server])
        defer { rig.cleanUp() }
        try rig.renameServerInfo(to: "Music Assistant (abc123)")
        rig.model.appeared()
        rig.model.tokenText = testToken.rawValue
        await rig.runTest()
        #expect(rig.model.servers[0].address.serverID == fixtureServerID)
        #expect(rig.model.servers[0].name == MusicAssistantServerConfiguration.defaultName)
    }

    @Test func testReplacesAStoredGenericNameWithARealOne() async throws {
        let server = makeServer(id: nil, name: "Music Assistant (abc123)")
        let rig = try SettingsRig(servers: [server])
        defer { rig.cleanUp() }
        try rig.renameServerInfo(to: "Living Room")
        rig.model.appeared()
        rig.model.tokenText = testToken.rawValue
        await rig.runTest()
        #expect(rig.model.servers[0].name == "Living Room")
    }

    @Test func testConnectedMessageOmitsAGenericName() async throws {
        let server = makeServer(id: nil, name: MusicAssistantServerConfiguration.defaultName)
        let rig = try SettingsRig(servers: [server])
        defer { rig.cleanUp() }
        try rig.renameServerInfo(to: "Music Assistant (abc123)")
        rig.model.appeared()
        rig.model.tokenText = testToken.rawValue
        await rig.runTest()
        let message = try #require(rig.model.statusMessage)
        #expect(message.hasPrefix("Connected"))
        #expect(!message.contains("abc123"))
        #expect(!message.contains("Music Assistant ("))
    }

    @Test func testNeedsTokenMessageOmitsAGenericName() async throws {
        let server = makeServer(id: nil)
        let rig = try SettingsRig(servers: [server])
        defer { rig.cleanUp() }
        try rig.renameServerInfo(to: "Music Assistant (abc123)")
        rig.model.appeared()
        await rig.runTest()
        #expect(rig.model.selectedStatus == .failed(.needsToken(foundName: nil)))
        let message = try #require(rig.model.statusMessage)
        #expect(message == "Found a Music Assistant server. Enter a token.")
        #expect(!message.contains("abc123"))
    }

    @Test func testNeedsTokenMessageKeepsAFriendlyName() async throws {
        let server = makeServer(id: nil)
        let rig = try SettingsRig(servers: [server])
        defer { rig.cleanUp() }
        try rig.renameServerInfo(to: "Living Room")
        rig.model.appeared()
        await rig.runTest()
        #expect(rig.model.statusMessage == "Found Living Room. Enter a token.")
    }

    @Test func testMismatchMessageOmitsAGenericName() async throws {
        let server = makeServer(id: "other-server-id")
        let rig = try SettingsRig(servers: [server])
        defer { rig.cleanUp() }
        try rig.renameServerInfo(to: "Music Assistant (abc123)")
        rig.model.appeared()
        rig.model.tokenText = testToken.rawValue
        await rig.runTest()
        #expect(rig.model.selectedStatus == .failed(.serverMismatch(foundName: nil)))
        let message = try #require(rig.model.statusMessage)
        #expect(message == "A different server answered. Its token was not sent.")
        #expect(!message.contains("abc123"))
        #expect(rig.factory.made == 0)
    }

    @Test func testResetsAStoredGenericNameWithTheIDWhenTheServerStaysGeneric() async throws {
        let server = makeServer(id: nil, name: "Music Assistant (abc123)")
        let rig = try SettingsRig(servers: [server])
        defer { rig.cleanUp() }
        try rig.renameServerInfo(to: "Music Assistant (abc123)")
        rig.model.appeared()
        rig.model.tokenText = testToken.rawValue
        await rig.runTest()
        #expect(rig.model.servers[0].name == MusicAssistantServerConfiguration.defaultName)
        #expect(rig.store.load()[0].name == MusicAssistantServerConfiguration.defaultName)
    }

    @Test func addDiscoveredServerDropsAGenericAdvertisedName() throws {
        let rig = try SettingsRig()
        defer { rig.cleanUp() }
        let offer = MusicAssistantDiscoveredServer(
            id: "id-new", url: URL(string: "http://a.local:8095")!, name: "Music Assistant (abc123)")
        rig.model.addDiscoveredServer(offer)
        let added = try #require(rig.store.load().last)
        #expect(added.name == MusicAssistantServerConfiguration.defaultName)
        #expect(added.displayName == "a.local")
    }
}
