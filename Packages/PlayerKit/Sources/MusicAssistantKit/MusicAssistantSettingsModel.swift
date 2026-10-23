import Foundation
import Observation
import os

private let log = Logger(subsystem: "co.sstools.roadie", category: "MusicAssistantSettings")

/// Everything Settings › Music Assistant does, apart from drawing it: the server list, one Keychain item per
/// server, address and token editing, and Test Connection.
///
/// The token is write-only: it is never read back into `tokenText`. An empty field means "keep what is stored".
/// A failed Keychain read or existence check never deletes anything; only `removeToken()`, `removeServer(_:)` and
/// `replaceIdentity()` delete. Logs carry counts, states and OSStatus numbers only.
@MainActor @Observable
public final class MusicAssistantSettingsModel: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public typealias Failure = MusicAssistantConnectionFailure

    public enum Status: Hashable, Sendable {
        case untested
        case testing
        case connected(name: String?, version: String?)
        /// Never a cancellation: that goes back to `.untested`.
        case failed(Failure)
    }

    @ObservationIgnored private let store: MusicAssistantServerStore
    @ObservationIgnored private let tokenStore: @Sendable (String) -> any MusicAssistantTokenStore
    @ObservationIgnored private let test: MusicAssistantConnectionTest
    @ObservationIgnored private let active: MusicAssistantActiveServer
    @ObservationIgnored private var testTask: Task<Void, Never>?
    /// The token field was edited since the last commit. Only a dirty, non-empty field is ever saved.
    @ObservationIgnored private var tokenDirty = false

    public private(set) var servers: [MusicAssistantServerConfiguration] = []
    private var selection: UUID?
    private var addressDraft = ""
    private var enteredToken = ""

    public private(set) var status: [UUID: Status] = [:]
    /// From `exists()`; an absent key means unknown.
    public private(set) var hasStoredToken: [UUID: Bool] = [:]
    public private(set) var tokenStoreError: String?
    /// Called (on the main actor) after every change to the stored list (#0075: the selection re-checks unless only names changed, #0092).
    @ObservationIgnored public var onServersChanged: (@MainActor () -> Void)?
    @ObservationIgnored private let wifi: (any WiFiNetworkProvider)?
    /// Why "Use Current Network" added nothing (no Location access, no Wi-Fi). Cleared by the next success or edit.
    public private(set) var locationMessage: LocationMessage?

    public enum LocationMessage: Hashable, Sendable {
        case needsLocationAccess
        case notOnWiFi

        public var text: String {
            switch self {
            case .needsLocationAccess:
                "Using the network name needs Location access. Roadie still finds your server by trying each one."
            case .notOnWiFi: "Not connected to Wi-Fi."
            }
        }
    }

    /// No I/O here: the app's launch must not touch the Keychain, the network or the stored list.
    public init(
        store: MusicAssistantServerStore, tokenStore: @escaping @Sendable (String) -> any MusicAssistantTokenStore,
        test: MusicAssistantConnectionTest, active: MusicAssistantActiveServer, wifi: (any WiFiNetworkProvider)? = nil
    ) {
        self.wifi = wifi
        self.store = store
        self.tokenStore = tokenStore
        self.test = test
        self.active = active
    }

    public nonisolated var description: String { "MusicAssistantSettingsModel(redacted)" }
    public nonisolated var debugDescription: String { description }
    public nonisolated var customMirror: Mirror { Mirror(self, children: []) }

    // MARK: Selection and inputs

    /// The row being edited. Not persisted. Changing it commits the old row's edits and cancels a test.
    public var selectedID: UUID? {
        get { selection }
        set { select(newValue) }
    }

    public var selected: MusicAssistantServerConfiguration? { servers.first { $0.id == selection } }

    public var name: String {
        get { selected?.name ?? "" }
        set {
            guard let index = selectedIndex, servers[index].name != newValue else { return }
            servers[index].name = newValue
            persist()  // also refreshes the active copy, so the Library subtitle follows a rename
        }
    }

    /// What the user typed. Applied to the server by `commitAddress()` (Return, Test Connection, leaving the row or
    /// the window), so typing never reconnects the backend halfway through an address.
    public var addressText: String {
        get { addressDraft }
        set {
            guard newValue != addressDraft else { return }
            addressDraft = newValue
            invalidate()
        }
    }

    /// Memory only until committed. Changing it cancels an in-flight test.
    public var tokenText: String {
        get { enteredToken }
        set {
            guard newValue != enteredToken else { return }
            enteredToken = newValue
            tokenDirty = true
            invalidate()
        }
    }

    /// The problem with the typed address, shown as soon as there is one. nil for an empty field (nothing typed yet).
    public var addressProblem: MusicAssistantAddressInput.Problem? {
        guard !addressDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if case .failure(let problem) = MusicAssistantAddressInput.parse(addressDraft) { return problem }
        return nil
    }

    public var selectedStatus: Status { selection.flatMap { status[$0] } ?? .untested }
    public var isTesting: Bool { selectedStatus == .testing }
    public var canTest: Bool {
        guard selected != nil, !isTesting else { return false }
        if case .success = MusicAssistantAddressInput.parse(addressDraft) { return true }
        return false
    }

    /// The selected server has a stored token; nil while unknown.
    public var selectedHasStoredToken: Bool? { selection.flatMap { hasStoredToken[$0] } }

    public var statusMessage: String? {
        switch selectedStatus {
        case .untested, .testing: nil
        case .connected(let name, let version):
            "Connected" + (name.map { " to \($0)" } ?? "") + (version.map { " (version \($0))" } ?? "") + "."
        case .failed(let failure): failure.message
        }
    }

    /// The server currently in use, if any.
    public var activeID: UUID? { active.current?.id }

    // MARK: Lifecycle

    /// Reads the list from defaults and asks the Keychain which servers have a token (attributes only: no prompt).
    public func appeared() {
        servers = store.load()
        if selection == nil || !servers.contains(where: { $0.id == selection }) {
            selection = servers.first?.id
        }
        loadDraft()
        var failed = 0
        for server in servers {
            do {
                hasStoredToken[server.id] = try tokenStore(server.keychainAccount).exists()
            } catch {
                failed += 1
            }
        }
        tokenStoreError = failed == 0 ? nil : "The Keychain could not be checked for a saved token."
        log.info("appeared: \(self.servers.count) servers, \(failed) token checks failed")
    }

    /// Commits a typed address and token for the selected row and cancels a test.
    public func disappeared() {
        commitAddress()
        commitToken()
        cancelTest()
    }

    // MARK: List

    public func addServer() {
        commitEdits()
        let server = MusicAssistantServerConfiguration()
        servers.append(server)
        persist()
        select(server.id)
        log.info("server added: \(self.servers.count) now")
    }

    // MARK: Discovery (#0104)

    /// Adds a server found on the network as an untested row (no `serverID`: Test Connection learns it) and selects
    /// it. A row with the same address or id is selected instead. Works when Settings never appeared.
    public func addDiscoveredServer(_ found: MusicAssistantDiscoveredServer) {
        commitEdits()
        servers = store.load()
        if let existing = servers.first(where: { $0.address.baseURL == found.url || $0.address.serverID == found.id }) {
            select(existing.id)
            return
        }
        let name = MusicAssistantServerConfiguration.isGenericName(found.name)
            ? MusicAssistantServerConfiguration.defaultName : found.name!
        let server = MusicAssistantServerConfiguration(name: name, address: MusicAssistantServerAddress(baseURL: found.url))
        servers.append(server)
        persist()
        select(server.id)
        log.info("discovered server added: \(self.servers.count) now")
    }

    /// The same server answered at `url` and its stored address did not: move the row there, keeping its id, token,
    /// name and networks. Changes nothing unless the row's stored `server_id` equals `serverID`. The selection re-checks
    /// through `onServersChanged`.
    public func adoptDiscoveredAddress(_ url: URL, for id: UUID, serverID: String) {
        commitEdits()
        servers = store.load()
        guard let index = servers.firstIndex(where: { $0.id == id }), servers[index].address.serverID == serverID,
            servers[index].address.baseURL != url
        else { return }
        servers[index].address.baseURL = url
        persist()
        if id == selection { loadDraft() }
        log.info("server address updated from discovery")
    }

    public func removeServer(_ id: UUID) {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = id == selection
        if wasSelected { cancelTest() }
        let account = servers[index].keychainAccount
        servers.remove(at: index)
        status[id] = nil
        hasStoredToken[id] = nil
        persist()
        do {
            try tokenStore(account).delete()
        } catch let error as MusicAssistantTokenStoreError {
            if case .keychain(let code) = error { log.info("token delete failed \(code, privacy: .public)") }
        } catch {
            log.info("token delete failed")
        }
        if wasSelected {
            selection = servers.indices.contains(index) ? servers[index].id : servers.last?.id
            enteredToken = ""
            tokenDirty = false
            loadDraft()
        }
        log.info("server removed: \(self.servers.count) left")
    }

    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().filter { servers.indices.contains($0) }.map { servers[$0] }
        guard !moving.isEmpty else { return }
        var remaining = servers
        for index in source.sorted().reversed() where remaining.indices.contains(index) { remaining.remove(at: index) }
        let insertAt = max(0, min(remaining.count, destination - source.filter { $0 < destination }.count))
        remaining.insert(contentsOf: moving, at: insertAt)
        servers = remaining
        persist()
    }

    // MARK: Wi-Fi networks (#0075)

    /// The selected server's Wi-Fi network names.
    public var networks: [String] { selected?.networks ?? [] }

    /// Adds a network name typed by hand (trimmed; a duplicate or empty name is ignored).
    public func addNetwork(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = selectedIndex, !trimmed.isEmpty, !servers[index].networks.contains(trimmed) else { return }
        servers[index].networks.append(trimmed)
        locationMessage = nil
        persist()
    }

    public func removeNetwork(_ name: String) {
        guard let index = selectedIndex, servers[index].networks.contains(name) else { return }
        servers[index].networks.removeAll { $0 == name }
        persist()
    }

    /// "Use Current Network": the only place Location permission is requested, and only when undetermined.
    public func useCurrentNetwork() async {
        guard let wifi, selected != nil else { return }
        var authorization = wifi.authorization
        if authorization == .notDetermined { authorization = await wifi.requestAuthorization() }
        switch authorization {
        case .authorized:
            guard let ssid = wifi.currentSSID()?.trimmingCharacters(in: .whitespacesAndNewlines), !ssid.isEmpty else {
                locationMessage = .notOnWiFi
                return
            }
            locationMessage = nil
            addNetwork(ssid)
        case .denied, .restricted, .notDetermined:
            locationMessage = .needsLocationAccess
        }
    }

    // MARK: Token

    /// Return in the token field: commits only an edit that is not empty.
    public func submitToken() {
        commitToken()
    }

    /// The explicit delete.
    public func removeToken() {
        guard let server = selected else { return }
        cancelTest()
        enteredToken = ""
        tokenDirty = false
        do {
            try tokenStore(server.keychainAccount).delete()
            hasStoredToken[server.id] = false
            tokenStoreError = nil
            log.info("token removed")
        } catch {
            noteStoreFailure(error)
        }
        status[server.id] = .untested
    }

    /// After `.serverMismatch`: forgets the learned `server_id` and deletes this server's token, so the user can
    /// enter the token of the server that now answers.
    public func replaceIdentity() {
        guard let index = selectedIndex else { return }
        cancelTest()
        let server = servers[index]
        servers[index].address.serverID = nil
        persist()
        enteredToken = ""
        tokenDirty = false
        do {
            try tokenStore(server.keychainAccount).delete()
            hasStoredToken[server.id] = false
            tokenStoreError = nil
        } catch {
            noteStoreFailure(error)
        }
        status[server.id] = .untested
        log.info("identity replaced")
    }

    // MARK: Test Connection

    public func testConnection() {
        commitAddress()
        cancelTest()
        guard let index = selectedIndex else { return }
        let server = servers[index]
        let url: URL
        switch MusicAssistantAddressInput.parse(addressDraft) {
        case .success(let parsed): url = parsed
        case .failure(let problem):
            status[server.id] = .failed(.invalidAddress(problem))
            return
        }
        let typed = trimmedToken
        let typedToken = tokenDirty && !typed.isEmpty ? MusicAssistantToken(typed) : nil
        status[server.id] = .testing
        let test = test
        let account = server.keychainAccount
        let tokenStore = tokenStore
        let knownID = server.address.serverID
        let id = server.id
        log.info("test started")
        testTask = Task { [weak self] in
            let outcome = await test.run(
                baseURL: url, knownServerID: knownID, typedToken: typedToken, loadStored: { try tokenStore(account).load() })
            guard let self, !Task.isCancelled, let outcome else { return }
            self.apply(outcome, for: id, typedToken: typedToken)
        }
    }

    public func cancelTest() {
        testTask?.cancel()
        testTask = nil
        if let id = selection, status[id] == .testing { status[id] = .untested }
    }

    /// Awaits the in-flight test, for tests.
    public func waitForTest() async {
        await testTask?.value
    }

    // MARK: Private

    private var selectedIndex: Int? { servers.firstIndex { $0.id == selection } }
    private var trimmedToken: String { enteredToken.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func select(_ id: UUID?) {
        guard id != selection else { return }
        locationMessage = nil
        commitEdits()
        cancelTest()
        selection = id
        enteredToken = ""
        tokenDirty = false
        loadDraft()
    }

    private func loadDraft() {
        guard let server = selected, !server.hasNoAddress else {
            addressDraft = ""
            return
        }
        addressDraft = MusicAssistantAddressInput.displayText(server.address.baseURL)
    }

    /// An edit invalidates the last result and any test in flight.
    private func invalidate() {
        cancelTest()
        if let id = selection, status[id] != nil { status[id] = .untested }
    }

    private func commitEdits() {
        commitAddress()
        commitToken()
    }

    /// Applies a typed address that parses. The learned `serverID` is kept: the same server may have moved, and the
    /// next connection proves or refutes it ("a different server answered").
    public func commitAddress() {
        guard let index = selectedIndex, case .success(let url) = MusicAssistantAddressInput.parse(addressDraft),
            servers[index].address.baseURL != url
        else { return }
        servers[index].address.baseURL = url
        persist()
    }

    /// Saves a dirty, non-empty token for the selected server. An empty field commits nothing.
    @discardableResult
    private func commitToken() -> Bool {
        guard tokenDirty, let server = selected else { return true }
        let text = trimmedToken
        guard !text.isEmpty else { return true }
        do {
            try tokenStore(server.keychainAccount).save(MusicAssistantToken(text))
            hasStoredToken[server.id] = true
            tokenStoreError = nil
            enteredToken = ""
            tokenDirty = false
            log.info("token saved")
            return true
        } catch {
            noteStoreFailure(error)
            return false
        }
    }

    private func apply(_ outcome: MusicAssistantConnectionTest.Outcome, for id: UUID, typedToken: MusicAssistantToken?) {
        testTask = nil
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        switch outcome {
        case .failed(let failure):
            status[id] = .failed(failure)
            log.info("test failed")
        case .connected(let info):
            servers[index].address.serverID = info.serverID
            if MusicAssistantServerConfiguration.isGenericName(servers[index].name) {
                if let found = info.name, !MusicAssistantServerConfiguration.isGenericName(found) {
                    servers[index].name = found
                } else if servers[index].name != MusicAssistantServerConfiguration.defaultName {
                    // A legacy row holding the generic label with the server id: never show the id in the Name field.
                    servers[index].name = MusicAssistantServerConfiguration.defaultName
                }
            }
            persist()
            let saved = typedToken == nil || id != selection || commitToken()
            // displayName, not info.name: the advertised generic label carries the server id (#0119).
            status[id] = saved
                ? .connected(name: servers[index].displayName, version: info.serverVersion)
                : .failed(.keychain(tokenStoreError ?? ""))
            log.info("test connected")
        }
    }

    /// The selection (#0075) owns the choice. Here only the active copy follows a rename; an identity change or a
    /// removal clears it until the selection resolves again.
    private func refreshActive() {
        guard let current = active.current else { return }
        if let updated = servers.first(where: { $0.id == current.id }), updated.sameIdentity(as: current) {
            active.set(updated)
        } else {
            active.set(nil)
        }
    }

    /// Saves the list, refreshes the active copy and tells the selection.
    private func persist() {
        store.save(servers)
        refreshActive()
        onServersChanged?()
    }

    private func noteStoreFailure(_ error: any Error) {
        tokenStoreError = (error as? any LocalizedError)?.errorDescription ?? "The Keychain could not be used."
        if let storeError = error as? MusicAssistantTokenStoreError, case .keychain(let code) = storeError {
            log.info("token store failed \(code, privacy: .public)")
        }
    }
}
