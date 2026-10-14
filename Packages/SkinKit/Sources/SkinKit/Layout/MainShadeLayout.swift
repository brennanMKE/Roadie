import CoreGraphics

/// The 275x14 main window in shade mode, in skin pixels with a top-left origin (Webamp css/main-window.css "Shade
/// View", css/mini-time.css, components/MiniTime.tsx, Vis.tsx). Pure and headless; the SwiftUI layer only draws what
/// this says, and the title-bar drag view takes its holes from `dragExclusions`.
public enum MainShadeLayout {
    public static let size = CGSize(width: 275, height: 14)

    /// Same as normal mode: options x 6, minimize 244, shade 254, close 264; 9x9 at y 3 (css 22-48).
    public static var buttonRects: [CGRect] {
        MainWindowLayout.TitleButton.allCases.map { MainWindowLayout.rect($0) }
    }

    /// `.mini-time` at (127, 4), 25x6 (css 503-507, mini-time.css 1-5); the five 5x6 text.bmp cells sit at these x
    /// offsets inside it (MiniTime.tsx 17, 54-58): minus/space, minutes tens, minutes ones, seconds tens, seconds ones.
    /// The last cell ends at 30, past the 25 px box (overflow is visible).
    public static let miniTimeOrigin = CGPoint(x: 127, y: 4)
    public static let miniTimeCellX = [1, 7, 12, 20, 25]
    public static let miniTimeImageWidth = 30

    /// `.shade #visualizer`: (79, 5), 76x5 (css 160-163; Vis.tsx 69-70).
    public static let visualizerFrame = CGRect(x: 79, y: 5, width: 76, height: 5)

    /// Invisible hit areas over the strip's painted mini buttons (css 427-477, `background: none`).
    public enum Transport: CaseIterable, Sendable { case previous, play, pause, stop, next, eject }

    /// Previous (169,2) 7x10, play (176,2) 10x10, pause (186,2) 9x10, stop (195,2) 9x10, next (204,2) 10x10,
    /// eject (215,2) 10x10.
    public static func frame(of control: Transport) -> CGRect {
        switch control {
        case .previous: CGRect(x: 169, y: 2, width: 7, height: 10)
        case .play: CGRect(x: 176, y: 2, width: 10, height: 10)
        case .pause: CGRect(x: 186, y: 2, width: 9, height: 10)
        case .stop: CGRect(x: 195, y: 2, width: 9, height: 10)
        case .next: CGRect(x: 204, y: 2, width: 10, height: 10)
        case .eject: CGRect(x: 215, y: 2, width: 10, height: 10)
        }
    }

    /// The mini time's click area: the five cells, 30 px wide.
    public static var miniTimeHitArea: CGRect {
        CGRect(x: miniTimeOrigin.x, y: miniTimeOrigin.y, width: CGFloat(miniTimeImageWidth), height: 6)
    }

    /// Everything the title-bar drag view must leave to SwiftUI: the four buttons, mini time, visualizer, the six
    /// transport rects and the position slider.
    public static var dragExclusions: [CGRect] {
        buttonRects + [miniTimeHitArea, visualizerFrame] + Transport.allCases.map(frame(of:))
            + [CGRect(origin: MainSliders.shadePosition.origin, size: MainSliders.shadePosition.size)]
    }
}
