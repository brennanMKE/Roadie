import Foundation

/// A Music Assistant long-lived token. Prints as `MusicAssistantToken(redacted)` and is deliberately
/// not `Codable`, so it cannot ride along in a JSON index or a settings file.
public struct MusicAssistantToken: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The Keychain store and the `auth` message read this; nothing else should.
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { "MusicAssistantToken(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
