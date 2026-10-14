import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// PNG encode and decode through ImageIO; headless.
public enum PNGWriter {
    public struct WriteError: Error, CustomStringConvertible {
        public let description: String
    }

    public static func data(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    public static func write(_ image: CGImage, to url: URL) throws {
        guard let data = data(image) else { throw WriteError(description: "could not encode PNG") }
        try data.write(to: url, options: .atomic)
    }

    public static func read(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
