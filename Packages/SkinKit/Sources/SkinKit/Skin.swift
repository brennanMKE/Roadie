import CoreGraphics
import Foundation

/// A parsed classic skin. Missing files are recorded as warnings or fallbacks, not failures.
public struct Skin: @unchecked Sendable {
    /// Sheet name (e.g. "MAIN", "CBUTTONS") -> decoded bitmap. `CGImage` is immutable.
    public let sheets: [String: CGImage]
    /// Always 24 entries: viscolor.txt lines over Webamp's base-skin defaults.
    public let visColors: [RGBColor]
    /// Things that will render wrong (missing or undecodable required sheets, no number sheet at all).
    public let warnings: [String]
    /// Substitutions that keep the skin whole (balance from volume, digits from one number sheet,
    /// default viscolors...).
    public let fallbacks: [String]

    public init(sheets: [String: CGImage], visColors: [RGBColor], warnings: [String], fallbacks: [String] = []) {
        self.sheets = sheets
        self.visColors = visColors
        self.warnings = warnings
        self.fallbacks = fallbacks
    }

    /// True when nums_ex.bmp decoded; Webamp's `numExIsUsed`. Digits and the minus sign then come from
    /// NUMS_EX, and the minus sign is a 9x13 cell at (-1, 0) in #time instead of a 5x1 bar at (-1, 6).
    public var usesNumsEx: Bool { sheets["NUMS_EX"] != nil }

    /// Where a sprite is actually drawn from after the Webamp fallback rules; nil if nothing can draw it.
    /// `rect` is the crop rect in `sheet`; for a fallback it is the substitute's origin with the requested size.
    public func resolve(_ spriteName: String) -> (sheet: String, rect: CGRect)? {
        // Rule 2: the NUMS_EX sheet wins whenever it is present, else NUMBERS.
        if let pair = SkinSprites.numberPair(for: spriteName) {
            if sheets["NUMS_EX"] != nil, let entry = SkinSprites.byName[pair.ex] {
                return (entry.sheet, entry.sprite.rect)
            }
            if sheets["NUMBERS"] != nil, let entry = SkinSprites.byName[pair.plain] {
                return (entry.sheet, entry.sprite.rect)
            }
            return nil
        }
        guard let requested = SkinSprites.byName[spriteName] else { return nil }
        if sheets[requested.sheet] != nil { return (requested.sheet, requested.sprite.rect) }
        // Rule 1: Webamp's FALLBACKS, cropped to the requested size from the substitute's origin.
        if let substituteName = SkinSprites.fallbacks[spriteName],
           let substitute = SkinSprites.byName[substituteName],
           sheets[substitute.sheet] != nil
        {
            let size = CGSize(
                width: min(requested.sprite.width, substitute.sprite.width),
                height: min(requested.sprite.height, substitute.sprite.height))
            return (substitute.sheet, CGRect(origin: substitute.sprite.rect.origin, size: size))
        }
        return nil
    }

    /// Crops the resolved sprite (e.g. "MAIN_PLAY_BUTTON") out of its sheet.
    public func image(for spriteName: String) -> CGImage? {
        guard let (sheet, rect) = resolve(spriteName), let image = sheets[sheet] else { return nil }
        return image.cropping(to: rect)
    }
}
