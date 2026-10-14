import AppKit
import QuartzCore

/// Layer-backed container: masks its content to the skin region and refuses hits outside it.
/// Deliberately not flipped, so the mask layer's contents (row 0 at the top) are upright; the region
/// path is flipped into view coordinates instead.
final class SkinShapeView: NSView {
    /// The region in view coordinates (y up); nil = rectangular.
    private var regionPath: CGPath?
    private let maskLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        maskLayer.magnificationFilter = .nearest
        maskLayer.minificationFilter = .nearest
        maskLayer.contentsGravity = .resize
    }

    required init?(coder: NSCoder) { nil }

    /// `path` and `mask` come from `SkinRegion` at the same scale, top-left origin; both nil = rectangular.
    func apply(path: CGPath?, mask: CGImage?) {
        if let path {
            var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: bounds.height)
            regionPath = path.copy(using: &flip)
        } else {
            regionPath = nil
        }
        if let mask {
            maskLayer.contents = mask
            maskLayer.frame = bounds
            layer?.mask = maskLayer
        } else {
            layer?.mask = nil
        }
    }

    override func layout() {
        super.layout()
        maskLayer.frame = bounds
    }

    /// `point` is in the superview's coordinates.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let regionPath, !regionPath.contains(convert(point, from: superview), using: .winding) { return nil }
        return super.hitTest(point)
    }
}

@MainActor
protocol TitleBarDragging: AnyObject {
    func dragBegan()
    /// `proposedOrigin` is where the cursor's cumulative movement since mouse-down would put the window; the docking
    /// coordinator snaps it, a bare controller just moves the window there.
    func drag(to proposedOrigin: NSPoint)
    func dragEnded()
    /// No-op for now; #0031 toggles shade.
    func titleBarDoubleClicked()
}

/// Sits over the title bar, above the hosting view. Drags the window; leaves the button rects to SwiftUI.
final class TitleBarDragView: NSView {
    weak var delegate: TitleBarDragging?
    /// Button rects in this view's coordinates (top-left origin, in points).
    var excludedRects: [CGRect] = []
    /// The cursor and the window's origin at mouse-down; the drag is anchored there, not incremental, so snapping
    /// does not make the window drift from the cursor.
    private var mouseStart = NSPoint.zero
    private var startOrigin = NSPoint.zero

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// `point` is in the superview's coordinates.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return excludedRects.contains(where: { $0.contains(local) }) ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            delegate?.titleBarDoubleClicked()
            return
        }
        mouseStart = NSEvent.mouseLocation
        startOrigin = window?.frame.origin ?? .zero
        delegate?.dragBegan()
    }

    override func mouseDragged(with event: NSEvent) {
        let mouse = NSEvent.mouseLocation
        delegate?.drag(to: NSPoint(x: startOrigin.x + mouse.x - mouseStart.x, y: startOrigin.y + mouse.y - mouseStart.y))
    }

    override func mouseUp(with event: NSEvent) {
        delegate?.dragEnded()
    }
}
