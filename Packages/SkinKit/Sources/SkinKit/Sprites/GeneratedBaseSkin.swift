import CoreGraphics
import CoreText
import Foundation

/// A base skin drawn in code (bevelled grey boxes, 7-segment digits, system-font text), used by `SkinParser`
/// for sheets a skin doesn't ship or that don't decode. No artwork is copied from Winamp, Webamp or any skin.
enum GeneratedBaseSkin {
    /// Every sheet except BALANCE, NUMS_EX and EQ_EX (covered by Webamp fallbacks) and GEN (unused).
    static let sheetNames: Set<String> = Set(SkinSprites.sheets.keys).subtracting(["BALANCE", "NUMS_EX", "EQ_EX", "GEN"])

    /// The sheet's sprite extents: `max(x + width)` x `max(y + height)`.
    static func size(of sheet: String) -> (width: Int, height: Int) {
        let sprites = SkinSprites.sheets[sheet] ?? []
        return (sprites.map { $0.x + $0.width }.max() ?? 1, sprites.map { $0.y + $0.height }.max() ?? 1)
    }

    /// The cached generated sheet, or nil for names not in `sheetNames`.
    static func sheet(_ name: String) -> CGImage? { cache[name] }

    // CGImage is immutable, so sharing the cache is safe.
    nonisolated(unsafe) private static let cache: [String: CGImage] = Dictionary(
        uniqueKeysWithValues: sheetNames.compactMap { name in draw(name).map { (name, $0) } })

    private struct RGB { let r: Int, g: Int, b: Int }
    private static let ground = RGB(r: 40, g: 40, b: 48)
    private static let face = RGB(r: 150, g: 150, b: 160)
    private static let pressedFace = RGB(r: 120, g: 120, b: 130)
    private static let panelFace = RGB(r: 60, g: 60, b: 70)
    private static let light = RGB(r: 220, g: 220, b: 230)
    private static let dark = RGB(r: 70, g: 70, b: 80)
    private static let lit = RGB(r: 0, g: 230, b: 0)
    private static let black = RGB(r: 0, g: 0, b: 0)

    private static func set(_ context: CGContext, _ c: RGB) {
        context.setFillColor(red: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }

    /// Segment rects inside a 9x13 digit cell.
    private static let segments: [Character: CGRect] = [
        "a": CGRect(x: 1, y: 0, width: 7, height: 1), "b": CGRect(x: 7, y: 1, width: 1, height: 5),
        "c": CGRect(x: 7, y: 7, width: 1, height: 5), "d": CGRect(x: 1, y: 12, width: 7, height: 1),
        "e": CGRect(x: 1, y: 7, width: 1, height: 5), "f": CGRect(x: 1, y: 1, width: 1, height: 5),
        "g": CGRect(x: 1, y: 6, width: 7, height: 1),
    ]
    private static let digitSegments: [Int: String] = [
        0: "abcdef", 1: "bc", 2: "abged", 3: "abgcd", 4: "fgbc",
        5: "afgcd", 6: "afgedc", 7: "abc", 8: "abcdefg", 9: "abcdfg",
    ]

    private static func draw(_ sheet: String) -> CGImage? {
        guard let sprites = SkinSprites.sheets[sheet] else { return nil }
        let (w, h) = size(of: sheet)
        guard let context = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setShouldAntialias(false)
        context.translateBy(x: 0, y: CGFloat(h))
        context.scaleBy(x: 1, y: -1)
        let all = CGRect(x: 0, y: 0, width: w, height: h)

        switch sheet {
        case "NUMBERS":
            set(context, black); context.fill(all)
            set(context, lit)
            for digit in 0...9 {
                guard let sprite = SkinSprites.byName["DIGIT_\(digit)"]?.sprite else { continue }
                for segment in digitSegments[digit] ?? "" {
                    guard let rect = segments[segment] else { continue }
                    context.fill(rect.offsetBy(dx: CGFloat(sprite.x), dy: CGFloat(sprite.y)))
                }
            }
        case "TEXT":
            set(context, black); context.fill(all)
            let font = CTFontCreateWithName("Menlo" as CFString, 7, nil)
            let color = CGColor(red: CGFloat(lit.r) / 255, green: CGFloat(lit.g) / 255, blue: CGFloat(lit.b) / 255, alpha: 1)
            for sprite in sprites {
                guard sprite.name.hasPrefix("CHARACTER_"), let code = UInt32(sprite.name.dropFirst("CHARACTER_".count)),
                      code != 32, let scalar = UnicodeScalar(code)
                else { continue }
                let text = String(Character(scalar)).uppercased()
                let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
                guard let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else { continue }
                let line = CTLineCreateWithAttributedString(attributed)
                context.saveGState()
                context.clip(to: sprite.rect)
                context.translateBy(x: CGFloat(sprite.x), y: CGFloat(sprite.y + sprite.height))
                context.scaleBy(x: 1, y: -1)
                context.textPosition = CGPoint(x: 0, y: 1)
                CTLineDraw(line, context)
                context.restoreGState()
            }
        default:
            set(context, ground); context.fill(all)
            let ordered = sprites.sorted { ($0.width * $0.height, $1.name) > ($1.width * $1.height, $0.name) }
            for sprite in ordered { bevel(context, sprite) }
        }
        return context.makeImage()
    }

    private static func bevel(_ context: CGContext, _ sprite: Sprite) {
        let name = sprite.name
        let pressed = ["ACTIVE", "SELECTED", "DEPRESSED", "PRESSED"].contains { name.contains($0) }
        let panel = name.contains("BACKGROUND")
        let rect = sprite.rect
        set(context, panel ? panelFace : pressed ? pressedFace : face)
        context.fill(rect)
        guard sprite.width >= 3, sprite.height >= 3 else { return }
        let (topLeft, bottomRight) = pressed && !panel ? (dark, light) : (light, dark)
        set(context, topLeft)
        context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1))
        context.fill(CGRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height))
        set(context, bottomRight)
        context.fill(CGRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1))
        context.fill(CGRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height))
    }
}
