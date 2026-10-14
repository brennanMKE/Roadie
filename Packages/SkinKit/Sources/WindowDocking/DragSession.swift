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
}
