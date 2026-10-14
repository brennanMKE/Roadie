import Foundation
import MusicBackendKit
import os

/// Music Assistant behind `MusicBackend`. Browsing and search work now; remote transport and now-playing are
/// #0064 (the `MARequest` builders and `client.events()` / `states()` are its seam), local playback is #0066.
public actor MusicAssistantBackend: MusicBackend, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Reads the stored address; defaults only, never the Keychain.
    public typealias AddressProvider = @Sendable () -> MusicAssistantServerAddress?
    /// Reads the token for that address (the Keychain). Called only from `connect()`.
    public typealias TokenProvider = @Sendable (MusicAssistantServerAddress) throws -> MusicAssistantToken?

    public nonisolated let sourceID = "musicAssistant"
    public nonisolated let displayName = "Music Assistant"
    /// #0064 adds `.remoteOutputs`, #0066 `.localOutput`.
    public nonisolated let capabilities: BackendCapabilities = [.search, .playlists, .artwork]

    private let addressProvider: AddressProvider
    private let tokenProvider: TokenProvider
    private let transports: any MAWebSocketTransportFactory
    private let http: any MAHTTPTransport
    private let clock: any Clock<Duration>
    private let log = Logger(subsystem: "com.brennanmke.SkinAmp", category: "MusicAssistantBackend")

    /// #0064 subscribes to events and states through it.
    public private(set) var client: MusicAssistantClient?
    private var connectedBaseURL: URL?
    private var counts: [String: Int] = [:]

    public init(
        address: @escaping AddressProvider, token: @escaping TokenProvider,
        transports: any MAWebSocketTransportFactory = URLSessionWebSocketTransportFactory(),
        http: any MAHTTPTransport = URLSessionHTTPTransport(), clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.addressProvider = address
        self.tokenProvider = token
        self.transports = transports
        self.http = http
        self.clock = clock
    }

    public var isConnected: Bool { client != nil }

    public nonisolated var description: String { "MusicAssistantBackend" }
    public nonisolated var debugDescription: String { description }
    public nonisolated var customMirror: Mirror { Mirror(self, children: []) }

    // MARK: Connection

    public func connect() async throws {
        guard let address = addressProvider() else {
            throw MusicBackendError.notConfigured("Add a Music Assistant server under Settings \u{203A} Library.")
        }
        if let client, connectedBaseURL == address.baseURL {
            switch await client.state {
            case .connected, .reconnecting: return
            default: break
            }
        }
        let token: MusicAssistantToken?
        do {
            token = try tokenProvider(address)
        } catch {
            throw MusicBackendError.backend(
                (error as? any LocalizedError)?.errorDescription ?? "The Music Assistant token could not be read.")
        }
        guard let token else {
            throw MusicBackendError.notConfigured("Enter the Music Assistant token under Settings \u{203A} Library.")
        }
        if let old = client {
            await old.disconnect()
            client = nil
            connectedBaseURL = nil
            counts = [:]
        }
        let fresh = MusicAssistantClient(baseURL: address.baseURL, transports: transports, http: http, clock: clock)
        do {
            try await fresh.connect(token: token, expectedServerID: address.serverID)
        } catch {
            throw Self.map(error)
        }
        client = fresh
        connectedBaseURL = address.baseURL
        counts = [:]
        log.info("connected")
    }

    public func disconnect() async {
        let old = client
        client = nil
        connectedBaseURL = nil
        counts = [:]
        await old?.disconnect()
    }

    /// `GET /info` and the server-id comparison. No socket, no token, no Keychain read.
    public func probe() async throws {
        guard let address = addressProvider() else {
            throw MusicBackendError.notConfigured("Add a Music Assistant server under Settings \u{203A} Library.")
        }
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
    /// are not (the Sendspin web player is `hide_in_ui`). Groups are listed like players; their semantics are #0064's.
    public func outputs() async throws -> [OutputDevice] {
        try await guarded {
            let client = try requireClient()
            let players = try await client.call(.playersAll(), as: [MAPlayer].self)
            return players.filter { $0.enabled != false && $0.hideInUI != true }.map(OutputDevice.init(ma:))
        }
    }

    public func play(_ items: [MediaID], on output: OutputDevice.ID, mode: PlayMode) async throws {
        try await requireOutput(output)
        // #0064: `MARequest.playMedia(queueID:media:option:startItem:)` with `.replace` / `.add`, `startItem` for
        // `PlayMode.replace(startIndex:)`; `queue_id == player_id` unless `activeQueue(playerID:)` says otherwise.
        throw MusicBackendError.unsupported(.remoteOutputs)
    }

    public func transport(_ command: TransportCommand, on output: OutputDevice.ID) async throws {
        try await requireOutput(output)
        // #0064: `playerCommand`, `seek(Int(seconds))`, `volumeSet(Int(volume * 100))`, `shuffle`, `repeat(.all/.off)`;
        // `.setBalance` stays `.unsupported`.
        throw MusicBackendError.unsupported(.remoteOutputs)
    }

    public func nowPlaying(on output: OutputDevice.ID) async -> AsyncStream<NowPlaying> {
        // #0064: `client.events()` / `states()` plus `queue(id:)`; elapsed time from `elapsedTime` + `elapsedTimeLastUpdated`.
        AsyncStream { $0.finish() }
    }

    private func requireOutput(_ output: OutputDevice.ID) async throws {
        let listed = try await outputs()
        guard listed.contains(where: { $0.id == output }) else { throw MusicBackendError.unknownOutput(output) }
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
