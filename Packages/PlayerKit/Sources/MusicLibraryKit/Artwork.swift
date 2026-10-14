import CoreGraphics
import Foundation

/// A decoded thumbnail. `CGImage` is immutable, so sharing it across actors is sound.
public struct Artwork: @unchecked Sendable {
    public let image: CGImage
    public var pixelWidth: Int { image.width }
    public var pixelHeight: Int { image.height }
    /// Decoded size in bytes (bytesPerRow x height), the cost used for the byte budget.
    public var byteCount: Int { image.bytesPerRow * image.height }

    public init(image: CGImage) { self.image = image }
}
