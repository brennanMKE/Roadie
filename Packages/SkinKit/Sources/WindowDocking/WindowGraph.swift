import CoreGraphics

/// How docked windows hang together, and how far they move when one of them changes size. A port of Webamp's
/// `resizeUtils.ts`.
public struct Edges: Equatable, Sendable {
    /// "This window's top is that window's bottom."
    public var below: WindowKind?
    /// "This window's left is that window's right."
    public var right: WindowKind?

    public init(below: WindowKind? = nil, right: WindowKind? = nil) {
        self.below = below
        self.right = right
    }
}

public enum WindowGraph {
    /// resizeUtils.ts 87-141: exact edge equality, and the other axis must overlap (strict on the non-overlap test).
    /// Boxes are rounded to whole points first so a fractional frame cannot break equality.
    public static func generate(_ windows: [DockedWindow]) -> [WindowKind: Edges] {
        let boxes = windows.map { DockedWindow(kind: $0.kind, box: $0.box.rounded) }
        var graph: [WindowKind: Edges] = [:]
        for w in boxes {
            var edges = Edges()
            for other in boxes where other.box.bottom == w.box.top {
                let isToTheLeft = other.box.right < w.box.left
                let isToTheRight = other.box.left > w.box.right
                if !(isToTheLeft || isToTheRight) {
                    edges.below = other.kind
                    break
                }
            }
            for other in boxes where other.box.right == w.box.left {
                let isAbove = other.box.bottom < w.box.top
                let isBelow = other.box.top > w.box.bottom
                if !(isAbove || isBelow) {
                    edges.right = other.kind
                    break
                }
            }
            graph[w.kind] = edges
        }
        return graph
    }

    /// resizeUtils.ts 24-75: invert the graph, then walk down from every node with no `below` and right from every node
    /// with no `right`, accumulating `diff + parent's diff`.
    public static func positionDiff(
        graph: [WindowKind: Edges], sizeDiff: [WindowKind: (width: CGFloat, height: CGFloat)]
    ) -> [WindowKind: Offset] {
        var above: [WindowKind: [WindowKind]] = [:]
        var left: [WindowKind: [WindowKind]] = [:]
        var diff: [WindowKind: Offset] = [:]
        let keys = WindowKind.allCases.filter { graph[$0] != nil }
        for key in keys { diff[key] = .zero }
        for key in keys {
            guard let edges = graph[key] else { continue }
            if let right = edges.right { left[right, default: []].append(key) }
            if let below = edges.below { above[below, default: []].append(key) }
        }
        func walkRight(_ key: WindowKind) {
            for neighbor in left[key] ?? [] {
                diff[neighbor]!.x += (sizeDiff[key]?.width ?? 0) + diff[key]!.x
                walkRight(neighbor)
            }
        }
        func walkDown(_ key: WindowKind) {
            for neighbor in above[key] ?? [] {
                diff[neighbor]!.y += (sizeDiff[key]?.height ?? 0) + diff[key]!.y
                walkDown(neighbor)
            }
        }
        for key in keys {
            guard let edges = graph[key] else { continue }
            if edges.below == nil { walkDown(key) }
            if edges.right == nil { walkRight(key) }
        }
        return diff
    }
}
