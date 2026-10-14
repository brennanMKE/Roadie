import CoreGraphics

/// Converts between AppKit's screen space (origin at the bottom-left of the primary screen, y up) and the engine's
/// (origin at the top-left of the primary screen, y down).
public struct DesktopSpace: Equatable, Sendable {
    /// `NSScreen.screens[0].frame.maxY`.
    public let primaryTop: CGFloat

    public init(primaryTop: CGFloat) {
        self.primaryTop = primaryTop
    }

    public func box(_ rect: CGRect) -> Box {
        Box(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }

    public func rect(_ box: Box) -> CGRect {
        CGRect(x: box.x, y: primaryTop - box.bottom, width: box.width, height: box.height)
    }
}
