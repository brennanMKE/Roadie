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

    public struct Missing: Error, CustomStringConvertible {
        public var name: String
        public var description: String { "Missing music assistant fixture \(name)" }
    }

    public var data: Data {
        get throws {
            guard let url = Bundle.module.url(forResource: rawValue, withExtension: "json", subdirectory: "Fixtures") else {
                throw Missing(name: rawValue)
            }
            return try Data(contentsOf: url)
        }
    }

    public var json: MAJSON {
        get throws { try MAJSON.parse(data) }
    }

    /// nil for the handshake, `info-http`, `artwork-probe` and `events`.
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
