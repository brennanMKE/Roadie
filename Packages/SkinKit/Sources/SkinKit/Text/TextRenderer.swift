import CoreGraphics

extension Skin {
    /// `text` in the text.bmp font, one 5x6 cell per UTF-16 unit, left to right, cells without a glyph
    /// transparent. nil when the skin has no TEXT sheet or `text` is empty.
    public func textImage(_ text: String) -> CGImage? {
        guard let sheet = sheets[TextFont.sheet] else { return nil }
        let cells = TextFont.cells(for: text)
        guard !cells.isEmpty else { return nil }
        guard let context = CGContext(
            data: nil, width: cells.count * TextFont.cellWidth, height: TextFont.cellHeight,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .none
        for (index, name) in cells.enumerated() {
            guard let name, let entry = SkinSprites.byName[name],
                  let glyph = sheet.cropping(to: entry.sprite.rect)
            else { continue }
            context.draw(
                glyph,
                in: CGRect(x: index * TextFont.cellWidth, y: 0, width: TextFont.cellWidth, height: TextFont.cellHeight))
        }
        return context.makeImage()
    }
}
