import CryptoKit
import Foundation

/// A GraphQL request body: operation text plus variables. User text only ever travels in `variables`.
public struct GraphQLRequest: Sendable, Hashable, Encodable {
    public var operationName: String
    public var query: String
    public var variables: [String: GraphQLValue]
}

public enum GraphQLValue: Sendable, Hashable, Encodable {
    case string(String), int(Int), bool(Bool), enumValue(String)

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v), .enumValue(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        }
    }
}

public enum MuseumQuery: Sendable, Hashable {
    case search(text: String, offset: Int, first: Int, includeNSFW: Bool)
    case browse(offset: Int, first: Int, includeNSFW: Bool)

    public static let pageSize = 60

    static let fields =
        "__typename md5 filename(normalize_extension: true, include_museum_id: true) screenshot_url download_url museum_url nsfw"

    // `skins(filter:)` values confirmed against webamp packages/skin-database/api/graphql/schema.graphql on 2026-10-20:
    // SkinsFilterOption = APPROVED | NSFW | REJECTED | TWEETED, SkinsSortOption = MUSEUM. No sort is sent.
    static let searchText = """
        query MuseumSearch($query: String!, $first: Int!, $offset: Int!, $nsfw: Boolean) {
          search_classic_skins(query: $query, first: $first, offset: $offset, nsfw: $nsfw) { \(fields) }
        }
        """
    static let browseText = """
        query MuseumBrowse($first: Int!, $offset: Int!, $filter: SkinsFilterOption) {
          skins(first: $first, offset: $offset, filter: $filter) { count nodes { \(fields) } }
        }
        """

    public var first: Int {
        switch self {
        case .search(_, _, let f, _), .browse(_, let f, _): f
        }
    }

    public var includeNSFW: Bool {
        switch self {
        case .search(_, _, _, let n), .browse(_, _, let n): n
        }
    }

    public func request() -> GraphQLRequest {
        switch self {
        case let .search(text, offset, first, includeNSFW):
            var vars: [String: GraphQLValue] = ["query": .string(text), "first": .int(first), "offset": .int(offset)]
            if !includeNSFW { vars["nsfw"] = .bool(false) }
            return GraphQLRequest(operationName: "MuseumSearch", query: Self.searchText, variables: vars)
        case let .browse(offset, first, includeNSFW):
            var vars: [String: GraphQLValue] = ["first": .int(first), "offset": .int(offset)]
            if !includeNSFW { vars["filter"] = .enumValue("APPROVED") }
            return GraphQLRequest(operationName: "MuseumBrowse", query: Self.browseText, variables: vars)
        }
    }

    /// SHA-256 of the encoded request (sorted keys), for the result cache.
    public var cacheKey: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(request())) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
