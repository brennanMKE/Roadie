import CoreGraphics
import Testing
@testable import WindowDocking

private func w(_ kind: WindowKind, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat = 275, _ height: CGFloat = 116) -> DockedWindow {
    DockedWindow(kind: kind, box: Box(x: x, y: y, width: width, height: height))
}

struct WindowGraphTests {
    @Test func graphOfStackedWindows() {
        let graph = WindowGraph.generate([w(.main, 0, 0), w(.equalizer, 0, 116), w(.playlist, 0, 232)])
        #expect(graph[.main] == Edges())
        #expect(graph[.equalizer] == Edges(below: .main))
        #expect(graph[.playlist] == Edges(below: .equalizer))
    }

    @Test func graphIgnoresGapsAndNonOverlappingTouches() {
        // A gap, a window beside (not below), and a touching corner only.
        #expect(WindowGraph.generate([w(.main, 0, 0), w(.equalizer, 0, 120)])[.equalizer] == Edges())
        #expect(WindowGraph.generate([w(.main, 0, 0), w(.equalizer, 300, 116)])[.equalizer] == Edges())
        #expect(WindowGraph.generate([w(.main, 0, 0), w(.equalizer, 276, 0)])[.equalizer] == Edges())
        #expect(WindowGraph.generate([w(.main, 0, 0), w(.equalizer, 275, 0)])[.equalizer] == Edges(right: .main))
    }

    @Test func graphRoundsFractionalFrames() {
        let graph = WindowGraph.generate([w(.main, 0.2, 0.4), w(.equalizer, 0.2, 116.4)])
        #expect(graph[.equalizer] == Edges(below: .main))
    }

    @Test func positionDiffShadeTop() {
        let graph: [WindowKind: Edges] = [.main: Edges(), .equalizer: Edges(below: .main), .playlist: Edges(below: .equalizer)]
        let diff = WindowGraph.positionDiff(graph: graph, sizeDiff: [.main: (0, -75), .equalizer: (0, 0), .playlist: (0, 0)])
        #expect(diff[.main] == .zero)
        #expect(diff[.equalizer] == Offset(x: 0, y: -75))
        #expect(diff[.playlist] == Offset(x: 0, y: -75))
    }

    @Test func positionDiffShadeMiddleMovesOnlyTheOneBelow() {
        let graph: [WindowKind: Edges] = [.main: Edges(), .equalizer: Edges(below: .main), .playlist: Edges(below: .equalizer)]
        let diff = WindowGraph.positionDiff(graph: graph, sizeDiff: [.main: (0, 0), .equalizer: (0, -75), .playlist: (0, 0)])
        #expect(diff[.equalizer] == .zero)
        #expect(diff[.playlist] == Offset(x: 0, y: -75))
    }

    @Test func positionDiffUnshadePropagates() {
        let graph: [WindowKind: Edges] = [.main: Edges(), .equalizer: Edges(below: .main), .playlist: Edges(below: .equalizer)]
        let diff = WindowGraph.positionDiff(graph: graph, sizeDiff: [.main: (0, 75), .equalizer: (0, 0), .playlist: (0, 0)])
        #expect(diff[.equalizer]?.y == 75 && diff[.playlist]?.y == 75)
    }

    @Test func positionDiffDoubleSizeAndHorizontalShade() {
        let stacked: [WindowKind: Edges] = [.main: Edges(), .equalizer: Edges(below: .main), .playlist: Edges(below: .equalizer)]
        let grow = (width: CGFloat(100), height: CGFloat(100))
        let diff = WindowGraph.positionDiff(graph: stacked, sizeDiff: [.main: grow, .equalizer: grow, .playlist: grow])
        #expect(diff[.equalizer] == Offset(x: 0, y: 100))
        #expect(diff[.playlist] == Offset(x: 0, y: 200))
        // A pure width change moves nothing when nothing is to the right.
        let wide = WindowGraph.positionDiff(graph: stacked, sizeDiff: [.main: (50, 0), .equalizer: (0, 0), .playlist: (0, 0)])
        #expect(wide.values.allSatisfy { $0 == .zero })
        // A window to the right moves by the width change.
        let side: [WindowKind: Edges] = [.main: Edges(), .equalizer: Edges(right: .main)]
        let moved = WindowGraph.positionDiff(graph: side, sizeDiff: [.main: (100, 0), .equalizer: (0, 0)])
        #expect(moved[.equalizer] == Offset(x: 100, y: 0))
    }
}
