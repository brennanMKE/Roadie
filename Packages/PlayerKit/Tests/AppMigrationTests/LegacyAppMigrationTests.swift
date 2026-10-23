import Foundation
import Testing
@testable import AppMigration

private let newID = "co.sstools.roadie"
private let legacyService = "com.brennanmke.SkinAmp.musicAssistant"
private let newService = "co.sstools.roadie.musicAssistant"
private let secret = "secret-token-value-123"

/// In-memory Keychain: service → account → token.
private final class FakeTokenCopier: TokenItemCopier {
    var items: [String: [String: String]] = [:]
    var denied: Set<String> = []
    var copyCalls = 0

    func accounts(service: String) -> [String] { (items[service] ?? [:]).keys.sorted() }

    func copy(account: String, from source: String, to destination: String, label: String) -> TokenCopyStatus {
        copyCalls += 1
        if denied.contains(account) { return .denied }
        guard let token = items[source]?[account] else { return .failed(-25300) }
        items[destination, default: [:]][account] = token
        return .copied
    }
}

private final class Fixture {
    let suite = "AppMigrationTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let root: URL
    let keychain = FakeTokenCopier()
    var legacy: [String: Any]? = nil
    var running = false

    init() {
        defaults = UserDefaults(suiteName: suite)!
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    var legacyDir: URL { root.appendingPathComponent(LegacyAppMigration.legacyBundleID, isDirectory: true) }
    var newDir: URL { root.appendingPathComponent(newID, isDirectory: true) }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }

    func migration() -> LegacyAppMigration {
        LegacyAppMigration(defaults: defaults, legacyDomain: { self.legacy }, fileManager: .default,
                           appSupport: root, newBundleID: newID, keychain: keychain,
                           isLegacyAppRunning: { self.running })
    }
}

struct LegacyAppMigrationTests {
    @Test func defaultsCopyOnlyAbsentKeysAndKeepSendspinClientID() {
        let f = Fixture()
        f.defaults.set("/roadie/skins", forKey: "skinsFolderPath")
        f.legacy = ["skinsFolderPath": "/old/skins", "sendspin.clientID": "client-abc", "LibrarySource": "folder"]
        let report = f.migration().run()
        #expect(report.outcome == .migrated)
        #expect(report.defaultsCopied == 2)
        #expect(f.defaults.string(forKey: "skinsFolderPath") == "/roadie/skins")
        #expect(f.defaults.string(forKey: "sendspin.clientID") == "client-abc")
        #expect(f.defaults.string(forKey: "LibrarySource") == "folder")
        #expect(f.defaults.integer(forKey: LegacyAppMigration.markerKey) == 1)
    }

    @Test func noLegacyDomainIsANoOpThatSetsTheMarker() {
        let f = Fixture()
        let report = f.migration().run()
        #expect(report.outcome == .migrated)
        #expect(report.defaultsCopied == 0)
        #expect(report.filesCopied == 0)
        #expect(report.keychainAbsent)
        #expect(f.defaults.integer(forKey: LegacyAppMigration.markerKey) == 1)
    }

    @Test func runningLegacyAppIsANoOpWithoutTheMarker() throws {
        let f = Fixture()
        f.running = true
        f.legacy = ["LibrarySource": "folder"]
        try f.write("q", to: f.legacyDir.appendingPathComponent("queue.json"))
        f.keychain.items[legacyService] = ["server-1": secret]
        let report = f.migration().run()
        #expect(report.outcome == .legacyAppRunning)
        #expect(f.defaults.object(forKey: LegacyAppMigration.markerKey) == nil)
        #expect(f.defaults.object(forKey: "LibrarySource") == nil)
        #expect(!FileManager.default.fileExists(atPath: f.newDir.appendingPathComponent("queue.json").path))
        #expect(f.keychain.copyCalls == 0)
    }

    @Test func filesCopyIntoAnEmptyDestination() throws {
        let f = Fixture()
        try f.write("queue", to: f.legacyDir.appendingPathComponent("queue.json"))
        for suffix in ["", "-wal", "-shm"] {
            try f.write("db\(suffix)", to: f.legacyDir.appendingPathComponent("SkinLibrary/index.sqlite\(suffix)"))
        }
        let report = f.migration().run()
        #expect(report.filesCopied == 4)
        #expect(f.read(f.newDir.appendingPathComponent("queue.json")) == "queue")
        #expect(f.read(f.newDir.appendingPathComponent("SkinLibrary/index.sqlite-wal")) == "db-wal")
        #expect(f.read(f.legacyDir.appendingPathComponent("queue.json")) == "queue")
    }

    @Test func filesNeverOverwriteTheDestination() throws {
        let f = Fixture()
        try f.write("old", to: f.legacyDir.appendingPathComponent("queue.json"))
        try f.write("old-db", to: f.legacyDir.appendingPathComponent("SkinLibrary/index.sqlite"))
        try f.write("new", to: f.newDir.appendingPathComponent("queue.json"))
        let report = f.migration().run()
        #expect(report.filesCopied == 1)
        #expect(f.read(f.newDir.appendingPathComponent("queue.json")) == "new")
        #expect(f.read(f.newDir.appendingPathComponent("SkinLibrary/index.sqlite")) == "old-db")
    }

    @Test func keychainCopiesEveryAccountAndSkipsPresentOnes() {
        let f = Fixture()
        f.keychain.items[legacyService] = ["a": secret, "b": secret, "c": secret]
        f.keychain.items[newService] = ["c": "roadie-token"]
        let report = f.migration().run()
        #expect(report.keychainCopied == 2)
        #expect(report.keychainSkipped == 1)
        #expect(!report.keychainAbsent)
        #expect(f.keychain.items[newService] == ["a": secret, "b": secret, "c": "roadie-token"])
    }

    @Test func keychainDeniedSetsTheMarkerAndReportsDenied() {
        let f = Fixture()
        f.keychain.items[legacyService] = ["a": secret, "b": secret]
        f.keychain.denied = ["b"]
        let report = f.migration().run()
        #expect(report.keychainCopied == 1)
        #expect(report.keychainDenied == 1)
        #expect(report.description.contains("denied 1"))
        #expect(f.defaults.integer(forKey: LegacyAppMigration.markerKey) == 1)
    }

    @Test func reportNeverContainsTheToken() {
        let f = Fixture()
        f.keychain.items[legacyService] = ["a": secret]
        let report = f.migration().run()
        #expect(!report.description.contains(secret))
        #expect(!String(describing: report).contains(secret))
        #expect(!String(reflecting: report).contains(secret))
    }

    @Test func secondRunIsIdempotent() throws {
        let f = Fixture()
        f.legacy = ["LibrarySource": "folder"]
        try f.write("queue", to: f.legacyDir.appendingPathComponent("queue.json"))
        f.keychain.items[legacyService] = ["a": secret]
        f.migration().run()
        f.defaults.set("ma", forKey: "LibrarySource")
        let calls = f.keychain.copyCalls
        let second = f.migration().run()
        #expect(second.outcome == .alreadyMigrated)
        #expect(f.defaults.string(forKey: "LibrarySource") == "ma")
        #expect(f.keychain.copyCalls == calls)
    }
}
