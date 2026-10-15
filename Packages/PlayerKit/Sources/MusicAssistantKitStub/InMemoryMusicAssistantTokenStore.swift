import Foundation
import MusicAssistantKit
import os

/// A token store for tests and, later, the UI-test launch path. Counts its calls.
public final class InMemoryMusicAssistantTokenStore: MusicAssistantTokenStore, @unchecked Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    private struct State {
        var token: MusicAssistantToken?
        var loads = 0
        var saves = 0
        var deletes = 0
        var existsChecks = 0
        var failLoad: OSStatus?
        var failSave: OSStatus?
        var failDelete: OSStatus?
        var failExists: OSStatus?
        var failure: MusicAssistantTokenStoreError?
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(token: MusicAssistantToken? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(token: token))
    }

    public var token: MusicAssistantToken? { state.withLock { $0.token } }
    public var loads: Int { state.withLock { $0.loads } }
    public var saves: Int { state.withLock { $0.saves } }
    public var deletes: Int { state.withLock { $0.deletes } }
    public var existsChecks: Int { state.withLock { $0.existsChecks } }
    /// Per-operation failures by `OSStatus` (the Keychain's own codes).
    public var failLoad: OSStatus? {
        get { state.withLock { $0.failLoad } }
        set { state.withLock { $0.failLoad = newValue } }
    }
    public var failSave: OSStatus? {
        get { state.withLock { $0.failSave } }
        set { state.withLock { $0.failSave = newValue } }
    }
    public var failDelete: OSStatus? {
        get { state.withLock { $0.failDelete } }
        set { state.withLock { $0.failDelete = newValue } }
    }
    public var failExists: OSStatus? {
        get { state.withLock { $0.failExists } }
        set { state.withLock { $0.failExists = newValue } }
    }
    /// When set, every call throws it (for the "Keychain refused" path).
    public var failure: MusicAssistantTokenStoreError? {
        get { state.withLock { $0.failure } }
        set { state.withLock { $0.failure = newValue } }
    }

    public func load() throws -> MusicAssistantToken? {
        try state.withLock { s in
            s.loads += 1
            if let failure = s.failure { throw failure }
            if let status = s.failLoad { throw MusicAssistantTokenStoreError.keychain(status) }
            return s.token
        }
    }

    public func save(_ token: MusicAssistantToken) throws {
        try state.withLock { s in
            s.saves += 1
            if let failure = s.failure { throw failure }
            if let status = s.failSave { throw MusicAssistantTokenStoreError.keychain(status) }
            s.token = token
        }
    }

    public func delete() throws {
        try state.withLock { s in
            s.deletes += 1
            if let failure = s.failure { throw failure }
            if let status = s.failDelete { throw MusicAssistantTokenStoreError.keychain(status) }
            s.token = nil
        }
    }

    /// Counted apart from `loads`: asking whether a token exists must not read it.
    public func exists() throws -> Bool {
        try state.withLock { s in
            s.existsChecks += 1
            if let failure = s.failure { throw failure }
            if let status = s.failExists { throw MusicAssistantTokenStoreError.keychain(status) }
            return s.token != nil
        }
    }

    public var description: String { "InMemoryMusicAssistantTokenStore" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

/// One in-memory store per Keychain account, so a test can inspect the store the settings model used for a server.
public final class InMemoryMusicAssistantTokenStores: @unchecked Sendable {
    private let stores = OSAllocatedUnfairLock(initialState: [String: InMemoryMusicAssistantTokenStore]())

    public init() {}

    public func store(for account: String) -> InMemoryMusicAssistantTokenStore {
        stores.withLock { stores in
            if let existing = stores[account] { return existing }
            let created = InMemoryMusicAssistantTokenStore()
            stores[account] = created
            return created
        }
    }

    /// The closure the settings model takes.
    public var factory: @Sendable (String) -> any MusicAssistantTokenStore {
        { [self] account in store(for: account) }
    }
}
