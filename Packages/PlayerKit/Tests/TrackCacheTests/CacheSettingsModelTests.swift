import Foundation
import Testing
@testable import TrackCache

@MainActor
struct CacheSettingsModelTests {
    private struct Rig {
        let harness: Harness
        let defaults: UserDefaults
        let suite: String

        init(limit: Int64 = 1_000_000) {
            harness = Harness(limit: limit)
            suite = "CacheSettingsModelTests-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
        }

        func cleanup() {
            harness.cleanup()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    @Test func limitDefaultsToTwoGigabytes() {
        let rig = Rig(); defer { rig.cleanup() }
        #expect(CacheSettingsModel.storedLimit(in: rig.defaults) == 2_000_000_000)
        #expect(CacheSettingsModel(cache: rig.harness.cache, defaults: rig.defaults).limitBytes == 2_000_000_000)
        rig.defaults.set(Int64(5_000_000_000), forKey: CacheSettingsModel.limitDefaultsKey)
        #expect(CacheSettingsModel.storedLimit(in: rig.defaults) == 5_000_000_000)
        #expect(CacheSettingsModel(cache: rig.harness.cache, defaults: rig.defaults).limitBytes == 5_000_000_000)
        #expect(CacheSettingsModel.limitChoices.contains(2_000_000_000))
    }

    @Test func changingTheLimitPersistsAndEvicts() async throws {
        let rig = Rig(limit: 1000); defer { rig.cleanup() }
        for key in ["A", "B", "C", "D"] {
            try await rig.harness.get(key, bytes: 100)
            rig.harness.clock.advance(seconds: 10)
        }
        let model = CacheSettingsModel(cache: rig.harness.cache, defaults: rig.defaults)
        await model.refresh()
        #expect(model.usageBytes == 400)
        model.limitBytes = 300
        #expect(CacheSettingsModel.storedLimit(in: rig.defaults) == 300)
        await model.waitForPending()
        await model.refresh()
        #expect(model.usageBytes <= 300)
        #expect(model.fileCount == 3)
    }

    @Test func refreshReportsUsage() async throws {
        let rig = Rig(); defer { rig.cleanup() }
        let model = CacheSettingsModel(cache: rig.harness.cache, defaults: rig.defaults)
        await model.refresh()
        #expect(model.usageText == "0 bytes")
        #expect(!model.canClear)
        try await rig.harness.get("A", bytes: 100)
        try await rig.harness.get("B", bytes: 100)
        await model.refresh()
        #expect(model.usageBytes == 200)
        #expect(model.fileCount == 2)
        #expect(model.usageText == "200 bytes")
        #expect(model.canClear)
    }

    @Test func clearCacheEmptiesAndRefreshes() async throws {
        let rig = Rig(); defer { rig.cleanup() }
        try await rig.harness.get("A", bytes: 100)
        let model = CacheSettingsModel(cache: rig.harness.cache, defaults: rig.defaults)
        await model.refresh()
        #expect(model.canClear)
        await model.clearCache()
        #expect(model.usageBytes == 0)
        #expect(model.fileCount == 0)
        #expect(!model.canClear)
        #expect(model.errorMessage == nil)
        #expect(filesOnDisk(rig.harness.dir).isEmpty)
    }
}
