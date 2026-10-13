import Foundation

public enum PlexClientIdentifier {
    public static let defaultsKey = "PlexClientIdentifier"

    /// Returns the stored identifier, creating and storing a UUID string on first use.
    /// Not a secret, so UserDefaults is the right place.
    public static func stored(in defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: defaultsKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: defaultsKey)
        return fresh
    }
}
