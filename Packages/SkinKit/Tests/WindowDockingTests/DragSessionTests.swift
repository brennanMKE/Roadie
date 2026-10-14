import CoreGraphics
import Testing
@testable import WindowDocking

private func w(_ kind: WindowKind, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat = 275, _ height: CGFloat = 116) -> DockedWindow {
    DockedWindow(kind: kind, box: Box(x: x, y: y, width: width, height: height))
}

private let screen = Box(x: -5000, y: -5000, width: 10000, height: 10000)

struct DragSessionTests {
    @Test func draggingMainMovesTheDockedGroup() {
        let session = DragSession(
            dragging: .main, windows: [w(.main, 100, 100), w(.equalizer, 100, 216), w(.playlist, 600, 100, 275, 232)])
        let positions = session.positions(forMouseDelta: Offset(x: 50, y: 0), within: screen)
        #expect(positions[.main] == Offset(x: 150, y: 100))
        #expect(positions[.equalizer] == Offset(x: 150, y: 216))
        #expect(positions[.playlist] == nil)
    }

    @Test func draggingAChildMovesOnlyItself() {
        let session = DragSession(
            dragging: .equalizer, windows: [w(.main, 100, 100), w(.equalizer, 100, 216), w(.playlist, 600, 100, 275, 232)])
        #expect(session.moving.map(\.kind) == [.equalizer])
        #expect(session.stationary.map(\.kind) == [.main, .playlist])
    }

    @Test func groupSnapsToAStationaryEdgeAsOne() {
        let session = DragSession(
            dragging: .main, windows: [w(.main, 100, 100), w(.equalizer, 100, 216), w(.playlist, 600, 100, 275, 232)])
        let positions = session.positions(forMouseDelta: Offset(x: 220, y: 0), within: screen)
        // Main's right edge would be 595; the playlist's left is 600, so main snaps to x 325.
        #expect(positions[.main]?.x == 325)
        #expect(positions[.equalizer]?.x == 325)
    }

    @Test func positionsFollowTheCursorAfterLeavingSnapRange() {
        let session = DragSession(
            dragging: .main, windows: [w(.main, 100, 100), w(.equalizer, 100, 216), w(.playlist, 600, 100, 275, 232)])
        #expect(session.positions(forMouseDelta: Offset(x: 220, y: 0), within: screen)[.main]?.x == 325)
        #expect(session.positions(forMouseDelta: Offset(x: 260, y: 0), within: screen)[.main]?.x == 360)
    }

    @Test func groupSnapsWithinBounds() {
        let session = DragSession(dragging: .main, windows: [w(.main, 100, 100), w(.equalizer, 100, 216)])
        let bounds = Box(x: 0, y: 25, width: 1440, height: 875)
        let positions = session.positions(forMouseDelta: Offset(x: 0, y: -70), within: bounds)
        #expect(positions[.main]?.y == 25)
        #expect(positions[.equalizer]?.y == 141)
    }

    @Test func hiddenWindowsDoNotParticipate() {
        let session = DragSession(dragging: .main, windows: [w(.main, 100, 100)])
        let positions = session.positions(forMouseDelta: Offset(x: 220, y: 0), within: screen)
        #expect(positions[.main]?.x == 320)
    }
}
