import CoreGraphics
import Foundation

/// A parsed classic skin. Missing files are recorded as warnings, not failures.
public struct Skin: @unchecked Sendable {
    /// Sheet name (e.g. "MAIN", "CBUTTONS") -> decoded bitmap. `CGImage` is immutable.
    public let sheets: [String: CGImage]
    public let visColors: [RGBColor]
    public let warnings: [String]

    /// Crops a named sprite (e.g. "MAIN_PLAY_BUTTON") out of its sheet.
    public func image(for spriteName: String) -> CGImage? {
        guard let (sheet, sprite) = SkinSprites.byName[spriteName],
              let image = sheets[sheet]
        else { return nil }
        return image.cropping(to: sprite.rect)
    }
}
