import Foundation
import Testing
@testable import FolderBackendKit

@MainActor
@Suite struct FolderSettingsModelTests {
    @MainActor private struct Harness {
        let fixture: BackendFixture
        let defaults: UserDefaults
        let suite: String
        let model: FolderSettingsModel

        init() throws {
            suite = "FolderBackendKitTests-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            let root = makeTempDir()
            let defaults = self.defaults
            fixture = try BackendFixture(root: root, settings: FolderBackend.settingsProvider(defaults: defaults))
            model = FolderSettingsModel(backend: fixture.backend, defaults: defaults, cacheDirectory: fixture.cache)
        }

        func cleanup() {
            fixture.cleanup()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    @Test func chooseStoresThePathAndConnects() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let model = harness.model
        model.appeared()
        defer { model.disappeared() }
        model.choose(harness.fixture.root)
        await model.waitForPending()
        await harness.fixture.backend.waitForIndexing()

        #expect(harness.defaults.string(forKey: FolderBackend.folderDefaultsKey) == harness.fixture.root.path)
        #expect(model.hasFolder)
        #expect(await waitFor { model.statusText == "3 artists, 4 albums, 7 tracks, 2 files skipped" })
        #expect(await harness.fixture.backend.isConnected)
        #expect(model.errorMessage == nil)
    }

    @Test func appearedConnectsWhenAFolderIsStoredAndNotOtherwise() async throws {
        let empty = try Harness()
        defer { empty.cleanup() }
        empty.model.appeared()
        defer { empty.model.disappeared() }
        await empty.model.waitForPending()
        #expect(empty.model.statusText == "Not indexed")
        #expect(await empty.fixture.backend.isConnected == false)

        let stored = try Harness()
        defer { stored.cleanup() }
        stored.defaults.set(stored.fixture.root.path, forKey: FolderBackend.folderDefaultsKey)
        let model = FolderSettingsModel(
            backend: stored.fixture.backend, defaults: stored.defaults, cacheDirectory: stored.fixture.cache)
        model.appeared()
        defer { model.disappeared() }
        await model.waitForPending()
        #expect(await stored.fixture.backend.isConnected)
        #expect(await waitFor { model.statusText == "3 artists, 4 albums, 7 tracks, 2 files skipped" })
    }

    @Test func clearForgetsThePathDisconnectsAndRemovesTheCache() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let model = harness.model
        model.choose(harness.fixture.root)
        await model.waitForPending()
        let cacheFile = FolderIndexCache.fileURL(for: harness.fixture.root, in: harness.fixture.cache)
        #expect(FileManager.default.fileExists(atPath: cacheFile.path))

        model.clear()
        await model.waitForPending()
        #expect(harness.defaults.string(forKey: FolderBackend.folderDefaultsKey) == nil)
        #expect(await harness.fixture.backend.isConnected == false)
        #expect(!FileManager.default.fileExists(atPath: cacheFile.path))
        #expect(model.pathText == "No folder chosen")
        #expect(!model.hasFolder)
    }

    @Test func aMissingFolderShowsTheErrorAndKeepsThePath() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let missing = harness.fixture.root.appending(path: "Unplugged Drive")
        harness.model.choose(missing)
        await harness.model.waitForPending()
        #expect(harness.model.errorMessage?.contains("Unplugged Drive") == true)
        #expect(harness.model.hasFolder)
        #expect(harness.defaults.string(forKey: FolderBackend.folderDefaultsKey) == missing.path)
    }

    @Test func storedFolderReadsDefaults() {
        let suite = "FolderBackendKitTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(FolderBackend.storedFolder(in: defaults) == nil)
        defaults.set("", forKey: FolderBackend.folderDefaultsKey)
        #expect(FolderBackend.storedFolder(in: defaults) == nil)
        defaults.set("/Music/Library", forKey: FolderBackend.folderDefaultsKey)
        #expect(FolderBackend.storedFolder(in: defaults)?.path == "/Music/Library")
    }
}
