import Foundation

/// `GET /info` and the first WebSocket message (twelve fields, recorded in #0060).
public struct MAServerInfo: Codable, Hashable, Sendable {
    public var serverID: String
    public var serverVersion: String?
    public var schemaVersion: Int
    public var minSupportedSchemaVersion: Int
    public var baseURL: String?
    public var homeassistantAddon: Bool?
    public var onboardDone: Bool?
    public var name: String?
    public var status: String?
    public var internalURL: String?
    public var externalURL: String?
    public var hasRemoteAccess: Bool?

    enum CodingKeys: String, CodingKey {
        case serverID = "server_id"
        case serverVersion = "server_version"
        case schemaVersion = "schema_version"
        case minSupportedSchemaVersion = "min_supported_schema_version"
        case baseURL = "base_url"
        case homeassistantAddon = "homeassistant_addon"
        case onboardDone = "onboard_done"
        case name, status
        case internalURL = "internal_url"
        case externalURL = "external_url"
        case hasRemoteAccess = "has_remote_access"
    }
}

public struct MAUser: Codable, Hashable, Sendable {
    public var userID: String
    public var username: String
    public var role: String
    public var displayName: String?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case username, role
        case displayName = "display_name"
    }
}

public struct MAAuthResult: Codable, Hashable, Sendable {
    public var authenticated: Bool
    public var user: MAUser?
}

public struct MAProvider: Codable, Hashable, Sendable {
    public var type: String
    public var domain: String
    public var name: String
    public var instanceID: String
    public var supportedFeatures: [String]?
    public var available: Bool?
    public var isStreamingProvider: Bool?
    public var lookupKey: String?

    enum CodingKeys: String, CodingKey {
        case type, domain, name
        case instanceID = "instance_id"
        case supportedFeatures = "supported_features"
        case available
        case isStreamingProvider = "is_streaming_provider"
        case lookupKey = "lookup_key"
    }
}
