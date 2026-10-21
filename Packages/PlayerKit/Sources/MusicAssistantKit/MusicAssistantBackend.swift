import Foundation
import MusicBackendKit
import os

/// Music Assistant behind `MusicBackend`: browsing, search, and controlling MA players (#0064). Local playback
/// through Sendspin is #0066.
public actor MusicAssistantBackend: MusicBackend, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Reads the stored address; defaults only, never the Keychain.
    public typealias AddressProvider = @Sendable () -> MusicAssistantServerAddress?
    /// Reads the token for that address (the Keychain). Called only from `connect()`.
    public typealias TokenProvider = @Sendable (MusicAssistantServerAddress) throws -> MusicAssistantToken?
    /// The active server (#0063): defaults only, never the Keychain.
    public typealias ServerProvider = @Sendable () async -> MusicAssistantServerConfiguration?
    /// The token for that server (the Keychain). Called only from `connect()`, and never for an unverified server.
    public typealias ServerTokenProvider = @Sendable (MusicAssistantServerConfiguration) throws -> MusicAssistantToken?

    /// Which init built the backend: they differ in the messages and in whether an unverified server may connect.
    private enum Mode { case address, server }
    /// The id the address-based init gives its one configuration.
    private static let addressConfigurationID = UUID(uuidString: "00000000-0000-0000-0000-00000000A0DD")!

    public nonisolated let sourceID = "musicAssistant"
    public nonisolated let displayName = "Music Assistant"
    /// `.localOutput`: This Mac plays through the MA player wrapping SkinAmp's Sendspin client (#0107).
    public nonisolated let capabilities: BackendCapabilities = [
        .search, .playlists, .artwork, .remoteOutputs, .localOutput,
    ]

    public static let thisMacNotRegisteredText =
        "This Mac isn't connected to Music Assistant. Turn on Play on this Mac in Settings \u{203A} Music Assistant."
    public static let thisMacPendingText =
        "Music Assistant is still setting up this Mac as a player. Try again in a few seconds."
    public static let thisMacUnavailableText = "This Mac isn't connected to Music Assistant right now."

    private let mode: Mode
    private let serverProvider: ServerProvider
    /// A verified server is configured, so a nil from the provider means none is reachable (#0075), not "add one".
    private let hasVerifiedServer: @Sendable () -> Bool
    private let tokenProvider: ServerTokenProvider
    private let transports: any MAWebSocketTransportFactory
    /// Internal for the command probe in `MAServerCommands.swift`.
    let http: any MAHTTPTransport
    private let clock: any Clock<Duration>
    private let policy: MANowPlayingPolicy
    private let log = Logger(subsystem: "com.brennanmke.SkinAmp", category: "MusicAssistantBackend")

    /// The now-playing watchers subscribe to its events and states.
    public private(set) var client: MusicAssistantClient?
    private var connectedBaseURL: URL?
    /// The token `connect()` used, kept for the Sendspin endpoint (#0109) so the app never reads the Keychain again.
    private var connectedToken: MusicAssistantToken?
    private var connectedConfiguration: MusicAssistantServerConfiguration?
    private var counts: [String: Int] = [:]
    /// Players by id, from `outputs()`, `players/get` and the watchers: commands never list every player.
    private var players: [String: MAPlayer] = [:]
    /// SkinAmp's own Sendspin client id, set by the app while its Sendspin session runs (#0109).
    private var localClientID: String?
    /// The MA player that wraps `localClientID`, once found.
    private var localPlayerID: String?

    private struct Watcher {
        var output: OutputDevice.ID
        var continuation: AsyncStream<NowPlaying>.Continuation
        var task: Task<Void, Never>?
    }

    /// One per `nowPlaying(on:)` subscriber.
    private var watchers: [UUID: Watcher] = [:]
    /// `connectionStates()` subscribers, and the task forwarding the installed client's states to them (#0075).
    private var stateContinuations: [UUID: AsyncStream<MusicAssistantClient.ConnectionState>.Continuation] = [:]
    private var stateForward: Task<Void, Never>?
    /// `playbackActivity()` subscribers (#0121), the last snapshot, and the task following the installed client.
    private var activityContinuations: [UUID: AsyncStream<[OutputActivity]>.Continuation] = [:]
    private var lastActivity: [OutputActivity] = []
    private var activityTask: Task<Void, Never>?
    private var activityRefetch: Task<Void, Never>?
    /// The server's commands (#0137): filled by `commandProbe` after connect, cached per server identity, and
    /// trimmed when a command answers error 12. Internal for `MAServerCommands.swift`.
    var serverCommands = MAServerCommands.empty
    var commandProbe: Task<Void, Never>?
    var probedCommands: [String: MAServerCommands] = [:]

    /// One fixed address, trust on first use when it has no `serverID`. For tests: the app must use `init(server:token:...)`,
    /// which refuses to connect to a server whose identity has not been learned and verified.
    public init(
        address: @escaping AddressProvider, token: @escaping TokenProvider,
        transports: any MAWebSocketTransportFactory = URLSessionWebSocketTransportFactory(),
        http: any MAHTTPTransport = URLSessionHTTPTransport(), clock: any Clock<Duration> = ContinuousClock(),
        policy: MANowPlayingPolicy = .standard
    ) {
        mode = .address
        self.policy = policy
        hasVerifiedServer = { false }
        serverProvider = {
            address().map { MusicAssistantServerConfiguration(id: Self.addressConfigurationID, address: $0) }
        }
        tokenProvider = { try token($0.address) }
        self.transports = transports
        self.http = http
        self.clock = clock
    }

    /// The app's init (#0063): the active server from Settings. `https` and `http` addresses reach the socket as
    /// `wss` and `ws`. A server whose `server_id` has not been learned by Test Connection is not connected to.
    public init(
        server: @escaping ServerProvider, token: @escaping ServerTokenProvider,
        hasVerifiedServer: @escaping @Sendable () -> Bool = { false },
        transports: any MAWebSocketTransportFactory = URLSessionWebSocketTransportFactory(),
        http: any MAHTTPTransport = URLSessionHTTPTransport(), clock: any Clock<Duration> = ContinuousClock(),
        policy: MANowPlayingPolicy = .standard
    ) {
        mode = .server
        self.hasVerifiedServer = hasVerifiedServer
        self.policy = policy
        serverProvider = server
        tokenProvider = token
        self.transports = transports
        self.http = http
        self.clock = clock
    }

    public var isConnected: Bool { client != nil }

    public nonisolated var description: String { "MusicAssistantBackend" }
    public nonisolated var debugDescription: String { description }
    public nonisolated var customMirror: Mirror { Mirror(self, children: []) }

    // MARK: Connection

    private func requireConfiguration() async throws -> MusicAssistantServerConfiguration {
        guard let configuration = await serverProvider() else {
            if mode == .server, hasVerifiedServer() {
                throw MusicBackendError.unreachable(MusicAssistantServerRanking.noneReachableText)
            }
            throw MusicBackendError.notConfigured(
                mode == .server
                    ? "Add a Music Assistant server under Settings \u{203A} Music Assistant."
                    : "Add a Music Assistant server under Settings \u{203A} Library.")
        }
        if mode == .server, configuration.address.serverID == nil {
            throw MusicBackendError.notConfigured(
                "Test the connection to \(configuration.displayName) under Settings \u{203A} Music Assistant.")
        }
        return configuration
    }

    public func connect() async throws {
        let configuration = try await requireConfiguration()
        let address = configuration.address
        // Same id, address and server id: the live connection is the right one. Two locations that both use
        // `homeassistant.local:8095` differ by id, so a change of the active one reconnects.
        if let client, let connected = connectedConfiguration, connected.sameIdentity(as: configuration) {
            switch await client.state {
            case .connected, .reconnecting: return
            default: break
            }
        }
        let token: MusicAssistantToken?
        do {
            token = try tokenProvider(configuration)
        } catch {
            throw MusicBackendError.backend(
                (error as? any LocalizedError)?.errorDescription ?? "The Music Assistant token could not be read.")
        }
        guard let token else {
            throw MusicBackendError.notConfigured(
                mode == .server
                    ? "Enter the Music Assistant token under Settings \u{203A} Music Assistant."
                    : "Enter the Music Assistant token under Settings \u{203A} Library.")
        }
        if let old = client {
            stopForwardingStates()
            stopWatchers()
            stopActivity()
            await old.disconnect()
            client = nil
            connectedBaseURL = nil
            connectedToken = nil
            connectedConfiguration = nil
            counts = [:]
            players = [:]
            localPlayerID = nil
        }
        let fresh = MusicAssistantClient(baseURL: address.baseURL, transports: transports, http: http, clock: clock)
        do {
            try await fresh.connect(token: token, expectedServerID: address.serverID)
        } catch {
            throw Self.map(error)
        }
        // A concurrent connect() may have installed its own client while this one awaited; the later one wins
        // and the other is closed, so no connection is left running unowned.
        let raced = client
        client = fresh
        connectedBaseURL = address.baseURL
        connectedToken = token
        connectedConfiguration = configuration
        counts = [:]
        players = [:]
        localPlayerID = nil
        log.info("connected")
        forwardStates(of: fresh)
        restartWatchers()
        restartActivity()
        let info = await fresh.serverInfo
        startCommandProbe(
            base: address.baseURL,
            identity: "\(info?.serverID ?? address.baseURL.absoluteString)|\(info?.serverVersion ?? "")")
        if let raced, raced !== fresh { await raced.disconnect() }
    }

    /// Where SkinAmp's Sendspin session connects (#0109): the server the API is connected to, with its token. nil
    /// when not connected.
    public func sendspinEndpoint() -> MusicAssistantSendspinEndpoint? {
        guard client != nil, let baseURL = connectedBaseURL, let token = connectedToken else { return nil }
        return MusicAssistantSendspinEndpoint(baseURL: baseURL, token: token)
    }

    public func disconnect() async {
        stopForwardingStates()
        broadcast(.disconnected)
        let old = client
        client = nil
        connectedBaseURL = nil
        connectedToken = nil
        connectedConfiguration = nil
        counts = [:]
        players = [:]
        localPlayerID = nil
        stopWatchers()
        stopActivity()
        commandProbe?.cancel()
        commandProbe = nil
        serverCommands = .empty
        await old?.disconnect()
    }

    // MARK: Playback activity (#0121)

    /// Every visible player's playback: one snapshot per (re)connect, then one per player or queue change (debounced).
    /// `[]` while disconnected. Runs only while someone subscribes, so a backend nobody watches sends nothing extra.
    public func playbackActivity() -> AsyncStream<[OutputActivity]> {
        let (stream, continuation) = AsyncStream<[OutputActivity]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        activityContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeActivityContinuation(id) }
        }
        if client == nil {
            continuation.yield([])
        } else if activityTask == nil {
            restartActivity()
        } else {
            continuation.yield(lastActivity)
        }
        return stream
    }

    private func removeActivityContinuation(_ id: UUID) {
        activityContinuations[id] = nil
        if activityContinuations.isEmpty { stopActivity(yieldEmpty: false) }
    }

    private func restartActivity() {
        stopActivity(yieldEmpty: false)
        guard let client, !activityContinuations.isEmpty else { return }
        activityTask = Task { [weak self] in
            let events = await client.events()
            let states = await client.states()
            await self?.snapshotActivity(from: client)
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await event in events {
                        guard let self else { return }
                        await self.activityEvent(event, from: client)
                    }
                }
                group.addTask {
                    var lost = false
                    for await state in states {
                        switch state {
                        case .reconnecting: lost = true
                        case .connected where lost:
                            lost = false
                            await self?.snapshotActivity(from: client)
                        default: break
                        }
                    }
                }
                await group.waitForAll()
            }
        }
    }

    private func stopActivity(yieldEmpty: Bool = true) {
        activityTask?.cancel()
        activityTask = nil
        activityRefetch?.cancel()
        activityRefetch = nil
        guard yieldEmpty else { return }
        lastActivity = []
        for continuation in activityContinuations.values { continuation.yield([]) }
    }

    static let activityEvents: Set<String> = ["player_updated", "queue_updated", "player_added", "player_removed"]

    private func activityEvent(_ event: MAServerEvent, from source: MusicAssistantClient) {
        guard source === client, Self.activityEvents.contains(event.event), activityRefetch == nil else { return }
        let clock = clock, delay = policy.refetchDebounce
        activityRefetch = Task { [weak self] in
            do { try await clock.sleep(for: delay) } catch { return }
            await self?.debouncedActivity(from: source)
        }
    }

    private func debouncedActivity(from source: MusicAssistantClient) async {
        activityRefetch = nil
        guard !Task.isCancelled else { return }
        await snapshotActivity(from: source)
    }

    private func snapshotActivity(from source: MusicAssistantClient) async {
        do {
            async let players = source.call(.playersAll(), as: [MAPlayer].self)
            async let queues = source.call(.queuesAll(), as: [MAPlayerQueue].self)
            let (all, allQueues) = try await (players, queues)
            guard source === client, !Task.isCancelled else { return }
            for player in all { self.players[player.playerID] = player }
            let snapshot = MAPlaybackActivity.map(players: all, queues: allQueues, localClientID: localClientID)
            lastActivity = snapshot
            for continuation in activityContinuations.values { continuation.yield(snapshot) }
        } catch {
            log.debug("activity snapshot failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    /// The connection state of whichever client is installed: `.disconnected` first when none is, then every change,
    /// following a reconnect to another server (#0075 watches it for a dropped server).
    public func connectionStates() -> AsyncStream<MusicAssistantClient.ConnectionState> {
        let (stream, continuation) = AsyncStream<MusicAssistantClient.ConnectionState>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        stateContinuations[id] = continuation
        if client == nil { continuation.yield(.disconnected) }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStateContinuation(id) }
        }
        // Restarting the forward yields the installed client's current state first (others see it again: harmless).
        if let client { forwardStates(of: client) }
        return stream
    }

    private func removeStateContinuation(_ id: UUID) { stateContinuations[id] = nil }

    private func broadcast(_ state: MusicAssistantClient.ConnectionState) {
        for continuation in stateContinuations.values { continuation.yield(state) }
    }

    private func forwardStates(of client: MusicAssistantClient) {
        stateForward?.cancel()
        stateForward = Task { [weak self] in
            for await state in await client.states() {
                guard !Task.isCancelled, let self else { return }
                await self.forwarded(state, from: client)
            }
        }
    }

    /// Only the installed client's states reach subscribers.
    private func forwarded(_ state: MusicAssistantClient.ConnectionState, from source: MusicAssistantClient) {
        guard source === client else { return }
        broadcast(state)
    }

    private func stopForwardingStates() {
        stateForward?.cancel()
        stateForward = nil
    }

    /// `GET /info` and the server-id comparison. No socket, no token, no Keychain read.
    public func probe() async throws {
        let address = try await requireConfiguration().address
        let info: MAServerInfo
        do {
            info = try await MusicAssistantClient.serverInfo(at: address.baseURL, http: http)
        } catch {
            throw Self.map(error)
        }
        if let expected = address.serverID, expected != info.serverID {
            throw MusicBackendError.unreachable(MusicAssistantError.serverMismatch.errorDescription ?? "")
        }
    }

    // MARK: Library

    public func artists(page: PageRequest) async throws -> Page<LibraryArtist> {
        try await guarded {
            let (items, total) = try await listing(.artist, as: MAArtist.self, page: page, albumArtistsOnly: true)
            return Page.make(items: items.map(LibraryArtist.init(ma:)), request: page, total: total)
        }
    }

    public func albums(of artist: MediaID?, page: PageRequest) async throws -> Page<LibraryAlbum> {
        try await guarded {
            guard let artist else {
                let (items, total) = try await listing(.album, as: MAAlbum.self, page: page, albumArtistsOnly: false)
                return Page.make(items: items.map(LibraryAlbum.init(ma:)), request: page, total: total)
            }
            guard let uri = MAURI.parse(artist.rawValue), uri.mediaType == .artist else {
                throw MusicBackendError.notFound(artist)
            }
            let client = try requireClient()
            let all = try await client.call(
                .artistAlbums(itemID: uri.itemID, provider: uri.provider), as: [MAAlbum].self)
            let slice = Array(all.dropFirst(page.offset).prefix(page.limit))
            return Page.make(items: slice.map(LibraryAlbum.init(ma:)), request: page, total: all.count)
        }
    }

    public func tracks(of album: MediaID) async throws -> [LibraryTrack] {
        try await guarded {
            guard let uri = MAURI.parse(album.rawValue), uri.mediaType == .album else {
                throw MusicBackendError.notFound(album)
            }
            let client = try requireClient()
            let tracks = try await client.call(
                .albumTracks(itemID: uri.itemID, provider: uri.provider, inLibraryOnly: true), as: [MATrack].self)
            return tracks.enumerated().sorted { lhs, rhs in
                let l = (lhs.element.discNumber ?? 0, lhs.element.trackNumber ?? 0, lhs.offset)
                let r = (rhs.element.discNumber ?? 0, rhs.element.trackNumber ?? 0, rhs.offset)
                return l < r
            }.map { LibraryTrack(ma: $0.element) }
        }
    }

    public func playlists(page: PageRequest) async throws -> Page<LibraryPlaylist> {
        try await guarded {
            let (items, total) = try await listing(.playlist, as: MAPlaylist.self, page: page, albumArtistsOnly: false)
            return Page.make(items: items.map(LibraryPlaylist.init(ma:)), request: page, total: total)
        }
    }

    public func tracks(ofPlaylist playlist: MediaID) async throws -> [LibraryTrack] {
        try await guarded {
            guard let uri = MAURI.parse(playlist.rawValue), uri.mediaType == .playlist else {
                throw MusicBackendError.notFound(playlist)
            }
            let client = try requireClient()
            let tracks = try await client.call(
                .playlistTracks(itemID: uri.itemID, provider: uri.provider), as: [MATrack].self)
            return tracks.map(LibraryTrack.init(ma:))
        }
    }

    public func search(_ query: String, limit: Int) async throws -> SearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        return try await guarded {
            let client = try requireClient()
            let found = try await client.call(
                .search(query: trimmed, mediaTypes: [.artist, .album, .track], limit: limit), as: MASearchResults.self)
            return SearchResults(
                artists: found.artists.map(LibraryArtist.init(ma:)), albums: found.albums.map(LibraryAlbum.init(ma:)),
                tracks: found.tracks.map(LibraryTrack.init(ma:)))
        }
    }

    /// The image proxy needs no credentials, so no request here carries the token.
    public func artwork(_ ref: ArtworkRef, maxPixels: Int) async throws -> Data {
        guard client != nil, let base = connectedBaseURL else { throw MusicBackendError.notConnected }
        let size = MAImageProxy.size(for: maxPixels)
        guard let url = MAImageProxy.url(base: base, proxyID: ref.rawValue, size: size) else {
            throw MusicBackendError.backend(MusicAssistantError.invalidURL.errorDescription ?? "")
        }
        let response: MAHTTPResponse
        do {
            response = try await http.get(url, headers: [:], timeout: .seconds(15))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MusicBackendError.unreachable(MusicAssistantError.transport(.cannotConnectToHost).errorDescription ?? "")
        }
        switch response.status {
        case 200..<300: return response.body
        case 404: throw MusicBackendError.unsupported(.artwork)
        case 400: throw MusicBackendError.backend("Music Assistant refused the artwork size.")
        default: throw MusicBackendError.backend("Music Assistant could not provide the artwork.")
        }
    }

    // MARK: Outputs

    /// Enabled, visible players. Unavailable ones are listed with `isAvailable == false`; hidden and disabled ones
    /// are not (the Sendspin web player is `hide_in_ui`). Groups have `isGroup` set.
    public func outputs() async throws -> [OutputDevice] {
        try await guarded {
            let client = try requireClient()
            let all = try await client.call(.playersAll(), as: [MAPlayer].self)
            players = Dictionary(all.map { ($0.playerID, $0) }, uniquingKeysWith: { _, last in last })
            let local = localClientID
            let hostingIDs = Set(local.map { id in all.filter { $0.hosts(sendspinClientID: id) }.map(\.playerID) } ?? [])
            return all.filter { player in
                guard player.enabled != false, player.hideInUI != true else { return false }
                if let local, player.hosts(sendspinClientID: local) { return false }
                return true
            }.map { player in
                // This Mac's wrapper shows up as This Mac, so a speaker knows whether it can join it (#0118).
                let groupable = player.canGroupWith.map { ids in
                    Set(ids.map { hostingIDs.contains($0) ? OutputDevice.thisMacID : OutputDevice.ID(rawValue: $0) })
                }
                return OutputDevice(ma: player, groupable: groupable)
            }
        }
    }

    /// Plays on a Music Assistant player. `queue_id == player_id` for every recorded player; a group's queue is
    /// unrecorded, so the player id is sent and MA redirects.
    public func play(_ items: [MediaID], on output: OutputDevice.ID, mode: PlayMode) async throws {
        guard !items.isEmpty else { return }
        try await guarded {
            let client = try requireClient()
            let queueID = try await playerID(for: output)
            let media = items.map(\.rawValue)
            let request: MARequest
            switch mode {
            case .replace(let startIndex):
                let start = startIndex > 0 && startIndex < items.count ? items[startIndex].rawValue : nil
                request = .playMedia(queueID: queueID, media: media, option: .replace, startItem: start)
            case .append:
                request = .playMedia(queueID: queueID, media: media, option: .add)
            }
            _ = try await client.call(request)
        }
    }

    public func transport(_ command: TransportCommand, on output: OutputDevice.ID) async throws {
        try await guarded {
            let client = try requireClient()
            let player: MAPlayer
            if output == OutputDevice.thisMacID {
                switch command {
                case .setVolume, .setBalance:
                    // The app applies these to the local player, which reports volume through Sendspin (#0108).
                    throw MusicBackendError.unsupported(.localOutput)
                default: player = try await self.player(for: output)
                }
            } else {
                player = try await self.player(for: output)
            }
            // A synced member plays its leader's queue, so playback commands go to the leader (#0121); volume stays.
            let id: String
            switch command {
            case .setVolume, .setBalance: id = player.playerID
            default: id = player.activeGroup ?? player.syncedTo ?? player.playerID
            }
            let request: MARequest
            switch command {
            case .play: request = .playerCommand(.play, playerID: id)
            case .pause: request = .playerCommand(.pause, playerID: id)
            case .togglePlayPause: request = .playerCommand(.playPause, playerID: id)
            case .stop: request = .playerCommand(.stop, playerID: id)
            case .next: request = .playerCommand(.next, playerID: id)
            case .previous: request = .playerCommand(.previous, playerID: id)
            case .seek(let seconds):
                let position = seconds.isFinite ? max(0, Int(seconds.rounded())) : 0
                request = .seek(playerID: id, position: position)
            case .setVolume(let volume):
                let lacksVolumeSet = player.supportedFeatures.map { !$0.contains("volume_set") } ?? false
                if lacksVolumeSet || player.volumeLevel == nil {
                    throw MusicBackendError.unsupported(.remoteOutputs)
                }
                let level = volume.isFinite ? min(max(Int((volume * 100).rounded()), 0), 100) : 0
                request = .volumeSet(playerID: player.playerID, level: level)
            case .setShuffle(let enabled): request = .shuffle(playerID: id, enabled: enabled)
            case .setRepeat(let on): request = .repeat(playerID: id, mode: on ? .all : .off)
            case .setBalance: throw MusicBackendError.unsupported(.remoteOutputs)
            }
            _ = try await client.call(request)
        }
    }

    /// Moves what plays on `source` to `target` (`player_queues/transfer`); MA stops the source itself, so no extra
    /// `stop` is sent (it could hit the target when both sit in one group).
    public func transfer(from source: OutputDevice.ID, to target: OutputDevice.ID, autoPlay: Bool) async throws {
        guard source != target else { return }
        try await guarded {
            let client = try requireClient()
            let sourceQueue = try await queueID(for: source, client: client)
            let targetQueue = try await playerID(for: target)
            guard sourceQueue != targetQueue else { return }
            _ = try await client.call(
                .transferQueue(sourceQueueID: sourceQueue, targetQueueID: targetQueue, autoPlay: autoPlay))
        }
    }

    /// Syncs `adding` to `leader` and unsyncs `removing` (`players/cmd/set_members`, #0118). This Mac stands for its
    /// Music Assistant wrapper, so with Sendspin off it throws `thisMacNotRegisteredText`.
    public func setGroupMembers(
        of leader: OutputDevice.ID, adding: [OutputDevice.ID], removing: [OutputDevice.ID]
    ) async throws {
        guard !adding.isEmpty || !removing.isEmpty else { return }
        try await guarded {
            let client = try requireClient()
            let target = try await playerID(for: leader)
            var add: [String] = []
            for id in adding { add.append(try await playerID(for: id)) }
            var remove: [String] = []
            for id in removing { remove.append(try await playerID(for: id)) }
            _ = try await client.call(.setMembers(target: target, add: add, remove: remove))
            // Their sync state changed: the next lookup refetches.
            for id in [target] + add + remove { players[id] = nil }
        }
    }

    /// The queue that plays on `output` now: its active queue (a speaker synced into a group plays the group's),
    /// else its own.
    private func queueID(for output: OutputDevice.ID, client: MusicAssistantClient) async throws -> String {
        let playerID = try await playerID(for: output)
        let json = try await client.call(.activeQueue(playerID: playerID))
        if !json.isNull, let queue = try? json.decode(as: MAPlayerQueue.self) { return queue.queueID }
        return playerID
    }

    /// This Mac → the player MA wraps this client in; any other id → that recorded player (else `unknownOutput`).
    private func player(for output: OutputDevice.ID) async throws -> MAPlayer {
        output == OutputDevice.thisMacID ? try await resolveLocalPlayer() : try await requireOutput(output)
    }

    /// The Music Assistant player id behind `output`; `play`, `transport` and `transfer` share it.
    func playerID(for output: OutputDevice.ID) async throws -> String {
        try await player(for: output).playerID
    }

    /// The current snapshot at once, then one per change: events applied when they decode, refetches and polls as
    /// the safety net (#0076). Idle while not connected; `connect()` and `disconnect()` restart or idle the stream
    /// without ending it.
    public func nowPlaying(on output: OutputDevice.ID) async -> AsyncStream<NowPlaying> {
        let (stream, continuation) = AsyncStream<NowPlaying>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        watchers[id] = Watcher(output: output, continuation: continuation, task: nil)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeWatcher(id) }
        }
        startWatcher(id)
        return stream
    }

    private func removeWatcher(_ id: UUID) {
        watchers.removeValue(forKey: id)?.task?.cancel()
    }

    private func startWatcher(_ id: UUID) {
        guard var watcher = watchers[id] else { return }
        watcher.task?.cancel()
        watcher.task = nil
        let isThisMac = watcher.output == OutputDevice.thisMacID
        guard let client, !isThisMac || localClientID != nil else {
            watchers[id] = watcher
            watcher.continuation.yield(.idle(on: watcher.output))
            return
        }
        let continuation = watcher.continuation
        if isThisMac {
            let clock = clock, policy = policy
            watcher.task = Task { [weak self] in
                guard let playerID = await self?.awaitLocalPlayerID(yieldingIdleTo: continuation) else { return }
                let watch = MANowPlayingWatch(
                    client: client, output: OutputDevice.ID(rawValue: playerID), clock: clock, policy: policy,
                    yield: { snapshot in
                        var snapshot = snapshot
                        snapshot.output = OutputDevice.thisMacID
                        continuation.yield(snapshot)
                    },
                    cachePlayer: { [weak self] in await self?.cache($0) })
                await watch.run()
            }
            watchers[id] = watcher
            return
        }
        let watch = MANowPlayingWatch(
            client: client, output: watcher.output, clock: clock, policy: policy,
            yield: { continuation.yield($0) },
            cachePlayer: { [weak self] in await self?.cache($0) })
        watcher.task = Task { await watch.run() }
        watchers[id] = watcher
        log.debug("now playing watch started (\(self.watchers.count, privacy: .public) active)")
    }

    private func restartWatchers() {
        for id in watchers.keys { startWatcher(id) }
    }

    /// Ends every watch and shows idle; the streams stay open for the next `connect()`.
    private func stopWatchers() {
        for (id, var watcher) in watchers {
            watcher.task?.cancel()
            watcher.task = nil
            watchers[id] = watcher
            watcher.continuation.yield(.idle(on: watcher.output))
        }
    }

    /// The local player's id, retrying every 2 s for up to 30 s while MA is still wrapping the client. Idle meanwhile.
    private func awaitLocalPlayerID(yieldingIdleTo continuation: AsyncStream<NowPlaying>.Continuation) async -> String? {
        var waited: Duration = .zero
        var yieldedIdle = false
        while !Task.isCancelled {
            do {
                return try await resolveLocalPlayer().playerID
            } catch MusicBackendError.backend(let message) where message == Self.thisMacPendingText {
                if waited >= .seconds(30) { break }
            } catch {
                break
            }
            if !yieldedIdle {
                continuation.yield(.idle(on: OutputDevice.thisMacID))
                yieldedIdle = true
            }
            do { try await clock.sleep(for: .seconds(2)) } catch { return nil }
            waited += .seconds(2)
        }
        if !yieldedIdle, !Task.isCancelled { continuation.yield(.idle(on: OutputDevice.thisMacID)) }
        return nil
    }

    // MARK: This Mac (#0107)

    /// Called by the app when its Sendspin session starts (the client id) or stops (nil). Restarts This Mac watchers.
    public func setLocalSendspinClientID(_ id: String?) {
        guard id != localClientID else { return }
        localClientID = id
        localPlayerID = nil
        for (watcherID, watcher) in watchers where watcher.output == OutputDevice.thisMacID { startWatcher(watcherID) }
    }

    /// The MA player hosting SkinAmp's Sendspin client: the cache first, else `players/all`.
    private func resolveLocalPlayer() async throws -> MAPlayer {
        guard let clientID = localClientID else { throw MusicBackendError.backend(Self.thisMacNotRegisteredText) }
        if let cachedID = localPlayerID, let cached = players[cachedID], cached.available {
            return cached
        }
        var match = Self.localPlayer(in: Array(players.values), clientID: clientID)
        if match?.available != true {
            let client = try requireClient()
            let all = try await client.call(.playersAll(), as: [MAPlayer].self)
            guard clientID == localClientID else { throw CancellationError() }
            for player in all { players[player.playerID] = player }
            match = Self.localPlayer(in: all, clientID: clientID)
        }
        guard let match else { throw MusicBackendError.backend(Self.thisMacPendingText) }
        guard match.available else { throw MusicBackendError.backend(Self.thisMacUnavailableText) }
        localPlayerID = match.playerID
        return match
    }

    private static func localPlayer(in players: [MAPlayer], clientID: String) -> MAPlayer? {
        let hosting = players.filter { $0.hosts(sendspinClientID: clientID) }
        return hosting.first(where: \.available) ?? hosting.first
    }

    private func cache(_ player: MAPlayer) {
        guard client != nil else { return }
        players[player.playerID] = player
    }

    /// The cached player, else `players/get` (a null result is an unknown player).
    @discardableResult
    private func requireOutput(_ output: OutputDevice.ID) async throws -> MAPlayer {
        if let cached = players[output.rawValue] { return cached }
        let client = try requireClient()
        let json = try await client.call(.player(id: output.rawValue))
        guard !json.isNull else { throw MusicBackendError.unknownOutput(output) }
        let player: MAPlayer
        do {
            player = try json.decode(as: MAPlayer.self)
        } catch {
            throw MusicAssistantError.decoding(command: "players/get", detail: MusicAssistantClient.describe(error))
        }
        players[player.playerID] = player
        return player
    }

    // MARK: Helpers

    private func requireClient() throws -> MusicAssistantClient {
        guard let client else { throw MusicBackendError.notConnected }
        return client
    }

    private func guarded<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw Self.map(error)
        }
    }

    /// One listing request plus, with the first page, a count built from the same filters.
    private func listing<T: Decodable & Sendable>(
        _ kind: MAMediaKind, as type: T.Type, page: PageRequest, albumArtistsOnly: Bool
    ) async throws -> (items: [T], total: Int?) {
        let client = try requireClient()
        let request = MARequest.libraryItems(
            kind, limit: page.limit, offset: page.offset, orderBy: "sort_name", albumArtistsOnly: albumArtistsOnly)
        let key = kind.rawValue
        if page.offset == 0 || counts[key] == nil {
            async let items = client.call(request, as: [T].self)
            async let total = Self.count(client, kind, albumArtistsOnly: albumArtistsOnly)
            let loaded = try await items
            let count = await total
            if let count { counts[key] = count }
            return (loaded, count)
        }
        return (try await client.call(request, as: [T].self), counts[key])
    }

    private static func count(_ client: MusicAssistantClient, _ kind: MAMediaKind, albumArtistsOnly: Bool) async -> Int? {
        try? await client.call(.count(kind, albumArtistsOnly: albumArtistsOnly), as: Int.self)
    }

    /// Client errors to backend errors. The address does not lead to the configured server for a mismatch or an
    /// unsupported schema, so those read as unreachable and the token was never sent.
    public static func map(_ error: any Error) -> any Error {
        if error is CancellationError || error is MusicBackendError { return error }
        guard let failure = error as? MusicAssistantError else {
            return MusicBackendError.backend("The Music Assistant request failed.")
        }
        let message = failure.errorDescription ?? "The Music Assistant request failed."
        switch failure {
        case .tokenRejected, .unauthenticated: return MusicBackendError.unauthorized
        case .transport, .handshakeFailed, .timeout, .disconnected, .serverMismatch, .schemaUnsupported:
            return MusicBackendError.unreachable(message)
        case .notConnected: return MusicBackendError.notConnected
        case .server, .decoding, .invalidURL: return MusicBackendError.backend(message)
        }
    }
}

/// The Music Assistant server SkinAmp's Sendspin session targets (#0109).
public struct MusicAssistantSendspinEndpoint: Sendable, Equatable, CustomStringConvertible {
    public let baseURL: URL
    public let token: MusicAssistantToken

    public init(baseURL: URL, token: MusicAssistantToken) {
        self.baseURL = baseURL
        self.token = token
    }

    public var description: String { "MusicAssistantSendspinEndpoint(token: redacted)" }
}
