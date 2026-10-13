import Foundation
import os

private let log = Logger(subsystem: "com.brennanmke.SkinAmp", category: "PlexSignIn")

public enum PlexSignInFailure: Error, Hashable, Sendable, LocalizedError {
    /// plex.tv did not answer the PIN request, or kept failing while polling.
    case unreachable(PlexError)
    /// The opener returned false.
    case couldNotOpenBrowser
    /// The PIN was gone before it was claimed (404 while polling, or past `expiresIn`).
    case expired
    /// `Options.timeout` passed.
    case timedOut
    /// The task was cancelled; the UI shows nothing for it.
    case cancelled

    /// The user-facing text; the one place these strings live (docs/plex-music-library.md).
    public var message: String {
        switch self {
        case .unreachable: "Can't reach plex.tv. Check your internet connection and try again."
        case .couldNotOpenBrowser: "Couldn't open your browser. Paste a token instead."
        case .expired: "The sign-in code expired before it was used. Try again."
        case .timedOut: "Sign-in took too long. Try again."
        case .cancelled: "Sign-in was cancelled."
        }
    }

    public var errorDescription: String? { message }

    public var underlying: PlexError? {
        if case .unreachable(let error) = self { return error }
        return nil
    }

    var caseName: String {
        switch self {
        case .unreachable: "unreachable"
        case .couldNotOpenBrowser: "couldNotOpenBrowser"
        case .expired: "expired"
        case .timedOut: "timedOut"
        case .cancelled: "cancelled"
        }
    }
}

/// The plex.tv PIN sign-in loop: create a PIN, open the browser, poll until it is claimed.
public struct PlexPinSignIn: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public struct Options: Hashable, Sendable {
        public var pollInterval: Duration
        public var timeout: Duration
        public var maxConsecutiveFailures: Int

        public init(pollInterval: Duration = .seconds(2), timeout: Duration = .seconds(600), maxConsecutiveFailures: Int = 5) {
            self.pollInterval = pollInterval
            self.timeout = timeout
            self.maxConsecutiveFailures = maxConsecutiveFailures
        }
    }

    /// Returns false when the URL could not be opened. Called on the main actor.
    public typealias URLOpener = @MainActor @Sendable (URL) -> Bool

    public var account: PlexAccountClient
    public var options: Options

    public init(account: PlexAccountClient, options: Options = Options()) {
        self.account = account
        self.options = options
    }

    public var description: String { "PlexPinSignIn" }
    public var debugDescription: String { description }

    /// Create a PIN, open the browser, poll until the PIN is claimed. Cancel the task to stop.
    public func run(open: URLOpener) async throws(PlexSignInFailure) -> PlexToken {
        do {
            return try await loop(open: open)
        } catch {
            log.info("sign-in: \(error.caseName, privacy: .public)")
            throw error
        }
    }

    private func loop(open: URLOpener) async throws(PlexSignInFailure) -> PlexToken {
        let pin: PlexPin
        do {
            try Task.checkCancellation()
            pin = try await account.createPin()
        } catch {
            throw Self.failure(error)
        }
        log.info("pin created")

        let pinLife = Duration.seconds(pin.expiresIn ?? 1800)
        let appTimeoutIsSmaller = options.timeout <= pinLife
        let deadline = ContinuousClock.now.advanced(by: appTimeoutIsSmaller ? options.timeout : pinLife)

        guard await open(account.authURL(for: pin)) else { throw .couldNotOpenBrowser }
        log.info("auth URL opened")

        var failures = 0
        while true {
            do {
                try await Task.sleep(for: options.pollInterval)
            } catch {
                throw .cancelled
            }
            if Task.isCancelled { throw .cancelled }
            if ContinuousClock.now >= deadline { throw appTimeoutIsSmaller ? .timedOut : .expired }
            do {
                let current = try await account.pin(pin)
                failures = 0
                if let token = current.authToken { return token }
                log.debug("poll: waiting")
            } catch {
                let failure = Self.failure(error)
                switch failure {
                case .unreachable(.notFound): throw .expired
                case .unreachable:
                    failures += 1
                    if failures >= options.maxConsecutiveFailures { throw failure }
                default: throw failure
                }
            }
        }
    }

    private static func failure(_ error: any Error) -> PlexSignInFailure {
        if error is CancellationError { return .cancelled }
        guard let plex = error as? PlexError else { return .unreachable(.transport(.unknown)) }
        if case .transport(.cancelled) = plex { return .cancelled }
        return .unreachable(plex)
    }
}
