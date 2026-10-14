import CoreGraphics
import Foundation

/// Main-window slider and toggle geometry and frame math, from Webamp's css/main-window.css, in skin pixels.
/// Pure and headless so the numbers can be tested; the SwiftUI layer only draws what this says.
public enum MainSliders {
    public struct Slider: Sendable, Equatable {
        /// Background top-left.
        public let origin: CGPoint
        public let size: CGSize
        public let thumbSize: CGSize
        /// 1 for volume and balance ("top: 1px"), 0 for position.
        public let thumbInsetY: CGFloat
        /// Input width minus thumb width: how far a native range thumb moves.
        public let travel: CGFloat

        /// Thumb x (window pixels) for a 0...1 fraction: `origin.x + round(fraction * travel)`.
        public func thumbX(for fraction: Double) -> CGFloat {
            origin.x + (min(max(fraction, 0), 1) * Double(travel)).rounded()
        }

        /// Inverse of `thumbX(for:)` for a pointer at window x: the thumb is centred on the pointer and clamped to the track.
        public func fraction(forPointerX x: CGFloat) -> Double {
            guard travel > 0 else { return 0 }
            let left = x - origin.x - thumbSize.width / 2
            return min(max(Double(left / travel), 0), 1)
        }
    }

    public static let volume = Slider(
        origin: CGPoint(x: 107, y: 57), size: CGSize(width: 68, height: 13),
        thumbSize: CGSize(width: 14, height: 11), thumbInsetY: 1, travel: 51)
    public static let balance = Slider(
        origin: CGPoint(x: 177, y: 57), size: CGSize(width: 38, height: 13),
        thumbSize: CGSize(width: 14, height: 11), thumbInsetY: 1, travel: 24)
    public static let position = Slider(
        origin: CGPoint(x: 16, y: 72), size: CGSize(width: 248, height: 10),
        thumbSize: CGSize(width: 29, height: 10), thumbInsetY: 0, travel: 219)

    /// `.shade #position`: (226, 4) 17x7, 3x7 thumb, travel 14 (css 479-497; TITLEBAR sprites 17x7 / 3x7).
    public static let shadePosition = Slider(
        origin: CGPoint(x: 226, y: 4), size: CGSize(width: 17, height: 7),
        thumbSize: CGSize(width: 3, height: 7), thumbInsetY: 0, travel: 14)

    /// Position.tsx 44-51: `position <= 33` is LEFT, `>= 66` is RIGHT, else the plain thumb (position is
    /// floor(elapsed)/duration*100, unrounded, so the thresholds are fraction <= 0.33 and >= 0.66).
    public static func shadePositionThumbName(fraction: Double) -> String {
        if fraction <= 0.33 { return "MAIN_SHADE_POSITION_THUMB_LEFT" }
        if fraction >= 0.66 { return "MAIN_SHADE_POSITION_THUMB_RIGHT" }
        return "MAIN_SHADE_POSITION_THUMB"
    }

    /// The equalizer's shade-strip volume and balance: only the 3x7 thumb is drawn (the strip paints the tracks), on
    /// a 6-high input at y 4 (css/equalizer-window.css 28-53).
    public static let eqShadeVolume = Slider(
        origin: CGPoint(x: 61, y: 4), size: CGSize(width: 97, height: 6),
        thumbSize: CGSize(width: 3, height: 7), thumbInsetY: 0, travel: 94)
    public static let eqShadeBalance = Slider(
        origin: CGPoint(x: 164, y: 4), size: CGSize(width: 43, height: 6),
        thumbSize: CGSize(width: 3, height: 7), thumbInsetY: 0, travel: 40)

    public enum ShadeSegment: Sendable { case left, center, right }

    /// EqualizerShade.tsx 17-19, utils.ts `segment`: the thumb sprite by thirds, `round(fraction * 2)`.
    public static func shadeSegment(fraction: Double) -> ShadeSegment {
        if fraction < 0.25 { return .left }
        if fraction < 0.75 { return .center }
        return .right
    }

    /// Frame height in volume.bmp / balance.bmp; 28 frames fill the 420-row sprite.
    public static let frameHeight = 15
    public static let frameCount = 28
    /// Visible rows of a frame: the `#volume` / `#balance` divs are 13 px tall.
    public static let visibleFrameRows = 13

    /// Webamp MainVolume.tsx: sprite = round(percent * 28), offset = (sprite - 1) * 15. Sprite 0 is an invalid
    /// CSS position the browser ignores, so frame 0 shows: clamp at 0.
    public static func volumeFrame(_ volume: Float) -> Int {
        max(0, min(frameCount - 1, Int((volume * Float(frameCount)).rounded()) - 1))
    }

    /// Webamp MainBalance.tsx offsetFromBalance: floor(|balance| * 27) frames down.
    public static func balanceFrame(_ balance: Float) -> Int {
        min(frameCount - 1, Int((abs(balance) * Float(frameCount - 1)).rounded(.down)))
    }

    /// The 13 visible rows of frame `frame` of a 15-row-per-frame background sprite.
    public static func frameRect(of sprite: Sprite, frame: Int) -> CGRect {
        frameRect(in: sprite.rect, frame: frame)
    }

    /// Same, for a resolved crop rect (which a fallback may have moved to another sheet).
    public static func frameRect(in rect: CGRect, frame: Int) -> CGRect {
        CGRect(
            x: rect.minX, y: rect.minY + CGFloat(frame * frameHeight),
            width: rect.width, height: CGFloat(visibleFrameRows))
    }

    /// Webamp setBalance: |balance| < 25 % snaps to centre.
    public static func snappedBalance(_ balance: Float) -> Float {
        abs(balance) < 0.25 ? 0 : balance
    }

    /// Balance value for a 0...1 slider fraction (0 = full left, 0.5 = centre, 1 = full right).
    public static func balance(forFraction fraction: Double) -> Float {
        Float(min(max(fraction, 0), 1) * 2 - 1)
    }

    public static func fraction(forBalance balance: Float) -> Double {
        (Double(min(max(balance, -1), 1)) + 1) / 2
    }

    public enum Toggle: CaseIterable, Sendable { case shuffle, repeatAll, equalizer, playlist }

    public struct ToggleFrame: Sendable, Equatable {
        public let origin: CGPoint
        public let size: CGSize
    }

    public static func frame(of toggle: Toggle) -> ToggleFrame {
        switch toggle {
        case .shuffle: ToggleFrame(origin: CGPoint(x: 164, y: 89), size: CGSize(width: 47, height: 15))
        case .repeatAll: ToggleFrame(origin: CGPoint(x: 210, y: 89), size: CGSize(width: 28, height: 15))
        case .equalizer: ToggleFrame(origin: CGPoint(x: 219, y: 58), size: CGSize(width: 23, height: 12))
        case .playlist: ToggleFrame(origin: CGPoint(x: 242, y: 58), size: CGSize(width: 23, height: 12))
        }
    }

    /// Sprite name for a toggle state. The suffix order differs per sheet row: SHUFREP's shuffle and repeat use
    /// `_SELECTED_DEPRESSED`, EQ and playlist use `_DEPRESSED_SELECTED` (Webamp skinSelectors).
    public static func spriteName(_ toggle: Toggle, selected: Bool, pressed: Bool) -> String {
        let base: String
        let both: String
        switch toggle {
        case .shuffle: (base, both) = ("MAIN_SHUFFLE_BUTTON", "_SELECTED_DEPRESSED")
        case .repeatAll: (base, both) = ("MAIN_REPEAT_BUTTON", "_SELECTED_DEPRESSED")
        case .equalizer: (base, both) = ("MAIN_EQ_BUTTON", "_DEPRESSED_SELECTED")
        case .playlist: (base, both) = ("MAIN_PLAYLIST_BUTTON", "_DEPRESSED_SELECTED")
        }
        switch (selected, pressed) {
        case (false, false): return base
        case (true, false): return base + "_SELECTED"
        case (false, true): return base + "_DEPRESSED"
        case (true, true): return base + both
        }
    }
}
