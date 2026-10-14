import CoreGraphics

public enum ScreenSelection {
    /// The screen with the largest intersection with `box`; ties go to the first, no intersection gives `fallback`.
    public static func bounds(for box: Box, among screens: [Box], fallback: Box) -> Box {
        var best: Box?
        var bestArea: CGFloat = 0
        for screen in screens {
            let width = min(box.right, screen.right) - max(box.left, screen.left)
            let height = min(box.bottom, screen.bottom) - max(box.top, screen.top)
            guard width > 0, height > 0 else { continue }
            if width * height > bestArea {
                bestArea = width * height
                best = screen
            }
        }
        return best ?? fallback
    }

    /// The screen with the largest intersection with `box` (as `bounds(for:)`); with no intersection the screen with the
    /// smallest gap to `box` (dx = max(0, screen.left - box.right, box.left - screen.right), likewise dy, smallest
    /// dx² + dy²), ties to the first; `fallback` when `screens` is empty.
    public static func nearest(to box: Box, among screens: [Box], fallback: Box) -> Box {
        var best: Box?
        var bestArea: CGFloat = 0
        for screen in screens {
            let width = min(box.right, screen.right) - max(box.left, screen.left)
            let height = min(box.bottom, screen.bottom) - max(box.top, screen.top)
            guard width > 0, height > 0 else { continue }
            if width * height > bestArea {
                bestArea = width * height
                best = screen
            }
        }
        if let best { return best }
        var nearest: Box?
        var nearestDistance = CGFloat.greatestFiniteMagnitude
        for screen in screens {
            let dx = max(0, screen.left - box.right, box.left - screen.right)
            let dy = max(0, screen.top - box.bottom, box.top - screen.bottom)
            let distance = dx * dx + dy * dy
            if distance < nearestDistance {
                nearestDistance = distance
                nearest = screen
            }
        }
        return nearest ?? fallback
    }
}
