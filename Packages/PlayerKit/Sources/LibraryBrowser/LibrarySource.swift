import MusicBackendKit

/// One selectable library source: the backend plus what Settings shows about it.
public struct LibrarySource: Identifiable, Sendable {
    /// `backend.sourceID`: "musicAssistant", "folder".
    public var id: String
    public var displayName: String
    public var backend: any MusicBackend
    /// Whether the user has set this source up, from UserDefaults only (never the Keychain or the network).
    /// Settings shows "not set up" from it; the fallback (#0067) reads it.
    public var isConfigured: @Sendable () -> Bool

    /// Answers "usable right now?" cheaply. Default: `backend.connect()` mapped by `SourceProbes.checking`.
    /// The folder passes a stat; Music Assistant will pass its handshake. Never called at launch.
    public var probe: SourceProbe

    public init(
        backend: any MusicBackend, isConfigured: @escaping @Sendable () -> Bool, probe: SourceProbe? = nil
    ) {
        id = backend.sourceID
        displayName = backend.displayName
        self.backend = backend
        self.isConfigured = isConfigured
        self.probe = probe ?? SourceProbes.checking { try await backend.connect() }
    }
}

/// "Is this source usable right now?" without side effects beyond what the backend's own check has.
public typealias SourceProbe = @Sendable () async -> SourceProbeOutcome

public enum SourceProbes {
    /// `.reachable` when `check` returns; `.notConfigured`/`.unreachable` from the thrown `MusicBackendError`
    /// (any other error is `.unreachable` with its description). Never throws: the driver detects cancellation.
    public static func checking(_ check: @escaping @Sendable () async throws -> Void) -> SourceProbe {
        {
            do {
                try await check()
                return .reachable
            } catch let error as MusicBackendError {
                if case .notConfigured(let message) = error { return .notConfigured(message) }
                return .unreachable(error.errorDescription ?? "The music source can't be reached.")
            } catch {
                return .unreachable(error.localizedDescription)
            }
        }
    }
}

/// Pure: which source a stored choice resolves to.
public enum LibrarySourceSelection {
    /// `stored` when it names one of `available`; else `fallback` when it does; else the first available id.
    public static func resolve(stored: String?, available: [LibrarySource], fallback: String) -> String {
        precondition(!available.isEmpty, "at least one library source is required")
        if let stored, available.contains(where: { $0.id == stored }) { return stored }
        if available.contains(where: { $0.id == fallback }) { return fallback }
        return available[0].id
    }
}
