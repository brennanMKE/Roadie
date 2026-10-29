import Foundation
import Testing
@testable import VisualizationKit

struct VisualizationSettingsTests {
    private func suite() -> (UserDefaults, String) {
        let name = "VisualizationSettingsTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func defaultsMatchTheDesign() {
        let d = VisualizationSettings.defaults
        #expect(d.autoAdvance)
        #expect(d.autoAdvanceSeconds == 16)
        #expect(d.autoAdvanceVaries)
        #expect(d.blendSeconds == 2.7)
        #expect(d.order == .random)
        #expect(!d.locked)
        #expect(d.overlayIdleSeconds == 3)
        #expect(d.songTitleOnTrackChange)
        #expect(d.readouts.isEmpty)
        #expect(!d.openOnPlay)
        #expect(!d.windowOpen)
        #expect(d.lastPreset == nil && d.presetsFolder == nil)
        #expect(d.autoAdvancePolicy == .init(isEnabled: true, interval: 16, varies: true))
        #expect(VisualizationSettings.keyBlend == 1.7)
        #expect(VisualizationSettings.reducedMotionMinimumBlend == 5)

        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(VisualizationSettings.load(from: defaults) == d)
    }

    @Test func roundTripsThroughAUserDefaultsSuite() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = VisualizationSettings(
            autoAdvance: false, autoAdvanceSeconds: 42, autoAdvanceVaries: false, blendSeconds: 0.5,
            order: .sequential, locked: true, lastPreset: "user:a.milk", presetsFolder: "/tmp/presets",
            overlayIdleSeconds: 0, songTitleOnTrackChange: false, readouts: [.fps, .title], openOnPlay: true,
            windowOpen: true, changeWithReduceMotion: true, flashNoticeShown: true
        )
        settings.save(to: defaults)
        #expect(defaults.string(forKey: "visualization.order") == "sequential")
        #expect(VisualizationSettings.load(from: defaults) == settings)

        VisualizationSettings.defaults.save(to: defaults)
        #expect(VisualizationSettings.load(from: defaults) == .defaults)
    }

    @Test func outOfRangeValuesClampAndWrongTypesFallBack() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(1, forKey: "visualization.autoAdvanceSeconds")
        defaults.set(99.0, forKey: "visualization.blendSeconds")
        defaults.set(-4.0, forKey: "visualization.overlayIdleSeconds")
        defaults.set("shuffle", forKey: "visualization.order")
        defaults.set("not a bool", forKey: "visualization.locked")
        defaults.set(7, forKey: "visualization.autoAdvance")
        defaults.set(42, forKey: "visualization.readouts")
        defaults.set(true, forKey: "visualization.lastPreset")

        let loaded = VisualizationSettings.load(from: defaults)
        #expect(loaded.autoAdvanceSeconds == 5)
        #expect(loaded.blendSeconds == 10)
        #expect(loaded.overlayIdleSeconds == 0)
        #expect(loaded.order == .random)
        #expect(!loaded.locked)
        #expect(loaded.autoAdvance)
        #expect(loaded.readouts.isEmpty)
        #expect(loaded.lastPreset == nil)

        defaults.set(500.0, forKey: "visualization.autoAdvanceSeconds")
        defaults.set(true, forKey: "visualization.blendSeconds")
        let again = VisualizationSettings.load(from: defaults)
        #expect(again.autoAdvanceSeconds == 300)
        #expect(again.blendSeconds == 2.7)
    }
}
