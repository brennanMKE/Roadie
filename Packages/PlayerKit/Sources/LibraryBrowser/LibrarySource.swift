import MusicBackendKit

/// One selectable library source: the backend plus what Settings shows about it.
public struct LibrarySource: Identifiable, Sendable {
    /// `backend.sourceID`: "plex", "folder", "musicAssistant".
    public var id: String
    public var displayName: String
    public var backend: any MusicBackend
    /// Whether the user has set this source up, from UserDefaults only (never the Keychain or the network).
    /// Settings shows "not set up" from it; the fallback (#0067) reads it.
    public var isConfigured: @Sendable () -> Bool

    public init(backend: any MusicBackend, isConfigured: @escaping @Sendable () -> Bool) {
        id = backend.sourceID
        displayName = backend.displayName
        self.backend = backend
        self.isConfigured = isConfigured
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
