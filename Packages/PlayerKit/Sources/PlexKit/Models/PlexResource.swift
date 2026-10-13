import Foundation

public struct PlexResourceConnection: Codable, Hashable, Sendable {
    /// "https" or "http".
    public var `protocol`: String
    /// "10-0-0-5.<hash>.plex.direct" or an IP.
    public var address: String
    public var port: Int
    /// "https://10-0-0-5.<hash>.plex.direct:32400"
    public var uri: String
    public var local: Bool
    public var relay: Bool
    public var ipv6: Bool

    public var isHTTPS: Bool { `protocol` == "https" }
    /// Plex reports the IP in `address` and puts the plex.direct name in `uri`.
    public var isPlexDirect: Bool { url?.host?.hasSuffix(".plex.direct") == true || address.hasSuffix(".plex.direct") }
    public var url: URL? { URL(string: uri) }

    private enum CodingKeys: String, CodingKey {
        case `protocol`, address, port, uri, local, relay
        case ipv6 = "IPv6"
    }

    public init(protocol: String, address: String, port: Int, uri: String, local: Bool, relay: Bool, ipv6: Bool = false) {
        self.protocol = `protocol`
        self.address = address
        self.port = port
        self.uri = uri
        self.local = local
        self.relay = relay
        self.ipv6 = ipv6
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        `protocol` = try c.decode(String.self, forKey: .protocol)
        address = try c.decode(String.self, forKey: .address)
        port = try c.decode(Int.self, forKey: .port)
        uri = try c.decode(String.self, forKey: .uri)
        local = try c.decodeIfPresent(Bool.self, forKey: .local) ?? false
        relay = try c.decodeIfPresent(Bool.self, forKey: .relay) ?? false
        ipv6 = try c.decodeIfPresent(Bool.self, forKey: .ipv6) ?? false
    }
}

/// One entry of /api/v2/resources. `Decodable` only; Plex's per-server `accessToken` is
/// deliberately not decoded (one token per app, see #0011).
public struct PlexResource: Decodable, Hashable, Sendable, Identifiable {
    public var name: String
    /// Equals /identity's `machineIdentifier`.
    public var clientIdentifier: String
    /// "server", "server,client", "client", ...
    public var provides: String
    public var owned: Bool
    public var presence: Bool?
    public var productVersion: String?
    public var platform: String?
    public var httpsRequired: Bool?
    public var connections: [PlexResourceConnection]

    public var id: String { clientIdentifier }
    public var isServer: Bool { provides.split(separator: ",").contains("server") }

    /// Local https non-relay, remote https non-relay, relay, http; IPv4 before IPv6 within a
    /// tier; Plex's own order is kept within the rest.
    public var rankedConnections: [PlexResourceConnection] {
        return connections.enumerated().sorted { a, b in
            let (ta, tb) = (a.element.tier, b.element.tier)
            if ta != tb { return ta < tb }
            if a.element.ipv6 != b.element.ipv6 { return !a.element.ipv6 }
            return a.offset < b.offset
        }.map(\.element)
    }

    public var preferredConnection: PlexResourceConnection? { rankedConnections.first }

    private enum CodingKeys: String, CodingKey {
        case name, clientIdentifier, provides, owned, presence, productVersion, platform, httpsRequired, connections
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        clientIdentifier = try c.decode(String.self, forKey: .clientIdentifier)
        provides = try c.decodeIfPresent(String.self, forKey: .provides) ?? ""
        owned = try c.decodeIfPresent(Bool.self, forKey: .owned) ?? false
        presence = try c.decodeIfPresent(Bool.self, forKey: .presence)
        productVersion = try c.decodeIfPresent(String.self, forKey: .productVersion)
        platform = try c.decodeIfPresent(String.self, forKey: .platform)
        httpsRequired = try c.decodeIfPresent(Bool.self, forKey: .httpsRequired)
        connections = try c.decodeIfPresent([PlexResourceConnection].self, forKey: .connections) ?? []
    }

    public init(
        name: String, clientIdentifier: String, provides: String = "server", owned: Bool = true,
        connections: [PlexResourceConnection] = []
    ) {
        self.name = name
        self.clientIdentifier = clientIdentifier
        self.provides = provides
        self.owned = owned
        self.connections = connections
    }
}

extension PlexResourceConnection {
    /// The ranking tier `PlexResource.rankedConnections` uses, best first.
    public enum Tier: Int, Comparable, Sendable {
        case localHTTPS, remoteHTTPS, relay, http

        public static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }

        /// "local https", "remote https", "relay", "http": for logs; never an address.
        public var name: String {
            switch self {
            case .localHTTPS: "local https"
            case .remoteHTTPS: "remote https"
            case .relay: "relay"
            case .http: "http"
            }
        }
    }

    public var tier: Tier { !isHTTPS ? .http : relay ? .relay : local ? .localHTTPS : .remoteHTTPS }
}
