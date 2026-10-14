import CoreGraphics

/// One title-bar drag, as a value: a port of `useHandleMouseDown` (Webamp `WindowManager.tsx` 29-156). The main window
/// brings the windows docked to it; any other window moves alone. Positions are always computed from the positions at
/// mouse-down plus the cumulative mouse delta, so leaving the snap range follows the cursor exactly.
public struct DragSession: Sendable {
    public let moving: [DockedWindow]
    public let stationary: [DockedWindow]
    public let boundingBox: Box

    /// `windows` = the visible skinned windows.
    public init(dragging kind: WindowKind, windows: [DockedWindow]) {
        var movingKinds: Set<WindowKind> = [kind]
        if kind == .main, let target = windows.first(where: { $0.kind == .main }) {
            movingKinds = SnapUtils.traceConnection(windows, from: target)
            movingKinds.insert(.main)
        }
        moving = windows.filter { movingKinds.contains($0.kind) }
        stationary = windows.filter { !movingKinds.contains($0.kind) }
        boundingBox = SnapUtils.boundingBoxOrNil(moving.map(\.box)) ?? Box(x: 0, y: 0, width: 0, height: 0)
    }

    /// What the whole group moves by for a cumulative mouse delta since mouse-down, snapped to the stationary windows
    /// and kept within `bounds`.
    public func groupDiff(forMouseDelta delta: Offset, within bounds: Box) -> Offset {
        guard !moving.isEmpty else { return .zero }
        let proposedBoxes = moving.map { window in
            Box(x: window.box.x + delta.x, y: window.box.y + delta.y, width: window.box.width, height: window.box.height)
        }
        let proposedBounding = Box(
            x: boundingBox.x + delta.x, y: boundingBox.y + delta.y, width: boundingBox.width, height: boundingBox.height)
        let snap = SnapUtils.snapDiffManyToMany(proposedBoxes, stationary.map(\.box))
        let within = SnapUtils.snapWithinDiff(proposedBounding, in: bounds)
        return SnapUtils.applyMultipleDiffs(delta, snap, within)
    }

    /// The top-left of every moving window.
    public func positions(forMouseDelta delta: Offset, within bounds: Box) -> [WindowKind: Offset] {
        let diff = groupDiff(forMouseDelta: delta, within: bounds)
        var result: [WindowKind: Offset] = [:]
        for window in moving {
            result[window.kind] = Offset(x: window.box.x + diff.x, y: window.box.y + diff.y)
        }
        return result
    }

    /// `positions(forMouseDelta:within:)` followed by `LayoutRules.dragRecovery` on the result, applied to every moving
    /// window, so no window can be left in a gap between displays or under a menu bar even mid-drag.
    public func positions(forMouseDelta delta: Offset, limits: DragLimits) -> [WindowKind: Offset] {
        var result = positions(forMouseDelta: delta, within: limits.bounds)
        let proposed = moving.compactMap { window -> DockedWindow? in
            guard let origin = result[window.kind] else { return nil }
            return DockedWindow(kind: window.kind, box: Box(x: origin.x, y: origin.y, width: window.box.width, height: window.box.height))
        }
        if let shift = LayoutRules.dragRecovery(
            moving: proposed, titleBarHeights: limits.titleBarHeights, screens: limits.screens, primary: limits.primary)
        {
            for (kind, origin) in result { result[kind] = Offset(x: origin.x + shift.x, y: origin.y + shift.y) }
        }
        return result
    }
}

/// What limits a drag: where the group's bounding box may go (`snapWithin`), and the screens its strips must stay on.
public struct DragLimits: Sendable {
    public var bounds: Box
    public var screens: [Box]
    public var primary: Box
    public var titleBarHeights: [WindowKind: CGFloat]

    /// `bounds` is the one screen's work area, or with several displays the box they span (#0030: a per-screen bound
    /// would trap a window on its display); no screens gives `primary`.
    public init(screens: [Box], primary: Box, titleBarHeights: [WindowKind: CGFloat]) {
        self.screens = screens
        self.primary = primary
        self.titleBarHeights = titleBarHeights
        if screens.count > 1 {
            bounds = SnapUtils.boundingBox(screens)
        } else {
            bounds = screens.first ?? primary
        }
    }
}
