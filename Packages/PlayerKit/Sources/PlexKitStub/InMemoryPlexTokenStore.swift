import Foundation
import os
import PlexKit

/// A token store for tests and, later, the UI-test launch path. Counts its calls.
public final class InMemoryPlexTokenStore: PlexTokenStore, @unchecked Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    private struct State {
        var token: PlexToken?
        var loads = 0
        var saves = 0
        var deletes = 0
        var failure: PlexTokenStoreError?
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(token: PlexToken? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(token: token))
    }

    public var token: PlexToken? { state.withLock { $0.token } }
    public var loads: Int { state.withLock { $0.loads } }
    public var saves: Int { state.withLock { $0.saves } }
    public var deletes: Int { state.withLock { $0.deletes } }
    /// When set, every call throws it (for the "Keychain refused" path in the model).
    public var failure: PlexTokenStoreError? {
        get { state.withLock { $0.failure } }
        set { state.withLock { $0.failure = newValue } }
    }

    public func load() throws -> PlexToken? {
        try state.withLock { s in
            s.loads += 1
            if let failure = s.failure { throw failure }
            return s.token
        }
    }

    public func save(_ token: PlexToken) throws {
        try state.withLock { s in
            s.saves += 1
            if let failure = s.failure { throw failure }
            s.token = token
        }
    }

    public func delete() throws {
        try state.withLock { s in
            s.deletes += 1
            if let failure = s.failure { throw failure }
            s.token = nil
        }
    }

    public var description: String { "InMemoryPlexTokenStore" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
