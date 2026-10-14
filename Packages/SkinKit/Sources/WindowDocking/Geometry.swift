import CoreGraphics

/// Webamp's `Box` (types.ts 41-44): top-left origin, y down, in points.
public struct Box: Equatable, Hashable, Sendable {
    public var x: CGFloat
    public var y: CGFloat
    public var width: CGFloat
    public var height: CGFloat

    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var top: CGFloat { y }
    public var bottom: CGFloat { y + height }
    public var left: CGFloat { x }
    public var right: CGFloat { x + width }

    /// The box with its origin rounded to whole points, so a fractional `visibleFrame` cannot break edge equality.
    public var rounded: Box {
        Box(x: x.rounded(), y: y.rounded(), width: width.rounded(), height: height.rounded())
    }
}

/// Webamp's `Point` used as a diff or a position.
public struct Offset: Equatable, Sendable {
    public var x: CGFloat
    public var y: CGFloat

    public init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }

    public static let zero = Offset(x: 0, y: 0)
}

/// Webamp's `Diff` (types.ts 31-34): nil means this axis did not snap.
public struct SnapResult: Equatable, Sendable {
    public var x: CGFloat?
    public var y: CGFloat?

    public init(x: CGFloat? = nil, y: CGFloat? = nil) {
        self.x = x
        self.y = y
    }
}

/// The three skinned windows that dock to each other.
public enum WindowKind: String, Codable, CaseIterable, Sendable {
    case main, equalizer, playlist
}

public struct DockedWindow: Equatable, Sendable {
    public let kind: WindowKind
    public var box: Box

    public init(kind: WindowKind, box: Box) {
        self.kind = kind
        self.box = box
    }
}
