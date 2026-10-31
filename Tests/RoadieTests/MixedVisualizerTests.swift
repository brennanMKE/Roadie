import AppKit
import Metal
import SkinKit
import VisualizationKit
import XCTest

@testable import Roadie

/// `MixedVisualizer` (#0257): routing, the visible view, crossfades and the factory. Doubles, so no Metal except the
/// factory test.
@MainActor
final class MixedVisualizerTests: XCTestCase {
    private let milkPreset = VisualizationPreset.milk(
        url: URL(fileURLWithPath: "/tmp/Alpha.milk"), relativePath: "Alpha.milk", source: .user)
    private let otherMilk = VisualizationPreset.milk(
        url: URL(fileURLWithPath: "/tmp/Beta.milk"), relativePath: "Beta.milk", source: .user)

    private func make() -> (MixedVisualizer, StandInMilkRenderer, StandInMilkRenderer) {
        let classic = StandInMilkRenderer.classic()
        let milk = StandInMilkRenderer()
        return (MixedVisualizer(classic: classic, milk: milk), classic, milk)
    }

    private func samples(_ mixed: MixedVisualizer) {
        let buffer = [Float](repeating: 0, count: 8)
        buffer.withUnsafeBufferPointer { mixed.feed($0, channels: 2, sampleRate: 48_000) }
    }

    func testRoutesEachPresetToTheRendererThatCanLoadIt() throws {
        let (mixed, classic, milk) = make()
        try mixed.load(.classic(.mirror), transition: 0)
        try mixed.load(milkPreset, transition: 0)
        XCTAssertEqual(classic.loads, ["classic:mirror"])
        XCTAssertEqual(milk.loads, [milkPreset.id])
    }

    func testCanLoadMilkOnlyWithAMilkRenderer() {
        let without = MixedVisualizer(classic: StandInMilkRenderer.classic(), milk: nil)
        XCTAssertFalse(without.canLoad(milkPreset))
        XCTAssertTrue(without.canLoad(.classic(.spectrum)))
        XCTAssertThrowsError(try without.load(milkPreset, transition: 0))
        let (with, _, _) = make()
        XCTAssertTrue(with.canLoad(milkPreset))
    }

    func testKindNameFollowsTheActiveRenderer() throws {
        let (mixed, _, _) = make()
        XCTAssertEqual(mixed.kindName, "classic")
        try mixed.load(milkPreset, transition: 0)
        XCTAssertEqual(mixed.kindName, "milk")
        try mixed.load(.classic(.spectrum), transition: 0)
        XCTAssertEqual(mixed.kindName, "classic")
    }

    func testSwitchingKindsSwapsTheVisibleView() throws {
        let (mixed, classic, milk) = make()
        XCTAssertFalse(classic.view.isHidden)
        XCTAssertTrue(milk.view.isHidden)
        try mixed.load(milkPreset, transition: 0)
        XCTAssertTrue(classic.view.isHidden)
        XCTAssertFalse(milk.view.isHidden)
        XCTAssertEqual(milk.view.alphaValue, 1)

        try mixed.load(.classic(.spectrum), transition: 1)
        XCTAssertFalse(classic.view.isHidden)
        XCTAssertFalse(milk.view.isHidden)
        mixed.draw(at: 10)
        mixed.draw(at: 10.5)
        XCTAssertEqual(classic.view.alphaValue, 0.5, accuracy: 0.01)
        XCTAssertFalse(milk.view.isHidden)
        mixed.draw(at: 11)
        XCTAssertFalse(classic.view.isHidden)
        XCTAssertEqual(classic.view.alphaValue, 1)
        XCTAssertTrue(milk.view.isHidden)
    }

    func testAFailedLoadOfTheOtherKindKeepsTheCurrentOne() throws {
        let (mixed, classic, milk) = make()
        try mixed.load(.classic(.mirror), transition: 0)
        milk.failing = true
        XCTAssertThrowsError(try mixed.load(milkPreset, transition: 1))
        XCTAssertEqual(mixed.kindName, "classic")
        XCTAssertFalse(classic.view.isHidden)
        XCTAssertTrue(milk.view.isHidden)
    }

    func testHiddenRendererGetsNoFeedOrDraw() throws {
        let (mixed, classic, milk) = make()
        samples(mixed)
        mixed.draw(at: 0)
        XCTAssertEqual(milk.feeds, 0)
        XCTAssertEqual(milk.draws, 0)
        try mixed.load(milkPreset, transition: 1)
        samples(mixed)
        mixed.draw(at: 1)
        XCTAssertEqual(classic.feeds, 2, "the outgoing renderer is fed during the crossfade")
        XCTAssertEqual(classic.draws, 2, "the outgoing renderer is drawn during the crossfade")
        mixed.draw(at: 2)
        let (feeds, draws) = (classic.feeds, classic.draws)
        samples(mixed)
        mixed.draw(at: 3)
        XCTAssertEqual(classic.feeds, feeds)
        XCTAssertEqual(classic.draws, draws)
        XCTAssertEqual(milk.draws, 3)
    }

    func testMilkIsResetWhenItBecomesActiveAgain() throws {
        let (mixed, _, milk) = make()
        try mixed.load(.classic(.mirror), transition: 0)
        try mixed.load(milkPreset, transition: 0)
        XCTAssertEqual(milk.resets, 1)
        try mixed.load(otherMilk, transition: 0)
        XCTAssertEqual(milk.resets, 1, "a MilkDrop → MilkDrop change doesn't reset")
        try mixed.load(.classic(.spectrum), transition: 0)
        try mixed.load(milkPreset, transition: 0)
        XCTAssertEqual(milk.resets, 2)
    }

    func testReducedMotionAndColorsReachBothRenderers() {
        let (mixed, classic, milk) = make()
        mixed.setReducedMotion(true)
        mixed.setColors(VisRenderer.defaultColors)
        XCTAssertEqual(classic.reducedMotion, true)
        XCTAssertEqual(milk.reducedMotion, true)
        XCTAssertEqual(classic.colorSets, 1)
        XCTAssertEqual(milk.colorSets, 1)
    }

    func testFactoryBuildsMixedWithAMetalDevice() throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "no Metal device")
        let renderer = VisualizationRendererFactory.make(configuration: RoadieConfiguration(), colors: VisRenderer.defaultColors)
        let mixed = try XCTUnwrap(renderer as? MixedVisualizer)
        XCTAssertTrue(mixed.canLoad(milkPreset))
        XCTAssertTrue(mixed.canLoad(.classic(.spectrum)))
        XCTAssertEqual(mixed.kindName, "classic")
    }

    func testClassicHookBuildsOnlyClassic() {
        var configuration = RoadieConfiguration()
        configuration.visRenderer = "classic"
        let renderer = VisualizationRendererFactory.make(configuration: configuration, colors: VisRenderer.defaultColors)
        XCTAssertTrue(renderer is ClassicVisualizer)
        XCTAssertFalse(renderer.canLoad(milkPreset))
    }
}
