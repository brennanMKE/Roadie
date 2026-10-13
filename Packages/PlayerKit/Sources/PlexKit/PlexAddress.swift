import Foundation

/// Turns what the user typed into the base URL of a Plex server.
public enum PlexAddress {
    public static let defaultPort = 32400

    /// Adds `http://` and `:32400` when missing and throws `PlexError.invalidBaseURL` otherwise.
    /// Never guesses beyond that. Query, fragment and trailing slashes are dropped, and a Plex Web path (`/web/…`) is cut off; credentials are rejected.
    public static func normalize(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PlexError.invalidBaseURL }
        let withScheme = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard var components = URLComponents(string: withScheme) else { throw PlexError.invalidBaseURL }

        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw PlexError.invalidBaseURL
        }
        guard let host = components.host, !host.isEmpty else { throw PlexError.invalidBaseURL }
        guard components.user == nil, components.password == nil else { throw PlexError.invalidBaseURL }
        let port = components.port ?? defaultPort
        guard (1...65535).contains(port) else { throw PlexError.invalidBaseURL }

        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        // A link copied from Plex Web (`…/web/index.html#!/…`) is cut back to the server.
        var parts = path.split(separator: "/", omittingEmptySubsequences: true)
        if let web = parts.firstIndex(where: { $0.lowercased() == "web" }) { parts.removeSubrange(web...) }
        path = parts.isEmpty ? "" : "/" + parts.joined(separator: "/")

        components.scheme = scheme
        components.host = host.lowercased()
        components.port = port
        components.percentEncodedPath = path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw PlexError.invalidBaseURL }
        return url
    }
}

extension PlexClient {
    /// `PlexClient(baseURL: try PlexAddress.normalize(address), …)`.
    public init(
        address: String,
        token: PlexToken?,
        clientIdentifier: String,
        product: String = "SkinAmp",
        version: String = "0.1.0",
        timeout: TimeInterval = 15,
        session: URLSession = .shared
    ) throws {
        self.init(
            baseURL: try PlexAddress.normalize(address), token: token, clientIdentifier: clientIdentifier,
            product: product, version: version, timeout: timeout, session: session)
    }
}
