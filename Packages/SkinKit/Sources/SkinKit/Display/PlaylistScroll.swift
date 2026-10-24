import CoreGraphics
import Foundation

/// Webamp's playlist scroll rules (selectors.ts getScrollOffset / getPlaylistScrollPosition, actionCreators
/// scrollNTracks / scrollPlaylistByDelta). `position` is Webamp's 0...100 percent of the overflow.
public enum PlaylistScroll {
    /// JS `Math.round`: halves go up.
    private static func jsRound(_ value: Double) -> Int { Int((value + 0.5).rounded(.down)) }

    /// `max(0, count - visibleRows)`: how many rows are out of view.
    public static func overflow(count: Int, visibleRows: Int) -> Int { max(0, count - visibleRows) }

    /// `percentToIndex(position / 100, overflow + 1)` = `round(p * overflow)`: the first visible row.
    public static func offset(position: Double, count: Int, visibleRows: Int) -> Int {
        let overflow = overflow(count: count, visibleRows: visibleRows)
        return min(max(jsRound(position / 100 * Double(overflow)), 0), overflow)
    }

    /// The scroll handle's 0...1 value: the position snapped to whole rows; 0 when nothing overflows.
    public static func handleValue(position: Double, count: Int, visibleRows: Int) -> Double {
        let overflow = overflow(count: count, visibleRows: visibleRows)
        guard overflow > 0 else { return 0 }
        let snapped = Double(jsRound(Double(overflow) * position / 100)) / Double(overflow)
        return Double(jsRound(snapped * 100)) / 100
    }

    /// `scrollNTracks`: move by `rows` from the current offset, clamped; the position it gives, 0...100.
    public static func position(scrollingBy rows: Int, position: Double, count: Int, visibleRows: Int) -> Double {
        let overflow = overflow(count: count, visibleRows: visibleRows)
        guard overflow > 0 else { return 0 }
        let current = offset(position: position, count: count, visibleRows: visibleRows)
        return min(max(Double(current + rows) / Double(overflow), 0), 1) * 100
    }

    /// `scrollPlaylistByDelta`: `delta` (skin pixels, wheel direction) as a percent of the whole list's height.
    public static func position(wheelDelta: CGFloat, position: Double, count: Int) -> Double {
        guard count > 0 else { return 0 }
        let percent = Double(wheelDelta) / (Double(count) * Double(PlaylistLayout.rowHeight)) * 100
        return min(max(position + percent, 0), 100)
    }

    /// The rows in view.
    public static func visibleRange(position: Double, count: Int, visibleRows: Int) -> Range<Int> {
        let start = offset(position: position, count: count, visibleRows: visibleRows)
        return start..<min(start + visibleRows, count)
    }

    /// The position (0...100) that brings row `index` into view with the least scrolling: unchanged when it is already
    /// visible, else it becomes the first visible row (when above) or the last (when below). 0 when nothing overflows
    /// (#0175).
    public static func position(revealing index: Int, position: Double, count: Int, visibleRows: Int) -> Double {
        guard count > 0 else { return 0 }
        let overflow = overflow(count: count, visibleRows: visibleRows)
        guard overflow > 0 else { return 0 }
        let index = min(max(index, 0), count - 1)
        let start = offset(position: position, count: count, visibleRows: visibleRows)
        if (start..<start + visibleRows).contains(index) { return position }
        let target = min(max(index < start ? index : index - visibleRows + 1, 0), overflow)
        return Double(target) / Double(overflow) * 100
    }
}
