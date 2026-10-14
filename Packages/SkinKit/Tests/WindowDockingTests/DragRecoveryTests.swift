import CoreGraphics
import Testing
@testable import WindowDocking

private func b(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> Box {
    Box(x: x, y: y, width: width, height: height)
}

private func w(_ kind: WindowKind, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat = 550, _ height: CGFloat = 232) -> DockedWindow {
    DockedWindow(kind: kind, box: b(x, y, width, height))
}

private let primary = b(0, 25, 1440, 875)
private let rightSame = b(1440, 25, 1920, 875)
private let rightShorter = b(1440, 25, 1920, 775)
private let rightHigher = b(1440, -155, 1920, 1055)
private let strips: [WindowKind: CGFloat] = [.main: 28, .equalizer: 28, .playlist: 40]

struct DragRecoveryTests {
    @Test func nearestScreenPrefersTheLargestIntersectionThenTheSmallestGap() {
        let screens = [primary, rightShorter]
        #expect(ScreenSelection.nearest(to: b(1300, 100, 550, 232), among: screens, fallback: primary) == rightShorter)
        #expect(ScreenSelection.nearest(to: b(2000, 830, 550, 232), among: screens, fallback: primary) == rightShorter)
        #expect(ScreenSelection.nearest(to: b(-700, 100, 550, 232), among: screens, fallback: rightShorter) == primary)
        #expect(ScreenSelection.nearest(to: b(0, 0, 10, 10), among: [], fallback: rightHigher) == rightHigher)
    }

    @Test func grabbableNeedsTheFullStripHeightOnOneScreen() {
        let on = [primary]
        #expect(LayoutRules.isGrabbable(b(100, 25, 550, 232), titleBarHeight: 28, on: on))
        #expect(!LayoutRules.isGrabbable(b(100, 20, 550, 232), titleBarHeight: 28, on: on))
        #expect(LayoutRules.isGrabbable(b(100, 850, 550, 232), titleBarHeight: 28, on: on))
        #expect(LayoutRules.isGrabbable(b(100, 100, 40, 40), titleBarHeight: 28, on: on))
        #expect(LayoutRules.isGrabbable(b(100, 25, 550, 232), titleBarHeight: 0, on: on))
        #expect(!LayoutRules.isGrabbable(b(100, 20, 550, 232), titleBarHeight: 0, on: on))
    }

    @Test func grabbableAcceptsAStraddlingStrip() {
        let same = [primary, rightSame]
        #expect(LayoutRules.isGrabbable(b(1165, 100, 550, 232), titleBarHeight: 28, on: same))
        #expect(LayoutRules.isGrabbable(b(1410, 100, 550, 232), titleBarHeight: 28, on: same))
        let higher = [primary, rightHigher]
        #expect(LayoutRules.isGrabbable(b(1410, 0, 550, 232), titleBarHeight: 28, on: higher))
        #expect(!LayoutRules.isGrabbable(b(910, 0, 550, 232), titleBarHeight: 28, on: higher))
    }

    @Test func dragRecoveryLeavesGrabbableGroupsAlone() {
        let screens = [primary, rightShorter]
        func recover(_ moving: [DockedWindow]) -> Offset? {
            LayoutRules.dragRecovery(moving: moving, titleBarHeights: strips, screens: screens, primary: primary)
        }
        #expect(recover([w(.main, 300, 100), w(.equalizer, 300, 332)]) == nil)
        #expect(recover([w(.main, 300, 850)]) == nil)
        #expect(recover([w(.main, 1165, 100)]) == nil)
        #expect(recover([w(.main, 1000, 100), w(.equalizer, 1550, 100)]) == nil)
        #expect(recover([]) == nil)
    }

    @Test func dragRecoveryLiftsAStripOutOfTheGapBelowAShorterDisplay() {
        let screens = [primary, rightShorter]
        let moving = [w(.main, 2000, 790)]
        let shift = LayoutRules.dragRecovery(moving: moving, titleBarHeights: strips, screens: screens, primary: primary)
        #expect(shift == Offset(x: 0, y: -18))
        let moved = b(2000, 790 + (shift?.y ?? 0), 550, 232)
        #expect(LayoutRules.isGrabbable(moved, titleBarHeight: 28, on: screens))
    }

    @Test func dragRecoveryInAGapGoesToTheNearestScreen() {
        let shift = LayoutRules.dragRecovery(
            moving: [w(.main, 2000, 830)], titleBarHeights: strips, screens: [primary, rightShorter], primary: primary)
        #expect(shift == Offset(x: 0, y: -58))
    }

    @Test func dragRecoveryPullsAStripFromUnderTheMenuBar() {
        let screens = [primary, rightHigher]
        #expect(
            LayoutRules.dragRecovery(moving: [w(.main, 300, 5)], titleBarHeights: strips, screens: screens, primary: primary)
                == Offset(x: 0, y: 20))
        #expect(
            LayoutRules.dragRecovery(moving: [w(.main, 1600, 5)], titleBarHeights: strips, screens: screens, primary: primary)
                == nil)
    }

    @Test func dragRecoveryMovesADockedGroupAsOne() {
        let shift = LayoutRules.dragRecovery(
            moving: [w(.main, 1700, 560), w(.equalizer, 1700, 792)], titleBarHeights: strips,
            screens: [primary, rightShorter], primary: primary)
        #expect(shift == Offset(x: 0, y: -20))
    }

    @Test func dragRecoveryRevealsTheTopLeftCornerWhenTheGroupCannotFit() {
        let screens = [primary, rightShorter]
        let moving = [w(.main, 2000, 820), w(.playlist, 2000, 1052, 550, 900)]
        let shift = LayoutRules.dragRecovery(moving: moving, titleBarHeights: strips, screens: screens, primary: primary)
        #expect(shift == Offset(x: 0, y: -48))
        let moved = b(2000, 820 + (shift?.y ?? 0), 550, 232)
        #expect(LayoutRules.isGrabbable(moved, titleBarHeight: 28, on: screens))
    }

    @Test func dragLimitsSpanEveryScreenWhenThereAreSeveral() {
        #expect(DragLimits(screens: [primary, rightHigher], primary: primary, titleBarHeights: strips).bounds == b(0, -155, 3360, 1055))
        #expect(DragLimits(screens: [rightShorter], primary: primary, titleBarHeights: strips).bounds == rightShorter)
        #expect(DragLimits(screens: [], primary: primary, titleBarHeights: strips).bounds == primary)
    }

    @Test func dragSessionPositionsKeepTheStripOnAScreen() {
        let limits = DragLimits(screens: [primary, rightHigher], primary: primary, titleBarHeights: strips)
        let session = DragSession(dragging: .main, windows: [w(.main, 300, 100)])
        #expect(session.positions(forMouseDelta: Offset(x: 0, y: -90), limits: limits)[.main] == Offset(x: 300, y: 25))
        #expect(session.positions(forMouseDelta: Offset(x: 1300, y: -90), limits: limits)[.main] == Offset(x: 1600, y: 10))
        #expect(session.positions(forMouseDelta: .zero, limits: limits)[.main] == Offset(x: 300, y: 100))
    }

    @Test func dragSessionIsContinuousAtAGapEdge() {
        let tall = b(1440, 25, 2560, 1415)
        let limits = DragLimits(screens: [primary, tall], primary: primary, titleBarHeights: strips)
        let session = DragSession(dragging: .main, windows: [w(.main, 300, 600)])
        for dy: CGFloat in [272, 273, 300, 340] {
            #expect(session.positions(forMouseDelta: Offset(x: 0, y: dy), limits: limits)[.main] == Offset(x: 300, y: 872))
        }
        // Shaded main (all strip) sliding right along the bottom of the primary beside a shorter display.
        let shortLimits = DragLimits(screens: [primary, rightShorter], primary: primary, titleBarHeights: strips)
        let shaded = DragSession(dragging: .main, windows: [w(.main, 890, 872, 550, 28)])
        #expect(shaded.positions(forMouseDelta: Offset(x: 500, y: 0), limits: shortLimits)[.main] == Offset(x: 1390, y: 872))
        for dx: CGFloat in [501, 502, 600] {
            #expect(shaded.positions(forMouseDelta: Offset(x: dx, y: 0), limits: shortLimits)[.main] == Offset(x: 1390, y: 872))
        }
    }
}
