import Foundation
import VisualizationKit
import XCTest

@testable import Roadie

/// The song title on track change and on T, the F2–F5 readouts and the F1 help card (#0239), on a manual clock.
@MainActor
final class VisualizationTitleTests: PlayerModelTestCase {
    private var now: TimeInterval = 0
    /// The player model, kept alive for the test (the visualization holds it weakly), and its defaults.
    private var model: PlayerModel?
    private var defaults: UserDefaults?

    private func openVis(_ setUp: (UserDefaults) -> Void = { _ in }) throws -> VisualizationModel {
        var configuration = try testConfiguration()
        configuration.visRenderer = "classic"
        configuration.visSeed = 1
        setUp(configuration.defaults)
        let model = makeModel(configuration)
        self.model = model
        defaults = configuration.defaults
        let vis = model.visualization
        vis.currentTime = { [unowned self] in self.now }
        now = 0
        vis.open()
        vis.setVisible(true)
        return vis
    }

    func testATrackChangeStartsATitleShow() throws {
        let vis = try openVis()
        vis.noteTrack(identity: "one", text: "The Band – Song One")
        XCTAssertEqual(vis.songTitleShowCount, 0)
        vis.noteTrack(identity: "two", text: "The Band – Song Two")
        XCTAssertEqual(vis.songTitleShowCount, 1)
        XCTAssertEqual(vis.songTitle?.text, "The Band – Song Two")
        // The same track again (a state change) shows nothing new.
        vis.noteTrack(identity: "two", text: "The Band – Song Two")
        XCTAssertEqual(vis.songTitleShowCount, 1)
    }

    func testTheFirstTrackAfterOpeningDoesNotShow() throws {
        let vis = try openVis()
        vis.noteTrack(identity: nil, text: nil)
        vis.noteTrack(identity: "one", text: "Song One")
        XCTAssertEqual(vis.songTitleShowCount, 0)
        XCTAssertNil(vis.songTitle)
        // Closed: nothing; reopening starts over.
        vis.close()
        vis.noteTrack(identity: "two", text: "Song Two")
        XCTAssertEqual(vis.songTitleShowCount, 0)
    }

    func testTheSettingTurnsItOff() throws {
        let vis = try openVis()
        vis.updateSettings { $0.songTitleOnTrackChange = false }
        vis.noteTrack(identity: "one", text: "Song One")
        vis.noteTrack(identity: "two", text: "Song Two")
        XCTAssertEqual(vis.songTitleShowCount, 0)
    }

    func testTShowsItOnDemand() throws {
        let vis = try openVis()
        vis.perform(.showSongTitle)
        XCTAssertEqual(vis.songTitleShowCount, 1)
        XCTAssertEqual(vis.songTitle?.text, "Nothing is playing")
        vis.perform(.showSongTitle)
        XCTAssertEqual(vis.songTitleShowCount, 2)
        XCTAssertEqual(vis.songTitle?.id, 2, "a new show replaces the running one")
    }

    func testTitleWithoutArtist() {
        XCTAssertEqual(VisualizationModel.songTitleText(title: "Song One", artist: "The Band"), "The Band – Song One")
        XCTAssertEqual(VisualizationModel.songTitleText(title: "Song One", artist: nil), "Song One")
        XCTAssertEqual(VisualizationModel.songTitleText(title: "Song One", artist: ""), "Song One")
        XCTAssertNil(VisualizationModel.songTitleText(title: nil, artist: "The Band"))
    }

    func testReadoutsPersist() throws {
        let vis = try openVis()
        vis.perform(.toggleReadout(.time))
        vis.perform(.toggleReadout(.fps))
        XCTAssertEqual(vis.settings.readouts, [.time, .fps])
        let defaults = try XCTUnwrap(defaults)
        XCTAssertEqual(defaults.stringArray(forKey: VisualizationSettings.Key.readouts), ["time", "fps"])
        XCTAssertEqual(VisualizationSettings.load(from: defaults).readouts, [.time, .fps])
        vis.perform(.toggleReadout(.time))
        vis.perform(.toggleReadout(.fps))
        XCTAssertEqual(vis.settings.readouts, [])
        XCTAssertEqual(defaults.stringArray(forKey: VisualizationSettings.Key.readouts), [])
        // The menu shows ✓ per readout.
        vis.perform(.toggleReadout(.preset))
        let menu = VisualizationContextMenu.make(model: vis)
        let preset = try XCTUnwrap(menu.items.first { $0.title == "Preset Name" })
        XCTAssertEqual(preset.state, .on)
        XCTAssertTrue(preset.isEnabled)
        XCTAssertEqual(menu.items.first { $0.title == "Frame Rate" }?.state, .off)
    }

    func testBottomReadoutsHideWhileTheCardIsVisible() {
        let all = Set(VisReadout.allCases)
        for readout in VisReadout.allCases {
            XCTAssertTrue(VisualizationModel.showsReadout(readout, on: all, overlayVisible: false), "\(readout)")
            XCTAssertFalse(VisualizationModel.showsReadout(readout, on: [], overlayVisible: false), "\(readout)")
        }
        XCTAssertTrue(VisualizationModel.showsReadout(.fps, on: all, overlayVisible: true))
        XCTAssertFalse(VisualizationModel.showsReadout(.title, on: all, overlayVisible: true))
        XCTAssertFalse(VisualizationModel.showsReadout(.time, on: all, overlayVisible: true))
        XCTAssertFalse(VisualizationModel.showsReadout(.preset, on: all, overlayVisible: true))
    }

    func testHelpHoldsTheOverlayAndSuspendsAutoAdvance() throws {
        let vis = try openVis()
        XCTAssertFalse(vis.clock.isSuspended)
        vis.perform(.help)
        XCTAssertTrue(vis.isHelpOpen)
        XCTAssertTrue(vis.overlay.holds.contains(.help))
        XCTAssertTrue(vis.clock.isSuspended)
        // Esc closes it first.
        vis.perform(.escape)
        XCTAssertFalse(vis.isHelpOpen)
        XCTAssertFalse(vis.overlay.holds.contains(.help))
        XCTAssertFalse(vis.clock.isSuspended)
        vis.perform(.help)
        vis.perform(.help)
        XCTAssertFalse(vis.isHelpOpen, "F1 again closes it")
    }
}
