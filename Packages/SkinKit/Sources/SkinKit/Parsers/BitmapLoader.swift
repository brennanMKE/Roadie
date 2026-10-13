import CoreGraphics
import Foundation
import ImageIO

enum BitmapLoader {
    /// Decodes BMP (or PNG, which WACUP permits) data via ImageIO.
    /// TODO: add a fallback BMP decoder for files ImageIO rejects.
    static func image(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
