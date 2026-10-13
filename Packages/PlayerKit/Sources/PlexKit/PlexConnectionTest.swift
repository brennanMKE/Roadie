import Foundation
import os

private let log = Logger(subsystem: "com.brennanmke.SkinAmp", category: "PlexConnectionTest")

/// What a successful connection test learned. Holds no token.
public struct PlexConnection: Hashable, Sendable {
    public var baseURL: URL
    public var identity: PlexIdentity
    /// Non-empty by construction.
    public var musicSections: [PlexLibrarySection]

    public init(baseURL: URL, identity: PlexIdentity, musicSections: [PlexLibrarySection]) {
        self.baseURL = baseURL
        self.identity = identity
        self.musicSections = musicSections
    }
}

public enum PlexConnectionFailure: Error, Hashable, Sendable, LocalizedError {
    /// The address would not normalize.
    case invalidAddress
    /// Step 1 failed for any reason.
    case unreachable(PlexError)
    /// Step 2: 401 or 403.
    case unauthorized
    /// Step 3: no section of type "artist".
    case noMusicLibrary
    /// The task was cancelled (an edit, Cancel, or Settings closed). The UI shows nothing for it.
    case cancelled

    /// The user-facing text (docs/plex-music-library.md). The one place these strings live.
    public var message: String {
        switch self {
        case .invalidAddress: "The server address is not valid."
        case .unreachable: "Can't reach the server. Check the address, and whether you're on the home network or Tailscale."
        case .unauthorized: "Signed in, but this account can't access this server."
        case .noMusicLibrary: "This server has no music library."
        case .cancelled: "The connection test was cancelled."
        }
    }

    public var errorDescription: String? { message }

    /// The client error behind `.unreachable`, for logs and a disclosure in Settings.
    public var underlying: PlexError? {
        if case .unreachable(let error) = self { return error }
        return nil
    }

    fileprivate var caseName: String {
        switch self {
        case .invalidAddress: "invalidAddress"
        case .unreachable: "unreachable"
        case .unauthorized: "unauthorized"
        case .noMusicLibrary: "noMusicLibrary"
        case .cancelled: "cancelled"
        }
    }
}

/// The three-step connection test: identity, sections with the token, a music section exists.
public struct PlexConnectionTest: Sendable {
    public var clientIdentifier: String
    public var product: String
    public var version: String
    public var timeout: TimeInterval
    public var session: URLSession

    public init(
        clientIdentifier: String, product: String = "SkinAmp", version: String = "0.1.0",
        timeout: TimeInterval = 15, session: URLSession = .shared
    ) {
        self.clientIdentifier = clientIdentifier
        self.product = product
        self.version = version
        self.timeout = timeout
        self.session = session
    }

    /// Normalizes `address`, then runs the three checks. No request is sent for an invalid address.
    public func run(address: String, token: PlexToken) async throws(PlexConnectionFailure) -> PlexConnection {
        let baseURL: URL
        do {
            baseURL = try PlexAddress.normalize(address)
        } catch {
            log.info("connection test: invalidAddress")
            throw .invalidAddress
        }
        return try await run(baseURL: baseURL, token: token)
    }

    /// The three checks against an already-normalized base URL.
    public func run(baseURL: URL, token: PlexToken) async throws(PlexConnectionFailure) -> PlexConnection {
        let host = baseURL.host ?? ""
        do {
            let connection = try await check(baseURL: baseURL, token: token)
            log.info("connection test: ok host \(host, privacy: .public)")
            return connection
        } catch {
            log.info("connection test: \(error.caseName, privacy: .public) host \(host, privacy: .public)")
            throw error
        }
    }

    private func client(_ baseURL: URL, token: PlexToken?) -> PlexClient {
        PlexClient(
            baseURL: baseURL, token: token, clientIdentifier: clientIdentifier,
            product: product, version: version, timeout: timeout, session: session)
    }

    private func check(baseURL: URL, token: PlexToken) async throws(PlexConnectionFailure) -> PlexConnection {
        // 1. Identity, deliberately without the token: tells a wrong address from a wrong token.
        let identity: PlexIdentity
        do {
            try Task.checkCancellation()
            identity = try await client(baseURL, token: nil).identity()
        } catch {
            throw Self.failure(error)
        }
        // 2. Sections with the token.
        let sections: [PlexLibrarySection]
        do {
            try Task.checkCancellation()
            sections = try await client(baseURL, token: token).librarySections()
        } catch let error as PlexError {
            switch error {
            case .unauthorized, .httpStatus(403): throw .unauthorized
            default: throw Self.failure(error)
            }
        } catch {
            throw Self.failure(error)
        }
        // 3. A music section exists.
        let music = sections.filter(\.isMusic)
        guard !music.isEmpty else { throw .noMusicLibrary }
        return PlexConnection(baseURL: baseURL, identity: identity, musicSections: music)
    }

    private static func failure(_ error: any Error) -> PlexConnectionFailure {
        if error is CancellationError { return .cancelled }
        guard let plex = error as? PlexError else { return .unreachable(.transport(.unknown)) }
        if case .transport(.cancelled) = plex { return .cancelled }
        return .unreachable(plex)
    }
}
