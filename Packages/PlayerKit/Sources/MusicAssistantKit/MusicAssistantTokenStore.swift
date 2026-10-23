import Foundation
import Security

/// Where a server's token lives. The only code that reads `MusicAssistantToken.rawValue` besides the `auth` message.
public protocol MusicAssistantTokenStore: Sendable {
    /// nil when there is none.
    func load() throws -> MusicAssistantToken?
    /// Adds or replaces.
    func save(_ token: MusicAssistantToken) throws
    /// No error when there is none.
    func delete() throws
    /// Whether an item is stored, without reading it. The Keychain version asks for attributes only, so it never
    /// decrypts the secret and never shows a prompt.
    func exists() throws -> Bool
}

public enum MusicAssistantTokenStoreError: Error, Hashable, Sendable, LocalizedError {
    case keychain(OSStatus)

    /// Never contains the token.
    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "The Keychain refused the request (\(text), status \(status))."
        }
    }
}

/// A generic-password item in the login keychain, one per server (`account`). Not the data-protection
/// keychain: the app is ad-hoc signed, which that keychain does not accept. Not synchronizable.
public struct KeychainMusicAssistantTokenStore: MusicAssistantTokenStore {
    public static let defaultService = "co.sstools.roadie.musicAssistant"
    public var service: String
    /// One per configured server; #0075 passes the server configuration's id.
    public var account: String

    public init(service: String = Self.defaultService, account: String) {
        self.service = service
        self.account = account
    }

    var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func load() throws -> MusicAssistantToken? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw MusicAssistantTokenStoreError.keychain(status) }
        guard let data = result as? Data, let text = String(data: data, encoding: .utf8) else { return nil }
        return MusicAssistantToken(text)
    }

    public func exists() throws -> Bool {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true  // deliberately no kSecReturnData
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw MusicAssistantTokenStoreError.keychain(status) }
        return true
    }

    public func save(_ token: MusicAssistantToken) throws {
        let data = Data(token.rawValue.utf8)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw MusicAssistantTokenStoreError.keychain(status) }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "SkinAmp Music Assistant token"
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw MusicAssistantTokenStoreError.keychain(addStatus) }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MusicAssistantTokenStoreError.keychain(status) }
    }
}
