import Foundation
import LibraryBrowser
import XCTest

@testable import Roadie

/// `LegacyDataCleanup.run` (#0219) on a throwaway defaults suite and a temp caches root, with a stub Keychain remover:
/// the real Keychain, `.standard` and `~/Library/Caches` are never touched.
final class LegacyDataCleanupTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var cachesRoot: URL!
    /// The stub Keychain remover's calls.
    private var keychainCalls = 0

    override func setUpWithError() throws {
        suiteName = "co.sstools.roadie.tests.legacy.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        cachesRoot = FileManager.default.temporaryDirectory.appending(
            path: "roadie-legacy-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cachesRoot, withIntermediateDirectories: true)
        keychainCalls = 0
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: cachesRoot)
    }

    /// Runs the cleanup on the test suite, caches root and stub Keychain. Not named `run`: a bare `run()` inside an
    /// XCTestCase resolves to `XCTest.run()` and starts the test run again. `removeKeychain` runs synchronously;
    /// `onCacheRemoved` runs on the cleanup's detached task, hence `@Sendable`.
    @MainActor
    private func runCleanup(onCacheRemoved: (@Sendable () -> Void)? = nil) {
        LegacyDataCleanup.run(
            defaults: defaults, bundleIdentifier: "co.sstools.roadie.tests",
            removeKeychain: {
                self.keychainCalls += 1
                return "absent"
            }, cachesRoot: cachesRoot, onCacheRemoved: onCacheRemoved)
    }

    @MainActor
    func testLegacyCleanupRemovesPlexState() {
        for key in LegacyDataCleanup.defaultsKeys { defaults.set("x", forKey: key) }
        defaults.set(LegacyDataCleanup.removedSourceID, forKey: LibrarySourceController.defaultsKey)
        runCleanup()
        for key in LegacyDataCleanup.defaultsKeys { XCTAssertNil(defaults.object(forKey: key), key) }
        XCTAssertNil(defaults.object(forKey: LibrarySourceController.defaultsKey))
        XCTAssertEqual(keychainCalls, 1)
        XCTAssertEqual(defaults.integer(forKey: LegacyDataCleanup.versionKey), LegacyDataCleanup.version)
    }

    @MainActor
    func testLegacyCleanupKeepsFolderChoice() {
        defaults.set("folder", forKey: LibrarySourceController.defaultsKey)
        runCleanup()
        XCTAssertEqual(defaults.string(forKey: LibrarySourceController.defaultsKey), "folder")
    }

    @MainActor
    func testLegacyCleanupDeletesTrackCache() throws {
        let tracks = cachesRoot.appending(path: "co.sstools.roadie.tests", directoryHint: .isDirectory)
            .appending(path: "Tracks", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tracks, withIntermediateDirectories: true)
        try Data("mp3".utf8).write(to: tracks.appending(path: "a.mp3"))
        let done = expectation(description: "cache removed")
        runCleanup(onCacheRemoved: { done.fulfill() })
        wait(for: [done], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tracks.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tracks.deletingLastPathComponent().path))
    }

    @MainActor
    func testLegacyCleanupRunsOnce() {
        runCleanup()
        XCTAssertEqual(keychainCalls, 1)
        defaults.set(LegacyDataCleanup.removedSourceID, forKey: LibrarySourceController.defaultsKey)
        defaults.set("x", forKey: LegacyDataCleanup.defaultsKeys[0])
        runCleanup()
        XCTAssertEqual(keychainCalls, 1)
        XCTAssertEqual(defaults.string(forKey: LibrarySourceController.defaultsKey), LegacyDataCleanup.removedSourceID)
        XCTAssertNotNil(defaults.object(forKey: LegacyDataCleanup.defaultsKeys[0]))
    }
}
