import Foundation
import MusicBackendKit

/// Discover rows (#0143): `music/recommendations` and `music/recommendations/items`.
extension MusicAssistantBackend {
    public func recommendationRows() async throws -> [RecommendationRow] {
        try await guarded {
            let client = try requireClient()
            let folders = try await client.call(.recommendations(), as: [MARecommendationFolder].self)
            return folders.map(RecommendationRow.init(ma:))
        }
    }

    public func recommendationItems(_ row: RecommendationRow) async throws -> [RecommendationItem] {
        try await guarded {
            let client = try requireClient()
            let items = try await client.call(
                .recommendationItems(provider: row.provider, itemID: row.itemID), as: [MARecommendationItem].self)
            return items.compactMap(RecommendationItem.init(ma:))
        }
    }

    /// A mapping through `music/item_by_uri` (the library item when it is in the library); the item unchanged when
    /// the server can't say more.
    public func resolve(_ item: RecommendationItem) async throws -> RecommendationItem {
        guard case .other(let uri, _, _, _, _) = item else { return item }
        return try await guarded {
            let client = try requireClient()
            let found = try await client.call(.itemByURI(uri), as: MARecommendationItem.self)
            return RecommendationItem(ma: found) ?? item
        }
    }
}

extension RecommendationRow {
    init(ma folder: MARecommendationFolder) {
        let library = folder.provider == "recommendations" || folder.provider == "library"
        self.init(
            provider: folder.provider, itemID: folder.itemID, name: folder.name, subtitle: folder.subtitle,
            icon: folder.icon, isEnabledByDefault: folder.enabledByDefault,
            kind: folder.type == "timeline" ? .timeline : .shelf,
            providerName: library ? nil : MAMapping.providerDisplayName(folder.provider.split(separator: "-").first.map(String.init) ?? folder.provider))
    }
}

extension RecommendationItem {
    /// nil for an item with nothing to show.
    init?(ma item: MARecommendationItem) {
        switch item {
        case .artist(let artist): self = .artist(LibraryArtist(ma: artist))
        case .album(let album): self = .album(LibraryAlbum(ma: album))
        case .track(let track): self = .track(LibraryTrack(ma: track))
        case .playlist(let playlist): self = .playlist(LibraryPlaylist(ma: playlist))
        case .mapping(let mapping):
            let kind = (mapping.mediaType.flatMap(MAMediaKind.init(rawValue:)) ?? MAURI.parse(mapping.uri)?.mediaType)?
                .mediaKind
            self = .other(
                uri: mapping.uri, kind: kind, name: mapping.name, subtitle: nil,
                artwork: mapping.image?.proxyID.map { ArtworkRef($0) })
        case .unknown: return nil
        }
    }
}
