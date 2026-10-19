import CoreGraphics
import Foundation
import ImageIO

enum BitmapLoader {
    /// Decodes BMP (or PNG, which WACUP permits) data: ImageIO first, then `BMPDecoder` for BMP variants ImageIO rejects.
    static func image(from data: Data) -> CGImage? {
        image(from: data, primary: imageIO)
    }

    static func image(from data: Data, primary: (Data) -> CGImage?) -> CGImage? {
        primary(data) ?? BMPDecoder.decode(data)
    }

    static func imageIO(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
