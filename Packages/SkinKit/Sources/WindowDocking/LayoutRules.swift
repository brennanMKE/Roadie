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

    /// After (and during) a drag. nil when every window in `moving` is grabbable. Otherwise the offset that moves the
    /// group as one onto the nearest screen: the whole bounding box when it fits that screen, else its top-left corner
    /// (`minimumGrabWidth` wide, the topmost window's strip tall; ties to the first window). Never `.reset`.
    public static func dragRecovery(
        moving: [DockedWindow], titleBarHeights: [WindowKind: CGFloat], screens: [Box], primary: Box
    ) -> Offset? {
        let screenList = screens.isEmpty ? [primary] : screens
        func stripHeight(_ window: DockedWindow) -> CGFloat { titleBarHeights[window.kind] ?? 0 }
        if moving.allSatisfy({ isGrabbable($0.box, titleBarHeight: stripHeight($0), on: screenList) }) { return nil }
        guard let bounding = SnapUtils.boundingBoxOrNil(moving.map(\.box)) else { return nil }
        let chosen = ScreenSelection.nearest(to: bounding, among: screenList, fallback: primary)
        if bounding.width <= chosen.width && bounding.height <= chosen.height {
            return shift(toFit: bounding, in: chosen)
        }
        var topmost = moving[0]
        for window in moving where window.box.top < topmost.box.top { topmost = window }
        let corner = Box(
            x: bounding.x, y: bounding.y, width: min(bounding.width, minimumGrabWidth), height: stripHeight(topmost))
        return shift(toFit: corner, in: chosen)
    }
}
