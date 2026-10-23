import Foundation
import LibraryBrowser
import Security
import os

/// One-time removal of what the removed Plex source (#0074) left on this Mac: its Keychain item, its defaults
/// and the track cache. Runs first in `PlayerModel.init`; idempotent through `versionKey`; logs counts and
/// statuses only. In the Tart guest nothing exists, so every step is a no-op and nothing can prompt.
@MainActor
enum LegacyDataCleanup {
    static let versionKey = "legacyCleanupVersion"
    static let version = 1
    static let defaultsKeys = ["PlexServerSelection", "PlexClientIdentifier", "TrackCacheLimitBytes"]
    static let keychainService = "com.brennanmke.SkinAmp.plex"
    static let removedSourceID = "plex"

    private static let log = Logger(subsystem: "co.sstools.roadie", category: "LegacyCleanup")

    static func run(defaults: UserDefaults = .standard, bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        guard defaults.integer(forKey: versionKey) < version else { return }

        // Defaults: Plex's keys, and a stored Library choice of the removed source (the controller then picks
        // Music Assistant; a user who chose the folder keeps it).
        var removedDefaults = 0
        for key in defaultsKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
            removedDefaults += 1
        }
        if defaults.string(forKey: LibrarySourceController.defaultsKey) == removedSourceID {
            defaults.removeObject(forKey: LibrarySourceController.defaultsKey)
            removedDefaults += 1
        }

        // Keychain: an attribute-only query (no data, so it never prompts or decrypts), then delete. The token is never read.
        let keychain = removeKeychainItems()

        // The track cache directory, off the main actor. Not retried: macOS purges Caches anyway.
        let cacheDir = URL.cachesDirectory
            .appending(path: bundleIdentifier ?? "co.sstools.roadie", directoryHint: .isDirectory)
            .appending(path: "Tracks", directoryHint: .isDirectory)
        let cacheExists = FileManager.default.fileExists(atPath: cacheDir.path)
        if cacheExists {
            Task.detached(priority: .utility) {
                do {
                    try FileManager.default.removeItem(at: cacheDir)
                    Logger(subsystem: "co.sstools.roadie", category: "LegacyCleanup").info("cache directory removed")
                } catch {
                    Logger(subsystem: "co.sstools.roadie", category: "LegacyCleanup")
                        .error("could not remove the cache directory: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        defaults.set(version, forKey: versionKey)
        log.info(
            "legacy cleanup: removed \(removedDefaults) default(s); keychain \(keychain, privacy: .public); cache dir \(cacheExists ? "removing" : "absent", privacy: .public)")
    }

    /// "absent", "removed", or the failing status. Never asks for the item's data.
    private static func removeKeychainItems() -> String {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnAttributes: true,
        ]
        var result: CFTypeRef?
        let found = SecItemCopyMatching(query as CFDictionary, &result)
        switch found {
        case errSecItemNotFound:
            return "absent"
        case errSecSuccess:
            let status = SecItemDelete(
                [kSecClass: kSecClassGenericPassword, kSecAttrService: keychainService] as CFDictionary)
            if status == errSecSuccess || status == errSecItemNotFound { return "removed" }
            log.error("keychain delete failed: \(status)")
            return "delete failed \(status)"
        default:
            log.error("keychain lookup failed: \(found)")
            return "lookup failed \(found)"
        }
    }
}
