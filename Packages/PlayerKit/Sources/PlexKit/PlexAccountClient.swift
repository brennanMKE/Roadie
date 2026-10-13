import Foundation

/// plex.tv: PIN sign-in and the account's servers. Every request goes through `PlexClient`, so the
/// headers, the error mapping and the token rules are the ones the server client has.
public struct PlexAccountClient: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let defaultBaseURL = URL(string: "https://plex.tv")!
    public static let defaultAuthURL = URL(string: "https://app.plex.tv/auth")!

    public var clientIdentifier: String
    public var product: String
    public var version: String
    /// Tests use https://stub.plex.tv (the stub matches on path).
    public var baseURL: URL
    public var authBaseURL: URL
    public var timeout: TimeInterval
    public var session: URLSession

    public init(
        clientIdentifier: String, product: String = "SkinAmp", version: String = "0.1.0",
        baseURL: URL = defaultBaseURL, authBaseURL: URL = defaultAuthURL,
        timeout: TimeInterval = 15, session: URLSession = .shared
    ) {
        self.clientIdentifier = clientIdentifier
        self.product = product
        self.version = version
        self.baseURL = baseURL
        self.authBaseURL = authBaseURL
        self.timeout = timeout
        self.session = session
    }

    public var description: String { "PlexAccountClient" }
    public var debugDescription: String { description }

    private func client(token: PlexToken?) -> PlexClient {
        PlexClient(
            baseURL: baseURL, token: token, clientIdentifier: clientIdentifier,
            product: product, version: version, timeout: timeout, session: session)
    }

    /// POST /api/v2/pins?strong=true, no token. A strong PIN has a 24-character code.
    public func createPin() async throws -> PlexPin {
        let client = client(token: nil)
        return try await client.fetch(client.request(method: "POST", path: "/api/v2/pins", query: [.init(name: "strong", value: "true")]))
    }

    /// GET /api/v2/pins/<id>?code=<code>, no token; `authToken` is set once the user has signed in.
    public func pin(_ pin: PlexPin) async throws -> PlexPin {
        let client = client(token: nil)
        return try await client.fetch(client.request(path: "/api/v2/pins/\(pin.id)", query: [.init(name: "code", value: pin.code)]))
    }

    /// https://app.plex.tv/auth#?clientID=...&code=...&context[device][product]=... Never a token.
    public func authURL(for pin: PlexPin) -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        let pairs = [
            ("clientID", clientIdentifier),
            ("code", pin.code),
            ("context[device][product]", product),
        ]
        var components = URLComponents(url: authBaseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.percentEncodedFragment = "?" + pairs.map { "\(enc($0.0))=\(enc($0.1))" }.joined(separator: "&")
        return components.url ?? authBaseURL
    }

    /// GET /api/v2/resources?includeHttps=1&includeRelay=1, token in the header. Servers only, owned first.
    public func resources(token: PlexToken) async throws -> [PlexResource] {
        let client = client(token: token)
        let query = [URLQueryItem(name: "includeHttps", value: "1"), URLQueryItem(name: "includeRelay", value: "1")]
        let all: [PlexResource] = try await client.fetch(client.request(path: "/api/v2/resources", query: query))
        return all.filter(\.isServer).sorted { a, b in
            if a.owned != b.owned { return a.owned }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}
