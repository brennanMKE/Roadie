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
    /// #0066 adds `.localOutput`.
    public nonisolated let capabilities: BackendCapabilities = [.search, .playlists, .artwork, .remoteOutputs]

    private let mode: Mode
    private let serverProvider: ServerProvider
    private let tokenProvider: ServerTokenProvider
    private let transports: any MAWebSocketTransportFactory
    private let http: any MAHTTPTransport
    private let clock: any Clock<Duration>
    private let policy: MANowPlayingPolicy
    private let log = Logger(subsystem: "com.brennanmke.SkinAmp", category: "MusicAssistantBackend")

    /// The now-playing watchers subscribe to its events and states.
    public private(set) var client: MusicAssistantClient?
    private var connectedBaseURL: URL?
    private var connectedConfiguration: MusicAssistantServerConfiguration?
    private var counts: [String: Int] = [:]
    /// Players by id, from `outputs()`, `players/get` and the watchers: commands never list every player.
    private var players: [String: MAPlayer] = [:]

    private struct Watcher {
        var output: OutputDevice.ID
        var continuation: AsyncStream<NowPlaying>.Continuation
        var task: Task<Void, Never>?
    }

    /// One per `nowPlaying(on:)` subscriber.
    private var watchers: [UUID: Watcher] = [:]

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
        transports: any MAWebSocketTransportFactory = URLSessionWebSocketTransportFactory(),
        http: any MAHTTPTransport = URLSessionHTTPTransport(), clock: any Clock<Duration> = ContinuousClock(),
        policy: MANowPlayingPolicy = .standard
    ) {
        mode = .server
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
            throw MusicBackendError.notConfigured(
                mode == .server
                    ? "Add a Music Assistant server under Settings \u{203A} Music Assistant."
                    : "Add a Music Assistant server under Settings \u{203A} Library.")
        }
        if mode == .server, configuration.address.serverID == nil {
            throw MusicBackendError.notConfigured(
                "Test the connection to \(configuration.name) under Settings \u{203A} Music Assistant.")
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
            stopWatchers()
            await old.disconnect()
            client = nil
            connectedBaseURL = nil
            connectedConfiguration = nil
            counts = [:]
            players = [:]
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
        connectedConfiguration = configuration
        counts = [:]
        players = [:]
        log.info("connected")
        restartWatchers()
        if let raced, raced !== fresh { await raced.disconnect() }
    }

    public func disconnect() async {
        let old = client
        client = nil
        connectedBaseURL = nil
        connectedConfiguration = nil
        counts = [:]
        players = [:]
        stopWatchers()
        await old?.disconnect()
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
            return all.filter { $0.enabled != false && $0.hideInUI != true }.map(OutputDevice.init(ma:))
        }
    }

    /// Plays on a Music Assistant player. `queue_id == player_id` for every recorded player; a group's queue is
    /// unrecorded, so the player id is sent and MA redirects.
    public func play(_ items: [MediaID], on output: OutputDevice.ID, mode: PlayMode) async throws {
        if output == OutputDevice.thisMacID {
            // Playing Music Assistant on this Mac needs Sendspin (#0066).
            throw MusicBackendError.backend("Choose a speaker in the Library's Output menu to play from Music Assistant.")
        }
        guard !items.isEmpty else { return }
        try await guarded {
            let client = try requireClient()
            try await requireOutput(output)
            let media = items.map(\.rawValue)
            let request: MARequest
            switch mode {
            case .replace(let startIndex):
                let start = startIndex > 0 && startIndex < items.count ? items[startIndex].rawValue : nil
                request = .playMedia(queueID: output.rawValue, media: media, option: .replace, startItem: start)
            case .append:
                request = .playMedia(queueID: output.rawValue, media: media, option: .add)
            }
            _ = try await client.call(request)
        }
    }

    public func transport(_ command: TransportCommand, on output: OutputDevice.ID) async throws {
        try await guarded {
            let client = try requireClient()
            let player = try await requireOutput(output)
            let id = output.rawValue
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
                request = .volumeSet(playerID: id, level: level)
            case .setShuffle(let enabled): request = .shuffle(playerID: id, enabled: enabled)
            case .setRepeat(let on): request = .repeat(playerID: id, mode: on ? .all : .off)
            case .setBalance: throw MusicBackendError.unsupported(.remoteOutputs)
            }
            _ = try await client.call(request)
        }
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
        guard let client, watcher.output != OutputDevice.thisMacID else {
            watchers[id] = watcher
            watcher.continuation.yield(.idle(on: watcher.output))
            return
        }
        let continuation = watcher.continuation
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
