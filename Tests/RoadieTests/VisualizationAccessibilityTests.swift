import AppKit
import VisualizationKit
import XCTest

@testable import Roadie

/// Reduce Motion, Dim Flashing Lights, VoiceOver and the flashing notice (#0242, design §7): classic renderer, seed 1,
/// sequential order, a manual clock, the system's settings replaced through `accessibilityInputs`.
@MainActor
final class VisualizationAccessibilityTests: PlayerModelTestCase {
    private var now: TimeInterval = 0

    private func openVis(
        _ inputs: VisAccessibilityInputs = VisAccessibilityInputs(), setUp: (UserDefaults) -> Void = { _ in }
    ) throws -> VisualizationModel {
        var configuration = try testConfiguration()
        configuration.visRenderer = "classic"
        configuration.visSeed = 1
        configuration.defaults.set("sequential", forKey: VisualizationSettings.Key.order)
        configuration.defaults.set(16.0, forKey: VisualizationSettings.Key.autoAdvanceSeconds)
        configuration.defaults.set(false, forKey: VisualizationSettings.Key.autoAdvanceVaries)
        setUp(configuration.defaults)
        let model = makeModel(configuration)
        let vis = model.visualization
        vis.currentTime = { [unowned self] in self.now }
        now = 0
        vis.accessibilityInputs = { inputs }
        vis.refreshAccessibility()
        vis.open()
        vis.setVisible(true)
        return vis
    }

    func testPolicyTable() {
        let none = VisualizationAccessibilityPolicy.make(
            reduceMotion: false, dimFlashing: false, voiceOver: false, changeWithReduceMotion: false)
        XCTAssertEqual(none, VisualizationAccessibilityPolicy())
        XCTAssertTrue(none.animatesOverlay)

        let reduce = VisualizationAccessibilityPolicy.make(
            reduceMotion: true, dimFlashing: false, voiceOver: false, changeWithReduceMotion: false)
        XCTAssertTrue(reduce.suspendsAutoAdvance)
        XCTAssertTrue(reduce.hardCutBecomesBlend)
        XCTAssertEqual(reduce.minimumBlend, 0)
        XCTAssertTrue(reduce.crossfadeOnly)
        XCTAssertFalse(reduce.dimsPicture)
        XCTAssertFalse(reduce.overlayNeverHides)
        XCTAssertFalse(reduce.announcesPresetChanges)
        XCTAssertFalse(reduce.animatesOverlay)
        XCTAssertFalse(VisualizationAccessibilityPolicy.make(
            reduceMotion: true, dimFlashing: false, voiceOver: false, changeWithReduceMotion: true).suspendsAutoAdvance)

        let dim = VisualizationAccessibilityPolicy.make(
            reduceMotion: false, dimFlashing: true, voiceOver: false, changeWithReduceMotion: false)
        XCTAssertFalse(dim.suspendsAutoAdvance)
        XCTAssertTrue(dim.hardCutBecomesBlend)
        XCTAssertEqual(dim.minimumBlend, 5)
        XCTAssertTrue(dim.crossfadeOnly)
        XCTAssertTrue(dim.dimsPicture)
        XCTAssertFalse(dim.overlayNeverHides)
        XCTAssertFalse(dim.announcesPresetChanges)
        XCTAssertTrue(dim.animatesOverlay)

        let voiceOver = VisualizationAccessibilityPolicy.make(
            reduceMotion: false, dimFlashing: false, voiceOver: true, changeWithReduceMotion: false)
        XCTAssertFalse(voiceOver.suspendsAutoAdvance)
        XCTAssertFalse(voiceOver.hardCutBecomesBlend)
        XCTAssertFalse(voiceOver.crossfadeOnly)
        XCTAssertFalse(voiceOver.dimsPicture)
        XCTAssertTrue(voiceOver.overlayNeverHides)
        XCTAssertTrue(voiceOver.announcesPresetChanges)
        XCTAssertTrue(voiceOver.animatesOverlay)

        let all = VisualizationAccessibilityPolicy.make(
            reduceMotion: true, dimFlashing: true, voiceOver: true, changeWithReduceMotion: false)
        XCTAssertEqual(all, VisualizationAccessibilityPolicy(
            suspendsAutoAdvance: true, hardCutBecomesBlend: true, minimumBlend: 5, crossfadeOnly: true,
            dimsPicture: true, overlayNeverHides: true, announcesPresetChanges: true, animatesOverlay: false))
        XCTAssertEqual(all.transition(0), 5)
        XCTAssertEqual(reduce.transition(0), 1.7)
        XCTAssertEqual(none.transition(0), 0)
        XCTAssertEqual(dim.transition(2.7), 5)
        XCTAssertEqual(dim.transition(8), 8)
    }

    func testReduceMotionSuspendsAutoAdvanceUnlessOverridden() throws {
        let vis = try openVis(VisAccessibilityInputs(reduceMotion: true))
        XCTAssertTrue(vis.isAutoAdvanceSuspended)
        XCTAssertTrue(vis.reducesMotion)
        now = 40
        vis.tick(now: 40)
        XCTAssertEqual(vis.presetChanges, 0)
        vis.updateSettings { $0.changeWithReduceMotion = true }
        XCTAssertFalse(vis.isAutoAdvanceSuspended)
        now = 56
        vis.tick(now: 56)
        XCTAssertEqual(vis.presetChanges, 1)
        XCTAssertEqual(vis.lastTransition, "blend 2.7")
    }

    func testHardCutBlendsUnderReduceMotionAndDimFlashing() throws {
        let reduce = try openVis(VisAccessibilityInputs(reduceMotion: true))
        reduce.perform(.hardCut)
        XCTAssertEqual(reduce.lastTransition, "blend 1.7")
        let dim = try openVis(VisAccessibilityInputs(dimFlashing: true))
        dim.perform(.hardCut)
        XCTAssertEqual(dim.lastTransition, "blend 5.0")
        dim.perform(.nextPreset)
        XCTAssertEqual(dim.lastTransition, "blend 5.0")
    }

    func testDimFlashingDimsThePicture() throws {
        let vis = try openVis(VisAccessibilityInputs(dimFlashing: true))
        XCTAssertTrue(vis.isPictureDimmed)
        let host = VisualizationHostView(rendererView: NSView())
        XCTAssertFalse(host.isDimmed)
        host.setDimmed(vis.isPictureDimmed)
        XCTAssertEqual(host.dimmingView.layer?.opacity, 0.4)
        let plain = try openVis()
        XCTAssertFalse(plain.isPictureDimmed)
    }

    func testVoiceOverHoldsTheOverlay() throws {
        let vis = try openVis(VisAccessibilityInputs(voiceOver: true))
        XCTAssertTrue(vis.overlay.holds.contains(.voiceOver))
        vis.showOverlay()
        now = 60
        vis.tickOverlay()
        XCTAssertTrue(vis.overlay.isOverlayVisible)
        XCTAssertFalse(vis.overlay.isCursorHidden)
        vis.accessibilityInputs = { VisAccessibilityInputs() }
        vis.refreshAccessibility()
        XCTAssertFalse(vis.overlay.holds.contains(.voiceOver))
    }

    func testPresetChangesAreAnnouncedOnlyForKeysAndTheList() throws {
        let vis = try openVis(VisAccessibilityInputs(voiceOver: true))
        var announced: [String] = []
        vis.announce = { announced.append($0) }
        vis.perform(.nextPreset)
        XCTAssertEqual(announced, ["Classic Oscilloscope"])
        vis.openList()
        vis.presetList?.moveSelection(by: 1)
        let listed = vis.presetList?.selectedRow?.preset.name
        vis.loadListSelection()
        XCTAssertEqual(announced.count, 2)
        XCTAssertEqual(announced.last, listed)
        now = 40
        vis.tick(now: 40)
        XCTAssertEqual(vis.presetChanges, 3)
        XCTAssertEqual(announced.count, 2, "an automatic change was announced: \(announced)")

        let quiet = try openVis()
        var quietAnnounced: [String] = []
        quiet.announce = { quietAnnounced.append($0) }
        quiet.perform(.nextPreset)
        XCTAssertEqual(quietAnnounced, [])
    }

    func testFlashNoticeShowsOnceAndHoldsTheVisualization() throws {
        let vis = try openVis()
        XCTAssertFalse(vis.isFlashNoticeUp)
        vis.presentFlashNoticeIfNeeded()
        XCTAssertTrue(vis.isFlashNoticeUp)
        XCTAssertTrue(vis.isPictureDimmed)
        XCTAssertTrue(vis.isAutoAdvanceSuspended)
        XCTAssertTrue(vis.overlay.holds.contains(.notice))
        now = 40
        vis.tick(now: 40)
        XCTAssertEqual(vis.presetChanges, 0)
        vis.perform(.nextPreset)
        XCTAssertEqual(vis.presetChanges, 0, "a key got past the notice")
        vis.dismissFlashNotice()
        XCTAssertFalse(vis.isFlashNoticeUp)
        XCTAssertFalse(vis.isPictureDimmed)
        XCTAssertFalse(vis.isAutoAdvanceSuspended)
        XCTAssertFalse(vis.overlay.holds.contains(.notice))
        XCTAssertTrue(vis.settings.flashNoticeShown)
        vis.presentFlashNoticeIfNeeded()
        XCTAssertFalse(vis.isFlashNoticeUp)

        let shown = try openVis { $0.set(true, forKey: VisualizationSettings.Key.flashNoticeShown) }
        shown.presentFlashNoticeIfNeeded()
        XCTAssertFalse(shown.isFlashNoticeUp)
    }
}
