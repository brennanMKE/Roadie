import CoreGraphics
import Foundation

/// Equalizer-window geometry and value math from Webamp's css/equalizer-window.css, EqualizerWindow/Band.tsx,
/// VerticalSlider.tsx and actionCreators/equalizer.ts, in skin pixels with a top-left origin. Values are Webamp's
/// 0...100 slider scale (50 = 0 dB); `EQState` stores dB, converted by `value(forGain:)` and `gain(forValue:)`.
/// Pure and headless so the numbers can be tested; the SwiftUI layer only draws what this says.
public enum EQLayout {
    public static let windowSize = CGSize(width: 275, height: 116)
    public static let shadeSize = CGSize(width: 275, height: 14)
    public static let titleBarHeight: CGFloat = 14

    /// Shade (9x9 at 254, 3) and close (9x9 at 264, 3).
    public static let shadeButton = CGRect(x: 254, y: 3, width: 9, height: 9)
    public static let closeButton = CGRect(x: 264, y: 3, width: 9, height: 9)
    public static let titleButtonRects: [CGRect] = [shadeButton, closeButton]

    public static let onButton = CGRect(x: 14, y: 18, width: 26, height: 12)
    public static let autoButton = CGRect(x: 40, y: 18, width: 32, height: 12)
    public static let presetsButton = CGRect(x: 217, y: 18, width: 44, height: 12)
    public static let graph = CGRect(x: 86, y: 17, width: 113, height: 19)
    /// The three invisible labels that set every band to +12 dB, 0 dB and -12 dB.
    public static let plus12 = CGRect(x: 45, y: 36, width: 22, height: 8)
    public static let zero = CGRect(x: 45, y: 64, width: 22, height: 8)
    public static let minus12 = CGRect(x: 45, y: 95, width: 22, height: 8)

    /// Band.tsx: height 63 (one pixel taller than the 62-px slider it holds); VerticalSlider width 14.
    public static let bandSize = CGSize(width: 14, height: 63)
    public static let sliderHeight: CGFloat = 62
    /// Handle: 11x11 with marginLeft 1.
    public static let thumbSize = CGSize(width: 11, height: 11)
    public static let thumbInsetX: CGFloat = 1
    /// 62 - 11.
    public static let thumbTravel: CGFloat = 51
    public static let preampOrigin = CGPoint(x: 21, y: 38)
    public static let bandSpacing: CGFloat = 18
    public static let bandCount = 10

    public static func bandOrigin(_ index: Int) -> CGPoint {
        CGPoint(x: 78 + bandSpacing * CGFloat(index), y: 38)
    }

    /// The whole band strip, for one drag gesture: the last band ends at 240 + 14 = 254.
    public static let bandStrip = CGRect(x: 78, y: 38, width: 176, height: 63)

    /// Band under a window x: the 4-px gap right of a band belongs to it; outside the strip clamps to the ends.
    public static func bandIndex(atX x: CGFloat) -> Int {
        let raw = ((x - bandStrip.minX) / bandSpacing).rounded(.down)
        guard raw.isFinite else { return 0 }
        return Int(min(max(raw, 0), CGFloat(bandCount - 1)))
    }

    // MARK: Value math (0...100)

    public static let midValue: Double = 50
    /// `_snapBandValue`: a value within 5 of the middle snaps to it.
    public static let snapDistance: Double = 5

    /// dB (-12...12) to the slider scale; out-of-range gains clamp.
    public static func value(forGain gain: Float) -> Double {
        min(max((Double(gain) + 12) / 24 * 100, 0), 100)
    }

    /// media/index.ts setEqBand: `value / 100 * 24 - 12`.
    public static func gain(forValue value: Double) -> Float {
        Float(min(max(value, 0), 100) / 100 * 24 - 12)
    }

    public static func snapped(_ value: Double) -> Double {
        abs(value - midValue) < snapDistance ? midValue : value
    }

    // MARK: Band background frames

    /// 14 columns by 2 rows of 15x65 cells in the 209x129 sprite.
    public static let frameCount = 28

    /// Band.tsx spriteNumber: `round(value / 100 * 27)`, 0 = -12 dB ... 27 = +12 dB.
    public static func frame(forValue value: Double) -> Int {
        Int((min(max(value, 0), 100) / 100 * 27).rounded())
    }

    /// Crop rect of frame `frame` in the sheet: x = `n % 14` and y = `n / 14` cells of 15x65 from the sprite's origin,
    /// 14x63 each. `rect` is the resolved `EQ_SLIDER_BACKGROUND` rect.
    public static func bandFrameRect(in rect: CGRect, frame: Int) -> CGRect {
        CGRect(
            x: rect.minX + CGFloat(frame % 14) * 15, y: rect.minY + CGFloat(frame / 14) * 65,
            width: bandSize.width, height: bandSize.height)
    }

    // MARK: Thumb and pointer

    /// VerticalSlider: `floor((62 - 11) * (1 - value / 100))` from the slider top.
    public static func thumbY(forValue value: Double) -> CGFloat {
        (thumbTravel * (1 - min(max(value, 0), 100) / 100)).rounded(.down)
    }

    /// A pointer at `y` in the 62-px slider centres the handle on itself (VerticalSlider, a click outside the handle),
    /// clamped to the track. Not snapped.
    public static func value(forPointerY y: CGFloat) -> Double {
        let fraction = min(max(Double((y - thumbSize.height / 2) / thumbTravel), 0), 1)
        return (1 - fraction) * 100
    }
}
