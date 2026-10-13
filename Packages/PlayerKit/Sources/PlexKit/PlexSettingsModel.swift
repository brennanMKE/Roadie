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

    /// JSON of `PlexServerSelection`.
    public nonisolated static let selectionDefaultsKey = "PlexServerSelection"

    @ObservationIgnored private let tokenStore: any PlexTokenStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let connectionTest: PlexConnectionTest
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
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

    /// No I/O here: the app's launch must not touch the Keychain or the network.
    public init(tokenStore: any PlexTokenStore, defaults: UserDefaults = .standard, connectionTest: PlexConnectionTest) {
        self.tokenStore = tokenStore
        self.defaults = defaults
        self.connectionTest = connectionTest
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
    }

    /// Trimmed `tokenText` to the store; empty deletes the item. Explicit callers (Forget, Return)
    /// commit regardless of the dirty flag.
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
        tokenText = ""
        commitToken()
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

    // MARK: Private

    private var trimmedToken: String { enteredToken.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func invalidate() {
        cancelTest()
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
