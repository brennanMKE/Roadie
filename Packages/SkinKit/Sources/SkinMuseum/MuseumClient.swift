import Foundation

public actor MuseumClient {
    public static let defaultEndpoint = URL(string: "https://skins.webamp.org/graphql")!
    public static let maxRetryAfter: Duration = .seconds(10)

    private let transport: any MuseumTransport
    private let userAgent: String
    private let endpoint: URL
    private let sleep: @Sendable (Duration) async throws -> Void
    private let resultCache: MuseumResultCache?

    public init(
        transport: any MuseumTransport, userAgent: String, endpoint: URL = MuseumClient.defaultEndpoint,
        resultCache: MuseumResultCache? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.resultCache = resultCache
        self.transport = transport
        self.userAgent = userAgent
        self.endpoint = endpoint
        self.sleep = sleep
    }

    public func page(_ query: MuseumQuery) async throws -> MuseumPage {
        let data = try await post(query.request())
        let page = try Self.decodePage(data, for: query)
        await resultCache?.store(page, for: query.cacheKey)
        return page
    }

    /// The last successful page for `query`, if cached; `isStale` once past the cache's TTL.
    public func cachedPage(_ query: MuseumQuery) async -> (page: MuseumPage, isStale: Bool)? {
        await resultCache?.page(for: query.cacheKey)
    }

    private func makeRequest(_ body: GraphQLRequest) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// One retry after `Retry-After` (capped) for 429/503, then the error.
    private func post(_ body: GraphQLRequest) async throws -> Data {
        let request = try makeRequest(body)
        var retried = false
        while true {
            let data: Data, response: HTTPURLResponse
            do {
                (data, response) = try await transport.send(request)
            } catch is URLError {
                throw MuseumError.offline
            }
            let status = response.statusCode
            if status == 429 || status == 503, !retried {
                retried = true
                try await self.sleep(Self.retryDelay(response))
                continue
            }
            guard (200..<300).contains(status) else { throw MuseumError.http(status) }
            return data
        }
    }

    static func retryDelay(_ response: HTTPURLResponse) -> Duration {
        let header = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces)
        let seconds = header.flatMap { Int($0) } ?? 1
        return min(.seconds(max(seconds, 0)), maxRetryAfter)
    }

    // MARK: Decoding

    private struct Envelope<D: Decodable>: Decodable {
        var data: D?
        var errors: [GraphQLError]?
    }
    private struct GraphQLError: Decodable { var message: String }
    private struct SearchData: Decodable { var search_classic_skins: [Row?]? }
    private struct BrowseData: Decodable { var skins: Connection? }
    private struct Connection: Decodable {
        var count: Int?
        var nodes: [Row?]?
    }

    /// A row that never fails the page: a non-classic or malformed row decodes to nil and is dropped.
    private struct Row: Decodable {
        var skin: MuseumSkin?
        init(from decoder: Decoder) throws {
            struct Kind: Decodable { var __typename: String? }
            guard (try? Kind(from: decoder))?.__typename == "ClassicSkin" else {
                skin = nil
                return
            }
            skin = try? MuseumSkin(from: decoder)
        }
    }

    static func decodePage(_ data: Data, for query: MuseumQuery) throws -> MuseumPage {
        let rows: [Row?]
        let total: Int?
        switch query {
        case .search:
            rows = try decodeEnvelope(SearchData.self, data).search_classic_skins ?? []
            total = nil
        case .browse:
            guard let connection = try decodeEnvelope(BrowseData.self, data).skins else { throw MuseumError.decoding }
            rows = connection.nodes ?? []
            total = connection.count
        }
        let skins = rows.compactMap { $0?.skin }.filter { skin in
            skin.isAcceptable && (query.includeNSFW || skin.nsfw != true)
        }
        // A short raw page (before client filtering) is the last one.
        var hasMore = rows.count >= query.first
        if case let .browse(offset, _, _) = query, let total { hasMore = hasMore && offset + rows.count < total }
        return MuseumPage(skins: skins, total: total, hasMore: hasMore)
    }

    private static func decodeEnvelope<D: Decodable>(_: D.Type, _ data: Data) throws -> D {
        let env: Envelope<D>
        do { env = try JSONDecoder().decode(Envelope<D>.self, from: data) } catch { throw MuseumError.decoding }
        if let message = env.errors?.first?.message { throw MuseumError.graphQL(message) }
        guard let payload = env.data else { throw MuseumError.decoding }
        return payload
    }
}
