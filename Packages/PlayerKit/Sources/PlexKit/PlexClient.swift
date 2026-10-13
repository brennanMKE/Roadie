import Foundation
import os

private let log = Logger(subsystem: "com.brennanmke.SkinAmp", category: "PlexKit")

/// An async client for one Plex Media Server. Every request is a GET with JSON accepted and the
/// token (when there is one) in the `X-Plex-Token` header, never in the URL, so no error or log
/// line can carry it.
public struct PlexClient: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let baseURL: URL
    /// `nil` is allowed: `/identity` needs none.
    public let token: PlexToken?
    public let clientIdentifier: String
    public let product: String
    public let version: String
    public let timeout: TimeInterval
    public let session: URLSession

    public init(
        baseURL: URL,
        token: PlexToken?,
        clientIdentifier: String,
        product: String = "SkinAmp",
        version: String = "0.1.0",
        timeout: TimeInterval = 15,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.token = token
        self.clientIdentifier = clientIdentifier
        self.product = product
        self.version = version
        self.timeout = timeout
        self.session = session
    }

    public var description: String { "PlexClient(\(baseURL.absoluteString))" }
    public var debugDescription: String { description }

    /// Builds a GET with every Plex header set. Public so a download can use the same headers
    /// (token in the header, never in the URL).
    public func request(path: String, query: [URLQueryItem] = [], page: PlexPageRequest? = nil) -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        let tail = path.hasPrefix("/") ? path : "/" + path
        components.percentEncodedPath = basePath + tail.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        if !query.isEmpty {
            // Encode strictly so a value like "cowboys & aliens" cannot split into two parameters.
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
            components.percentEncodedQuery = query.map { "\(enc($0.name))=\(enc($0.value ?? ""))" }.joined(separator: "&")
        }
        // `URLComponents.url` can only fail for a malformed base; fall back to the base itself.
        var request = URLRequest(url: components.url ?? baseURL, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue(product, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(version, forHTTPHeaderField: "X-Plex-Version")
        request.setValue("macOS", forHTTPHeaderField: "X-Plex-Platform")
        if let token {
            request.setValue(token.rawValue, forHTTPHeaderField: "X-Plex-Token")
        }
        if let page {
            request.setValue(String(page.start), forHTTPHeaderField: "X-Plex-Container-Start")
            request.setValue(String(page.size), forHTTPHeaderField: "X-Plex-Container-Size")
        }
        return request
    }

    func fetch<T: Decodable>(_ request: URLRequest) async throws -> T {
        let path = request.url?.path ?? ""
        log.debug("GET \(path, privacy: .public)")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            log.error("GET \(path, privacy: .public) failed: transport \(error.code.rawValue)")
            throw PlexError.transport(error.code)
        }
        guard let http = response as? HTTPURLResponse else {
            throw PlexError.transport(.badServerResponse)
        }
        switch http.statusCode {
        case 200..<300: break
        case 401:
            log.error("GET \(path, privacy: .public) failed: 401")
            throw PlexError.unauthorized
        case 404:
            log.error("GET \(path, privacy: .public) failed: 404")
            throw PlexError.notFound
        default:
            log.error("GET \(path, privacy: .public) failed: \(http.statusCode)")
            throw PlexError.httpStatus(http.statusCode)
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")
        guard contentType?.lowercased().contains("json") == true else {
            log.error("GET \(path, privacy: .public) failed: not JSON")
            throw PlexError.notJSON(contentType: contentType)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch let error as DecodingError {
            throw PlexError.decoding(path: Self.codingPath(of: error), detail: Self.detail(of: error))
        }
    }

    private static func codingPath(of error: DecodingError) -> String {
        let context: DecodingError.Context
        switch error {
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .keyNotFound(_, let c), .dataCorrupted(let c):
            context = c
        @unknown default:
            return ""
        }
        var parts = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }
        if case .keyNotFound(let key, _) = error { parts.append(key.stringValue) }
        return parts.joined(separator: ".")
    }

    /// Describes the failure from the decoder's own context, never the response body.
    private static func detail(of error: DecodingError) -> String {
        let path = codingPath(of: error)
        switch error {
        case .typeMismatch(let type, _): return "type mismatch (\(type)) at \(path)"
        case .valueNotFound(let type, _): return "missing value (\(type)) at \(path)"
        case .keyNotFound: return "missing key at \(path)"
        case .dataCorrupted: return "corrupted data at \(path)"
        @unknown default: return "decoding failed at \(path)"
        }
    }

    func list<Item: Decodable & Hashable & Sendable>(
        _ request: URLRequest, page: PlexPageRequest, as: Item.Type
    ) async throws -> PlexPage<Item> {
        let envelope: MediaContainerEnvelope<Item> = try await fetch(request)
        let body = envelope.container
        let items = body.metadata ?? body.directory ?? []
        let offset = body.offset ?? page.start
        let size = body.size ?? items.count
        return PlexPage(items: items, offset: offset, size: size, totalSize: body.totalSize ?? offset + size)
    }
}
