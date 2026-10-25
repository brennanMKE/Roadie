import Foundation
import MusicAssistantKit
import os

/// A small in-memory Music Assistant server built on the recorded fixtures (#0197, docs/design/test-automation.md
/// §2.2). The library answers as `FixtureScript.recorded(token:)` does; players, queues, favorites and playlists are
/// state that the app's commands change, and every change is followed by `player_updated`, `queue_updated` and
/// `queue_items_updated` events in the envelope from docs/ma-protocol-notes.md §8.
///
/// Its replies are recorded shapes with state applied, never new shapes: a queue is `player-queue-get.json`'s
/// object, a row is a recorded `player-queue-items-loaded.json` row (the synthetic shape of `BackendQueueTests` when
/// that is not recorded), a player is its `players-all.json` entry. `index` is always 0 on a row, as the real server
/// sends it (#0187). `current_media` while playing follows `SyntheticPlayback` (unrecorded).
public final class ScriptedMusicAssistant: @unchecked Sendable {
    public enum Scenario: String, CaseIterable, Sendable {
        /// The recording as it is: nothing playing, every queue empty.
        case libraryIdle
        /// The recorded loaded queue (synthetic rows when unrecorded) playing on `speakerID`, current index 2.
        case queueLoaded
        /// `SyntheticPlayback`: one track playing on `speakerID`.
        case playingOnSpeaker
        /// `players-all-sendspin.json`: This Mac is a Sendspin player.
        case thisMacIsASendspinPlayer
        /// Every connection fails (`.transport(.cannotConnectToHost)`).
        case unreachable
        /// `auth` always answers the recorded `error-auth`.
        case badToken
    }

    /// The speaker the playing scenarios use (the recorded `players/get` player).
    public static let speakerID = SyntheticPlayback.playerID

    /// One queue as the server holds it.
    public struct Queue: Sendable, Hashable {
        public var queueID: String
        /// The rows as sent by `player_queues/items` (`index` 0 on each).
        public var items: [MAJSON]
        public var currentIndex: Int?
        public var state: String
        public var repeatMode: String
        public var shuffleEnabled: Bool
        /// Elapsed seconds when last paused or started; `resumedAt` adds the time since.
        var elapsed: Double = 0
        var resumedAt: Duration?

        public var itemIDs: [String] { items.compactMap { $0["queue_item_id"]?.stringValue } }
    }

    // MARK: Recorded library (immutable)

    private struct Library: Sendable {
        var playersAll: [MAJSON]
        var playersAllSendspin: [MAJSON]
        var queueTemplate: MAJSON
        var rowTemplate: MAJSON
        var loadedRows: [MAJSON]
        var tracks: [MAJSON]
        var albums: [MAJSON]
        var artists: [MAJSON]
        var albumTracks: [String: [MAJSON]]
        var playlists: [MAJSON]
        var playlistTracks: [String: [MAJSON]]
        var playlistsCount: Int
        var lastUpdatedEpoch: Double
        var authOK: [MAJSON]
        var authBad: [MAJSON]
    }

    private struct State {
        var scenario: Scenario
        var players: [String: MAJSON] = [:]
        var playerOrder: [String] = []
        var queues: [String: Queue] = [:]
        var favorites: Set<String> = []
        var playlists: [MAJSON] = []
        var playlistTracks: [String: [MAJSON]] = [:]
        var createdPlaylists = 0
        var deletedPlaylists = 0
        var nextID = 1
        var received: [SentRequest] = []
        var events: [MAServerEvent] = []
        var transports: [StubWebSocketTransport] = []
    }

    private enum Reply: Sendable {
        case result(MAJSON)
        case error(code: Int, details: String)
    }

    private let library: Library
    private let base: FixtureScript
    private let uptime: @Sendable () -> Duration
    private let state: OSAllocatedUnfairLock<State>

    /// `/info`, `commands.json` and artwork.
    public let http = StubHTTPTransport()

    public convenience init(scenario: Scenario = .libraryIdle) throws {
        try self.init(scenario: scenario, clock: ContinuousClock())
    }

    /// `clock` advances elapsed time while a queue plays (a manual clock in tests).
    public init<C: Clock>(scenario: Scenario, clock: C) throws where C.Duration == Duration {
        let start = clock.now
        uptime = { start.duration(to: clock.now) }
        let library = try Self.loadLibrary()
        self.library = library
        // Auth is answered by `handle`; the token here only fills `recorded`'s own auth route.
        base = try FixtureScript.recorded(token: MusicAssistantToken("scripted"))
        var initial = State(scenario: scenario)
        Self.build(&initial, scenario: scenario, library: library)
        state = OSAllocatedUnfairLock(initialState: initial)
    }

    /// A transport factory whose every transport talks to one new server: reconnects keep its state.
    public static func transportFactory(scenario: Scenario) throws -> ScriptedTransportFactory {
        ScriptedTransportFactory(server: try ScriptedMusicAssistant(scenario: scenario))
    }

    // MARK: Introspection

    public var scenario: Scenario { state.withLock { $0.scenario } }
    /// Every request received, in order (the `auth` token redacted).
    public var receivedCommands: [SentRequest] { state.withLock { $0.received } }
    /// Every event pushed, in order.
    public var pushedEvents: [MAServerEvent] { state.withLock { $0.events } }
    public var transports: [StubWebSocketTransport] { state.withLock { $0.transports } }

    public func queue(for queueID: String) -> Queue? { state.withLock { $0.queues[queueID] } }

    /// The player object as `players/get` answers it.
    public func player(_ playerID: String) -> MAJSON? {
        let now = uptime()
        return state.withLock { s in s.players[playerID].map { Self.playerJSON($0, s: s, now: now, library: library) } }
    }

    /// Back to the scenario's starting state; the received log and events are cleared.
    public func reset(to scenario: Scenario) {
        let library = library
        state.withLock { s in
            let transports = s.transports
            s = State(scenario: scenario)
            s.transports = transports
            Self.build(&s, scenario: scenario, library: library)
        }
    }

    /// The last `limit` commands with their key arguments (`play_index index=3`), for the test probe (#0199).
    public func recentCommandSummaries(limit: Int = 20) -> [String] {
        receivedCommands.suffix(limit).map(Self.summary)
    }

    static func summary(_ request: SentRequest) -> String {
        let name = request.command.split(separator: "/").last.map(String.init) ?? request.command
        let skipped: Set<String> = ["queue_id", "player_id", "token"]
        let pairs = (request.args.objectValue ?? [:]).filter { !skipped.contains($0.key) }.sorted { $0.key < $1.key }
            .map { key, value -> String in
                let text: String
                switch value {
                case .string(let string): text = string
                case .number: text = value.intValue.map(String.init) ?? value.encodedString()
                case .array(let values): text = values.map { $0.stringValue ?? $0.encodedString() }.joined(separator: ",")
                default: text = value.encodedString()
                }
                return "\(key)=\(text)"
            }
        return ([name] + pairs).joined(separator: " ")
    }

    // MARK: Transport

    /// The script every transport answers from: `handle` first, then the recorded routes.
    public var script: FixtureScript {
        var script = base
        script.handler = { [weak self] command, args, id in self?.handle(command: command, args: args, messageID: id) }
        return script
    }

    func makeTransport() -> StubWebSocketTransport {
        let unreachable = scenario == .unreachable
        let transport = StubWebSocketTransport(
            script: script, connectError: unreachable ? .transport(.cannotConnectToHost) : nil)
        state.withLock { $0.transports.append(transport) }
        return transport
    }

    /// Pushes an event to the newest transport (a server-initiated change in a test).
    public func push(_ event: MAServerEvent) {
        let transport = state.withLock { s -> StubWebSocketTransport? in
            s.events.append(event)
            return s.transports.last
        }
        transport?.push(Self.eventText(event))
    }

    private static func eventText(_ event: MAServerEvent) -> String {
        var object: [String: MAJSON] = ["event": .string(event.event), "data": event.data]
        if let id = event.objectID { object["object_id"] = .string(id) }
        return MAJSON.object(object).encodedString()
    }

    /// The reply texts, then the events the change caused; nil hands the request to the recorded routes.
    private func handle(command: String, args: MAJSON, messageID: String) -> [String]? {
        let now = uptime()
        let library = library
        let outcome = state.withLock { s -> (texts: [String]?, events: [MAServerEvent]) in
            var logged = args
            if command == "auth", case .object(var object) = args {
                object["token"] = "redacted"
                logged = .object(object)
            }
            s.received.append(SentRequest(command: command, args: logged, messageID: messageID))
            if command == "auth" {
                let frames = s.scenario == .badToken ? library.authBad : library.authOK
                return (FixtureScript.replay(frames, messageID: messageID), [])
            }
            var events: [MAServerEvent] = []
            guard let reply = Self.apply(&s, command: command, args: args, now: now, library: library, events: &events)
            else { return (nil, []) }
            s.events += events
            let frame: MAJSON
            switch reply {
            case .result(let result): frame = ["result": result, "partial": false]
            case .error(let code, let details):
                frame = ["error_code": .number(Double(code)), "details": .string(details)]
            }
            return (FixtureScript.replay([frame], messageID: messageID), events)
        }
        guard let texts = outcome.texts else { return nil }
        return texts + outcome.events.map(Self.eventText)
    }

    // MARK: Loading

    private static func result(_ fixture: MAFixture) throws -> MAJSON {
        try fixture.frames().first?["result"] ?? .null
    }

    private static func rows(_ fixture: MAFixture) throws -> [MAJSON] {
        guard fixture.isRecorded else { return [] }
        return try fixture.frames().flatMap { $0["result"]?.arrayValue ?? [] }
    }

    private static func uri(of fixture: MAFixture, kind: String) -> String? {
        guard let id = fixture.args?["item_id"]?.stringValue else { return nil }
        let provider = fixture.args?["provider_instance_id_or_domain"]?.stringValue ?? "library"
        return "\(provider)://\(kind)/\(id)"
    }

    private static func unique(_ lists: [[MAJSON]]) -> [MAJSON] {
        var seen: Set<String> = []
        var out: [MAJSON] = []
        for item in lists.joined() {
            guard let uri = item["uri"]?.stringValue, seen.insert(uri).inserted else { continue }
            out.append(item)
        }
        return out
    }

    private static func loadLibrary() throws -> Library {
        let recordedLoaded = try rows(.playerQueueItemsLoaded) + rows(.playerQueueItemsPage2)
        let tracks = unique([
            try rows(.tracksPage), try rows(.tracksPageFull), try rows(.tracksLastPage), try rows(.albumTracks),
            try rows(.playlistTracks),
        ])
        var albumTracks: [String: [MAJSON]] = [:]
        if let uri = uri(of: .albumTracks, kind: "album") { albumTracks[uri] = try rows(.albumTracks) }
        var playlistTracks: [String: [MAJSON]] = [:]
        if let id = MAFixture.playlistTracks.args?["item_id"]?.stringValue {
            playlistTracks[id] = try rows(.playlistTracks)
        }
        let queueTemplate = try result(.playerQueueGet)
        return Library(
            playersAll: try rows(.playersAll),
            playersAllSendspin: try rows(.playersAllSendspin),
            queueTemplate: queueTemplate,
            rowTemplate: recordedLoaded.first ?? syntheticRowTemplate,
            loadedRows: recordedLoaded,
            tracks: tracks,
            albums: unique([try rows(.albumsPage), try rows(.albumsPageFull), try rows(.albumsLastPage), try rows(.artistAlbums)]),
            artists: unique([try rows(.artistsPage), try rows(.artistsPageFull), try rows(.artistsLastPage)]),
            albumTracks: albumTracks,
            playlists: try rows(.playlistsPage),
            playlistTracks: playlistTracks,
            playlistsCount: try result(.playlistsCount).intValue ?? 0,
            lastUpdatedEpoch: queueTemplate["elapsed_time_last_updated"]?.doubleValue ?? 0,
            authOK: try MAFixture.authOk.frames(),
            authBad: try MAFixture.errorAuth.frames())
    }

    /// SYNTHETIC, as `BackendQueueTests.itemJSON`, shaped after `QueueItem` in docs/ma-protocol/openapi.json: used
    /// only while `player-queue-items-loaded.json` is unrecorded.
    private static let syntheticRowTemplate: MAJSON = [
        "queue_id": "", "queue_item_id": "", "name": "", "duration": 0, "sort_index": 0, "streamdetails": nil,
        "media_item": nil, "image": nil, "index": 0, "available": true, "extra_attributes": [:],
    ]

    // MARK: Scenarios

    private static func build(_ s: inout State, scenario: Scenario, library: Library) {
        let players = scenario == .thisMacIsASendspinPlayer ? library.playersAllSendspin : library.playersAll
        for player in players {
            guard let id = player["player_id"]?.stringValue else { continue }
            s.players[id] = player
            s.playerOrder.append(id)
            s.queues[id] = Queue(queueID: id, items: [], currentIndex: nil, state: "idle", repeatMode: "off", shuffleEnabled: false)
        }
        s.playlists = library.playlists
        s.playlistTracks = library.playlistTracks
        let speaker = speakerID
        switch scenario {
        case .queueLoaded:
            var rows = library.loadedRows
            if rows.isEmpty {
                // 12 synthetic rows cycling the recorded tracks page.
                rows = (0..<12).compactMap { n in
                    library.tracks.isEmpty ? nil : makeRow(library.tracks[n % library.tracks.count], &s, library: library, queueID: speaker)
                }
            }
            rows = rows.map { set($0, ["queue_id": .string(speaker), "index": 0]) }
            s.queues[speaker]?.items = rows
            s.queues[speaker]?.currentIndex = rows.count > 2 ? 2 : (rows.isEmpty ? nil : 0)
            s.queues[speaker]?.state = rows.isEmpty ? "idle" : "playing"
            s.queues[speaker]?.resumedAt = .zero
            if let player = s.players[speaker] { s.players[speaker] = set(player, ["available": true]) }
        case .playingOnSpeaker:
            if let track = library.tracks.first {
                let row = makeRow(track, &s, library: library, queueID: speaker)
                s.queues[speaker]?.items = [row]
                s.queues[speaker]?.currentIndex = 0
                s.queues[speaker]?.state = "playing"
                s.queues[speaker]?.elapsed = 30
                s.queues[speaker]?.resumedAt = .zero
            }
            if let player = s.players[speaker] { s.players[speaker] = set(player, ["available": true]) }
        case .libraryIdle, .thisMacIsASendspinPlayer, .unreachable, .badToken:
            break
        }
    }

    // MARK: Building replies

    private static func set(_ json: MAJSON, _ changes: [String: MAJSON]) -> MAJSON {
        guard case .object(var object) = json else { return json }
        for (key, value) in changes { object[key] = value }
        return .object(object)
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private static func elapsed(_ queue: Queue, now: Duration) -> Double {
        queue.elapsed + (queue.resumedAt.map { seconds(now - $0) } ?? 0)
    }

    private static func row(_ row: MAJSON) -> MAJSON { set(row, ["index": 0]) }

    private static func queueJSON(_ queue: Queue, now: Duration, library: Library) -> MAJSON {
        let current = queue.currentIndex.flatMap { queue.items.indices.contains($0) ? queue.items[$0] : nil }
        let next = queue.currentIndex.flatMap { queue.items.indices.contains($0 + 1) ? queue.items[$0 + 1] : nil }
        return set(
            library.queueTemplate,
            [
                "queue_id": .string(queue.queueID),
                "items": .number(Double(queue.items.count)),
                "current_index": queue.currentIndex.map { .number(Double($0)) } ?? .null,
                "state": .string(queue.state),
                "elapsed_time": .number(elapsed(queue, now: now)),
                "elapsed_time_last_updated": .number(library.lastUpdatedEpoch + seconds(now)),
                "shuffle_enabled": .bool(queue.shuffleEnabled),
                "repeat_mode": .string(queue.repeatMode),
                "current_item": current.map(row) ?? .null,
                "next_item": next.map(row) ?? .null,
            ])
    }

    /// The stored player with its queue's state: `playback_state`, elapsed time and (SYNTHETIC) `current_media`.
    private static func playerJSON(_ player: MAJSON, s: State, now: Duration, library: Library) -> MAJSON {
        guard let id = player["player_id"]?.stringValue, let queue = s.queues[id] else { return player }
        let current = queue.currentIndex.flatMap { queue.items.indices.contains($0) ? queue.items[$0] : nil }
        var changes: [String: MAJSON] = ["playback_state": .string(queue.state)]
        if let current {
            let track = current["media_item"]
            var media: [String: MAJSON] = ["media_type": "track"]
            media["uri"] = track?["uri"] ?? .null
            media["title"] = track?["name"] ?? current["name"] ?? .null
            media["artist"] = track?["artists"]?[0]?["name"] ?? .null
            media["album"] = track?["album"]?["name"] ?? .null
            media["duration"] = current["duration"] ?? .null
            media["image_url"] = .null
            media["queue_item_id"] = current["queue_item_id"] ?? .null
            changes["current_media"] = .object(media)
            changes["elapsed_time"] = .number(elapsed(queue, now: now))
            changes["elapsed_time_last_updated"] = .number(library.lastUpdatedEpoch + seconds(now))
        } else if queue.state == "idle" {
            changes["current_media"] = .null
        }
        return set(player, changes)
    }

    /// A queue row for `track` in the recorded row shape.
    private static func makeRow(_ track: MAJSON, _ s: inout State, library: Library, queueID: String) -> MAJSON {
        let id = String(format: "%032lx", 0x5C1A_0000 + s.nextID)
        s.nextID += 1
        let title = track["name"]?.stringValue ?? ""
        let artist = track["artists"]?[0]?["name"]?.stringValue
        let image = track["metadata"]?["images"]?[0] ?? track["image"] ?? .null
        return set(
            library.rowTemplate,
            [
                "queue_id": .string(queueID), "queue_item_id": .string(id),
                "name": .string(artist.map { "\($0) - \(title)" } ?? title),
                "duration": track["duration"] ?? .null, "media_item": track, "image": image, "index": 0,
                "sort_index": .number(Double(s.nextID)), "available": true,
            ])
    }

    // MARK: Library lookups

    private static func track(uri: String, library: Library) -> MAJSON? {
        library.tracks.first { $0["uri"]?.stringValue == uri }
    }

    private static func playlistTracks(_ s: State, id: String) -> [MAJSON] { s.playlistTracks[id] ?? [] }

    /// The tracks `uri` plays: a track, an album's or playlist's recorded tracks, an artist's tracks.
    private static func expand(_ uri: String, s: State, library: Library) -> [MAJSON] {
        guard let parsed = MAURI.parse(uri) else { return [] }
        switch parsed.mediaType {
        case .track: return track(uri: uri, library: library).map { [$0] } ?? []
        case .album:
            return library.albumTracks[uri]
                ?? library.tracks.filter { $0["album"]?["uri"]?.stringValue == uri }
        case .playlist: return playlistTracks(s, id: parsed.itemID)
        case .artist:
            return library.tracks.filter { track in
                (track["artists"]?.arrayValue ?? []).contains { $0["uri"]?.stringValue == uri }
            }
        case .radio: return []
        }
    }

    private static func favorite(_ item: MAJSON, _ s: State) -> MAJSON {
        guard let uri = item["uri"]?.stringValue else { return item }
        return s.favorites.contains(uri) ? set(item, ["favorite": true]) : item
    }

    private static func listing(_ kind: String, s: State, library: Library) -> [MAJSON]? {
        switch kind {
        case "tracks": library.tracks
        case "albums": library.albums
        case "artists": library.artists
        case "playlists": s.playlists
        default: nil
        }
    }

    // MARK: Commands

    private static func queueID(forPlayer playerID: String, _ s: State) -> String? {
        guard let player = s.players[playerID] else { return s.queues[playerID] == nil ? nil : playerID }
        let leader = player["active_group"]?.stringValue ?? player["synced_to"]?.stringValue
        if let leader, s.queues[leader] != nil { return leader }
        return playerID
    }

    /// Queue and player events after a change of `queueID`.
    private static func changed(
        _ queueID: String, items: Bool, _ s: State, now: Duration, library: Library, events: inout [MAServerEvent]
    ) {
        guard let queue = s.queues[queueID] else { return }
        let json = queueJSON(queue, now: now, library: library)
        if let player = s.players[queueID] {
            events.append(MAServerEvent(event: "player_updated", objectID: queueID, data: playerJSON(player, s: s, now: now, library: library)))
        }
        events.append(MAServerEvent(event: "queue_updated", objectID: queueID, data: json))
        if items { events.append(MAServerEvent(event: "queue_items_updated", objectID: queueID, data: json)) }
    }

    private static func play(_ queue: inout Queue, at index: Int?, now: Duration) {
        queue.currentIndex = index
        queue.elapsed = 0
        if index == nil {
            queue.state = "idle"
            queue.resumedAt = nil
        } else {
            queue.state = "playing"
            queue.resumedAt = now
        }
    }

    private static func pause(_ queue: inout Queue, now: Duration) {
        queue.elapsed = elapsed(queue, now: now)
        queue.resumedAt = nil
        queue.state = "paused"
    }

    private static func resume(_ queue: inout Queue, now: Duration) {
        guard queue.currentIndex != nil else { return }
        if queue.resumedAt == nil { queue.resumedAt = now }
        queue.state = "playing"
    }

    private static func step(_ queue: inout Queue, by delta: Int, now: Duration) {
        guard !queue.items.isEmpty else { return }
        let target = min(max((queue.currentIndex ?? -1) + delta, 0), queue.items.count - 1)
        play(&queue, at: target, now: now)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func apply(
        _ s: inout State, command: String, args: MAJSON, now: Duration, library: Library, events: inout [MAServerEvent]
    ) -> Reply? {
        let queueArg = args["queue_id"]?.stringValue
        let playerArg = args["player_id"]?.stringValue

        switch command {
        // Players and queues
        case "players/all":
            return .result(.array(s.playerOrder.compactMap { s.players[$0] }.map { playerJSON($0, s: s, now: now, library: library) }))
        case "players/get":
            guard let id = playerArg, let player = s.players[id] else { return .result(.null) }
            return .result(playerJSON(player, s: s, now: now, library: library))
        case "player_queues/all":
            return .result(.array(s.playerOrder.compactMap { s.queues[$0] }.map { queueJSON($0, now: now, library: library) }))
        case "player_queues/get":
            guard let id = queueArg, let queue = s.queues[id] else { return .result(.null) }
            return .result(queueJSON(queue, now: now, library: library))
        case "player_queues/get_active_queue":
            guard let id = playerArg, let qid = queueID(forPlayer: id, s), let queue = s.queues[qid] else { return .result(.null) }
            return .result(queueJSON(queue, now: now, library: library))
        case "player_queues/items":
            guard let id = queueArg, let queue = s.queues[id] else { return .result([]) }
            let offset = max(args["offset"]?.intValue ?? 0, 0)
            let limit = max(args["limit"]?.intValue ?? 500, 0)
            guard offset < queue.items.count else { return .result([]) }
            return .result(.array(queue.items[offset..<min(offset + limit, queue.items.count)].map(row)))

        case "player_queues/play_index":
            guard let id = queueArg, var queue = s.queues[id] else { return nil }
            let index: Int?
            if let number = args["index"]?.intValue {
                index = number
            } else if let itemID = args["index"]?.stringValue {
                index = queue.itemIDs.firstIndex(of: itemID)
            } else {
                index = nil
            }
            guard let index, queue.items.indices.contains(index) else {
                return .error(code: 999, details: "IndexError: list index out of range")
            }
            play(&queue, at: index, now: now)
            s.queues[id] = queue
            changed(id, items: false, s, now: now, library: library, events: &events)
            return .result(.null)

        case "player_queues/play_media":
            guard let id = queueArg, var queue = s.queues[id] else { return nil }
            let uris = (args["media"]?.arrayValue ?? []).compactMap(\.stringValue)
            var tracks: [MAJSON] = []
            for uri in uris { tracks += expand(uri, s: s, library: library) }
            let rows = tracks.map { makeRow($0, &s, library: library, queueID: id) }
            let wasIdle = queue.items.isEmpty && queue.state == "idle"
            let afterCurrent = (queue.currentIndex ?? -1) + 1
            switch args["option"]?.stringValue ?? "play" {
            case "replace":
                queue.items = rows
                let start = args["start_item"]?.stringValue.flatMap { uri in
                    rows.firstIndex { $0["media_item"]?["uri"]?.stringValue == uri }
                } ?? 0
                play(&queue, at: rows.isEmpty ? nil : start, now: now)
            case "replace_next":
                queue.items = Array(queue.items.prefix(afterCurrent)) + rows
            case "next":
                queue.items.insert(contentsOf: rows, at: min(afterCurrent, queue.items.count))
                if wasIdle && !rows.isEmpty { play(&queue, at: 0, now: now) }
            case "add":
                queue.items += rows
                if wasIdle && !rows.isEmpty { play(&queue, at: 0, now: now) }
            default:  // "play"
                let at = min(afterCurrent, queue.items.count)
                queue.items.insert(contentsOf: rows, at: at)
                if !rows.isEmpty { play(&queue, at: at, now: now) }
            }
            s.queues[id] = queue
            changed(id, items: true, s, now: now, library: library, events: &events)
            return .result(.null)

        case "player_queues/move_item":
            guard let id = queueArg, var queue = s.queues[id], let itemID = args["queue_item_id"]?.stringValue,
                let from = queue.itemIDs.firstIndex(of: itemID)
            else { return nil }
            let currentID = queue.currentIndex.flatMap { queue.itemIDs.indices.contains($0) ? queue.itemIDs[$0] : nil }
            let to = min(max(from + (args["pos_shift"]?.intValue ?? 0), 0), queue.items.count - 1)
            let moved = queue.items.remove(at: from)
            queue.items.insert(moved, at: to)
            if let currentID { queue.currentIndex = queue.itemIDs.firstIndex(of: currentID) }
            s.queues[id] = queue
            changed(id, items: true, s, now: now, library: library, events: &events)
            return .result(.null)

        case "player_queues/delete_item":
            guard let id = queueArg, var queue = s.queues[id] else { return nil }
            let target = args["item_id_or_index"]
            guard let index = target?.intValue ?? target?.stringValue.flatMap({ queue.itemIDs.firstIndex(of: $0) }),
                queue.items.indices.contains(index)
            else { return .error(code: 999, details: "IndexError: list index out of range") }
            queue.items.remove(at: index)
            if let current = queue.currentIndex {
                if queue.items.isEmpty {
                    play(&queue, at: nil, now: now)
                } else if index < current {
                    queue.currentIndex = current - 1
                } else if current >= queue.items.count {
                    queue.currentIndex = queue.items.count - 1
                }
            }
            s.queues[id] = queue
            changed(id, items: true, s, now: now, library: library, events: &events)
            return .result(.null)

        case "player_queues/clear":
            guard let id = queueArg, var queue = s.queues[id] else { return nil }
            queue.items = []
            play(&queue, at: nil, now: now)
            s.queues[id] = queue
            changed(id, items: true, s, now: now, library: library, events: &events)
            return .result(.null)

        case "player_queues/next", "player_queues/previous":
            guard let id = queueArg, var queue = s.queues[id] else { return nil }
            step(&queue, by: command.hasSuffix("next") ? 1 : -1, now: now)
            s.queues[id] = queue
            changed(id, items: false, s, now: now, library: library, events: &events)
            return .result(.null)

        case "player_queues/shuffle", "players/cmd/shuffle", "player_queues/repeat", "players/cmd/repeat":
            guard let id = queueArg ?? playerArg.flatMap({ queueID(forPlayer: $0, s) }), var queue = s.queues[id]
            else { return nil }
            if let enabled = args["shuffle_enabled"]?.boolValue { queue.shuffleEnabled = enabled }
            if let mode = args["repeat_mode"]?.stringValue { queue.repeatMode = mode }
            s.queues[id] = queue
            changed(id, items: false, s, now: now, library: library, events: &events)
            return .result(.null)

        case "player_queues/transfer":
            guard let source = args["source_queue_id"]?.stringValue, let target = args["target_queue_id"]?.stringValue,
                var from = s.queues[source], var to = s.queues[target]
            else { return nil }
            to.items = from.items.map { set($0, ["queue_id": .string(target)]) }
            to.currentIndex = from.currentIndex
            to.elapsed = elapsed(from, now: now)
            to.resumedAt = nil
            to.state = "paused"
            if args["auto_play"]?.boolValue ?? true { resume(&to, now: now) }
            from.items = []
            play(&from, at: nil, now: now)
            s.queues[source] = from
            s.queues[target] = to
            changed(source, items: true, s, now: now, library: library, events: &events)
            changed(target, items: true, s, now: now, library: library, events: &events)
            return .result(.null)

        case "player_queues/save_as_playlist":
            guard let id = queueArg, let queue = s.queues[id] else { return nil }
            guard !queue.items.isEmpty else { return .error(code: 8, details: "Cannot save an empty queue as a playlist.") }
            let playlist = createPlaylist(&s, name: args["name"]?.stringValue ?? "", library: library)
            if let pid = playlist["item_id"]?.stringValue {
                s.playlistTracks[pid] = numbered(queue.items.compactMap { $0["media_item"] })
            }
            return .result(.null)

        case "players/cmd/play", "players/cmd/pause", "players/cmd/play_pause", "players/cmd/stop",
            "players/cmd/next", "players/cmd/previous", "players/cmd/seek":
            guard let pid = playerArg, let id = queueID(forPlayer: pid, s), var queue = s.queues[id] else { return nil }
            switch command {
            case "players/cmd/play": resume(&queue, now: now)
            case "players/cmd/pause": if queue.state == "playing" { pause(&queue, now: now) }
            case "players/cmd/play_pause":
                if queue.state == "playing" { pause(&queue, now: now) } else { resume(&queue, now: now) }
            case "players/cmd/stop":
                queue.elapsed = 0
                queue.resumedAt = nil
                queue.state = "idle"
            case "players/cmd/next": step(&queue, by: 1, now: now)
            case "players/cmd/previous": step(&queue, by: -1, now: now)
            default:  // seek
                queue.elapsed = Double(args["position"]?.intValue ?? 0)
                if queue.resumedAt != nil { queue.resumedAt = now }
            }
            s.queues[id] = queue
            changed(id, items: false, s, now: now, library: library, events: &events)
            return .result(.null)

        case "players/cmd/volume_set", "players/cmd/volume_mute":
            guard let id = playerArg, let player = s.players[id] else { return nil }
            if let level = args["volume_level"] {
                s.players[id] = set(player, ["volume_level": level])
            } else if let muted = args["muted"] {
                s.players[id] = set(player, ["volume_muted": muted])
            }
            if let updated = s.players[id] {
                events.append(MAServerEvent(event: "player_updated", objectID: id, data: playerJSON(updated, s: s, now: now, library: library)))
            }
            return .result(.null)

        case "players/cmd/set_members":
            guard let target = args["target_player"]?.stringValue, let leader = s.players[target] else { return nil }
            let add = (args["player_ids_to_add"]?.arrayValue ?? []).compactMap(\.stringValue)
            let remove = Set((args["player_ids_to_remove"]?.arrayValue ?? []).compactMap(\.stringValue))
            var members = (leader["group_members"]?.arrayValue ?? []).compactMap(\.stringValue).filter { !remove.contains($0) }
            for id in add where !members.contains(id) { members.append(id) }
            if !members.isEmpty && !members.contains(target) { members.insert(target, at: 0) }
            if members == [target] { members = [] }
            s.players[target] = set(leader, ["group_members": .array(members.map(MAJSON.string))])
            for id in add where id != target { s.players[id] = s.players[id].map { set($0, ["synced_to": .string(target)]) } }
            for id in remove { s.players[id] = s.players[id].map { set($0, ["synced_to": .null]) } }
            for id in [target] + add + remove.sorted() {
                if let player = s.players[id] {
                    events.append(MAServerEvent(event: "player_updated", objectID: id, data: playerJSON(player, s: s, now: now, library: library)))
                }
            }
            return .result(.null)

        // Favorites
        case "music/favorites/add_item":
            guard let uri = args["item"]?.stringValue else { return nil }
            s.favorites.insert(uri)
            return .result(.null)
        case "music/favorites/remove_item":
            guard let type = args["media_type"]?.stringValue, let id = args["library_item_id"]?.stringValue else { return nil }
            s.favorites.remove("library://\(type)/\(id)")
            return .result(.null)

        // Playlists (an in-memory copy of the recorded ones)
        case "music/playlists/library_items" where args["favorite"]?.boolValue != true:
            let offset = args["offset"]?.intValue ?? 0
            return .result(.array(offset == 0 ? s.playlists.map { favorite($0, s) } : []))
        case "music/playlists/count" where args["favorite_only"]?.boolValue != true:
            return .result(.number(Double(library.playlistsCount + s.createdPlaylists - s.deletedPlaylists)))
        case "music/playlists/get":
            guard let id = args["item_id"]?.stringValue else { return .result(.null) }
            return .result(s.playlists.first { $0["item_id"]?.stringValue == id }.map { favorite($0, s) } ?? .null)
        case "music/playlists/playlist_tracks":
            guard let id = args["item_id"]?.stringValue else { return .result([]) }
            return .result(.array(playlistTracks(s, id: id)))
        case "music/playlists/create_playlist":
            return .result(createPlaylist(&s, name: args["name"]?.stringValue ?? "", library: library))
        case "music/playlists/add_playlist_tracks":
            guard let id = args["db_playlist_id"]?.stringValue else { return nil }
            var tracks = playlistTracks(s, id: id)
            for uri in (args["uris"]?.arrayValue ?? []).compactMap(\.stringValue) {
                for track in expand(uri, s: s, library: library)
                where !tracks.contains(where: { $0["uri"] == track["uri"] }) {
                    tracks.append(track)
                }
            }
            s.playlistTracks[id] = numbered(tracks)
            return .result(.null)
        case "music/playlists/remove_playlist_tracks":
            guard let id = args["db_playlist_id"]?.stringValue else { return nil }
            let positions = Set((args["positions_to_remove"]?.arrayValue ?? []).compactMap(\.intValue))
            let kept = playlistTracks(s, id: id).enumerated().filter { !positions.contains($0.offset + 1) }.map(\.element)
            s.playlistTracks[id] = numbered(kept)
            return .result(.null)
        case "music/playlists/update":
            guard let id = args["item_id"]?.stringValue,
                let index = s.playlists.firstIndex(where: { $0["item_id"]?.stringValue == id })
            else { return nil }
            if let name = args["update"]?["name"]?.stringValue {
                s.playlists[index] = set(s.playlists[index], ["name": .string(name), "sort_name": .string(name.lowercased())])
            }
            return .result(s.playlists[index])
        case "music/library/remove_item":
            guard args["media_type"]?.stringValue == "playlist", let id = args["library_item_id"]?.stringValue else { return nil }
            let before = s.playlists.count
            s.playlists.removeAll { $0["item_id"]?.stringValue == id }
            if s.playlists.count < before { s.deletedPlaylists += 1 }
            s.playlistTracks[id] = nil
            return .result(.null)

        default:
            break
        }

        // Favorite listings and counts: `music/<kind>s/library_items {favorite: true}`, `count {favorite_only: true}`.
        let parts = command.split(separator: "/").map(String.init)
        if parts.count == 3, parts[0] == "music", let items = listing(parts[1], s: s, library: library) {
            if parts[2] == "library_items", args["favorite"]?.boolValue == true {
                let favorites = items.filter { ($0["uri"]?.stringValue).map(s.favorites.contains) ?? false }
                    .map { set($0, ["favorite": true]) }
                return .result(.array((args["offset"]?.intValue ?? 0) == 0 ? favorites : []))
            }
            if parts[2] == "count", args["favorite_only"]?.boolValue == true {
                let count = items.filter { ($0["uri"]?.stringValue).map(s.favorites.contains) ?? false }.count
                return .result(.number(Double(count)))
            }
        }
        return nil
    }

    private static func numbered(_ tracks: [MAJSON]) -> [MAJSON] {
        tracks.enumerated().map { set($0.element, ["position": .number(Double($0.offset + 1))]) }
    }

    /// A user playlist on the builtin provider, in the recorded playlist shape.
    private static func createPlaylist(_ s: inout State, name: String, library: Library) -> MAJSON {
        let id = String(9000 + s.nextID)
        s.nextID += 1
        let template = library.playlists.first ?? [:]
        var mappings = template["provider_mappings"]?.arrayValue ?? []
        if !mappings.isEmpty {
            mappings[0] = set(mappings[0], ["item_id": .string(id), "provider_domain": "builtin", "provider_instance": "builtin"])
        }
        let playlist = set(
            template,
            [
                "item_id": .string(id), "provider": "library", "name": .string(name), "sort_name": .string(name.lowercased()),
                "uri": .string("library://playlist/\(id)"), "owner": "user", "is_editable": true, "is_dynamic": false,
                "favorite": false, "provider_mappings": .array(mappings),
            ])
        s.playlists.append(playlist)
        s.playlistTracks[id] = []
        s.createdPlaylists += 1
        return playlist
    }
}

/// Every transport it makes talks to one `ScriptedMusicAssistant`.
public final class ScriptedTransportFactory: MAWebSocketTransportFactory, @unchecked Sendable {
    public let server: ScriptedMusicAssistant

    public init(server: ScriptedMusicAssistant) {
        self.server = server
    }

    public var http: StubHTTPTransport { server.http }

    public func makeTransport(url: URL) -> any MAWebSocketTransport {
        server.makeTransport()
    }
}
