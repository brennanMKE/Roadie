import CoreGraphics

/// Which skin cursor the pointer shows over a skinned window: Webamp's cursorSelectors (skinSelectors.ts 356-403)
/// with the geometry of its CSS, expressed as the CSS cascade, i.e. an ordered list of cursor names per point. The
/// geometry comes from the layout tables the views draw from (`MainWindowLayout`, `MainShadeLayout`, `MainSliders`,
/// `EQLayout`, `PlaylistLayout`, `PlaylistShadeLayout`), so the two cannot drift.
public enum CursorRegions {
    public enum MainMode: Sendable { case normal, shade }

    /// A window, in the mode and size it currently has. Points are in skin pixels, y down.
    public enum Window: Sendable, Equatable {
        case main(MainMode)
        case equalizer(shaded: Bool)
        case playlist(PlaylistLayout.Steps, shaded: Bool)

        public var size: CGSize {
            switch self {
            case .main(.normal): MainWindowLayout.size
            case .main(.shade): MainWindowLayout.shadeSize
            case .equalizer(let shaded): shaded ? EQLayout.shadeSize : EQLayout.windowSize
            case .playlist(let steps, let shaded):
                shaded
                    ? CGSize(width: PlaylistLayout(steps: steps).size.width, height: PlaylistLayout.shadeHeight)
                    : PlaylistLayout(steps: steps).size
            }
        }
    }

    /// Cursor names to try in order for a point in skin pixels (y down). Empty outside the window.
    public static func candidates(at point: CGPoint, window: Window) -> [String] {
        guard CGRect(origin: .zero, size: window.size).contains(point) else { return [] }
        switch window {
        case .main(let mode): return main(point, shade: mode == .shade)
        case .equalizer(let shaded): return equalizer(point, shaded: shaded)
        case .playlist(let steps, let shaded): return playlist(point, layout: PlaylistLayout(steps: steps), shaded: shaded)
        }
    }

    public static func candidates(at point: CGPoint, mode: MainMode) -> [String] {
        candidates(at: point, window: .main(mode))
    }

    /// The first candidate the skin has; nil -> system cursor.
    public static func resolve(at point: CGPoint, window: Window, in cursors: SkinCursors) -> SkinCursor? {
        for name in candidates(at: point, window: window) {
            if let cursor = cursors[name] { return cursor }
        }
        return nil
    }

    public static func resolve(at point: CGPoint, mode: MainMode, in cursors: SkinCursors) -> SkinCursor? {
        resolve(at: point, window: .main(mode), in: cursors)
    }

    /// The first candidate name, which identifies a region for change detection ("" outside the window).
    public static func regionKey(at point: CGPoint, window: Window) -> String {
        candidates(at: point, window: window).first ?? ""
    }

    public static func regionKey(at point: CGPoint, mode: MainMode) -> String {
        regionKey(at: point, window: .main(mode))
    }

    // MARK: Main

    private static func main(_ point: CGPoint, shade: Bool) -> [String] {
        let tail = shade ? ["WSNORMAL", "NORMAL"] : ["TITLEBAR", "NORMAL"]
        let buttons: [(MainWindowLayout.TitleButton, [String])] = [
            (.options, shade ? ["MMENU", "MAINMENU"] : ["MAINMENU"]),
            (.minimize, ["MIN"]), (.shade, ["WINBUT"]), (.close, ["CLOSE"]),
        ]
        for (button, names) in buttons where MainWindowLayout.rect(button).contains(point) {
            return names + tail
        }
        if shade {
            // `#main-window #position` still matches in shade mode, below the shade-only rule.
            let position = MainSliders.shadePosition
            if CGRect(origin: position.origin, size: position.size).contains(point) {
                return ["WSPOSBAR", "POSBAR"] + tail
            }
            return tail
        }
        if MainWindowLayout.titleBar.contains(point) { return tail }
        if MainWindowLayout.marqueeHitArea.contains(point) { return ["SONGNAME", "NORMAL"] }
        let position = MainSliders.position
        if CGRect(origin: position.origin, size: position.size).contains(point) { return ["POSBAR", "NORMAL"] }
        for slider in [MainSliders.volume, MainSliders.balance]
        where CGRect(origin: slider.origin, size: slider.size).contains(point) {
            return ["VOLBAL", "NORMAL"]
        }
        return ["NORMAL"]
    }

    // MARK: Equalizer

    /// `.band` (the ten bands and the preamp), the title bar, the close button and the shade strip.
    private static func equalizer(_ point: CGPoint, shaded: Bool) -> [String] {
        let tail = ["EQTITLE", "EQNORMAL", "NORMAL"]
        if EQLayout.closeButton.contains(point) { return ["EQCLOSE"] + tail }
        if shaded { return tail }   // `#equalizer-window.shade` and its inputs
        if point.y < EQLayout.titleBarHeight { return tail }
        let bandRects = [CGRect(origin: EQLayout.preampOrigin, size: EQLayout.bandSize)]
            + (0..<EQLayout.bandCount).map { CGRect(origin: EQLayout.bandOrigin($0), size: EQLayout.bandSize) }
        if bandRects.contains(where: { $0.contains(point) }) { return ["EQSLID", "EQNORMAL", "NORMAL"] }
        return ["EQNORMAL", "NORMAL"]
    }

    // MARK: Playlist

    private static func playlist(_ point: CGPoint, layout: PlaylistLayout, shaded: Bool) -> [String] {
        if shaded {
            // `#playlist-window-shade` is a window of its own: its fallback is PWSNORM, then the generic `.window` rule.
            let width = layout.size.width
            let tail = ["PWSNORM", "NORMAL"]
            if PlaylistShadeLayout.closeFrame(width: width).contains(point) { return ["PCLOSE"] + tail }
            if PlaylistShadeLayout.shadeFrame(width: width).contains(point) { return ["PWINBUT"] + tail }
            if PlaylistShadeLayout.resizeFrame(width: width).contains(point) { return ["PWSSIZE"] + tail }
            return tail
        }
        let top = ["PTBAR", "PNORMAL", "NORMAL"]
        if layout.closeButton.contains(point) { return ["PCLOSE"] + top }
        if layout.shadeButton.contains(point) { return ["PWINBUT"] + top }
        if point.y < PlaylistLayout.topHeight { return top }
        if layout.resizeTarget.contains(point) { return ["PSIZE", "PNORMAL", "NORMAL"] }
        if layout.scrollTrack.contains(point) { return ["PVSCROLL", "PNORMAL", "NORMAL"] }
        return ["PNORMAL", "NORMAL"]
    }
}
