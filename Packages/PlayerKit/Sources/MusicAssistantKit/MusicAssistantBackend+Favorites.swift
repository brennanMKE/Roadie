import Foundation
import MusicBackendKit

extension MARequest {
    /// `music/favorites/add_item`: a non-library item is added to the library first.
    public static func addFavorite(uri: String) -> MARequest {
        MARequest(command: "music/favorites/add_item", args: ["item": .string(uri)])
    }

    /// `music/favorites/remove_item`: needs the library item id.
    public static func removeFavorite(mediaType: MAMediaKind, libraryItemID: String) -> MARequest {
        MARequest(
            command: "music/favorites/remove_item",
            args: ["media_type": .string(mediaType.rawValue), "library_item_id": .string(libraryItemID)])
    }

    /// `players/add_currently_playing_to_favorites`.
    public static func addCurrentlyPlayingToFavorites(playerID: String) -> MARequest {
        MARequest(command: "players/add_currently_playing_to_favorites", args: ["player_id": .string(playerID)])
    }
}

extension MARequest {
    /// `music/<kind>s/library_items {favorite: true}` (#0142): the Favorites lists.
    public static func favoriteLibraryItems(_ kind: MAMediaKind, limit: Int, offset: Int) -> MARequest {
        var request = libraryItems(kind, limit: limit, offset: offset)
        request.args["favorite"] = .bool(true)
        return request
    }

    /// `music/<kind>s/count {favorite_only: true}`: the same filter as the listing it counts.
    public static func favoriteCount(_ kind: MAMediaKind) -> MARequest {
        MARequest(command: "music/\(kind.plural)/count", args: ["favorite_only": .bool(true)])
    }
}

extension MusicAssistantBackend {
    public func favoriteCount(_ kind: MediaKind) async throws -> Int? {
        try await guarded {
            try await requireClient().call(.favoriteCount(MAMediaKind(kind)), as: Int.self)
        }
    }

    public func favoriteTracks(page: PageRequest) async throws -> Page<LibraryTrack> {
        try await favoriteListing(.track, as: MATrack.self, page: page, map: LibraryTrack.init(ma:))
    }

    public func favoriteAlbums(page: PageRequest) async throws -> Page<LibraryAlbum> {
        try await favoriteListing(.album, as: MAAlbum.self, page: page, map: LibraryAlbum.init(ma:))
    }

    public func favoriteArtists(page: PageRequest) async throws -> Page<LibraryArtist> {
        try await favoriteListing(.artist, as: MAArtist.self, page: page, map: LibraryArtist.init(ma:))
    }

    public func favoritePlaylists(page: PageRequest) async throws -> Page<LibraryPlaylist> {
        try await favoriteListing(.playlist, as: MAPlaylist.self, page: page) { LibraryPlaylist(ma: $0) }
    }

    /// One page plus the favorite-only count (the total), fetched together.
    private func favoriteListing<T: Decodable & Sendable, Item: Hashable & Sendable>(
        _ kind: MAMediaKind, as type: T.Type, page: PageRequest, map: @Sendable (T) -> Item
    ) async throws -> Page<Item> {
        try await guarded {
            let client = try requireClient()
            async let items = client.call(
                .favoriteLibraryItems(kind, limit: page.limit, offset: page.offset), as: [T].self)
            async let total = try? client.call(.favoriteCount(kind), as: Int.self)
            let loaded = try await items
            return Page.make(items: loaded.map(map), request: page, total: await total)
        }
    }

    public static let unfavoriteNeedsLibraryText = "Only items in the Music Assistant library can be unfavorited."

    /// Favorite: the item's URI. Unfavorite: its `library://` id; anything else is refused before sending (#0141).
    public func setFavorite(_ id: MediaID, _ on: Bool) async throws {
        if on {
            _ = try await perform(.addFavorite(uri: id.rawValue))
            return
        }
        guard let uri = MAURI.parse(id.rawValue), uri.provider == "library" else {
            throw MusicBackendError.backend(Self.unfavoriteNeedsLibraryText)
        }
        _ = try await perform(.removeFavorite(mediaType: uri.mediaType, libraryItemID: uri.itemID))
    }

    /// Favorites what plays on `output`: the player itself, or This Mac's Sendspin wrapper.
    public func favoriteCurrentTrack(on output: OutputDevice.ID) async throws {
        let playerID: String
        do {
            playerID = try await self.playerID(for: output)
        } catch {
            throw Self.map(error)
        }
        _ = try await perform(.addCurrentlyPlayingToFavorites(playerID: playerID))
    }
}
