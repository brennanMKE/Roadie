import AppKit
import SkinKit
import VisualizationKit
import XCTest

@testable import Roadie

/// The preset list (#0240): filtering, selection, loading, and what it holds while open. Classic renderer, seed 1,
/// sequential order, a manual clock.
@MainActor
final class VisualizationListTests: PlayerModelTestCase {
    private var now: TimeInterval = 0

    private func openVis(renderer: (any VisualizationRenderer)? = nil) throws -> VisualizationModel {
        var configuration = try testConfiguration()
        configuration.visRenderer = "classic"
        configuration.visSeed = 1
        configuration.defaults.set("sequential", forKey: VisualizationSettings.Key.order)
        configuration.defaults.set(16.0, forKey: VisualizationSettings.Key.autoAdvanceSeconds)
        configuration.defaults.set(false, forKey: VisualizationSettings.Key.autoAdvanceVaries)
        let vis = makeModel(configuration).visualization
        vis.currentTime = { [unowned self] in self.now }
        if let renderer { vis.makeRenderer = { renderer } }
        now = 0
        vis.open()
        vis.setVisible(true)
        return vis
    }

    func testFilterMatchesNamesCaseAndDiacriticInsensitively() {
        let presets = [
            VisualizationPreset.classic(.mirror),
            VisualizationPreset(id: "user:Café Noir.milk", name: "Café Noir", kind: .milk, source: .user, url: nil),
            VisualizationPreset.classic(.spectrum),
        ]
        let list = PresetListModel(presets: presets, currentID: nil, failedIDs: [])
        list.query = "MIRR"
        XCTAssertEqual(list.rows.map(\.preset.name), ["Classic Mirror"])
        list.query = "cafe"
        XCTAssertEqual(list.rows.map(\.preset.name), ["Café Noir"])
        XCTAssertEqual(list.rows.first?.sourceTag, "Yours")
        list.query = ""
        XCTAssertEqual(list.rows.count, 3)
        list.query = "zzz"
        XCTAssertTrue(list.rows.isEmpty)
        XCTAssertNil(list.selection)
    }

    func testOpeningSelectsTheCurrentPreset() throws {
        let vis = try openVis()
        vis.perform(.nextPreset)
        vis.perform(.presetList)
        let list = try XCTUnwrap(vis.presetList)
        XCTAssertTrue(vis.isListOpen)
        XCTAssertEqual(list.selectedRow?.preset.name, "Classic Oscilloscope")
        XCTAssertEqual(list.selectedRow?.status, "current")
        XCTAssertEqual(list.rows.first?.sourceTag, "Classic")
    }

    func testReturnLoadsTheSelectionAndCloses() throws {
        let vis = try openVis()
        vis.openList()
        let list = try XCTUnwrap(vis.presetList)
        list.moveSelection(by: 1)
        list.moveSelection(by: 1)
        vis.loadListSelection()
        XCTAssertEqual(vis.currentPreset?.name, "Classic Spectrum and Scope")
        XCTAssertEqual(vis.presetChanges, 1)
        XCTAssertEqual(vis.lastTransition, "blend 1.7")
        XCTAssertFalse(vis.isListOpen)
    }

    func testFailedPresetsAreListedButCannotBeLoaded() throws {
        let vis = try openVis(renderer: ListFailingRenderer(failing: "classic:mirror"))
        XCTAssertFalse(vis.load(.classic(.mirror), transition: 0))
        vis.openList()
        let list = try XCTUnwrap(vis.presetList)
        list.query = "mirror"
        XCTAssertEqual(list.rows.map(\.preset.name), ["Classic Mirror"])
        XCTAssertEqual(list.selectedRow?.status, "failed")
        let changes = vis.presetChanges
        vis.loadListSelection()
        XCTAssertEqual(vis.presetChanges, changes)
        XCTAssertEqual(vis.currentPreset?.name, "Classic Spectrum")
        XCTAssertTrue(vis.isListOpen)
    }

    func testTheListHoldsTheOverlayAndSuspendsAutoAdvance() throws {
        let vis = try openVis()
        vis.openList()
        XCTAssertTrue(vis.isListOpen, "the overlay (#0238) holds itself up while this is true")
        now = 30
        vis.tick(now: 30)
        XCTAssertEqual(vis.presetChanges, 0)
        vis.perform(.escape)
        XCTAssertFalse(vis.isListOpen)
        now = 40
        vis.tick(now: 40)
        XCTAssertEqual(vis.presetChanges, 0, "the countdown resumed where it paused")
        now = 46
        vis.tick(now: 46)
        XCTAssertEqual(vis.presetChanges, 1)
    }

    func testKeysGoToTheListWhileItIsOpen() throws {
        let vis = try openVis()
        vis.perform(.presetList)
        vis.perform(.nextPreset)
        vis.perform(.hardCut)
        vis.perform(.toggleLock)
        XCTAssertEqual(vis.currentPreset?.name, "Classic Spectrum")
        XCTAssertEqual(vis.presetChanges, 0)
        XCTAssertFalse(vis.navigator.isLocked)
        XCTAssertTrue(vis.isListOpen)
        vis.perform(.escape)
        XCTAssertFalse(vis.isListOpen)
        vis.perform(.nextPreset)
        XCTAssertEqual(vis.currentPreset?.name, "Classic Oscilloscope")
    }
}

/// A renderer that throws for one preset id.
@MainActor
private final class ListFailingRenderer: VisualizationRenderer {
    struct Failure: Error {}

    let failing: String
    let view = NSView()
    let kindName = "double"
    let problems: [String] = []

    init(failing: String) { self.failing = failing }

    func canLoad(_ preset: VisualizationPreset) -> Bool { true }

    func load(_ preset: VisualizationPreset, transition: TimeInterval) throws {
        if preset.id == failing { throw Failure() }
    }

    func feed(_ samples: UnsafeBufferPointer<Float>, channels: Int, sampleRate: Double) {}
    func draw(at time: TimeInterval) {}
    func setReducedMotion(_ on: Bool) {}
    func setColors(_ colors: [SkinKit.RGBColor]) {}
}
