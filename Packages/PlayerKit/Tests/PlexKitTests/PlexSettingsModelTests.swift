import Foundation
import Testing
import PlexKit
import PlexKitStub

@MainActor
struct PlexSettingsModelTests {
    static let secret = "tok-UNIT-TEST-SECRET-0123"
    static let identifier = "11111111-2222-3333-4444-555555555555"
    static let machine = "0123456789abcdef0123456789abcdef01234567"

    struct Harness {
        let store: InMemoryPlexTokenStore
        let defaults: UserDefaults
        let suite: String
        let handle: StubURLProtocol.Handle
        let model: PlexSettingsModel
        let opened: URLRecorder

        func cleanup() { defaults.removePersistentDomain(forName: suite) }

        var savedSelection: PlexServerSelection? {
            defaults.data(forKey: PlexSettingsModel.selectionDefaultsKey)
                .flatMap { try? JSONDecoder().decode(PlexServerSelection.self, from: $0) }
        }
    }

    private func make(token: String? = nil, selection: PlexServerSelection? = nil, withAccount: Bool = true) -> Harness {
        let store = InMemoryPlexTokenStore(token: token.map(PlexToken.init))
        let suite = "PlexSettingsModelTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        if let selection { defaults.set(try! JSONEncoder().encode(selection), forKey: PlexSettingsModel.selectionDefaultsKey) }
        let handle = StubURLProtocol.handle()
        let opened = URLRecorder()
        let model = PlexSettingsModel(
            tokenStore: store, defaults: defaults,
            connectionTest: PlexConnectionTest(clientIdentifier: Self.identifier, session: handle.session),
            account: withAccount ? PlexTv.account(handle) : nil,
            signInOptions: .init(pollInterval: .milliseconds(50), timeout: .seconds(5), maxConsecutiveFailures: 3),
            serverResolver: PlexServerResolver(clientIdentifier: Self.identifier, session: handle.session),
            openURL: opened.opener)
        return Harness(store: store, defaults: defaults, suite: suite, handle: handle, model: model, opened: opened)
    }

    private func plexRoutes() throws -> [StubURLProtocol.Route] {
        [try PlexTv.createRoute(), try PlexTv.pollRoute(.pinClaimed), try PlexTv.resourcesRoute()]
    }

    private func okRoutes() throws -> [StubURLProtocol.Route] {
        [try .json(.identity, path: "/identity"), try .json(.sections, path: "/library/sections")]
    }

    private func delayed(_ route: StubURLProtocol.Route, _ seconds: TimeInterval) -> StubURLProtocol.Route {
        var route = route
        route.delay = seconds
        return route
    }

    private func header(_ request: StubURLProtocol.RecordedRequest, _ name: String) -> String? {
        request.headers.first { $0.key.lowercased() == name.lowercased() }?.value
    }

    private func sectionsObject() throws -> (object: [String: Any], container: [String: Any], directories: [[String: Any]]) {
        let object = try #require(try JSONSerialization.jsonObject(with: PlexFixture.sections.data) as? [String: Any])
        let container = try #require(object["MediaContainer"] as? [String: Any])
        let directories = try #require(container["Directory"] as? [[String: Any]])
        return (object, container, directories)
    }

    /// The fixture with its music sections replaced by `artistCount` artist directories.
    private func sectionsRoute(artistCount: Int) throws -> StubURLProtocol.Route {
        var (object, container, directories) = try sectionsObject()
        let artist = try #require(directories.first { ($0["type"] as? String) == "artist" })
        directories = directories.filter { ($0["type"] as? String) != "artist" }
        for index in 0..<artistCount {
            var copy = artist
            if index > 0 {
                copy["key"] = "\(98 + index)"
                copy["title"] = "Music \(index + 1)"
            }
            directories.append(copy)
        }
        container["Directory"] = directories
        object["MediaContainer"] = container
        return .init(path: "/library/sections", body: try JSONSerialization.data(withJSONObject: object))
    }

    @Test func initDoesNoIO() {
        let h = make(token: Self.secret)
        defer { h.cleanup() }
        #expect(h.store.loads == 0)
        #expect(h.handle.recorded.isEmpty)
        #expect(h.model.address == "")
        #expect(h.model.status == .idle)
    }

    @Test func loadReadsSavedSelectionAndToken() {
        let h = make(token: Self.secret, selection: PlexServerSelection(address: "joe", machineIdentifier: "AAAA", librarySectionKey: "5"))
        defer { h.cleanup() }
        h.model.load()
        #expect(h.model.address == "joe")
        #expect(h.model.librarySectionKey == "5")
        #expect(h.model.tokenText == Self.secret)
        #expect(h.model.hasStoredToken)
        h.model.load()
        #expect(h.store.loads == 1)
    }

    @Test func addressEditsPersistWithoutTouchingTheKeychain() {
        let h = make()
        defer { h.cleanup() }
        h.model.address = "joe"
        #expect(h.savedSelection?.address == "joe")
        #expect(h.store.saves == 0)
    }

    @Test func commitTokenSavesTrimmedTokenToTheStoreOnly() throws {
        let h = make()
        defer { h.cleanup() }
        h.model.address = "joe"
        h.model.tokenText = "  \(Self.secret) \n"
        h.model.commitToken()
        #expect(h.store.token == PlexToken(Self.secret))
        #expect(h.store.saves == 1)
        #expect(h.model.hasStoredToken)
        let domain = h.defaults.persistentDomain(forName: h.suite) ?? [:]
        let plist = try PropertyListSerialization.data(fromPropertyList: domain, format: .xml, options: 0)
        #expect(!String(decoding: plist, as: UTF8.self).contains(Self.secret))
    }

    @Test func commitEmptyTokenDeletesIt() {
        let h = make(token: Self.secret)
        defer { h.cleanup() }
        h.model.load()
        h.model.tokenText = ""
        h.model.commitToken()
        #expect(h.store.token == nil)
        #expect(h.store.deletes == 1)
        #expect(!h.model.hasStoredToken)

        let g = make(token: Self.secret)
        defer { g.cleanup() }
        g.model.load()
        g.model.forgetToken()
        #expect(g.store.token == nil)
        #expect(g.model.tokenText == "")
        #expect(!g.model.hasStoredToken)
    }

    @Test func failedLoadThenCloseDoesNotDeleteTheToken() {
        let h = make(token: Self.secret)
        defer { h.cleanup() }
        h.store.failure = .keychain(-128)
        h.model.load()
        #expect(h.model.tokenStoreError != nil)
        h.store.failure = nil
        h.model.disappeared()
        #expect(h.store.deletes == 0)
        #expect(h.store.saves == 0)
        #expect(h.store.token == PlexToken(Self.secret))
        // A later appearance retries the read.
        h.model.load()
        #expect(h.model.tokenText == Self.secret)
        #expect(h.model.tokenStoreError == nil)
    }

    @Test func failedLoadThenReturnDoesNotDeleteTheToken() {
        let h = make(token: Self.secret)
        defer { h.cleanup() }
        h.store.failure = .keychain(-128)
        h.model.load()
        h.store.failure = nil
        h.model.submitToken()
        #expect(h.store.deletes == 0)
        #expect(h.store.saves == 0)
        #expect(h.store.token == PlexToken(Self.secret))
    }

    @Test func returnAfterAnEditSaves() {
        let h = make(token: Self.secret)
        defer { h.cleanup() }
        h.model.load()
        h.model.tokenText = "other-token"
        h.model.submitToken()
        #expect(h.store.saves == 1)
        #expect(h.store.token == PlexToken("other-token"))
    }

    @Test func closeWithoutEditsDoesNotWrite() {
        let h = make(token: Self.secret)
        defer { h.cleanup() }
        h.model.load()
        h.model.disappeared()
        #expect(h.store.saves == 0)
        #expect(h.store.deletes == 0)
        #expect(h.store.token == PlexToken(Self.secret))
    }

    @Test func tokenStoreFailureIsShownNotThrown() {
        let h = make()
        defer { h.cleanup() }
        h.store.failure = .keychain(-25293)
        h.model.address = "stub.local"
        h.model.tokenText = Self.secret
        h.model.commitToken()
        let error = h.model.tokenStoreError
        #expect(error != nil)
        #expect(!(error ?? "").contains(Self.secret))
        h.model.testConnection()
        #expect(h.handle.recorded.isEmpty)
        #expect(h.model.status == .idle)
    }

    @Test func testConnectionSavesTokenThenSucceeds() async throws {
        let h = make()
        defer { h.cleanup() }
        h.handle.register(try okRoutes())
        h.model.address = "stub.local"
        h.model.tokenText = Self.secret
        h.model.testConnection()
        #expect(h.model.status == .testing)
        await h.model.waitForTest()
        guard case .connected(let connection, _) = h.model.status else {
            Issue.record("expected connected, got \(h.model.status)")
            return
        }
        let expectedKeys = try sectionsObject().directories.filter { ($0["type"] as? String) == "artist" }.compactMap { $0["key"] as? String }
        #expect(connection.musicSections.map(\.key) == expectedKeys)
        #expect(h.store.saves == 1)
        let recorded = h.handle.recorded
        #expect(recorded.count == 2)
        #expect(header(recorded[1], "X-Plex-Token") == Self.secret)
        #expect(h.savedSelection?.machineIdentifier == Self.machine)
        #expect(h.model.statusMessage?.hasPrefix("Connected to Plex Media Server") == true)
    }

    @Test func singleMusicLibraryIsAutoSelectedAndPickerHidden() async throws {
        let h = make()
        defer { h.cleanup() }
        h.handle.register([try .json(.identity, path: "/identity"), try sectionsRoute(artistCount: 1)])
        h.model.address = "stub.local"
        h.model.tokenText = Self.secret
        h.model.testConnection()
        await h.model.waitForTest()
        guard case .connected(let connection, let change) = h.model.status else {
            Issue.record("expected connected, got \(h.model.status)")
            return
        }
        #expect(change == .autoSelected)
        #expect(connection.musicSections.count == 1)
        #expect(h.model.librarySectionKey == connection.musicSections[0].key)
        #expect(!h.model.showsLibraryPicker)
        #expect(h.model.selectedSection?.title == connection.musicSections[0].title)
    }

    @Test func multipleMusicLibrariesShowThePicker() async throws {
        let h = make()
        defer { h.cleanup() }
        h.handle.register([try .json(.identity, path: "/identity"), try sectionsRoute(artistCount: 2)])
        h.model.address = "stub.local"
        h.model.tokenText = Self.secret
        h.model.testConnection()
        await h.model.waitForTest()
        #expect(h.model.showsLibraryPicker)
        #expect(h.model.librarySectionKey == nil)
        h.model.librarySectionKey = "99"
        #expect(h.savedSelection?.librarySectionKey == "99")
        #expect(h.model.selectedSection?.key == "99")
    }

    @Test func failureShowsTheConnectionTestMessage() async throws {
        let h = make()
        defer { h.cleanup() }
        h.handle.register([.init(path: "/identity", status: 500, headers: ["Content-Type": "text/html"], body: Data("x".utf8))])
        h.model.address = "stub.local"
        h.model.tokenText = Self.secret
        h.model.testConnection()
        await h.model.waitForTest()
        #expect(h.model.status == .failed(.unreachable(.httpStatus(500))))
        #expect(h.model.statusMessage == PlexConnectionFailure.unreachable(.httpStatus(500)).message)
        #expect(h.model.statusDetail == PlexError.httpStatus(500).errorDescription)

        h.handle.register([try .json(.identity, path: "/identity"),
                           .init(path: "/library/sections", status: 401, headers: ["Content-Type": "text/html"], body: Data("x".utf8))])
        h.model.testConnection()
        await h.model.waitForTest()
        #expect(h.model.status == .failed(.unauthorized))
        #expect(h.model.statusMessage == PlexConnectionFailure.unauthorized.message)
        #expect(h.model.statusDetail == nil)
    }

    @Test func invalidAddressFailsWithoutARequest() async {
        let h = make()
        defer { h.cleanup() }
        h.model.address = "ftp://joe"
        h.model.tokenText = Self.secret
        h.model.testConnection()
        await h.model.waitForTest()
        #expect(h.model.status == .failed(.invalidAddress))
        #expect(h.handle.recorded.isEmpty)
    }

    @Test func editingTheAddressCancelsTheTestWithoutAnError() async throws {
        for edit in [0, 1] {
            let h = make()
            defer { h.cleanup() }
            h.handle.register([delayed(try .json(.identity, path: "/identity"), 0.5), try .json(.sections, path: "/library/sections")])
            h.model.address = "stub.local"
            h.model.tokenText = Self.secret
            h.model.testConnection()
            #expect(h.model.status == .testing)
            if edit == 0 { h.model.address = "stub.local/other" } else { h.model.tokenText = "x" }
            #expect(h.model.status == .idle)
            await h.model.waitForTest()
            try await Task.sleep(for: .seconds(0.7))
            #expect(h.model.status == .idle)
        }
    }

    @Test func cancelTestLeavesIdle() async throws {
        let h = make()
        defer { h.cleanup() }
        h.handle.register([delayed(try .json(.identity, path: "/identity"), 0.5), try .json(.sections, path: "/library/sections")])
        h.model.address = "stub.local"
        h.model.tokenText = Self.secret
        h.model.testConnection()
        h.model.cancelTest()
        #expect(h.model.status == .idle)
        try await Task.sleep(for: .seconds(0.7))
        #expect(h.model.status == .idle)

        h.model.testConnection()
        #expect(h.model.status == .testing)
        h.model.disappeared()
        #expect(h.model.status == .idle)
        #expect(h.store.saves == 1)
        try await Task.sleep(for: .seconds(0.7))
        #expect(h.model.status == .idle)
    }

    @Test func aLaterTestWinsOverAnEarlierOne() async throws {
        let h = make()
        defer { h.cleanup() }
        h.handle.register([delayed(.init(path: "/identity", status: 500, headers: ["Content-Type": "text/html"], body: Data("x".utf8)), 0.5)])
        h.model.address = "stub.local"
        h.model.tokenText = Self.secret
        h.model.testConnection()
        try await Task.sleep(for: .seconds(0.1))
        h.handle.register(try okRoutes())
        h.model.testConnection()
        await h.model.waitForTest()
        try await Task.sleep(for: .seconds(0.6))
        guard case .connected = h.model.status else {
            Issue.record("expected connected, got \(h.model.status)")
            return
        }
        #expect(h.handle.recorded.count == 3)
    }

    @Test func appearedRunsTheTestOnlyWithSavedInputs() async throws {
        let h = make(token: Self.secret, selection: PlexServerSelection(address: "stub.local"))
        defer { h.cleanup() }
        h.handle.register(try okRoutes())
        h.model.appeared()
        await h.model.waitForTest()
        #expect(h.handle.recorded.count == 2)
        guard case .connected = h.model.status else {
            Issue.record("expected connected, got \(h.model.status)")
            return
        }

        let g = make(selection: PlexServerSelection(address: "stub.local"))
        defer { g.cleanup() }
        g.model.appeared()
        await g.model.waitForTest()
        #expect(g.handle.recorded.isEmpty)
        #expect(g.model.status == .idle)
    }

    @Test func serverChangeClearsTheLibrary() async throws {
        let h = make(token: Self.secret, selection: PlexServerSelection(address: "stub.local", machineIdentifier: "AAAA", librarySectionKey: "5"))
        defer { h.cleanup() }
        h.handle.register([try .json(.identity, path: "/identity"), try sectionsRoute(artistCount: 1)])
        h.model.appeared()
        await h.model.waitForTest()
        guard case .connected(let connection, let change) = h.model.status else {
            Issue.record("expected connected, got \(h.model.status)")
            return
        }
        #expect(change == .serverChanged)
        #expect(h.model.changeNote == "This address now points to a different server; the music library was reset.")
        #expect(h.model.librarySectionKey == connection.musicSections[0].key)
    }

    @Test func modelNeverPrintsTheToken() {
        let h = make()
        defer { h.cleanup() }
        h.model.address = "stub.local"
        h.model.tokenText = Self.secret
        var dumped = ""
        dump(h.model, to: &dumped)
        for text in [String(describing: h.model), String(reflecting: h.model), dumped] {
            #expect(!text.contains(Self.secret))
        }
    }

    // MARK: Sign in with Plex

    @Test func signInStoresTheTokenAndRunsTheTest() async throws {
        let fake = try PlexTv.fakeToken
        let h = make(selection: PlexServerSelection(address: "stub.local"))
        defer { h.cleanup() }
        h.model.load()
        h.handle.register(try plexRoutes() + okRoutes())
        h.model.signIn()
        #expect(h.model.isSigningIn)
        await h.model.waitForSignIn()
        #expect(h.store.token == PlexToken(fake))
        #expect(h.store.saves == 1)
        #expect(h.model.hasStoredToken)
        #expect(h.model.tokenText == fake)
        #expect(h.model.signInStatus == .signedIn)
        #expect(h.model.signInMessage == "Signed in with Plex.")
        #expect(h.opened.opened.count == 1)
        await h.model.waitForTest()
        guard case .connected = h.model.status else {
            Issue.record("expected connected, got \(h.model.status)")
            return
        }
        let sections = try #require(h.handle.recorded.first { $0.url.path == "/library/sections" })
        #expect(header(sections, "X-Plex-Token") == fake)
        h.model.disappeared()
        #expect(h.store.saves == 1)
        let domain = h.defaults.persistentDomain(forName: h.suite) ?? [:]
        let plist = try PropertyListSerialization.data(fromPropertyList: domain, format: .xml, options: 0)
        #expect(!String(decoding: plist, as: UTF8.self).contains(fake))
    }

    @Test func signInWithoutAnAddressChoosesTheOnlyServer() async throws {
        let h = make()
        defer { h.cleanup() }
        let only = try PlexTv.ownedServerOnly()
        h.handle.register(try [PlexTv.createRoute(), PlexTv.pollRoute(.pinClaimed), PlexTv.resourcesRoute(body: only)] + okRoutes())
        h.model.signIn()
        await h.model.waitForSignIn()
        await h.model.waitForServers()
        let resources = try JSONDecoder().decode([PlexResource].self, from: only)
        let uri = try #require(resources[0].preferredConnection?.uri)
        #expect(h.model.address == uri)
        #expect(h.savedSelection?.address == uri)
        await h.model.waitForTest()
        guard case .connected = h.model.status else {
            Issue.record("expected connected, got \(h.model.status)")
            return
        }
        #expect(h.savedSelection?.machineIdentifier == Self.machine)
    }

    @Test func signInWithoutAnAddressListsSeveralServers() async throws {
        let h = make()
        defer { h.cleanup() }
        h.handle.register(try plexRoutes() + okRoutes())
        h.model.signIn()
        await h.model.waitForSignIn()
        await h.model.waitForServers()
        #expect(h.model.servers.count == 2)
        #expect(h.model.address == "")
        #expect(h.model.status == .idle)
        let shared = try #require(h.model.servers.first { !$0.owned })
        #expect(h.model.serverLabel(shared).contains("(shared)"))
        let owned = try #require(h.model.servers.first { $0.owned })
        #expect(!h.model.serverLabel(owned).contains("(shared)"))
    }

    @Test func cancelSignInLeavesIdle() async throws {
        for variant in 0..<4 {
            let h = make(token: Self.secret)
            defer { h.cleanup() }
            h.model.load()
            h.handle.register([try PlexTv.createRoute(), try PlexTv.pollRoute()])
            h.model.signIn()
            let handle = h.handle
            #expect(await PlexTv.wait { handle.recorded.contains(where: PlexTv.isPoll) })
            switch variant {
            case 0: h.model.cancelSignIn()
            case 1: h.model.disappeared()
            case 2: h.model.forgetToken()
            default: h.model.tokenText = "typing"
            }
            #expect(h.model.signInStatus == .idle)
            try await Task.sleep(for: .seconds(0.3))
            #expect(h.model.signInStatus == .idle)
            #expect(h.store.saves == 0)
        }
    }

    @Test func signInFailureKeepsTheStoredToken() async throws {
        let h = make(token: Self.secret)
        defer { h.cleanup() }
        h.model.load()
        h.handle.register([try PlexTv.createRoute(status: 500)])
        h.model.signIn()
        await h.model.waitForSignIn()
        #expect(h.model.signInStatus == .failed(.unreachable(.httpStatus(500))))
        #expect(h.model.signInMessage == PlexSignInFailure.unreachable(.httpStatus(500)).message)
        #expect(h.model.signInDetail == PlexError.httpStatus(500).errorDescription)
        #expect(h.store.token == PlexToken(Self.secret))
        #expect(h.model.tokenText == Self.secret)
        #expect(h.store.saves == 0)
    }

    @Test func signInStoreFailureKeepsTheTokenInTheField() async throws {
        let fake = try PlexTv.fakeToken
        let h = make()
        defer { h.cleanup() }
        h.handle.register(try plexRoutes() + okRoutes())
        h.store.failure = .keychain(-25293)
        h.model.signIn()
        await h.model.waitForSignIn()
        await h.model.waitForServers()
        #expect(h.model.tokenStoreError != nil)
        #expect(h.model.tokenText == fake)
        #expect(h.model.signInStatus == .signedIn)
        let before = h.store.saves
        h.store.failure = nil
        h.model.submitToken()
        #expect(h.store.saves == before + 1)
        #expect(h.store.token == PlexToken(fake))
        #expect(h.model.tokenStoreError == nil)
    }

    @Test func useServerSetsTheAddressAndTests() async throws {
        let h = make(token: Self.secret)
        defer { h.cleanup() }
        h.model.load()
        h.handle.register(try plexRoutes() + okRoutes())
        h.model.loadServers()
        await h.model.waitForServers()
        let server = try #require(h.model.servers.first)
        h.model.useServer(server)
        await h.model.waitForServers()
        let preferred = try #require(server.preferredConnection)
        #expect(h.model.address == preferred.uri)
        await h.model.waitForTest()
        guard case .connected = h.model.status else {
            Issue.record("expected connected, got \(h.model.status)")
            return
        }
        let sections = try #require(h.handle.recorded.first { $0.url.path == "/library/sections" })
        #expect(sections.url.host == preferred.url?.host)
    }

    @Test func useServerKeepsTheAddressWhenNothingAnswers() async throws {
        let h = make(token: Self.secret, selection: PlexServerSelection(address: "joe"))
        defer { h.cleanup() }
        h.model.load()
        h.handle.register([try PlexTv.resourcesRoute(), .init(path: "/identity", error: URLError(.cannotConnectToHost))])
        h.model.loadServers()
        await h.model.waitForServers()
        let server = try #require(h.model.servers.first)
        h.model.useServer(server)
        await h.model.waitForServers()
        #expect(h.model.address == "joe")
        #expect(h.model.serversMessage?.contains("kept") == true)
        #expect(h.model.status == .idle)
        #expect(!h.handle.recorded.contains { $0.url.path == "/library/sections" })
    }

    @Test func loadServersNeedsAToken() async throws {
        let h = make()
        defer { h.cleanup() }
        h.handle.register([try PlexTv.resourcesRoute()])
        h.model.loadServers()
        await h.model.waitForServers()
        #expect(h.handle.recorded.isEmpty)
        #expect(h.model.servers.isEmpty)

        h.model.tokenText = Self.secret
        h.handle.register([try PlexTv.resourcesRoute(status: 401)])
        h.model.loadServers()
        await h.model.waitForServers()
        #expect(h.model.serversMessage?.contains("Sign in again") == true)
        #expect(h.model.servers.isEmpty)

        h.handle.register([try PlexTv.resourcesRoute(body: Data("[]".utf8))])
        h.model.loadServers()
        await h.model.waitForServers()
        #expect(h.model.serversMessage?.contains("no servers") == true)
    }

    @Test func modelNeverPrintsTheTokenAfterSignIn() async throws {
        let fake = try PlexTv.fakeToken
        let h = make(token: Self.secret)
        defer { h.cleanup() }
        h.model.load()
        h.handle.register(try plexRoutes() + okRoutes())
        h.model.signIn()
        await h.model.waitForSignIn()
        h.model.loadServers()
        await h.model.waitForServers()
        await h.model.waitForTest()
        var dumped = ""
        dump(h.model, to: &dumped)
        for text in [String(describing: h.model), String(reflecting: h.model), dumped] {
            #expect(!text.contains(fake))
            #expect(!text.contains(Self.secret))
        }
    }

    @Test func withoutAnAccountClientSignInIsOff() async {
        let h = make(token: Self.secret, withAccount: false)
        defer { h.cleanup() }
        h.model.load()
        #expect(!h.model.canSignIn)
        #expect(!h.model.canChooseServer)
        h.model.signIn()
        h.model.loadServers()
        await h.model.waitForSignIn()
        await h.model.waitForServers()
        #expect(h.model.signInStatus == .idle)
        #expect(h.handle.recorded.isEmpty)
    }
}
