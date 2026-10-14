import CoreGraphics

/// Every main-window position that is not a slider or toggle, in skin pixels with a top-left origin, from
/// Webamp's css/main-window.css. The SwiftUI views and `MainWindowRenderer` read this one table so the app and
/// the headless render cannot drift. Sliders and toggles stay in `MainSliders`.
public enum MainWindowLayout {
    public static let size = CGSize(width: 275, height: 116)
    public static let shadeSize = CGSize(width: 275, height: 14)
    public static let titleBar = CGRect(x: 0, y: 0, width: 275, height: 14)

    public enum TitleButton: CaseIterable, Sendable { case options, minimize, shade, close }

    /// 9x9 at y 3; x 6 / 244 / 254 / 264.
    public static func rect(_ button: TitleButton) -> CGRect {
        let x: CGFloat
        switch button {
        case .options: x = 6
        case .minimize: x = 244
        case .shade: x = 254
        case .close: x = 264
        }
        return CGRect(x: x, y: 3, width: 9, height: 9)
    }

    public static let clutterBar = CGRect(x: 10, y: 22, width: 8, height: 43)
    /// The sprite is listed 9 wide; Webamp shows 3 px.
    public static let workIndicator = CGRect(x: 24, y: 28, width: 3, height: 9)
    public static let playIndicator = CGPoint(x: 26, y: 28)
    /// The 59x13 click area of `#time`.
    public static let timeHitArea = CGRect(x: 39, y: 26, width: 59, height: 13)
    /// `#time` left 39 plus 9 / 21 / 39 / 51.
    public static let digitXs: [CGFloat] = [48, 60, 78, 90]
    public static let digitY: CGFloat = 26
    public static let visualizer = CGRect(x: 24, y: 43, width: 76, height: 16)
    /// `#marquee { top: 24px; padding: 3px 0 }` with content-box sizing: the text sits 3 px inside the box (y 27, like
    /// Winamp), and the 154x12 box is the clip and hit area.
    public static let marquee = CGRect(x: 111, y: 27, width: 154, height: 6)
    public static let marqueeHitArea = CGRect(x: 111, y: 24, width: 154, height: 12)
    public static let kbps = CGPoint(x: 111, y: 43)
    public static let khz = CGPoint(x: 156, y: 43)
    public static let mono = CGPoint(x: 212, y: 41)
    public static let stereo = CGPoint(x: 239, y: 41)

    public enum Transport: CaseIterable, Sendable { case previous, play, pause, stop, next, eject }

    /// 23x18 at y 88, x 16 / 39 / 62 / 85 / 108 (next is 22 wide); eject 22x16 at (136, 89).
    public static func rect(_ control: Transport) -> CGRect {
        switch control {
        case .previous: CGRect(x: 16, y: 88, width: 23, height: 18)
        case .play: CGRect(x: 39, y: 88, width: 23, height: 18)
        case .pause: CGRect(x: 62, y: 88, width: 23, height: 18)
        case .stop: CGRect(x: 85, y: 88, width: 23, height: 18)
        case .next: CGRect(x: 108, y: 88, width: 22, height: 18)   // css `#next { width: 22px }`: the sprite's 23rd column is clipped
        case .eject: CGRect(x: 136, y: 89, width: 22, height: 16)
        }
    }

    /// "MAIN_PLAY_BUTTON", or "MAIN_PLAY_BUTTON_ACTIVE" while pressed.
    public static func spriteName(_ control: Transport, pressed: Bool) -> String {
        let base: String
        switch control {
        case .previous: base = "MAIN_PREVIOUS_BUTTON"
        case .play: base = "MAIN_PLAY_BUTTON"
        case .pause: base = "MAIN_PAUSE_BUTTON"
        case .stop: base = "MAIN_STOP_BUTTON"
        case .next: base = "MAIN_NEXT_BUTTON"
        case .eject: base = "MAIN_EJECT_BUTTON"
        }
        return pressed ? base + "_ACTIVE" : base
    }

    // The minus sign is skin-dependent: `Skin.minusFrame` (DigitFont.swift) stays its source.
}
