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
}
