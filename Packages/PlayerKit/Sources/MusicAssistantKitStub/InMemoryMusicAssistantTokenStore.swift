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
    /// When set, every call throws it (for the "Keychain refused" path).
    public var failure: MusicAssistantTokenStoreError? {
        get { state.withLock { $0.failure } }
        set { state.withLock { $0.failure = newValue } }
    }

    public func load() throws -> MusicAssistantToken? {
        try state.withLock { s in
            s.loads += 1
            if let failure = s.failure { throw failure }
            return s.token
        }
    }

    public func save(_ token: MusicAssistantToken) throws {
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

    public var description: String { "InMemoryMusicAssistantTokenStore" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
