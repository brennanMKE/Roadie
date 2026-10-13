import CoreGraphics

/// A rectangle within one of a skin's bitmap sheets.
public struct Sprite: Sendable, Hashable {
    public let name: String
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

extension SkinSprites {
    /// Lookup table from sprite name to (sheet, sprite).
    public static let byName: [String: (sheet: String, sprite: Sprite)] = {
        var result: [String: (sheet: String, sprite: Sprite)] = [:]
        for (sheet, sprites) in sheets {
            for sprite in sprites { result[sprite.name] = (sheet, sprite) }
        }
        return result
    }()
}
