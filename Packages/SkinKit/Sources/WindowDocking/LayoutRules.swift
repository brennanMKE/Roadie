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
        var moveX: CGFloat = 0
        var moveY: CGFloat = 0
        if bounding.top <= chosen.top {
            moveY = chosen.top - bounding.top
        } else if bounding.bottom > chosen.bottom {
            moveY = chosen.bottom - bounding.bottom
        }
        if bounding.left <= chosen.left {
            moveX = chosen.left - bounding.left
        } else if bounding.right > chosen.right {
            moveX = chosen.right - bounding.right
        }
        return .shift(Offset(x: moveX, y: moveY))
    }
}
