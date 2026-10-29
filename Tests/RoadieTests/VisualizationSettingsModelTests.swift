import Foundation
import MusicBackendKit
import SkinKit
import VisualizationKit
import XCTest

@testable import Roadie

/// Settings › Visualization's effects on the running window (#0241).
@MainActor
final class VisualizationSettingsModelTests: PlayerModelTestCase {
    private var now: TimeInterval = 100

    private func visModel(_ setUp: (UserDefaults) -> Void = { _ in }) throws -> PlayerModel {
        var configuration = try testConfiguration()
        configuration.visRenderer = "classic"
        configuration.visSeed = 1
        configuration.defaults.set("sequential", forKey: VisualizationSettings.Key.order)
        setUp(configuration.defaults)
        let model = makeModel(configuration)
        model.visualization.currentTime = { [unowned self] in self.now }
        return model
    }

    private func presetsFolder(_ names: [String]) throws -> URL {
        let folder = try temporaryDirectory("roadie-vis-presets")
        for name in names { try Data("[preset00]\n".utf8).write(to: folder.appending(path: name)) }
        return folder
    }

    func testChangingTheIntervalReplansAutoAdvance() throws {
        let model = try visModel()
        let vis = model.visualization
        vis.updateSettings { $0.autoAdvanceVaries = false }
        vis.open()
        vis.setVisible(true)
        let before = try XCTUnwrap(vis.clock.deadline)
        XCTAssertEqual(before, 116, accuracy: 0.001)
        vis.updateSettings { $0.autoAdvanceSeconds = 30 }
        XCTAssertEqual(try XCTUnwrap(vis.clock.deadline), 130, accuracy: 0.001)
        XCTAssertEqual(VisualizationSettings.load(from: model.defaults).autoAdvanceSeconds, 30)
        vis.updateSettings { $0.autoAdvanceSeconds = 1 }
        XCTAssertEqual(vis.settings.autoAdvanceSeconds, 5, "clamped")
    }

    func testTurningAutoAdvanceOffStopsIt() throws {
        let model = try visModel()
        let vis = model.visualization
        vis.open()
        vis.setVisible(true)
        XCTAssertNotNil(vis.clock.deadline)
        vis.updateSettings { $0.autoAdvance = false }
        XCTAssertNil(vis.clock.deadline)
        now = 1000
        vis.tick(now: 1000)
        XCTAssertEqual(vis.presetChanges, 0)
    }

    func testIdleSettingChangesTheOverlayTimeout() throws {
        let model = try visModel()
        let vis = model.visualization
        XCTAssertEqual(vis.overlayIdleTimeout, 3)
        vis.updateSettings { $0.overlayIdleSeconds = 10 }
        XCTAssertEqual(vis.overlayIdleTimeout, 10)
        vis.updateSettings { $0.overlayIdleSeconds = 0 }
        XCTAssertNil(vis.overlayIdleTimeout, "Never")
        XCTAssertEqual(VisualizationSettings.load(from: model.defaults).overlayIdleSeconds, 0)
    }

    func testFolderScanAddsUserPresets() async throws {
        let folder = try presetsFolder(["Beta.milk", "Alpha.milk"])
        let model = try visModel()
        let vis = model.visualization
        vis.open()
        vis.updateSettings { $0.presetsFolder = folder.path }
        await vis.reloadCatalogue().value
        XCTAssertEqual(vis.folderStatus, .found(2))
        let names = vis.navigator.presets.map(\.name)
        XCTAssertEqual(names, PresetCatalog.classics.map(\.name) + ["Alpha", "Beta"])
    }

    func testClearingTheFolderRemovesThemAndKeepsTheCurrentClassic() async throws {
        let folder = try presetsFolder(["Alpha.milk"])
        let model = try visModel()
        let vis = model.visualization
        vis.open()
        vis.updateSettings { $0.presetsFolder = folder.path }
        await vis.reloadCatalogue().value
        XCTAssertTrue(vis.load(.classic(.mirror), transition: 0))
        vis.updateSettings { $0.presetsFolder = nil }
        XCTAssertEqual(vis.folderStatus, .none)
        XCTAssertEqual(vis.navigator.presets.map(\.id), PresetCatalog.classics.map(\.id))
        XCTAssertEqual(vis.currentPreset?.id, "classic:mirror")
        XCTAssertNil(VisualizationSettings.load(from: model.defaults).presetsFolder)
    }

    func testAMissingFolderReportsNotFound() async throws {
        let model = try visModel()
        let vis = model.visualization
        vis.open()
        vis.updateSettings { $0.presetsFolder = "/nonexistent/roadie-\(UUID())" }
        await vis.reloadCatalogue().value
        XCTAssertEqual(vis.folderStatus, .notFound)
        XCTAssertEqual(vis.navigator.presets.count, PresetCatalog.classics.count)
    }

    func testOpenOnPlayOpensOnStartButNotOnResume() throws {
        let model = try visModel()
        let vis = model.visualization
        vis.updateSettings { $0.openOnPlay = true }
        vis.playbackStateChanged(to: .loading)
        vis.playbackStateChanged(to: .playing)
        XCTAssertTrue(vis.isOpen, "stopped → playing opens")
        vis.close()
        vis.playbackStateChanged(to: .paused)
        vis.playbackStateChanged(to: .playing)
        XCTAssertFalse(vis.isOpen, "resume doesn't")
        vis.playbackStateChanged(to: .loading)
        vis.playbackStateChanged(to: .playing)
        XCTAssertFalse(vis.isOpen, "a track change doesn't")
        vis.updateSettings { $0.openOnPlay = false }
        vis.playbackStateChanged(to: .stopped)
        vis.playbackStateChanged(to: .playing)
        XCTAssertFalse(vis.isOpen, "off never opens")
    }

    func testVisualizationSettingsCommandSelectsTheTab() throws {
        let model = try visModel()
        model.perform(.visualizationSettings)
        XCTAssertEqual(model.defaults.string(forKey: SettingsTab.defaultsKey), "visualization")
        XCTAssertEqual(systemRequests.last, .settings)
    }
}
