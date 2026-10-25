import Foundation
import MusicAssistantKit

/// Maps a request to the recorded messages that answer it. First matching route wins; the fallback is the
/// recorded "unknown command" error. Replayed messages carry the request's own `message_id`.
public struct FixtureScript: Sendable {
    public struct Route: Sendable {
        public var command: String
        public var matches: @Sendable (MAJSON) -> Bool
        public var reply: @Sendable (_ args: MAJSON, _ messageID: String) -> [String]

        public init(
            command: String, matches: @escaping @Sendable (MAJSON) -> Bool = { _ in true },
            reply: @escaping @Sendable (_ args: MAJSON, _ messageID: String) -> [String]
        ) {
            self.command = command
            self.matches = matches
            self.reply = reply
        }

        /// Replays these messages.
        public static func frames(
            command: String, matches: @escaping @Sendable (MAJSON) -> Bool = { _ in true }, _ frames: [MAJSON]
        ) -> Route {
            Route(command: command, matches: matches, reply: { _, id in FixtureScript.replay(frames, messageID: id) })
        }

        /// One final result message.
        public static func result(
            command: String, matches: @escaping @Sendable (MAJSON) -> Bool = { _ in true }, _ result: MAJSON
        ) -> Route {
            frames(command: command, matches: matches, [["result": result, "partial": false]])
        }

        /// One error message.
        public static func error(
            command: String, matches: @escaping @Sendable (MAJSON) -> Bool = { _ in true }, code: Int, details: String
        ) -> Route {
            frames(command: command, matches: matches, [["error_code": .number(Double(code)), "details": .string(details)]])
        }

        /// Replays a recorded fixture under its own command.
        public static func fixture(
            _ fixture: MAFixture, matches: @escaping @Sendable (MAJSON) -> Bool = { _ in true }
        ) throws -> Route {
            frames(command: fixture.command ?? "", matches: matches, try fixture.frames())
        }
    }

    public var handshake: [String]
    public var routes: [Route]
    public var fallbackFrames: [MAJSON]

    public init(
        handshake: [String] = [], routes: [Route] = [],
        fallbackFrames: [MAJSON] = [["error_code": 12, "details": "Invalid or unsupported command."]]
    ) {
        self.handshake = handshake
        self.routes = routes
        self.fallbackFrames = fallbackFrames
    }

    public func replies(command: String, args: MAJSON, messageID: String) -> [String] {
        if let route = routes.first(where: { $0.command == command && $0.matches(args) }) {
            return route.reply(args, messageID)
        }
        return Self.replay(fallbackFrames, messageID: messageID)
    }

    /// Sets `message_id` on each message and serializes it.
    public static func replay(_ frames: [MAJSON], messageID: String) -> [String] {
        frames.map { frame in
            guard case .object(var object) = frame else { return frame.encodedString() }
            object["message_id"] = .string(messageID)
            return MAJSON.object(object).encodedString()
        }
    }

    /// Every recorded call, registered by its recorded command and arguments. `auth` answers `auth-ok` when the
    /// sent token equals `token`, else `error-auth`. Listings match on `offset` and `summary`; later pages answer an
    /// empty array; counts ignore their filters.
    public static func recorded(token: MusicAssistantToken) throws -> FixtureScript {
        let expected = token.rawValue
        let authOK = try MAFixture.authOk.frames()
        let authBad = try MAFixture.errorAuth.frames()
        var routes: [Route] = [
            Route(
                command: "auth",
                reply: { args, id in
                    FixtureScript.replay(args["token"]?.stringValue == expected ? authOK : authBad, messageID: id)
                })
        ]

        func any(_ fixture: MAFixture) throws -> Route { try Route.fixture(fixture) }
        func emptyList(_ command: String) -> Route { Route.result(command: command, []) }
        func argEquals(_ fixture: MAFixture, _ key: String) -> @Sendable (MAJSON) -> Bool {
            let wanted = fixture.args?[key]
            return { $0[key] == wanted }
        }

        // #0196: the `--record-queue` pages, by queue, offset and limit, ahead of the empty recorded queue.
        for fixture in [MAFixture.playerQueueItemsLoaded, .playerQueueItemsPage2] where fixture.isRecorded {
            let queue = fixture.args?["queue_id"], offset = fixture.args?["offset"]?.intValue ?? 0
            let limit = fixture.args?["limit"]
            routes.append(
                try Route.fixture(fixture, matches: {
                    $0["queue_id"] == queue && ($0["offset"]?.intValue ?? 0) == offset && $0["limit"] == limit
                }))
        }
        for fixture in [MAFixture.time, .infoWS, .authMe, .providers, .playersAll, .playerQueuesAll, .playerQueueActive,
                        .playerQueueItems, .artistsCount, .albumsCount, .tracksCount, .playlistsCount, .artistAlbums,
                        .albumGet, .itemByURI]
        {
            routes.append(try any(fixture))
        }
        routes.append(try Route.fixture(.playerGet, matches: argEquals(.playerGet, "player_id")))
        routes.append(try Route.fixture(.errorUnknownPlayer))
        routes.append(try Route.fixture(.playerQueueGet, matches: argEquals(.playerQueueGet, "queue_id")))
        routes.append(try Route.fixture(.albumTracks, matches: argEquals(.albumTracks, "item_id")))
        routes.append(emptyList("music/albums/album_tracks"))
        routes.append(try Route.fixture(.playlistTracks, matches: argEquals(.playlistTracks, "item_id")))
        routes.append(emptyList("music/playlists/playlist_tracks"))

        func listing(_ page: MAFixture, last: MAFixture?, full: MAFixture?) throws {
            let command = page.command ?? ""
            if let full { routes.append(try Route.fixture(full, matches: { $0["summary"]?.boolValue == false })) }
            if let last {
                let offset = last.args?["offset"]
                routes.append(try Route.fixture(last, matches: { $0["offset"] == offset }))
            }
            routes.append(try Route.fixture(page, matches: { ($0["offset"]?.intValue ?? 0) == 0 }))
            routes.append(emptyList(command))
        }
        try listing(.artistsPage, last: .artistsLastPage, full: .artistsPageFull)
        try listing(.albumsPage, last: .albumsLastPage, full: .albumsPageFull)
        try listing(.tracksPage, last: .tracksLastPage, full: .tracksPageFull)
        try listing(.playlistsPage, last: nil, full: nil)

        let searchFrames = try MAFixture.search.frames()
        let recordedQuery = MAFixture.search.args?["search_query"]
        let emptySearch: MAJSON = [
            "artists": [], "albums": [], "genres": [], "tracks": [], "playlists": [], "radio": [],
            "audiobooks": [], "podcasts": [], "sound_effects": [],
        ]
        routes.append(
            Route(
                command: "music/search",
                reply: { args, id in
                    let answer: [MAJSON] = args["search_query"] == recordedQuery ? searchFrames : [["result": emptySearch, "partial": false]]
                    return FixtureScript.replay(answer, messageID: id)
                }))

        return FixtureScript(
            handshake: try MAFixture.serverInfo.frameTexts(), routes: routes,
            fallbackFrames: try MAFixture.errorUnknownCommand.frames())
    }
}
