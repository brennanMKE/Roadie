import Foundation
import MusicBackendKit

/// A Music Assistant `Radio` (#0147). No radio response is recorded yet (#0133), so only `item_id`, `uri` and `name`
/// are required, and a row that lacks them is skipped rather than failing the page.
public struct MARadio: Codable, Hashable, Sendable {
    public var itemID: String
    public var provider: String?
    public var name: String
    public var uri: String
    public var metadata: MAMetadata?
    public var favorite: Bool?

    enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case provider, name, uri, metadata, favorite
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try? container.decode(String.self, forKey: .itemID) {
            itemID = id
        } else {
            itemID = String(try container.decode(Int.self, forKey: .itemID))
        }
        provider = try? container.decodeIfPresent(String.self, forKey: .provider)
        name = try container.decode(String.self, forKey: .name)
        uri = try container.decode(String.self, forKey: .uri)
        metadata = try? container.decodeIfPresent(MAMetadata.self, forKey: .metadata)
        favorite = try? container.decodeIfPresent(Bool.self, forKey: .favorite)
    }

    /// Decodes each element on its own; undecodable rows are dropped.
    static func lenientList(_ json: MAJSON) -> [MARadio] {
        guard case .array(let rows) = json else { return [] }
        return rows.compactMap { try? $0.decode(as: MARadio.self) }
    }
}

extension LibraryRadio {
    init(ma radio: MARadio) {
        self.init(
            id: MediaID(.radio, radio.uri), name: radio.name, artwork: MAMapping.artwork(radio.metadata),
            isFavorite: radio.favorite)
    }
}

extension MARequest {
    /// `builtin/add_radio`: adds a stream URL to the library as a radio station.
    public static func addRadio(url: String, name: String) -> MARequest {
        MARequest(command: "builtin/add_radio", args: ["url": .string(url), "name": .string(name)])
    }
}

extension MusicAssistantBackend {
    public func radios(page: PageRequest) async throws -> Page<LibraryRadio> {
        try await radioListing(
            .libraryItems(.radio, limit: page.limit, offset: page.offset), count: .count(.radio), page: page)
    }

    public func favoriteRadios(page: PageRequest) async throws -> Page<LibraryRadio> {
        try await radioListing(
            .favoriteLibraryItems(.radio, limit: page.limit, offset: page.offset), count: .favoriteCount(.radio),
            page: page)
    }

    public func addRadio(url: String, name: String) async throws -> LibraryRadio {
        let result = try await perform(.addRadio(url: url, name: name))
        guard let radio = try? result.decode(as: MARadio.self) else {
            // The command succeeded but answered with something else; the list refetch shows the station.
            return LibraryRadio(id: MediaID(.radio, url), name: name)
        }
        return LibraryRadio(ma: radio)
    }

    private func radioListing(_ request: MARequest, count: MARequest, page: PageRequest) async throws -> Page<LibraryRadio> {
        try await guarded {
            let client = try requireClient()
            async let items = client.call(request)
            async let total = try? client.call(count, as: Int.self)
            let loaded = MARadio.lenientList(try await items).map(LibraryRadio.init(ma:))
            return Page.make(items: loaded, request: page, total: await total)
        }
    }
}
