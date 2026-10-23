import Foundation
import os

/// One configured server. Codable for UserDefaults; carries no token (the Keychain item is keyed by `id`).
public struct MusicAssistantServerConfiguration: Identifiable, Hashable, Sendable, Codable {
    /// Shown until the first successful test replaces it with the server's own name.
    public static let defaultName = "Music Assistant"
    /// What a freshly added server points at until the user types an address. Never connected to: it has no `serverID`.
    public static let placeholderURL = URL(string: "http://homeassistant.local:8095")!

    public var id: UUID
    /// User-facing label.
    public var name: String
    /// The base URL plus the learned `server_id`.
    public var address: MusicAssistantServerAddress
    /// Wi-Fi names this server belongs to (#0075). No UI yet; stored so #0075 needs no migration.
    public var networks: [String]

    public init(
        id: UUID = UUID(), name: String = Self.defaultName,
        address: MusicAssistantServerAddress = MusicAssistantServerAddress(baseURL: Self.placeholderURL),
        networks: [String] = []
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.networks = networks
    }

    /// Music Assistant's generic label: nil, blank, "Music Assistant", or "Music Assistant (<token>)" where the
    /// token (typically the server id) has no spaces. Such a name says nothing to the user.
    public static func isGenericName(_ name: String?) -> Bool {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return true }
        let lower = trimmed.lowercased()
        let base = defaultName.lowercased()
        if lower == base { return true }
        guard lower.hasPrefix(base + " ("), lower.hasSuffix(")") else { return false }
        let token = lower.dropFirst(base.count + 2).dropLast()
        return !token.isEmpty && !token.contains(where: { $0.isWhitespace || $0 == "(" || $0 == ")" })
    }

    /// The label for `name` in the UI: itself unless generic, else the host, else `defaultName`. User data: UI only,
    /// never logged.
    public static func displayName(_ name: String?, host: String?) -> String {
        if !isGenericName(name), let name { return name.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let host, !host.isEmpty { return host }
        return defaultName
    }

    /// `name`, or the host when the name is generic. UI only, never logged.
    public var displayName: String { Self.displayName(name, host: address.baseURL.host()) }

    public var isVerified: Bool { address.serverID != nil }
    /// The Keychain `account` of this server's token.
    public var keychainAccount: String { id.uuidString }
    /// A server whose address the user has not typed yet.
    public var hasNoAddress: Bool { address.serverID == nil && address.baseURL == Self.placeholderURL }

    enum CodingKeys: String, CodingKey { case id, name, address, networks }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        address = try c.decode(MusicAssistantServerAddress.self, forKey: .address)
        networks = try c.decodeIfPresent([String].self, forKey: .networks) ?? []
    }

    /// The fields that decide which server the backend talks to.
    func sameIdentity(as other: Self) -> Bool {
        id == other.id && address.baseURL == other.address.baseURL && address.serverID == other.address.serverID
    }
}

/// The list in UserDefaults under `defaultsKey` (a JSON array in the user's order). Reads and writes defaults only.
public struct MusicAssistantServerStore: Sendable {
    public static let defaultsKey = "MusicAssistantServers"
    private static let log = Logger(subsystem: "co.sstools.roadie", category: "MusicAssistantSettings")

    nonisolated(unsafe) private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Missing or corrupt gives `[]` (logged by count only) and does not rewrite the stored bytes.
    public func load() -> [MusicAssistantServerConfiguration] {
        Self.servers(in: defaults)
    }

    public func save(_ servers: [MusicAssistantServerConfiguration]) {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// For `LibrarySource.isConfigured`: at least one verified server. Defaults only.
    public static func hasVerifiedServer(defaults: UserDefaults) -> Bool {
        servers(in: defaults).contains { $0.isVerified }
    }

    private static func servers(in defaults: UserDefaults) -> [MusicAssistantServerConfiguration] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        guard let servers = try? JSONDecoder().decode([MusicAssistantServerConfiguration].self, from: data) else {
            log.error("stored server list is unreadable (\(data.count) bytes)")
            return []
        }
        return servers
    }
}
