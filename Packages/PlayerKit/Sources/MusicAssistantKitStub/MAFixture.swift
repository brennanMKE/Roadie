import Foundation
import MusicAssistantKit

/// One recorded file from #0060 under `Fixtures/`. A call fixture is `{"command", "args", "frames": [verbatim server messages]}`;
/// the handshake is `{"frames": [...]}`; `info-http` is the bare `GET /info` body.
public enum MAFixture: String, CaseIterable, Sendable {
    case serverInfo = "server-info"
    case authOk = "auth-ok"
    case authMe = "auth-me"
    case errorAuth = "error-auth"
    case errorUnauthenticated = "error-unauthenticated"
    case errorUnknownCommand = "error-unknown-command"
    case errorUnknownPlayer = "error-unknown-player"
    case time
    case infoHTTP = "info-http"
    case infoWS = "info-ws"
    case providers
    case playersAll = "players-all"
    case playersAllUnavailable = "players-all-unavailable"
    case playersAllSendspin = "players-all-sendspin"
    case playersAllSendspinUnavailable = "players-all-sendspin-unavailable"
    case playerGet = "player-get"
    case playerQueuesAll = "player-queues-all"
    case playerQueueGet = "player-queue-get"
    case playerQueueActive = "player-queue-active"
    case playerQueueItems = "player-queue-items"
    case artistsCount = "artists-count"
    case artistsPage = "artists-page"
    case artistsLastPage = "artists-last-page"
    case artistsPageFull = "artists-page-full"
    case albumsCount = "albums-count"
    case albumsPage = "albums-page"
    case albumsLastPage = "albums-last-page"
    case albumsPageFull = "albums-page-full"
    case tracksCount = "tracks-count"
    case tracksPage = "tracks-page"
    case tracksLastPage = "tracks-last-page"
    case tracksPageFull = "tracks-page-full"
    case playlistsCount = "playlists-count"
    case playlistsPage = "playlists-page"
    case artistAlbums = "artist-albums"
    case albumTracks = "album-tracks"
    case albumGet = "album-get"
    case itemByURI = "item-by-uri"
    case playlistTracks = "playlist-tracks"
    case search
    case artworkProbe = "artwork-probe"
    case events

    // #0133: playlist, favorites, recommendation and queue captures. Not recorded until the user runs
    // the §1.5 recipe; `isRecorded` is false until then and tests skip or use synthetic routes.
    case playlistGet = "playlist-get"
    case playlistsFavoritesPage = "playlists-favorites-page"
    case tracksFavoritesPage = "tracks-favorites-page"
    case recommendations
    case recentlyPlayedItems = "recently-played-items"
    case recentlyAddedTracks = "recently-added-tracks"
    case radiosCount = "radios-count"
    case radiosPage = "radios-page"
    case playlistExport = "playlist-export"
    case playerQueueItemsLoaded = "player-queue-items-loaded"
    // Opt-in `--record-playlist-writes` run.
    case playlistCreate = "playlist-create"
    case playlistAddTracks = "playlist-add-tracks"
    case playlistTracksAfterAdd = "playlist-tracks-after-add"
    case playlistRemoveTracks = "playlist-remove-tracks"
    case playlistTracksAfterRemove = "playlist-tracks-after-remove"
    case playlistUpdate = "playlist-update"
    case favoriteAdd = "favorite-add"
    case favoriteRemove = "favorite-remove"
    case errorUnknownCommandMove = "error-unknown-command-move"
    case playlistDelete = "playlist-delete"
    case eventsPlaylists = "events-playlists"
    // #0196: `--record-queue`, a loaded and playing queue. Pending until the user records it.
    case playersAllPlaying = "players-all-playing"
    case playerQueueGetLoaded = "player-queue-get-loaded"
    case playerQueueItemsPage2 = "player-queue-items-page2"
    case eventsQueue = "events-queue"

    /// The fixtures recorded before #0133; the original 42.
    public static let baseline: [MAFixture] = Array(allCases.prefix(42))

    /// The cases whose file is in the bundle. Pending #0133 captures are absent until the user records them.
    public static var recorded: [MAFixture] { allCases.filter(\.isRecorded) }

    public var isRecorded: Bool { Self.url(named: rawValue) != nil }

    /// Per-row `recommendations-items-<item_id>` files, whose names depend on the server's rows.
    public static func recommendationItems(row: String) throws -> MAJSON {
        guard let url = url(named: "recommendations-items-" + row) else {
            throw Missing(name: "recommendations-items-" + row)
        }
        return try MAJSON.parse(Data(contentsOf: url))
    }

    private static func url(named name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
    }

    public struct Missing: Error, CustomStringConvertible {
        public var name: String
        public var description: String { "Missing music assistant fixture \(name)" }
    }

    public var data: Data {
        get throws {
            guard let url = Self.url(named: rawValue) else {
                throw Missing(name: rawValue)
            }
            return try Data(contentsOf: url)
        }
    }

    public var json: MAJSON {
        get throws { try MAJSON.parse(data) }
    }

    /// nil for the handshake, `info-http`, `artwork-probe`, `events`, `events-playlists` and `events-queue`.
    public var command: String? { (try? json)?["command"]?.stringValue }

    public var args: MAJSON? { (try? json)?["args"] }

    /// The verbatim server messages of a call (or the handshake).
    public func frames() throws -> [MAJSON] {
        try json["frames"]?.arrayValue ?? []
    }

    /// Each message re-serialized, as the client would receive it (key order aside).
    public func frameTexts() throws -> [String] {
        try frames().map { $0.encodedString() }
    }
}
