import CoreGraphics

/// A port of Webamp's `snapUtils.ts`. Quirks are kept on purpose and noted where they are; a later "fix" should be a
/// deliberate divergence. Not ported: `snapToMany` and `applySnap`, which Webamp's `WindowManager` does not use.
public enum SnapUtils {
    /// 15 points, unscaled (snapUtils.ts 3): the window's point size already includes the scale.
    public static let snapDistance: CGFloat = 15

    /// Strict `<` (snapUtils.ts 10).
    public static func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < snapDistance }

    /// `<=` plus the snap distance (snapUtils.ts 13-16): boxes that are close but not touching still overlap.
    public static func overlapX(_ a: Box, _ b: Box) -> Bool {
        a.left <= b.right + snapDistance && b.left <= a.right + snapDistance
    }

    public static func overlapY(_ a: Box, _ b: Box) -> Bool {
        a.top <= b.bottom + snapDistance && b.top <= a.bottom + snapDistance
    }

    /// A new position for `a` that snaps it to `b` (snapUtils.ts 19-47). Per axis the four cases are tried in order and
    /// the first match wins; an axis only snaps when the boxes overlap on the other axis.
    public static func snap(_ a: Box, to b: Box) -> SnapResult {
        var result = SnapResult()
        if overlapY(a, b) {
            if near(a.left, b.right) {
                result.x = b.right
            } else if near(a.right, b.left) {
                result.x = b.left - a.width
            } else if near(a.left, b.left) {
                result.x = b.left
            } else if near(a.right, b.right) {
                result.x = b.right - a.width
            }
        }
        if overlapX(a, b) {
            if near(a.top, b.bottom) {
                result.y = b.bottom
            } else if near(a.bottom, b.top) {
                result.y = b.top - a.height
            } else if near(a.top, b.top) {
                result.y = b.top
            } else if near(a.bottom, b.bottom) {
                result.y = b.bottom - a.height
            }
        }
        return result
    }

    /// 0 where the axis did not snap (snapUtils.ts 49-55).
    public static func snapDiff(_ a: Box, _ b: Box) -> Offset {
        let snapped = snap(a, to: b)
        return Offset(x: snapped.x.map { $0 - a.x } ?? 0, y: snapped.y.map { $0 - a.y } ?? 0)
    }

    /// snapUtils.ts 58-72. `x = x || diff.x` keeps the first non-zero diff per axis, and the early `break` fires only
    /// when both are positive, so a negative snap keeps scanning but is never replaced. Ported as written.
    public static func snapDiffManyToMany(_ boxes: [Box], _ others: [Box]) -> Offset {
        var x: CGFloat = 0
        var y: CGFloat = 0
        for a in boxes {
            for b in others {
                let diff = snapDiff(a, b)
                x = x != 0 ? x : diff.x
                y = y != 0 ? y : diff.y
                if x > 0 && y > 0 { break }
            }
        }
        return Offset(x: x, y: y)
    }

    /// snapUtils.ts 87-103, generalized to bounds with an origin (Webamp's viewport is always at 0, 0).
    public static func snapWithin(_ box: Box, in bounds: Box) -> SnapResult {
        var result = SnapResult()
        if box.x - snapDistance < bounds.x {
            result.x = bounds.x
        } else if box.right + snapDistance > bounds.right {
            result.x = bounds.right - box.width
        }
        if box.y - snapDistance < bounds.y {
            result.y = bounds.y
        } else if box.bottom + snapDistance > bounds.bottom {
            result.y = bounds.bottom - box.height
        }
        return result
    }

    public static func snapWithinDiff(_ box: Box, in bounds: Box) -> Offset {
        let snapped = snapWithin(box, in: bounds)
        return Offset(x: snapped.x.map { $0 - box.x } ?? 0, y: snapped.y.map { $0 - box.y } ?? 0)
    }

    public static func applyDiff(_ a: Offset, _ b: Offset) -> Offset {
        Offset(x: a.x + b.x, y: a.y + b.y)
    }

    /// snapUtils.ts 175-183. Per axis a zero yields to the other, otherwise the smaller (signed, not absolute; their
    /// TODO, kept). With one diff the reduce never runs, so that diff is used as it is.
    public static func applyMultipleDiffs(_ initial: Offset, _ diffs: Offset...) -> Offset {
        guard let first = diffs.first else { return initial }
        let meta = diffs.dropFirst().reduce(first) { m, diff in
            Offset(
                x: m.x == 0 || diff.x == 0 ? m.x + diff.x : min(m.x, diff.x),
                y: m.y == 0 || diff.y == 0 ? m.y + diff.y : min(m.y, diff.y))
        }
        return applyDiff(initial, meta)
    }

    /// snapUtils.ts 123-149. `boxes` must not be empty.
    public static func boundingBox(_ boxes: [Box]) -> Box {
        guard let box = boundingBoxOrNil(boxes) else { preconditionFailure("boundingBox needs at least one box") }
        return box
    }

    public static func boundingBoxOrNil(_ boxes: [Box]) -> Box? {
        guard let first = boxes.first else { return nil }
        var top = first.top, right = first.right, bottom = first.bottom, left = first.left
        for box in boxes.dropFirst() {
            top = min(top, box.top)
            right = max(right, box.right)
            bottom = max(bottom, box.bottom)
            left = min(left, box.left)
        }
        return Box(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// Webamp's `abuts` (WindowManager.tsx 10-15): `snap` gives an x or a y, i.e. within the snap distance, overlap
    /// included.
    public static func abuts(_ a: Box, _ b: Box) -> Bool {
        let snapped = snap(a, to: b)
        return snapped.x != nil || snapped.y != nil
    }

    /// snapUtils.ts 151-167: every candidate reachable from `node` through `areConnected`, `node` itself included when
    /// it is a candidate. Depth first; a candidate joins once.
    public static func traceConnection(
        _ candidates: [DockedWindow], from node: DockedWindow,
        areConnected: (Box, Box) -> Bool = abuts
    ) -> Set<WindowKind> {
        var connected = Set<WindowKind>()
        func check(_ n: DockedWindow) {
            for candidate in candidates where !connected.contains(candidate.kind) && areConnected(candidate.box, n.box) {
                connected.insert(candidate.kind)
                check(candidate)
            }
        }
        check(node)
        return connected
    }
}
