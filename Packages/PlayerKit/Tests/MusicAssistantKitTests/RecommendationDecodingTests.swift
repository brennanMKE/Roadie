import Foundation
import MusicBackendKit
import Testing
@testable import MusicAssistantKit

/// Synthetic until #0133 records `recommendations.json` and `recommendations-items-<row>.json`; shaped from
/// `music_assistant_models` `RecommendationFolder` and the `recommendations` provider's rows (#0143).
extension ModelDecodingTests {
    static let recommendationFolders = """
    [
      {"item_id": "recently_played", "provider": "recommendations", "name": "Recently played",
       "subtitle": "Tracks you played lately", "icon": "mdi-motion-play", "type": "default",
       "enabled_by_default": true, "supports_provider_filter": true, "uri": "library://folder/recently_played",
       "media_type": "folder", "items": [], "translation_key": "recently_played", "extra": {"x": 1}},
      {"item_id": "random_albums", "provider": "recommendations", "name": "Random albums", "icon": "mdi-album",
       "enabled_by_default": false, "items": []},
      {"item_id": "mix-1", "provider": "spotify--abc", "name": "Daily Mix 1", "type": "timeline"},
      {"item_id": "bare"}
    ]
    """

    @Test func recommendationFolderDecodes() throws {
        let folders = try JSONDecoder().decode([MARecommendationFolder].self, from: Data(Self.recommendationFolders.utf8))
        #expect(folders.count == 4)
        #expect(folders[0].itemID == "recently_played")
        #expect(folders[0].subtitle == "Tracks you played lately")
        #expect(folders[0].icon == "mdi-motion-play")
        #expect(folders[0].enabledByDefault)
        #expect(folders[0].supportsProviderFilter)
        #expect(folders[1].enabledByDefault == false)
        #expect(folders[3].name == "bare")
        #expect(folders[3].enabledByDefault)

        let rows = folders.map(RecommendationRow.init(ma:))
        #expect(rows[0].id == "recommendations/recently_played")
        #expect(rows[0].providerName == nil)
        #expect(rows[1].isEnabledByDefault == false)
        #expect(rows[2].kind == .timeline)
        #expect(rows[2].providerName == "Spotify")

        let request = MARequest.recommendationItems(provider: rows[1].provider, itemID: rows[1].itemID)
        #expect(request.command == "music/recommendations/items")
        #expect(request.args == ["provider": "recommendations", "item_id": "random_albums"])
    }

    @Test func recommendationItemsDecodeByMediaType() throws {
        let json = """
        [
          {"item_id": "1", "provider": "library", "name": "Song", "uri": "library://track/1", "media_type": "track",
           "duration": 200, "artists": [{"item_id": "9", "provider": "library", "name": "Band",
           "uri": "library://artist/9", "media_type": "artist"}], "metadata": {}},
          {"item_id": "2", "provider": "library", "name": "Record", "uri": "library://album/2", "media_type": "album",
           "artists": [{"item_id": "9", "name": "Band", "uri": "library://artist/9"}], "year": 2001},
          {"item_id": "3", "provider": "library", "name": "Band", "uri": "library://artist/3", "media_type": "artist"},
          {"item_id": "4", "provider": "library", "name": "Mix", "uri": "library://playlist/4", "media_type": "playlist",
           "is_editable": false},
          {"item_id": "5", "provider": "library", "name": "Station", "uri": "library://radio/5", "media_type": "radio"},
          {"item_id": "6", "provider": "spotify", "name": "Slim", "uri": "spotify://track/6", "media_type": "track",
           "image": {"type": "thumb", "path": "x", "proxy_id": "p6"}, "artists": "not a list"},
          {"item_id": "7", "provider": "podcasts", "name": "Episode", "uri": "podcasts://podcast_episode/7",
           "media_type": "podcast_episode"},
          {"nothing": true}
        ]
        """
        let decoded = try JSONDecoder().decode([MARecommendationItem].self, from: Data(json.utf8))
        #expect(decoded.count == 8)
        let items = decoded.compactMap(RecommendationItem.init(ma:))
        #expect(items.count == 7)
        guard case .track(let track) = items[0] else { Issue.record("track"); return }
        #expect(track.artistName == "Band")
        guard case .album(let album) = items[1] else { Issue.record("album"); return }
        #expect(album.year == 2001)
        guard case .artist = items[2] else { Issue.record("artist"); return }
        guard case .playlist(let playlist) = items[3] else { Issue.record("playlist"); return }
        #expect(playlist.isEditable == false)
        #expect(items[4].mediaID == MediaID(.radio, "library://radio/5"))
        // A track that doesn't decode as a full item falls back to its mapping, still playable.
        #expect(items[5].isMapping)
        #expect(items[5].mediaID == MediaID(.track, "spotify://track/6"))
        #expect(items[5].artwork == ArtworkRef("p6"))
        // A kind Roadie has no MediaKind for shows but can't be played.
        #expect(items[6].name == "Episode")
        #expect(items[6].mediaID == nil)
    }
}
