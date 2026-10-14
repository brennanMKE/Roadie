import CoreGraphics
import Foundation

/// The playlist window in shade mode: a 14 px strip as wide as the playlist (`275 + 25w`), from Webamp's
/// PlaylistWindow/PlaylistShade.tsx and css/playlist-window.css 242-306, in skin pixels with a top-left origin. Buttons
/// are measured from the right edge. Pure and headless; the SwiftUI layer only draws what this says.
public enum PlaylistShadeLayout {
    public static let height: CGFloat = 14
    public static let titleOrigin = CGPoint(x: 5, y: 4)
    public static let timeY: CGFloat = 4
    /// The `PLAYLIST_SHADE_BACKGROUND_LEFT` and `_RIGHT` pieces are 25 and 50 wide; the tile fills between them.
    public static let leftWidth: CGFloat = 25
    public static let rightWidth: CGFloat = 50

    /// 9x9 at `right: 2px`, top 3.
    public static func closeFrame(width: CGFloat) -> CGRect { CGRect(x: width - 11, y: 3, width: 9, height: 9) }
    /// `right: 12px`.
    public static func shadeFrame(width: CGFloat) -> CGRect { CGRect(x: width - 21, y: 3, width: 9, height: 9) }
    /// The width-only resize target, `right: 20px`.
    public static func resizeFrame(width: CGFloat) -> CGRect { CGRect(x: width - 29, y: 3, width: 9, height: 9) }
    /// The time text ends 30 px from the right edge (`right: 30px`).
    public static func timeRightEdge(width: CGFloat) -> CGFloat { width - 30 }

    /// Controls the drag view must leave alone.
    public static func dragExclusions(width: CGFloat) -> [CGRect] {
        [closeFrame(width: width), shadeFrame(width: width), resizeFrame(width: width)]
    }

    /// `"[No file]"` without a track; else the name cut to `(205 + added width) / 5` characters, the last replaced by
    /// "…" when it is longer (PlaylistShade.tsx 32-43). `name` is `"<n>. <title>"`.
    public static func title(name: String?, width: CGFloat) -> String {
        guard let name else { return "[No file]" }
        let limit = Int((205 + (width - 275)) / CGFloat(TextFont.cellWidth))
        guard name.count > limit else { return name }
        return String(name.prefix(max(limit - 1, 0))) + "\u{2026}"
    }

    /// `m:ss` with the leading minutes zero dropped (`getTimeStr`); empty without a time.
    public static func timeString(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "" }
        let digits = TimeDigits(seconds: seconds)
        let tens = digits.minutesTens == 0 ? "" : String(digits.minutesTens ?? 0)
        return "\(tens)\(digits.minutesOnes ?? 0):\(digits.secondsTens ?? 0)\(digits.secondsOnes ?? 0)"
    }
}
