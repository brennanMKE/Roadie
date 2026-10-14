import Foundation

/// Address and identity of one server. Codable (UserDefaults); carries no token. #0075 stores a list of these.
public struct MusicAssistantServerAddress: Hashable, Sendable, Codable {
    public var baseURL: URL
    /// Learned from the first successful connection; once set, a different server at this address is refused.
    public var serverID: String?

    public init(baseURL: URL, serverID: String? = nil) {
        self.baseURL = baseURL
        self.serverID = serverID
    }
}

/// What `connect()` needs: the address plus the token from the Keychain. Not Codable; prints redacted.
public struct MusicAssistantServerSettings: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var address: MusicAssistantServerAddress
    public var token: MusicAssistantToken

    public init(address: MusicAssistantServerAddress, token: MusicAssistantToken) {
        self.address = address
        self.token = token
    }

    public var description: String { "MusicAssistantServerSettings(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
