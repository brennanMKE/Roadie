import AppKit
import Foundation
import os
import Security

/// The result of copying one Keychain item.
public enum TokenCopyStatus: Equatable, Sendable {
    case copied
    /// The user denied the access prompt, or cancelled it.
    case denied
    /// Any other Keychain failure, as its `OSStatus`.
    case failed(Int32)
}

/// Copies Music Assistant token items between Keychain services. The tests inject a fake; `KeychainTokenItemCopier`
/// is the real one.
public protocol TokenItemCopier {
    /// The accounts stored under `service`. Attributes only, so this never prompts.
    func accounts(service: String) -> [String]
    /// Reads `account`'s data under `source` and adds it under `destination` with `label`. Never logs the data.
    func copy(account: String, from source: String, to destination: String, label: String) -> TokenCopyStatus
}

/// One-time migration of SkinAmp's settings, Application Support files and Music Assistant tokens into Roadie
/// (docs/design/release.md §2.2). Copies, never moves.
public struct LegacyAppMigration {
    public static let legacyBundleID = "com.brennanmke.SkinAmp"
    public static let markerKey = "migration.fromSkinAmp"
    public static let markerVersion = 1
    public static let tokenLabel = "Roadie Music Assistant token"

    public enum Outcome: Equatable, Sendable {
        /// The marker was already set; nothing ran.
        case alreadyMigrated
        /// SkinAmp is running; nothing ran and the marker is not set, so the next launch retries.
        case legacyAppRunning
        /// The migration ran and the marker is set.
        case migrated
    }

    /// Counts and statuses only: never a key's value, a path's contents or a token.
    public struct Report: Equatable, Sendable, CustomStringConvertible {
        public var outcome: Outcome
        public var defaultsCopied = 0
        public var filesCopied = 0
        public var keychainCopied = 0
        public var keychainDenied = 0
        public var keychainFailed = 0
        /// Legacy accounts already present under Roadie's service.
        public var keychainSkipped = 0
        /// True when SkinAmp had no token items at all.
        public var keychainAbsent = false

        public init(outcome: Outcome) { self.outcome = outcome }

        public var description: String {
            switch outcome {
            case .alreadyMigrated: return "migration: already done"
            case .legacyAppRunning: return "migration: SkinAmp is running, retry next launch"
            case .migrated:
                let keychain = keychainAbsent
                    ? "absent"
                    : "copied \(keychainCopied)/denied \(keychainDenied)/failed \(keychainFailed)/skipped \(keychainSkipped)"
                return "migration: \(defaultsCopied) defaults, \(filesCopied) files, keychain \(keychain)"
            }
        }
    }

    private let defaults: UserDefaults
    private let legacyDomain: () -> [String: Any]?
    private let fileManager: FileManager
    private let appSupport: URL
    private let newBundleID: String
    private let keychain: any TokenItemCopier
    private let isLegacyAppRunning: () -> Bool
    private let logger = Logger(subsystem: "co.sstools.roadie", category: "AppMigration")

    /// - Parameters:
    ///   - defaults: Roadie's defaults, which receive absent keys and the marker.
    ///   - legacyDomain: SkinAmp's persistent defaults domain, or nil when it has none.
    ///   - appSupport: the `~/Library/Application Support` root that holds both bundle-id folders.
    public init(defaults: UserDefaults, legacyDomain: @escaping () -> [String: Any]?,
                fileManager: FileManager, appSupport: URL, newBundleID: String,
                keychain: any TokenItemCopier, isLegacyAppRunning: @escaping () -> Bool) {
        self.defaults = defaults
        self.legacyDomain = legacyDomain
        self.fileManager = fileManager
        self.appSupport = appSupport
        self.newBundleID = newBundleID
        self.keychain = keychain
        self.isLegacyAppRunning = isLegacyAppRunning
    }

    /// The production wiring: standard defaults, the real Keychain and `NSRunningApplication`.
    public static func live(newBundleID: String) -> LegacyAppMigration {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return LegacyAppMigration(
            defaults: .standard,
            legacyDomain: { UserDefaults.standard.persistentDomain(forName: legacyBundleID) },
            fileManager: fileManager, appSupport: appSupport, newBundleID: newBundleID,
            keychain: KeychainTokenItemCopier(),
            isLegacyAppRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: legacyBundleID).isEmpty })
    }

    @discardableResult
    public func run() -> Report {
        if defaults.object(forKey: Self.markerKey) != nil {
            return Report(outcome: .alreadyMigrated)
        }
        if isLegacyAppRunning() {
            let report = Report(outcome: .legacyAppRunning)
            logger.info("\(report.description, privacy: .public)")
            return report
        }
        var report = Report(outcome: .migrated)
        report.defaultsCopied = copyDefaults()
        report.filesCopied = copyFiles()
        copyTokens(into: &report)
        defaults.set(Self.markerVersion, forKey: Self.markerKey)
        logger.info("\(report.description, privacy: .public)")
        return report
    }

    private func copyDefaults() -> Int {
        guard let domain = legacyDomain() else { return 0 }
        var copied = 0
        for (key, value) in domain where key != Self.markerKey && defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            copied += 1
        }
        return copied
    }

    private func copyFiles() -> Int {
        let source = appSupport.appendingPathComponent(Self.legacyBundleID, isDirectory: true)
        let destination = appSupport.appendingPathComponent(newBundleID, isDirectory: true)
        return copyMissing(from: source, to: destination)
    }

    /// Copies each file under `source` whose counterpart under `destination` doesn't exist. Returns the file count.
    private func copyMissing(from source: URL, to destination: URL) -> Int {
        guard let names = try? fileManager.contentsOfDirectory(atPath: source.path) else { return 0 }
        var copied = 0
        for name in names {
            let from = source.appendingPathComponent(name)
            let to = destination.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: from.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                copied += copyMissing(from: from, to: to)
            } else if !fileManager.fileExists(atPath: to.path) {
                do {
                    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                    try fileManager.copyItem(at: from, to: to)
                    copied += 1
                } catch {
                    logger.error("migration: file copy failed: \(String(describing: type(of: error)), privacy: .public)")
                }
            }
        }
        return copied
    }

    private func copyTokens(into report: inout Report) {
        let source = Self.legacyBundleID + ".musicAssistant"
        let destination = newBundleID + ".musicAssistant"
        let legacy = keychain.accounts(service: source)
        guard !legacy.isEmpty else {
            report.keychainAbsent = true
            return
        }
        let existing = Set(keychain.accounts(service: destination))
        for account in legacy {
            if existing.contains(account) {
                report.keychainSkipped += 1
                continue
            }
            switch keychain.copy(account: account, from: source, to: destination, label: Self.tokenLabel) {
            case .copied: report.keychainCopied += 1
            case .denied: report.keychainDenied += 1
            case .failed(let status):
                report.keychainFailed += 1
                logger.error("migration: keychain copy failed, status \(status, privacy: .public)")
            }
        }
    }
}

/// The login-keychain `TokenItemCopier`.
public struct KeychainTokenItemCopier: TokenItemCopier {
    public init() {}

    public func accounts(service: String) -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    public func copy(account: String, from source: String, to destination: String, label: String) -> TokenCopyStatus {
        let read: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: source,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        switch status {
        case errSecSuccess: break
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed: return .denied
        default: return .failed(status)
        }
        guard let data = result as? Data else { return .failed(errSecDecode) }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: destination,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: label,
            kSecValueData as String: data,
        ]
        let added = SecItemAdd(add as CFDictionary, nil)
        return added == errSecSuccess || added == errSecDuplicateItem ? .copied : .failed(added)
    }
}
