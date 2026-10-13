import Foundation
import Observation
import os

private let log = Logger(subsystem: "com.brennanmke.SkinAmp", category: "PlexSettings")

/// Everything the Settings › Plex tab does, apart from drawing it: persistence, the token commit,
/// the connection-test state machine, cancellation and picker visibility. The views stay thin.
@MainActor @Observable
public final class PlexSettingsModel: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public enum Status: Hashable, Sendable {
        case idle
        case testing
        case connected(PlexConnection, PlexServerSelection.Change)
        /// Never `.cancelled`: cancellation goes back to `.idle`.
        case failed(PlexConnectionFailure)
    }

    public enum SignInStatus: Hashable, Sendable {
        case idle
        case waitingForBrowser
        case signedIn
        /// Never `.cancelled`: cancellation goes back to `.idle`.
        case failed(PlexSignInFailure)
    }

    /// JSON of `PlexServerSelection`.
    public nonisolated static let selectionDefaultsKey = "PlexServerSelection"

    @ObservationIgnored private let tokenStore: any PlexTokenStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let connectionTest: PlexConnectionTest
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private let account: PlexAccountClient?
    @ObservationIgnored private let signInOptions: PlexPinSignIn.Options
    @ObservationIgnored private let serverResolver: PlexServerResolver
    @ObservationIgnored private let openURL: PlexPinSignIn.URLOpener
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    /// The one handle for every server lookup (resources, probe, auto-select chain). Invariant:
    /// every assignment cancels the previous task first, so a task that is not cancelled is the
    /// current one and may clear this field; a cancelled task never touches model state, and
    /// whoever cancelled it owns the state. `invalidate()` must not cancel it: `resolveAndUse`
    /// sets `address`, which calls `invalidate()` from inside the task.
    @ObservationIgnored private var serversTask: Task<Void, Never>?
    @ObservationIgnored private var loaded = false
    /// The field was edited since the last successful load or commit. Only then does closing the
    /// window or testing write to the store; a failed read must never turn into a delete.
    @ObservationIgnored private var tokenDirty = false

    private var selection = PlexServerSelection()
    private var enteredToken = ""

    public private(set) var status: Status = .idle
    /// From the last successful test this session.
    public private(set) var musicSections: [PlexLibrarySection] = []
    public private(set) var tokenStoreError: String?
    public private(set) var hasStoredToken = false
    private var lastChange: PlexServerSelection.Change = .none

    public private(set) var signInStatus: SignInStatus = .idle
    public private(set) var servers: [PlexResource] = []
    public private(set) var isLoadingServers = false
    public private(set) var serversMessage: String?

    /// No I/O here: the app's launch must not touch the Keychain or the network.
    ///
    /// `account == nil` turns the plex.tv features off (the buttons are disabled).
    public init(
        tokenStore: any PlexTokenStore, defaults: UserDefaults = .standard, connectionTest: PlexConnectionTest,
        account: PlexAccountClient? = nil, signInOptions: PlexPinSignIn.Options = .init(),
        serverResolver: PlexServerResolver? = nil, openURL: @escaping PlexPinSignIn.URLOpener = { _ in false }
    ) {
        self.tokenStore = tokenStore
        self.defaults = defaults
        self.connectionTest = connectionTest
        self.account = account
        self.signInOptions = signInOptions
        self.serverResolver = serverResolver
            ?? PlexServerResolver(clientIdentifier: connectionTest.clientIdentifier, session: connectionTest.session)
        self.openURL = openURL
    }

    // MARK: Inputs

    /// Persisted to defaults on every change. Changing it cancels an in-flight test.
    public var address: String {
        get { selection.address }
        set {
            guard newValue != selection.address else { return }
            selection.address = newValue
            persistSelection()
            invalidate()
        }
    }

    /// Memory only until `commitToken()`. Changing it cancels an in-flight test.
    public var tokenText: String {
        get { enteredToken }
        set {
            guard newValue != enteredToken else { return }
            enteredToken = newValue
            tokenDirty = true
            invalidate()
        }
    }

    public var librarySectionKey: String? {
        get { selection.librarySectionKey }
        set {
            guard newValue != selection.librarySectionKey else { return }
            selection.librarySectionKey = newValue
            persistSelection()
        }
    }

    // MARK: Outputs

    public var isTesting: Bool { status == .testing }

    public var canTest: Bool {
        !isTesting
            && !selection.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !trimmedToken.isEmpty
    }

    public var isSigningIn: Bool { signInStatus == .waitingForBrowser }

    public var canSignIn: Bool { account != nil && !isSigningIn && tokenStoreError == nil }

    public var canChooseServer: Bool { account != nil && hasStoredToken && !isLoadingServers && !isSigningIn }

    public var signInMessage: String? {
        switch signInStatus {
        case .failed(let failure): failure.message
        case .signedIn: "Signed in with Plex."
        case .idle, .waitingForBrowser: nil
        }
    }

    public var signInDetail: String? {
        if case .failed(let failure) = signInStatus { return failure.underlying?.errorDescription }
        return nil
    }

    /// "<name> · <preferred host or 'no address'>", plus "(shared)" for a server that is not the account's own.
    public func serverLabel(_ resource: PlexResource) -> String {
        let host = resource.preferredConnection?.url?.host ?? "no address"
        return "\(resource.name) · \(host)" + (resource.owned ? "" : " (shared)")
    }

    public var showsLibraryPicker: Bool { musicSections.count > 1 }

    public var selectedSection: PlexLibrarySection? { selection.selectedSection(in: musicSections) }

    public var statusMessage: String? {
        switch status {
        case .failed(let failure): failure.message
        case .connected(let connection, _): "Connected to Plex Media Server \(connection.identity.version)."
        case .idle, .testing: nil
        }
    }

    public var statusDetail: String? {
        if case .failed(let failure) = status { return failure.underlying?.errorDescription }
        return nil
    }

    public var changeNote: String? {
        guard case .connected(_, let change) = status else { return nil }
        switch change {
        case .serverChanged: return "This address now points to a different server; the music library was reset."
        case .libraryMissing: return "The selected library is no longer on this server."
        case .none, .autoSelected: return nil
        }
    }

    // MARK: Lifecycle

    /// Defaults to selection, store to `tokenText`. Idempotent after a successful read; a failed
    /// Keychain read is retried by the next call (the next time Settings appears) unless the user
    /// has already typed a token, which is never overwritten.
    public func load() {
        guard !loaded else { return }
        if let data = defaults.data(forKey: Self.selectionDefaultsKey),
           let saved = try? JSONDecoder().decode(PlexServerSelection.self, from: data) {
            selection = saved
        }
        guard !tokenDirty else { return }
        do {
            if let token = try tokenStore.load() {
                enteredToken = token.rawValue
                hasStoredToken = true
            }
            tokenStoreError = nil
            tokenDirty = false
            loaded = true
        } catch {
            tokenStoreError = error.localizedDescription
        }
    }

    /// `load()`, then a connection test when there is something to test with.
    public func appeared() {
        load()
        if canTest, status == .idle { testConnection() }
    }

    public func disappeared() {
        if tokenDirty { commitToken() }
        cancelTest()
        cancelSignIn()
        cancelServers()
    }

    /// Return in the token field. Commits only an edit, so Return in a field left empty by a
    /// failed read does not delete the stored token; Forget is the way to delete it.
    public func submitToken() {
        if tokenDirty { commitToken() }
    }

    /// Trimmed `tokenText` to the store; empty deletes the item. Commits regardless of the dirty
    /// flag (Forget and the guarded callers).
    public func commitToken() {
        let text = trimmedToken
        do {
            if text.isEmpty {
                try tokenStore.delete()
                hasStoredToken = false
                log.info("token removed")
            } else {
                try tokenStore.save(PlexToken(text))
                hasStoredToken = true
                log.info("token saved")
            }
            tokenStoreError = nil
            tokenDirty = false
        } catch {
            tokenStoreError = error.localizedDescription
            if let storeError = error as? PlexTokenStoreError, case .keychain(let code) = storeError {
                log.info("token store failed \(code, privacy: .public)")
            }
        }
    }

    public func forgetToken() {
        cancelSignIn()
        tokenText = ""
        commitToken()
        cancelServers()
        servers = []
        serversMessage = nil
        signInStatus = .idle
    }

    public func testConnection() {
        cancelTest()
        if tokenDirty { commitToken() }
        let text = trimmedToken
        guard tokenStoreError == nil, !text.isEmpty else { return }
        status = .testing
        let test = connectionTest
        let address = selection.address
        let token = PlexToken(text)
        connectionTask = Task { [weak self] in
            let result: Result<PlexConnection, PlexConnectionFailure>
            do throws(PlexConnectionFailure) {
                result = .success(try await test.run(address: address, token: token))
            } catch {
                result = .failure(error)
            }
            guard let self, !Task.isCancelled else { return }
            self.apply(result)
        }
    }

    public func cancelTest() {
        connectionTask?.cancel()
        connectionTask = nil
        if status == .testing { status = .idle }
    }

    /// Awaits the in-flight task, for tests.
    public func waitForTest() async {
        await connectionTask?.value
    }

    // MARK: Sign in with Plex

    /// Opens the browser to sign in; the token goes straight to the store.
    public func signIn() {
        guard let account else { return }
        cancelSignIn()
        cancelTest()
        signInStatus = .waitingForBrowser
        let signIn = PlexPinSignIn(account: account, options: signInOptions)
        let open = openURL
        signInTask = Task { [weak self] in
            let result: Result<PlexToken, PlexSignInFailure>
            do throws(PlexSignInFailure) {
                result = .success(try await signIn.run(open: open))
            } catch {
                result = .failure(error)
            }
            guard let self, !Task.isCancelled else { return }
            self.applySignIn(result)
        }
    }

    public func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        if signInStatus == .waitingForBrowser { signInStatus = .idle }
    }

    /// Awaits the sign-in task, for tests.
    public func waitForSignIn() async {
        await signInTask?.value
    }

    /// Lists the account's servers from plex.tv.
    public func loadServers() {
        startLoadingServers(useOnlyServer: false)
    }

    /// Probes the server's connections, then points the address at the best one that answers.
    public func useServer(_ resource: PlexResource) {
        serversTask?.cancel()
        isLoadingServers = true
        serversTask = Task { [weak self] in
            await self?.resolveAndUse(resource)
            guard let self, !Task.isCancelled else { return }
            self.serversTaskFinished()
        }
    }

    private func startLoadingServers(useOnlyServer: Bool) {
        guard let account else { return }
        let text = trimmedToken
        let token: PlexToken
        if !text.isEmpty {
            token = PlexToken(text)
        } else if let stored = try? tokenStore.load() {
            token = stored
        } else {
            return
        }
        serversTask?.cancel()
        isLoadingServers = true
        serversMessage = nil
        serversTask = Task { [weak self] in
            let result: Result<[PlexResource], PlexError>
            do {
                result = .success(try await account.resources(token: token))
            } catch let error as PlexError {
                result = .failure(error)
            } catch {
                result = .failure(.transport(.cancelled))
            }
            guard let self, !Task.isCancelled else { return }
            self.applyServers(result)
            if useOnlyServer, self.servers.count == 1, let only = self.servers.first {
                await self.resolveAndUse(only)
            }
            guard !Task.isCancelled else { return }
            self.serversTaskFinished()
        }
    }

    private func resolveAndUse(_ resource: PlexResource) async {
        let connection = await serverResolver.reachableConnection(of: resource)
        guard !Task.isCancelled else { return }
        if let connection {
            log.info("server: resolved")
            serversMessage = nil
            address = connection.uri
            testConnection()
        } else {
            log.info("server: unreachable")
            serversMessage = "Couldn't reach \(resource.name) at any of its addresses. The current address was kept."
        }
    }

    /// Awaits the resources or probe task, for tests.
    public func waitForServers() async {
        await serversTask?.value
    }

    // MARK: Private

    private func applySignIn(_ result: Result<PlexToken, PlexSignInFailure>) {
        signInTask = nil
        switch result {
        case .failure(.cancelled):
            signInStatus = .idle
            log.info("sign-in: cancelled")
        case .failure(let failure):
            signInStatus = .failed(failure)
            log.info("sign-in: failed")
        case .success(let token):
            storeSignedInToken(token)
            signInStatus = .signedIn
            servers = []
            serversMessage = nil
            log.info("sign-in: signedIn")
            if !selection.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                testConnection()
            } else {
                startLoadingServers(useOnlyServer: true)
            }
        }
    }

    private func storeSignedInToken(_ token: PlexToken) {
        enteredToken = token.rawValue
        do {
            try tokenStore.save(token)
            tokenDirty = false
            hasStoredToken = true
            tokenStoreError = nil
            log.info("token saved")
        } catch {
            // Keep it in the field so Test works this session; the next commit retries the write.
            tokenDirty = true
            tokenStoreError = error.localizedDescription
        }
    }

    private func cancelServers() {
        serversTask?.cancel()
        serversTask = nil
        isLoadingServers = false
    }

    private func serversTaskFinished() {
        serversTask = nil
        isLoadingServers = false
    }

    private func applyServers(_ result: Result<[PlexResource], PlexError>) {
        switch result {
        case .success(let list):
            servers = list
            serversMessage = list.isEmpty ? "Your Plex account has no servers. Type an address instead." : nil
            log.info("servers: \(list.count)")
        case .failure(.unauthorized):
            servers = []
            serversMessage = "plex.tv no longer accepts this token. Sign in again."
            log.info("servers: unauthorized")
        case .failure(.transport(.cancelled)):
            break
        case .failure(let error):
            servers = []
            serversMessage = error.errorDescription
            log.info("servers: failed")
        }
    }

    private var trimmedToken: String { enteredToken.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func invalidate() {
        cancelTest()
        cancelSignIn()
        if status != .idle { status = .idle }
    }

    private func persistSelection() {
        guard let data = try? JSONEncoder().encode(selection) else { return }
        defaults.set(data, forKey: Self.selectionDefaultsKey)
    }

    private func apply(_ result: Result<PlexConnection, PlexConnectionFailure>) {
        connectionTask = nil
        switch result {
        case .failure(.cancelled):
            status = .idle
            log.info("connection: cancelled")
        case .failure(let failure):
            status = .failed(failure)
            log.info("connection: failed")
        case .success(let connection):
            let change = selection.apply(connection)
            persistSelection()
            musicSections = connection.musicSections
            status = .connected(connection, change)
            log.info("connection: connected")
        }
    }

    // MARK: Printing

    public nonisolated var description: String { "PlexSettingsModel" }
    public nonisolated var debugDescription: String { description }
    public nonisolated var customMirror: Mirror { Mirror(self, children: []) }
}
