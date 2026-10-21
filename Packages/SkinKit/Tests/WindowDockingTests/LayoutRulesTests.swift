import CoreGraphics
import Testing
@testable import WindowDocking

private func w(_ kind: WindowKind, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat = 550, _ height: CGFloat = 232) -> DockedWindow {
    DockedWindow(kind: kind, box: Box(x: x, y: y, width: width, height: height))
}

struct LayoutRulesTests {
    private let screenA = Box(x: 0, y: 0, width: 1440, height: 900)
    private let screenB = Box(x: 1440, y: 0, width: 1920, height: 1080)

    @Test func screenWithLargestIntersectionWins() {
        let box = Box(x: 1300, y: 100, width: 550, height: 232)
        #expect(ScreenSelection.bounds(for: box, among: [screenA, screenB], fallback: screenA) == screenB)
        #expect(ScreenSelection.bounds(for: Box(x: 1000, y: 100, width: 550, height: 232), among: [screenA, screenB], fallback: screenB) == screenA)
    }

    @Test func noIntersectionGivesTheFallback() {
        let far = Box(x: 9000, y: 9000, width: 10, height: 10)
        #expect(ScreenSelection.bounds(for: far, among: [screenA, screenB], fallback: screenB) == screenB)
    }

    @Test func stackedAndCenteredLayout() {
        let sizes: [WindowKind: CGSize] = [
            .main: CGSize(width: 550, height: 232), .equalizer: CGSize(width: 550, height: 232),
            .playlist: CGSize(width: 550, height: 464),
        ]
        let bounds = Box(x: 0, y: 25, width: 1440, height: 875)
        let positions = LayoutRules.stackedAndCentered(sizes: sizes, order: [.main, .equalizer, .playlist], in: bounds)
        #expect(positions[.main] == Offset(x: 445, y: -1))
        #expect(positions[.equalizer] == Offset(x: 445, y: 231))
        #expect(positions[.playlist] == Offset(x: 445, y: 463))
    }

    @Test func recoveryLeavesAVisibleLayoutAlone() {
        #expect(LayoutRules.recovery(windows: [w(.main, 100, 100), w(.equalizer, 100, 332)], screens: [screenA], primary: screenA) == nil)
        #expect(LayoutRules.recovery(windows: [], screens: [screenA], primary: screenA) == nil)
    }

    @Test func recoveryShiftsAGroupThatFits() {
        let topLeft = [w(.main, -40, -10), w(.equalizer, -40, 222)]
        #expect(LayoutRules.recovery(windows: topLeft, screens: [screenA], primary: screenA) == .shift(Offset(x: 40, y: 10)))
        let pastRight = [w(.main, 1000, 100)]
        #expect(LayoutRules.recovery(windows: pastRight, screens: [screenA], primary: screenA) == .shift(Offset(x: -110, y: 0)))
    }

    @Test func recoveryAcceptsAGroupSplitAcrossTwoScreens() {
        let split = [w(.main, 800, 100), w(.equalizer, 1500, 100)]
        #expect(LayoutRules.recovery(windows: split, screens: [screenA, screenB], primary: screenA) == nil)
    }

    @Test func recoveryResetsAGroupThatCannotFit() {
        let tall = [w(.main, -10, 0, 550, 232), w(.playlist, -10, 232, 550, 900)]
        #expect(LayoutRules.recovery(windows: tall, screens: [screenA], primary: screenA) == .reset)
    }

    // MARK: showPosition (#0120)

    private let eqSize = CGSize(width: 550, height: 232)
    private let mainBox = Box(x: 100, y: 100, width: 550, height: 232)

    private func show(saved: Offset?, below reference: Box? = nil, visible: [DockedWindow]? = nil,
                      size: CGSize? = nil, screens: [Box]? = nil) -> Offset {
        LayoutRules.showPosition(
            size: size ?? eqSize, saved: saved, below: reference ?? mainBox,
            visible: visible ?? [DockedWindow(kind: .main, box: mainBox)], titleBarHeight: 28,
            screens: screens ?? [screenA], primary: screenA)
    }

    @Test func showPositionKeepsAClearSavedSpot() {
        #expect(show(saved: Offset(x: 700, y: 400)) == Offset(x: 700, y: 400))
    }

    @Test func showPositionDocksUnderReferenceWhenSavedSpotCoversMain() {
        #expect(show(saved: Offset(x: 100, y: 100)) == Offset(x: 100, y: 332))
    }

    @Test func showPositionDocksUnderReferenceWhenSavedSpotPartlyOverlaps() {
        #expect(show(saved: Offset(x: 300, y: 250)) == Offset(x: 100, y: 332))
    }

    @Test func showPositionAllowsSharedEdges() {
        #expect(show(saved: Offset(x: 100, y: 332)) == Offset(x: 100, y: 332))
        #expect(show(saved: Offset(x: 650, y: 100)) == Offset(x: 650, y: 100))
    }

    @Test func showPositionDocksUnderReferenceWhenUnpositioned() {
        #expect(show(saved: nil) == Offset(x: 100, y: 332))
    }

    @Test func showPositionDocksPlaylistUnderEqualizer() {
        let eqBox = Box(x: 100, y: 332, width: 550, height: 232)
        let visible = [DockedWindow(kind: .main, box: mainBox), DockedWindow(kind: .equalizer, box: eqBox)]
        let result = show(saved: Offset(x: 100, y: 332), below: eqBox, visible: visible,
                          size: CGSize(width: 550, height: 464))
        #expect(result == Offset(x: 100, y: 564))
    }

    @Test func showPositionIgnoresSavedSpotOffEveryScreen() {
        #expect(show(saved: Offset(x: 5000, y: 5000)) == Offset(x: 100, y: 332))
    }

    @Test func showPositionNeverMovesTheReference() {
        let laptop = Box(x: 0, y: 25, width: 1280, height: 775)
        let lowMain = Box(x: 300, y: 650, width: 550, height: 232)
        let result = show(saved: Offset(x: 300, y: 650), below: lowMain,
                          visible: [DockedWindow(kind: .main, box: lowMain)], screens: [laptop])
        #expect(result == Offset(x: 300, y: 882))
        let box = Box(x: result.x, y: result.y, width: eqSize.width, height: eqSize.height)
        #expect(!LayoutRules.overlap(box, lowMain))
    }
}
