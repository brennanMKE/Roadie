import AppKit
import SkinKit
import VisualizationKit
import XCTest

@testable import Roadie

/// The visualization window's keys, auto-advance and right-click menu (#0236): classic renderer, seed 1, sequential
/// order unless stated, a manual clock.
@MainActor
final class VisualizationModelKeyTests: PlayerModelTestCase {
    private var now: TimeInterval = 0

    private func visModel(_ setUp: (UserDefaults) -> Void = { _ in }) throws -> PlayerModel {
        var configuration = try testConfiguration()
        configuration.visRenderer = "classic"
        configuration.visSeed = 1
        configuration.defaults.set("sequential", forKey: VisualizationSettings.Key.order)
        configuration.defaults.set(16.0, forKey: VisualizationSettings.Key.autoAdvanceSeconds)
        configuration.defaults.set(false, forKey: VisualizationSettings.Key.autoAdvanceVaries)
        setUp(configuration.defaults)
        let model = makeModel(configuration)
        model.visualization.currentTime = { [unowned self] in self.now }
        return model
    }

    /// Open and rendering at time 0.
    private func openVis() throws -> (PlayerModel, VisualizationModel) {
        let model = try visModel()
        let vis = model.visualization
        now = 0
        vis.open()
        vis.setVisible(true)
        return (model, vis)
    }

    func testRightArrowLoadsTheNextPresetWithTheKeyBlend() throws {
        let (_, vis) = try openVis()
        XCTAssertEqual(vis.currentPreset?.name, "Classic Spectrum")
        var toasts: [String] = []
        vis.onKeyChange = { toasts.append($0.name) }
        vis.perform(.nextPreset)
        XCTAssertEqual(vis.currentPreset?.name, "Classic Oscilloscope")
        XCTAssertEqual(vis.lastTransition, "blend 1.7")
        XCTAssertEqual(vis.presetChanges, 1)
        XCTAssertEqual(toasts, ["Classic Oscilloscope"])
    }

    func testLeftArrowGoesBackThroughHistory() throws {
        let (_, vis) = try openVis()
        vis.perform(.nextPreset)
        vis.perform(.nextPreset)
        XCTAssertEqual(vis.currentPreset?.name, "Classic Spectrum and Scope")
        vis.perform(.previousPreset)
        XCTAssertEqual(vis.currentPreset?.name, "Classic Oscilloscope")
        vis.perform(.previousPreset)
        XCTAssertEqual(vis.currentPreset?.name, "Classic Spectrum")
        XCTAssertEqual(vis.lastTransition, "blend 1.7")
    }

    func testHardCutLoadsWithoutATransition() throws {
        let (_, vis) = try openVis()
        vis.perform(.hardCut)
        XCTAssertEqual(vis.currentPreset?.name, "Classic Oscilloscope")
        XCTAssertEqual(vis.lastTransition, "cut")
    }

    func testOrderAndLockPersist() throws {
        let (model, vis) = try openVis()
        vis.perform(.toggleOrder)
        XCTAssertEqual(vis.navigator.order, .random)
        XCTAssertEqual(model.defaults.string(forKey: VisualizationSettings.Key.order), "random")
        vis.perform(.toggleOrder)
        XCTAssertEqual(model.defaults.string(forKey: VisualizationSettings.Key.order), "sequential")
        vis.perform(.toggleLock)
        XCTAssertTrue(vis.navigator.isLocked)
        XCTAssertTrue(model.defaults.bool(forKey: VisualizationSettings.Key.locked))
        XCTAssertTrue(VisualizationSettings.load(from: model.defaults).locked)
        vis.perform(.toggleLock)
        XCTAssertFalse(model.defaults.bool(forKey: VisualizationSettings.Key.locked))
    }

    func testTransportCommandsReachThePlayer() throws {
        let (_, vis) = try openVis()
        var hotkeys: [WinampHotkey] = []
        vis.performHotkey = { hotkeys.append($0) }
        for transport in [VisTransport.previous, .play, .pause, .stop, .next] { vis.perform(.transport(transport)) }
        XCTAssertEqual(hotkeys, [.previous, .play, .pause, .stop, .next])
        // Without the override they go to PlayerModel.perform (testVolumeKeysNudgeTheVolume takes that path).
    }

    func testVolumeKeysNudgeTheVolume() throws {
        let (model, vis) = try openVis()
        model.setVolume(0.5)
        vis.perform(.transport(.volumeUp))
        XCTAssertEqual(model.volume, 0.5 + WinampHotkeys.volumeStep, accuracy: 0.0001)
        vis.perform(.transport(.volumeDown))
        vis.perform(.transport(.volumeDown))
        XCTAssertEqual(model.volume, 0.5 - WinampHotkeys.volumeStep, accuracy: 0.0001)
    }

    func testAutoAdvanceLoadsTheNextPresetWithTheSettingsBlend() throws {
        let (_, vis) = try openVis()
        vis.tick(now: 15)
        XCTAssertEqual(vis.presetChanges, 0)
        now = 16
        vis.tick(now: 16)
        XCTAssertEqual(vis.presetChanges, 1)
        XCTAssertEqual(vis.currentPreset?.name, "Classic Oscilloscope")
        XCTAssertEqual(vis.lastTransition, "blend 2.7")
    }

    func testAutoAdvanceSkipsWhileLocked() throws {
        let (_, vis) = try openVis()
        vis.perform(.toggleLock)
        for t in stride(from: 1.0, through: 60, by: 1) {
            now = t
            vis.tick(now: t)
        }
        XCTAssertEqual(vis.presetChanges, 0)
        vis.perform(.nextPreset)
        XCTAssertEqual(vis.presetChanges, 1, "a key still changes a locked preset")
    }

    func testAManualChangeRestartsTheCountdown() throws {
        let (_, vis) = try openVis()
        now = 10
        vis.perform(.nextPreset)
        XCTAssertEqual(vis.presetChanges, 1)
        now = 16
        vis.tick(now: 16)
        XCTAssertEqual(vis.presetChanges, 1)
        now = 26
        vis.tick(now: 26)
        XCTAssertEqual(vis.presetChanges, 2)
        XCTAssertEqual(vis.lastTransition, "blend 2.7")
    }

    func testNotRenderingSuspendsTheCountdown() throws {
        let (_, vis) = try openVis()
        now = 5
        vis.setVisible(false)
        now = 15
        vis.setVisible(true)
        now = 20
        vis.tick(now: 20)
        XCTAssertEqual(vis.presetChanges, 0)
        now = 26
        vis.tick(now: 26)
        XCTAssertEqual(vis.presetChanges, 1)
    }

    func testContextMenuHasEveryCommandWithItsKey() throws {
        let (_, vis) = try openVis()
        let menu = VisualizationContextMenu.make(model: vis)
        let titles = menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
        XCTAssertEqual(titles, [
            "Next Preset", "Previous Preset", "Next Preset Without Blending", "-",
            "Random Order", "Lock Preset", "Presets…", "-",
            "Show Song Title", "Song Title", "Song Time", "Preset Name", "Frame Rate", "-",
            "Enter Full Screen", "Keyboard Shortcuts",
        ])
        for item in menu.items where !item.isSeparatorItem {
            XCTAssertFalse(item.keyEquivalent.isEmpty, "\(item.title) shows no key")
        }
        XCTAssertEqual(menu.items[2].keyEquivalent, "h")
        XCTAssertTrue(menu.items[0].isEnabled)
        XCTAssertTrue(menu.items[6].isEnabled, "Presets… (#0240)")
        XCTAssertEqual(menu.items[4].state, .off, "sequential")
        XCTAssertEqual(menu.items[5].state, .off)
        vis.perform(.toggleOrder)
        vis.perform(.toggleLock)
        let checked = VisualizationContextMenu.make(model: vis)
        XCTAssertEqual(checked.items[4].state, .on)
        XCTAssertEqual(checked.items[5].state, .on)
        // Picking an item runs its command.
        let next = try XCTUnwrap(checked.items[0] as? VisualizationCommandItem)
        _ = next.target?.perform(next.action, with: next)
        XCTAssertEqual(vis.presetChanges, 1)
    }
}
