import CoreGraphics
import Testing
@testable import WindowDocking

private func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 100, _ h: CGFloat = 100) -> Box {
    Box(x: x, y: y, width: w, height: h)
}

struct SnapUtilsTests {
    @Test func boxSides() {
        let b = box(10, 15, 50, 100)
        #expect(b.top == 15 && b.bottom == 115 && b.left == 10 && b.right == 60)
    }

    @Test func nearIsStrictlyInsideSnapDistance() {
        #expect(SnapUtils.near(10, 20))
        #expect(!SnapUtils.near(10, 30))
        #expect(!SnapUtils.near(0, 15))
    }

    @Test func overlapCountsSnapDistance() {
        #expect(SnapUtils.overlapY(box(0, 10, 10, 50), box(0, 40, 10, 50)))
        #expect(SnapUtils.overlapY(box(0, 10, 10, 50), box(0, 70, 10, 50)))
        #expect(!SnapUtils.overlapY(box(0, 10, 10, 50), box(0, 80, 10, 50)))
        #expect(SnapUtils.overlapX(box(10, 0, 50, 10), box(70, 0, 50, 10)))
        #expect(!SnapUtils.overlapX(box(10, 0, 50, 10), box(80, 0, 50, 10)))
    }

    @Test func snapFarApartSnapsNothing() {
        #expect(SnapUtils.snap(box(10, 10), to: box(200, 200)) == SnapResult(x: nil, y: nil))
    }

    @Test func snapSidesToSides() {
        #expect(SnapUtils.snap(box(120, 30), to: box(10, 10)) == SnapResult(x: 110, y: nil))
        #expect(SnapUtils.snap(box(20, 30), to: box(130, 10)).x == 30)
        #expect(SnapUtils.snap(box(30, 120), to: box(10, 10)).y == 110)
        #expect(SnapUtils.snap(box(30, 10), to: box(10, 120)).y == 20)
    }

    @Test func snapNeedsOverlapOnTheOtherAxis() {
        #expect(SnapUtils.snap(box(10, 10), to: box(110, 150)) == SnapResult())
    }

    @Test func snapBothAxesAtCorners() {
        #expect(SnapUtils.snap(box(10, 10), to: box(120, 120)) == SnapResult(x: 20, y: 20))
        #expect(SnapUtils.snap(box(110, 110), to: box(0, 0)) == SnapResult(x: 100, y: 100))
    }

    @Test func snapAlignsLikeEdges() {
        #expect(SnapUtils.snap(box(10, 10), to: box(15, 110)) == SnapResult(x: 15, y: 10))
        #expect(SnapUtils.snap(box(10, 10), to: box(110, 15)) == SnapResult(x: 10, y: 15))
    }

    @Test func snapPushesASlightOverlapOut() {
        #expect(SnapUtils.snap(box(0, 90), to: box(0, 0)) == SnapResult(x: 0, y: 100))
    }

    @Test func snapWithinEdges() {
        let screen = box(0, 0, 1000, 1000)
        #expect(SnapUtils.snapWithin(box(120, 10, 100, 100), in: screen) == SnapResult(x: nil, y: 0))
        #expect(SnapUtils.snapWithin(box(120, 910, 100, 100), in: screen) == SnapResult(x: nil, y: 900))
        #expect(SnapUtils.snapWithin(box(910, 120, 100, 100), in: screen) == SnapResult(x: 900, y: nil))
        #expect(SnapUtils.snapWithin(box(10, 120, 100, 100), in: screen) == SnapResult(x: 0, y: nil))
        #expect(SnapUtils.snapWithin(box(10, 10, 100, 100), in: screen) == SnapResult(x: 0, y: 0))
    }

    @Test func snapWithinOffsetBounds() {
        let bounds = box(1440, 0, 1920, 1055)
        #expect(SnapUtils.snapWithin(box(1450, 500, 275, 232), in: bounds).x == 1440)
        #expect(SnapUtils.snapWithin(box(3100, 500, 275, 232), in: bounds).x == 3085)
    }

    @Test func snapDiffIsZeroWhereNothingSnapped() {
        #expect(SnapUtils.snapDiff(box(120, 30), box(10, 10)) == Offset(x: -10, y: 0))
        #expect(SnapUtils.snapDiff(box(10, 10), box(110, 150)) == .zero)
        #expect(SnapUtils.snapDiff(box(10, 10), box(120, 120)) == Offset(x: 10, y: 10))
    }

    @Test func snapDiffManyToManyKeepsTheFirstNonZeroAxis() {
        let a = box(103, 500, 10, 10)
        // Two stationary boxes to the right offering x diffs of 7 (left edge at 110) then 3 (at 106).
        #expect(SnapUtils.snapDiffManyToMany([a], [box(100, 500, 10, 10), box(96, 500, 10, 10)]).x == 7)
        // A negative first diff is kept although the loop keeps scanning.
        let negative = SnapUtils.snapDiffManyToMany([box(104, 500, 10, 10)], [box(90, 500, 10, 10), box(95, 500, 10, 10)])
        #expect(negative.x == -4)
    }

    @Test func applyMultipleDiffsTakesSmallestNonZeroPerAxis() {
        let initial = Offset(x: 10, y: 10)
        #expect(SnapUtils.applyMultipleDiffs(initial, Offset(x: 5, y: 0), Offset(x: 3, y: 7)) == Offset(x: 13, y: 17))
        #expect(SnapUtils.applyMultipleDiffs(.zero, Offset(x: 0, y: 0), Offset(x: -20, y: 0), Offset(x: 5, y: 0)).x == -20)
    }

    @Test func boundingBoxOfBoxes() {
        let one = box(10, 10)
        #expect(SnapUtils.boundingBox([one]) == one)
        #expect(SnapUtils.boundingBox([box(0, 0, 500, 500), box(10, 10)]) == box(0, 0, 500, 500))
        #expect(SnapUtils.boundingBox([box(10, 10), box(120, 220)]) == box(10, 10, 210, 310))
        #expect(SnapUtils.boundingBox([box(10, 10), box(120, 220), box(3, 220)]) == box(3, 10, 217, 310))
        #expect(SnapUtils.boundingBoxOrNil([]) == nil)
    }

    @Test func traceConnectionFollowsAbuttingWindows() {
        func windows(playlistY: CGFloat) -> [DockedWindow] {
            [
                DockedWindow(kind: .main, box: box(0, 0, 275, 116)),
                DockedWindow(kind: .equalizer, box: box(0, 116, 275, 116)),
                DockedWindow(kind: .playlist, box: box(0, playlistY, 275, 232)),
            ]
        }
        func group(_ list: [DockedWindow]) -> Set<WindowKind> { SnapUtils.traceConnection(list, from: list[0]) }
        #expect(group(windows(playlistY: 232)) == [.main, .equalizer, .playlist])
        #expect(group(windows(playlistY: 400)) == [.main, .equalizer])
        #expect(group(windows(playlistY: 246)) == [.main, .equalizer, .playlist])
    }
}
