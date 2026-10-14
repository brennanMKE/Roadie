import AudioCore
import Foundation
import LocalPlayback
import MusicBackendKit
import PlexKit
import TrackCache
import os

private let log = Logger(subsystem: "com.brennanmke.SkinAmp", category: "PlexBackend")

/// What the backend needs from Settings. Not Codable (it holds the token); prints redacted.
public struct PlexBackendSettings: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var selection: PlexServerSelection
    public var token: PlexToken

    public init(selection: PlexServerSelection, token: PlexToken) {
        self.selection = selection
        self.token = token
    }

    public var description: String { "PlexBackendSettings(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

/// Plex behind `MusicBackend`. Browsing goes through `PlexClient`; playback hands `Track`s (whose
/// source is `.plex`) to the "This Mac" output, so the player still resolves them through `TrackCache`.
public actor PlexBackend: MusicBackend, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public typealias SettingsProvider = @Sendable () throws -> PlexBackendSettings?

    public nonisolated let sourceID = "plex"
    public nonisolated let displayName = "Plex"
    public nonisolated let capabilities: BackendCapabilities = [.search, .artwork, .localOutput]

    private let settings: SettingsProvider
    private let clientIdentifier: String
    private let output: LocalPlayerOutput
    private let session: URLSession
    private let connectionTimeout: TimeInterval

    private var client: PlexClient?
    private var sectionKey: String?
    public private(set) var machineIdentifier: String?
    /// Every track listed so far, so a `.track` id can be played without another request.
    private var knownTracks: [String: PlexTrack] = [:]

    public var isConnected: Bool { client != nil && sectionKey != nil }

    /// `session` is used for every request the backend makes (JSON and artwork). Ephemeral and uncached by default.
    public init(
        settings: @escaping SettingsProvider, clientIdentifier: String, output: LocalPlayerOutput,
        session: URLSession = PlexPartDownloader.makeSession(), connectionTimeout: TimeInterval = 15
    ) {
        self.settings = settings
        self.clientIdentifier = clientIdentifier
        self.output = output
        self.session = session
        self.connectionTimeout = connectionTimeout
    }

    public nonisolated var description: String { "PlexBackend" }
    public nonisolated var debugDescription: String { description }
    public nonisolated var customMirror: Mirror { Mirror(self, children: []) }

    /// The saved selection from `defaults` and the token from `tokenStore`; nil when the address is
    /// empty or there is no token. Reads the Keychain on each call, so only `connect()` triggers it.
    public static func settingsProvider(
        defaults: UserDefaults = .standard,
        tokenStore: any PlexTokenStore = KeychainPlexTokenStore()
    ) -> SettingsProvider {
        nonisolated(unsafe) let defaults = defaults
        return {
            guard let data = defaults.data(forKey: PlexSettingsModel.selectionDefaultsKey),
                  let selection = try? JSONDecoder().decode(PlexServerSelection.self, from: data),
                  !selection.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let token = try tokenStore.load() else { return nil }
            return PlexBackendSettings(selection: selection, token: token)
        }
    }

    // MARK: Connection

    public func connect() async throws {
        let loaded: PlexBackendSettings?
        do { loaded = try settings() } catch {
            reset()
            throw MusicBackendError.backend(error.localizedDescription)
        }
        guard let loaded else {
            reset()
            log.info("connect: notConfigured")
            throw MusicBackendError.notConfigured("Add the Plex server address and sign in under Settings \u{203A} Plex.")
        }
        let test = PlexConnectionTest(clientIdentifier: clientIdentifier, timeout: connectionTimeout, session: session)
        let connection: PlexConnection
        do {
            connection = try await test.run(address: loaded.selection.address, token: loaded.token)
        } catch {
            reset()
            log.info("connect: failed")
            switch error {
            case .invalidAddress, .noMusicLibrary: throw MusicBackendError.notConfigured(error.message)
            case .unauthorized: throw MusicBackendError.unauthorized
            case .unreachable: throw MusicBackendError.unreachable(error.message)
            case .cancelled: throw CancellationError()
            }
        }
        let section = loaded.selection.selectedSection(in: connection.musicSections)
            ?? (connection.musicSections.count == 1 ? connection.musicSections.first : nil)
        guard let section else {
            reset()
            throw MusicBackendError.notConfigured("Choose a music library under Settings \u{203A} Plex.")
        }
        client = PlexClient(
            baseURL: connection.baseURL, token: loaded.token, clientIdentifier: clientIdentifier,
            timeout: connectionTimeout, session: session)
        sectionKey = section.key
        machineIdentifier = connection.identity.machineIdentifier
        knownTracks = [:]
        log.info("connect: ok")
    }

    public func disconnect() async {
        reset()
    }

    private func reset() {
        client = nil
        sectionKey = nil
        machineIdentifier = nil
        knownTracks = [:]
    }

    private func connected() throws -> (client: PlexClient, section: String) {
        guard let client, let sectionKey else { throw MusicBackendError.notConnected }
        return (client, sectionKey)
    }

    private static func map(_ error: any Error) -> any Error {
        if error is CancellationError || error is MusicBackendError { return error }
        guard let plex = error as? PlexError else { return MusicBackendError.backend(error.localizedDescription) }
        switch plex {
        case .unauthorized: return MusicBackendError.unauthorized
        case .transport: return MusicBackendError.unreachable(plex.errorDescription ?? "Could not reach the server.")
        default: return MusicBackendError.backend(plex.errorDescription ?? "The server could not be read.")
        }
    }

    // MARK: Library

    public func artists(page: PageRequest) async throws -> Page<LibraryArtist> {
        let (client, section) = try connected()
        do {
            let result = try await client.artists(in: section, page: PlexPageRequest(start: page.offset, size: page.limit))
            log.debug("artists: \(result.items.count, privacy: .public)")
            return Page(plex: result, request: page, map: LibraryArtist.init(plex:))
        } catch { throw Self.map(error) }
    }

    public func albums(of artist: MediaID?, page: PageRequest) async throws -> Page<LibraryAlbum> {
        let (client, section) = try connected()
        let request = PlexPageRequest(start: page.offset, size: page.limit)
        do {
            let result: PlexPage<PlexAlbum>
            if let artist {
                guard artist.kind == .artist else { throw MusicBackendError.notFound(artist) }
                result = try await client.albums(of: artist.rawValue, page: request)
            } else {
                result = try await client.albums(in: section, page: request)
            }
            log.debug("albums: \(result.items.count, privacy: .public)")
            return Page(plex: result, request: page, map: LibraryAlbum.init(plex:))
        } catch { throw Self.map(error) }
    }

    public func tracks(of album: MediaID) async throws -> [LibraryTrack] {
        try await plexTracks(of: album).map(LibraryTrack.init(plex:))
    }

    private func plexTracks(of album: MediaID) async throws -> [PlexTrack] {
        let (client, _) = try connected()
        guard album.kind == .album else { throw MusicBackendError.notFound(album) }
        do {
            let tracks = try await client.allItems { try await client.tracks(of: album.rawValue, page: $0) }
            for track in tracks { knownTracks[track.ratingKey] = track }
            log.debug("album tracks: \(tracks.count, privacy: .public)")
            return tracks
        } catch { throw Self.map(error) }
    }

    public func playlists(page: PageRequest) async throws -> Page<LibraryPlaylist> {
        throw MusicBackendError.unsupported(.playlists)
    }

    public func tracks(ofPlaylist playlist: MediaID) async throws -> [LibraryTrack] {
        throw MusicBackendError.unsupported(.playlists)
    }

    private enum SearchPart: Sendable {
        case artists([PlexArtist])
        case albums([PlexAlbum])
        case tracks([PlexTrack])
    }

    public func search(_ query: String, limit: Int) async throws -> SearchResults {
        let title = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .empty }
        let (client, section) = try connected()
        let page = PlexPageRequest(start: 0, size: limit)
        var artists: [PlexArtist] = [], albums: [PlexAlbum] = [], tracks: [PlexTrack] = []
        do {
            try await withThrowingTaskGroup(of: SearchPart.self) { group in
                group.addTask { .artists(try await client.searchArtists(in: section, title: title, page: page).items) }
                group.addTask { .albums(try await client.searchAlbums(in: section, title: title, page: page).items) }
                group.addTask { .tracks(try await client.searchTracks(in: section, title: title, page: page).items) }
                for try await part in group {
                    switch part {
                    case .artists(let items): artists = items
                    case .albums(let items): albums = items
                    case .tracks(let items): tracks = items
                    }
                }
            }
        } catch { throw Self.map(error) }
        for track in tracks { knownTracks[track.ratingKey] = track }
        return SearchResults(
            artists: artists.map(LibraryArtist.init(plex:)), albums: albums.map(LibraryAlbum.init(plex:)),
            tracks: tracks.map(LibraryTrack.init(plex:)))
    }

    public func artwork(_ ref: ArtworkRef, maxPixels: Int) async throws -> Data {
        let (client, _) = try connected()
        var request = client.request(path: "/photo/:/transcode", query: [
            URLQueryItem(name: "url", value: ref.rawValue),
            URLQueryItem(name: "width", value: String(maxPixels)),
            URLQueryItem(name: "height", value: String(maxPixels)),
            URLQueryItem(name: "minSize", value: "1"),
            URLQueryItem(name: "upscale", value: "1"),
        ])
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MusicBackendError.backend("The server did not answer.")
            }
            switch http.statusCode {
            case 200..<300: return data
            case 401: throw MusicBackendError.unauthorized
            // The item has no image on the server; callers show a placeholder and need not ask again.
            case 404: throw MusicBackendError.unsupported(.artwork)
            default: throw MusicBackendError.backend("The server answered with status \(http.statusCode).")
            }
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw MusicBackendError.unreachable(PlexError.transport(error.code).errorDescription ?? "Could not reach the server.")
        }
    }

    // MARK: Playback

    public func outputs() async throws -> [OutputDevice] {
        [LocalPlayerOutput.device]
    }

    public func play(_ items: [MediaID], on output: OutputDevice.ID, mode: PlayMode) async throws {
        guard output == OutputDevice.thisMacID else { throw MusicBackendError.unknownOutput(output) }
        _ = try connected()
        guard let machine = machineIdentifier else { throw MusicBackendError.notConnected }
        var expanded: [PlexTrack] = []
        for item in items {
            switch item.kind {
            case .track:
                guard let track = knownTracks[item.rawValue] else { throw MusicBackendError.notFound(item) }
                expanded.append(track)
            case .album:
                expanded.append(contentsOf: try await plexTracks(of: item))
            case .playlist:
                throw MusicBackendError.unsupported(.playlists)
            case .artist:
                throw MusicBackendError.notFound(item)
            }
        }
        var queue: [LocalQueueItem] = []
        for plex in expanded {
            do {
                queue.append(LocalQueueItem(
                    track: try Track(plexTrack: plex, machineIdentifier: machine), id: MediaID(.track, plex.ratingKey)))
            } catch {
                log.info("skipped a track with no file on the server")
            }
        }
        guard !queue.isEmpty else {
            throw MusicBackendError.backend("None of these tracks has a file on the Plex server.")
        }
        await self.output.play(queue, mode: mode)
    }

    public func transport(_ command: TransportCommand, on output: OutputDevice.ID) async throws {
        guard output == OutputDevice.thisMacID else { throw MusicBackendError.unknownOutput(output) }
        await self.output.perform(command)
    }

    public func nowPlaying(on output: OutputDevice.ID) async -> AsyncStream<NowPlaying> {
        guard output == OutputDevice.thisMacID else {
            return AsyncStream { $0.finish() }
        }
        return await self.output.nowPlaying()
    }
}
