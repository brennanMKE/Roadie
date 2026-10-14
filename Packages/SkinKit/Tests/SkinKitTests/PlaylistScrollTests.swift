import Testing
@testable import SkinKit

@Suite struct PlaylistScrollTests {
    @Test func nothingOverflowsNothingScrolls() {
        for position in [0.0, 50, 100] {
            #expect(PlaylistScroll.offset(position: position, count: 3, visibleRows: 4) == 0)
            #expect(PlaylistScroll.handleValue(position: position, count: 3, visibleRows: 4) == 0)
        }
        #expect(PlaylistScroll.visibleRange(position: 50, count: 3, visibleRows: 4) == 0..<3)
        #expect(PlaylistScroll.position(scrollingBy: 4, position: 0, count: 3, visibleRows: 4) == 0)
    }

    @Test func offsetMapsPercentToOverflowRows() {
        #expect(PlaylistScroll.offset(position: 0, count: 10, visibleRows: 4) == 0)
        #expect(PlaylistScroll.offset(position: 50, count: 10, visibleRows: 4) == 3)
        #expect(PlaylistScroll.offset(position: 100, count: 10, visibleRows: 4) == 6)
        #expect(PlaylistScroll.visibleRange(position: 50, count: 10, visibleRows: 4) == 3..<7)
        #expect(PlaylistScroll.visibleRange(position: 100, count: 10, visibleRows: 4) == 6..<10)
    }

    @Test func scrollingByFourClampsAtTheEnds() {
        let a = PlaylistScroll.position(scrollingBy: 4, position: 0, count: 10, visibleRows: 4)
        #expect(abs(a - 66.6667) < 0.001)
        #expect(PlaylistScroll.offset(position: a, count: 10, visibleRows: 4) == 4)
        #expect(PlaylistScroll.position(scrollingBy: 4, position: a, count: 10, visibleRows: 4) == 100)
        let c = PlaylistScroll.position(scrollingBy: -4, position: 100, count: 10, visibleRows: 4)
        #expect(abs(c - 33.3333) < 0.001)
    }

    @Test func wheelDeltaIsAPercentOfTheTotalHeight() {
        #expect(abs(PlaylistScroll.position(wheelDelta: 13, position: 50, count: 10) - 60) < 1e-9)
        #expect(PlaylistScroll.position(wheelDelta: 1000, position: 50, count: 10) == 100)
        #expect(PlaylistScroll.position(wheelDelta: -1000, position: 50, count: 10) == 0)
        #expect(PlaylistScroll.position(wheelDelta: 5, position: 50, count: 0) == 0)
    }

    @Test func handleValueSnapsToRows() {
        let v = PlaylistScroll.handleValue(position: 40, count: 10, visibleRows: 4)
        #expect(abs(v - 0.33) < 1e-9)   // round(2.4) / 6 = 0.333, rounded to a whole percent
        #expect(PlaylistScroll.handleValue(position: 100, count: 10, visibleRows: 4) == 1)
    }
}
