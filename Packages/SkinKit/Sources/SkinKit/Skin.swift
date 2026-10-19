import CoreGraphics
import Foundation

/// A parsed classic skin. Missing files are recorded as warnings or fallbacks, not failures.
public struct Skin: @unchecked Sendable {
    /// Sheet name (e.g. "MAIN", "CBUTTONS") -> decoded bitmap. `CGImage` is immutable.
    public let sheets: [String: CGImage]
    /// Always 24 entries: viscolor.txt lines over Webamp's base-skin defaults.
    public let visColors: [RGBColor]
    /// `region.txt`: the window shapes. `.empty` when the file is absent or has no usable section.
    public let region: SkinRegion
    /// Things that will render wrong (missing or undecodable required sheets, no number sheet at all).
    public let warnings: [String]
    /// Substitutions that keep the skin whole (balance from volume, digits from one number sheet,
    /// default viscolors, sheets from the generated base skin...).
    public let fallbacks: [String]
    /// Sheets drawn by `GeneratedBaseSkin` because the skin lacked them or they didn't decode.
    public let generatedSheets: Set<String>
    /// `pledit.txt`: the playlist window's colours and font; `.defaults` when the file is absent.
    public let playlistStyle: PlaylistStyle
    /// The skin's `.cur` files under Winamp's cursor names; `.empty` when it ships none.
    public let cursors: SkinCursors

    public init(
        sheets: [String: CGImage], visColors: [RGBColor], region: SkinRegion = .empty,
        playlistStyle: PlaylistStyle = .defaults, warnings: [String], fallbacks: [String] = [],
        cursors: SkinCursors = .empty, generatedSheets: Set<String> = []
    ) {
        self.generatedSheets = generatedSheets
        self.cursors = cursors
        self.playlistStyle = playlistStyle
        self.sheets = sheets
        self.visColors = visColors
        self.region = region
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

    /// Crops the visible rows (13 of each 15) of frame `frame` of a multi-frame background sprite
    /// (volume, balance), through the same `resolve` as `image(for:)`, so the balance -> volume fallback applies.
    /// nil when the frame lies outside the sheet.
    public func image(for spriteName: String, frame: Int) -> CGImage? {
        guard frame >= 0, let (sheet, rect) = resolve(spriteName), let image = sheets[sheet] else { return nil }
        let frameRect = MainSliders.frameRect(in: rect, frame: frame)
        guard frameRect.maxY <= CGFloat(image.height), frameRect.maxY <= rect.maxY else { return nil }
        return image.cropping(to: frameRect)
    }

    /// Crops frame `bandFrame` (0...27) of the 14x63 equalizer band backgrounds out of `EQ_SLIDER_BACKGROUND`, through
    /// the same `resolve` as `image(for:)`. nil when the frame lies outside the sheet (a short `eqmain.bmp`), never a crash.
    public func image(for spriteName: String, bandFrame: Int) -> CGImage? {
        guard (0..<EQLayout.frameCount).contains(bandFrame), let (sheet, rect) = resolve(spriteName), let image = sheets[sheet]
        else { return nil }
        let frameRect = EQLayout.bandFrameRect(in: rect, frame: bandFrame)
        guard frameRect.maxX <= CGFloat(image.width), frameRect.maxY <= CGFloat(image.height) else { return nil }
        return image.cropping(to: frameRect)
    }
}
