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

extension MusicAssistantBackend {
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
