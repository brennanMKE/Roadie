import CoreGraphics

/// The layout rules of Webamp's `actionCreators/windows.ts`: the default stack, and recovery of windows that ended up
/// off screen.
public enum LayoutRules {
    public enum Recovery: Equatable, Sendable {
        /// Move every window by this offset.
        case shift(Offset)
        /// Give up: stack the windows and centre them.
        case reset
    }

    /// Stacks the windows at x 0 in `order`, each directly under the previous (selectors.ts 612-623), then centres the
    /// group in `bounds` with Webamp's `ceil` (actionCreators/windows.ts 144-178). Returns each window's top-left.
    public static func stackedAndCentered(
        sizes: [WindowKind: CGSize], order: [WindowKind], in bounds: Box
    ) -> [WindowKind: Offset] {
        var positions: [WindowKind: Offset] = [:]
        var y: CGFloat = 0
        var width: CGFloat = 0
        for kind in order {
            guard let size = sizes[kind] else { continue }
            positions[kind] = Offset(x: 0, y: y)
            y += size.height
            width = max(width, size.width)
        }
        let moveX = (bounds.x + (bounds.width - width) / 2).rounded(.up)
        let moveY = (bounds.y + (bounds.height - y) / 2).rounded(.up)
        return positions.mapValues { Offset(x: $0.x + moveX, y: $0.y + moveY) }
    }

    /// actionCreators/windows.ts 250-315, generalized to several screens. nil = nothing to do.
    public static func recovery(windows: [DockedWindow], screens: [Box], primary: Box) -> Recovery? {
        guard let bounding = SnapUtils.boundingBoxOrNil(windows.map(\.box)) else { return nil }
        let screenList = screens.isEmpty ? [primary] : screens
        func contains(_ outer: Box, _ inner: Box) -> Bool {
            inner.left >= outer.left && inner.top >= outer.top && inner.right <= outer.right && inner.bottom <= outer.bottom
        }
        if screenList.contains(where: { contains($0, bounding) }) { return nil }
        // A group straddling two displays is fine.
        if windows.allSatisfy({ window in screenList.contains(where: { contains($0, window.box) }) }) { return nil }

        let chosen = ScreenSelection.bounds(for: bounding, among: screenList, fallback: primary)
        guard bounding.width <= chosen.width, bounding.height <= chosen.height else { return .reset }
        return .shift(shift(toFit: bounding, in: chosen))
    }

    /// Webamp's constant shift (actionCreators/windows.ts 283-306): `top <= bounds.top` moves down, else
    /// `bottom > bounds.bottom` moves up; the same for x. Shared by `recovery` and `dragRecovery`.
    static func shift(toFit bounding: Box, in bounds: Box) -> Offset {
        var moveX: CGFloat = 0
        var moveY: CGFloat = 0
        if bounding.top <= bounds.top {
            moveY = bounds.top - bounding.top
        } else if bounding.bottom > bounds.bottom {
            moveY = bounds.bottom - bounding.bottom
        }
        if bounding.left <= bounds.left {
            moveX = bounds.left - bounding.left
        } else if bounding.right > bounds.right {
            moveX = bounds.right - bounding.right
        }
        return Offset(x: moveX, y: moveY)
    }

    /// How much of a drag strip must show side to side for the window to count as grabbable (all of it when narrower).
    public static let minimumGrabWidth: CGFloat = 50

    /// True when some screen's work area shows the full height of the window's top `titleBarHeight` points over at least
    /// `minimumGrabWidth` of its width. A strip partly under the menu bar, the Dock or in a gap between displays is not.
    public static func isGrabbable(_ box: Box, titleBarHeight: CGFloat, on screens: [Box]) -> Bool {
        let strip = Box(x: box.x, y: box.y, width: box.width, height: min(titleBarHeight, box.height))
        let needed = min(strip.width, minimumGrabWidth)
        return screens.contains { screen in
            let width = min(strip.right, screen.right) - max(strip.left, screen.left)
            let height = min(strip.bottom, screen.bottom) - max(strip.top, screen.top)
            return height >= strip.height && width >= needed
        }
    }

    /// The smallest move that makes `strip` (a window's drag strip) grabbable on `screen`: vertically down to the top or up
    /// to the bottom of the work area, horizontally just far enough that `minimumGrabWidth` (or all of a narrower strip)
    /// shows. Zero on an axis that already satisfies it.
    static func gripShift(for strip: Box, on screen: Box) -> Offset {
        var moveY: CGFloat = 0
        if strip.top < screen.top {
            moveY = screen.top - strip.top
        } else if strip.bottom > screen.bottom {
            moveY = screen.bottom - strip.bottom
        }
        let needed = min(strip.width, minimumGrabWidth)
        var moveX: CGFloat = 0
        if strip.left < screen.left && strip.right - screen.left < needed {
            moveX = needed - (strip.right - screen.left)
        } else if strip.right > screen.right && screen.right - strip.left < needed {
            moveX = -(needed - (screen.right - strip.left))
        }
        return Offset(x: moveX, y: moveY)
    }

    /// After (and during) a drag. nil when every window in `moving` is grabbable. Otherwise one offset for the whole
    /// group: the smallest move that makes each failing window's strip grabbable on the nearest screen (per axis the
    /// largest requirement), so the result is continuous in the window position. When the requirements conflict or the
    /// group is larger than that screen, only the topmost window's strip is guaranteed (ties to the first window).
    /// Never `.reset`.
    public static func dragRecovery(
        moving: [DockedWindow], titleBarHeights: [WindowKind: CGFloat], screens: [Box], primary: Box
    ) -> Offset? {
        let screenList = screens.isEmpty ? [primary] : screens
        func strip(_ window: DockedWindow) -> Box {
            let box = window.box
            return Box(x: box.x, y: box.y, width: box.width, height: min(titleBarHeights[window.kind] ?? 0, box.height))
        }
        let failing = moving.filter { !isGrabbable($0.box, titleBarHeight: titleBarHeights[$0.kind] ?? 0, on: screenList) }
        if failing.isEmpty { return nil }
        guard let bounding = SnapUtils.boundingBoxOrNil(moving.map(\.box)) else { return nil }
        let chosen = ScreenSelection.nearest(to: bounding, among: screenList, fallback: primary)
        let needs = failing.map { gripShift(for: strip($0), on: chosen) }
        let fits = bounding.width <= chosen.width && bounding.height <= chosen.height
        let conflictX = needs.contains { $0.x > 0 } && needs.contains { $0.x < 0 }
        let conflictY = needs.contains { $0.y > 0 } && needs.contains { $0.y < 0 }
        if fits && !conflictX && !conflictY {
            func largest(_ values: [CGFloat]) -> CGFloat { values.max(by: { abs($0) < abs($1) }) ?? 0 }
            return Offset(x: largest(needs.map(\.x)), y: largest(needs.map(\.y)))
        }
        var topmost = moving[0]
        for window in moving where window.box.top < topmost.box.top { topmost = window }
        return gripShift(for: strip(topmost), on: chosen)
    }
}
