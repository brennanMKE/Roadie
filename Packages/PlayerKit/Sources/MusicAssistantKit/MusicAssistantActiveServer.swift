import Foundation
import os

/// What the backend connects to. The settings side writes; the backend reads from any isolation.
public final class MusicAssistantActiveServer: Sendable {
    private let lock: OSAllocatedUnfairLock<MusicAssistantServerConfiguration?>

    public init(_ initial: MusicAssistantServerConfiguration? = nil) {
        lock = OSAllocatedUnfairLock(initialState: initial)
    }

    public var current: MusicAssistantServerConfiguration? { lock.withLock { $0 } }

    /// Returns true when the identity (id, base URL, server id) changed; a rename alone returns false.
    @discardableResult
    public func set(_ new: MusicAssistantServerConfiguration?) -> Bool {
        lock.withLock { current in
            let changed: Bool
            switch (current, new) {
            case (nil, nil): changed = false
            case (let old?, let next?): changed = !old.sameIdentity(as: next)
            default: changed = true
            }
            current = new
            return changed
        }
    }

    /// #0063's rule: the first server in list order that has a learned `server_id`. #0075 replaces the caller.
    public static func firstVerified(in servers: [MusicAssistantServerConfiguration]) -> MusicAssistantServerConfiguration? {
        servers.first { $0.isVerified }
    }
}
