import Foundation

/// Why Test Connection failed. No case holds an address, a host, a server id or a token, so a message built
/// from one cannot leak them.
public enum MusicAssistantConnectionFailure: Hashable, Sendable {
    case invalidAddress(MusicAssistantAddressInput.Problem)
    /// From `MusicAssistantError.errorDescription`, which names no host.
    case unreachable(String)
    /// `.transport(.appTransportSecurityRequiresSecureConnection)`: should not happen once the address rules hold.
    case blockedByATS
    /// A different server answered. `foundName` is the server's own name, if it gave one.
    case serverMismatch(foundName: String?)
    case needsToken(foundName: String?)
    case tokenRejected
    case schema(String)
    /// `MusicAssistantTokenStoreError` text: the status only.
    case keychain(String)

    public var message: String {
        switch self {
        case .invalidAddress(let problem): problem.message
        case .unreachable(let text): text
        case .blockedByATS: "macOS blocks this connection. Use https; plain http works only on the local network."
        case .serverMismatch(let name):
            name.map { "A different server answered (\($0)). Its token was not sent." }
                ?? "A different server answered. Its token was not sent."
        case .needsToken(let name):
            name.map { "Found \($0). Enter a token." } ?? "Found a Music Assistant server. Enter a token."
        case .tokenRejected: "Music Assistant rejected this token."
        case .schema(let text): text
        case .keychain(let text): text
        }
    }
}

/// The steps of Test Connection, apart from the model so #0075's "Use current network" does not need it.
/// Reads `/info` without a token, compares the server id, and only then lets a token leave the process.
public struct MusicAssistantConnectionTest: Sendable {
    public enum Outcome: Sendable, Hashable {
        case connected(MAServerInfo)
        case failed(MusicAssistantConnectionFailure)
    }

    var http: any MAHTTPTransport
    var transports: any MAWebSocketTransportFactory
    var clock: any Clock<Duration>

    public init(
        http: any MAHTTPTransport = URLSessionHTTPTransport(),
        transports: any MAWebSocketTransportFactory = URLSessionWebSocketTransportFactory(),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.http = http
        self.transports = transports
        self.clock = clock
    }

    /// nil when the task was cancelled. `typedToken` wins over `loadStored`, which is called only after the
    /// identity check passed.
    public func run(
        baseURL: URL, knownServerID: String?, typedToken: MusicAssistantToken?,
        loadStored: @Sendable () throws -> MusicAssistantToken?
    ) async -> Outcome? {
        let info: MAServerInfo
        do {
            info = try await MusicAssistantClient.serverInfo(at: baseURL, http: http, timeout: .seconds(5))
        } catch is CancellationError {
            return nil
        } catch {
            return .failed(Self.failure(for: error, found: nil))
        }
        if Task.isCancelled { return nil }
        if info.schemaVersion < MusicAssistantClient.minimumSchemaVersion
            || info.minSupportedSchemaVersion > MusicAssistantClient.supportedSchemaVersion
        {
            let error = MusicAssistantError.schemaUnsupported(server: info.schemaVersion, minSupported: info.minSupportedSchemaVersion)
            return .failed(.schema(error.errorDescription ?? "This Music Assistant server is not supported."))
        }
        if let knownServerID, knownServerID != info.serverID {
            return .failed(.serverMismatch(foundName: info.name))
        }
        let token: MusicAssistantToken
        if let typedToken {
            token = typedToken
        } else {
            do {
                guard let stored = try loadStored() else { return .failed(.needsToken(foundName: info.name)) }
                token = stored
            } catch {
                return .failed(.keychain(Self.text(error)))
            }
        }
        if Task.isCancelled { return nil }
        let client = MusicAssistantClient(baseURL: baseURL, transports: transports, http: http, clock: clock)
        do {
            _ = try await client.connect(token: token, expectedServerID: info.serverID)
        } catch is CancellationError {
            await client.disconnect()
            return nil
        } catch {
            await client.disconnect()
            return .failed(Self.failure(for: error, found: info.name))
        }
        await client.disconnect()
        return .connected(info)
    }

    static func failure(for error: any Error, found: String?) -> MusicAssistantConnectionFailure {
        guard let failure = error as? MusicAssistantError else { return .unreachable("Can't reach the Music Assistant server.") }
        let text = failure.errorDescription ?? "Can't reach the Music Assistant server."
        switch failure {
        case .transport(.appTransportSecurityRequiresSecureConnection): return .blockedByATS
        case .tokenRejected, .unauthenticated: return .tokenRejected
        case .serverMismatch: return .serverMismatch(foundName: found)
        case .schemaUnsupported: return .schema(text)
        default: return .unreachable(text)
        }
    }

    private static func text(_ error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? "The Keychain could not be read."
    }
}
