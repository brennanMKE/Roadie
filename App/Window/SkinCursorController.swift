import AppKit
import SkinKit

/// Shows the skin's cursor for the region of a skinned window under the pointer; steps animated (RIFF) cursors.
/// One controller per window. The regions come from SkinKit's `CursorRegions`; an unknown or missing cursor falls
/// through the CSS-style cascade and finally to the system arrow.
@MainActor
final class SkinCursorController {
    private var cursors = SkinCursors.empty
    private var window = CursorRegions.Window.main(.normal)
    private var scale: CGFloat = 1
    /// Cursor name -> one NSCursor per frame, built lazily. Dropped whenever the skin changes.
    private var cache: [String: [NSCursor]] = [:]
    private var timer: Timer?
    /// The animated cursor being stepped; the timer closure reads it from here rather than capturing it.
    private var animating: (name: String, cursor: SkinCursor)?
    private var currentKey: String?
    /// The pointer in skin pixels (y down), nil while it is outside the window.
    private var lastPoint: CGPoint?
    /// The window these regions belong to. AppKit sends no `mouseExited` when a window is ordered out or minimized
    /// under the pointer, so nothing is set (and the animation stops) once it is no longer on screen.
    weak var hostWindow: NSWindow?

    private var isShowing: Bool {
        guard let hostWindow else { return false }
        return hostWindow.isVisible && !hostWindow.isMiniaturized
    }

    /// Called whenever the skin, scale, mode or size changes (`SkinWindowController.performLayout`). Cursors stay at
    /// one point per cursor pixel regardless of `scale`, as in Winamp; `scale` only converts view points to skin pixels.
    func apply(cursors: SkinCursors, window: CursorRegions.Window, scale: CGFloat) {
        self.cursors = cursors
        self.window = window
        self.scale = max(scale, 0.01)
        cache.removeAll()
        currentKey = nil
        stopTimer()
        if let lastPoint { update(at: lastPoint, force: true) }
    }

    /// `point` is in the window's content coordinates in points, y down.
    func pointerMoved(toViewPoint point: CGPoint) {
        let skinPoint = CGPoint(x: point.x / scale, y: point.y / scale)
        lastPoint = skinPoint
        update(at: skinPoint, force: false)
    }

    func pointerExited() {
        lastPoint = nil
        currentKey = nil
        stopTimer()
    }

    /// `cursorUpdate`: AppKit is about to reset the cursor; set ours again for the current region.
    func reapply() {
        if let lastPoint { update(at: lastPoint, force: true) }
    }

    private func update(at point: CGPoint, force: Bool) {
        guard isShowing else {
            pointerExited()
            return
        }
        let candidates = CursorRegions.candidates(at: point, window: window)
        let key = candidates.first ?? ""
        if !force, key == currentKey { return }
        let regionChanged = key != currentKey
        currentKey = key
        guard let name = candidates.first(where: { cursors[$0] != nil }), let cursor = cursors[name] else {
            stopTimer()
            NSCursor.arrow.set()
            return
        }
        let nsCursors = self.nsCursors(for: name, cursor)
        guard !nsCursors.isEmpty else {
            stopTimer()
            NSCursor.arrow.set()
            return
        }
        if regionChanged || !cursor.isAnimated { stopTimer() }
        if cursor.isAnimated {
            // Winamp restarts the animation whenever the pointer enters an element.
            if regionChanged || timer == nil {
                animating = (name, cursor)
                step(at: 0)
            }
        } else {
            nsCursors[min(cursor.steps[0].frame, nsCursors.count - 1)].set()
        }
    }

    private func step(at stepIndex: Int) {
        guard isShowing else {
            pointerExited()
            return
        }
        guard let (name, cursor) = animating else { return }
        let nsCursors = self.nsCursors(for: name, cursor)
        guard !nsCursors.isEmpty else { return }
        let (index, frame, interval) = Self.stepFrame(at: stepIndex, steps: cursor.steps, frameCount: nsCursors.count)
        nsCursors[frame].set()
        timer?.invalidate()
        let next = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.step(at: index + 1)
            }
        }
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    /// Step `stepIndex` of an animation (wrapping past the last step): its index, the frame to show (clamped to the
    /// frames built) and how long to show it (at least one 60 Hz frame). Pure, so tests drive it with explicit steps.
    nonisolated static func stepFrame(
        at stepIndex: Int, steps: [SkinCursor.Step], frameCount: Int
    ) -> (index: Int, frame: Int, interval: TimeInterval) {
        let index = stepIndex % steps.count
        let current = steps[index]
        return (index, min(current.frame, frameCount - 1), max(current.duration, 1.0 / 60))
    }

    private func stopTimer() {
        animating = nil
        timer?.invalidate()
        timer = nil
    }

    private func nsCursors(for name: String, _ cursor: SkinCursor) -> [NSCursor] {
        if let cached = cache[name] { return cached }
        let built = cursor.frames.map { frame -> NSCursor in
            let size = NSSize(width: frame.image.width, height: frame.image.height)
            let image = NSImage(size: size)
            let base = NSBitmapImageRep(cgImage: frame.image)
            base.size = size
            image.addRepresentation(base)
            // A second, nearest-neighbour representation keeps the pixels crisp on Retina instead of blurred.
            if let double = frame.upscaled(2) {
                let rep = NSBitmapImageRep(cgImage: double)
                rep.size = size
                image.addRepresentation(rep)
            }
            return NSCursor(image: image, hotSpot: NSPoint(x: frame.hotSpot.x, y: frame.hotSpot.y))
        }
        cache[name] = built
        return built
    }
}
