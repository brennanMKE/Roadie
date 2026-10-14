import CoreGraphics
import Foundation

/// `region.txt`: per window state, the polygons (skin pixels, y down, union) that are drawn.
public struct SkinRegion: Sendable, Equatable {
    public struct Point: Sendable, Hashable {
        public let x: Int
        public let y: Int
        public init(x: Int, y: Int) {
            self.x = x
            self.y = y
        }
    }

    public typealias Polygon = [Point]

    /// Lowercased section name to polygons; Webamp's `RegionData`.
    public let sections: [String: [Polygon]]

    public init(sections: [String: [Polygon]]) {
        self.sections = sections
    }

    public static let empty = SkinRegion(sections: [:])
    public var isEmpty: Bool { sections.isEmpty }

    // Webamp's mapRegionNamesToIds (Skin.tsx); nil = rectangular.
    public var normal: [Polygon]? { sections["normal"] }
    public var windowShade: [Polygon]? { sections["windowshade"] }
    public var equalizer: [Polygon]? { sections["equalizer"] }
    public var equalizerShade: [Polygon]? { sections["equalizerws"] }

    /// The polygons as one path in points x scale, nonzero winding (ClipPaths.tsx draws one SVG
    /// `<polygon>` per entry inside one `<clipPath>`: a union). Top-left origin, y down.
    public static func path(_ polygons: [Polygon], scale: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for polygon in polygons {
            guard let first = polygon.first else { continue }
            path.move(to: CGPoint(x: CGFloat(first.x) * scale, y: CGFloat(first.y) * scale))
            for point in polygon.dropFirst() {
                path.addLine(to: CGPoint(x: CGFloat(point.x) * scale, y: CGFloat(point.y) * scale))
            }
            path.closeSubpath()
        }
        return path
    }

    /// An alpha mask of `size` (skin pixels) at `scale`, filled without antialiasing so edges land on
    /// whole pixels like Winamp's Win32 region. Row 0 of the image is the top of the skin.
    public static func maskImage(_ polygons: [Polygon], size: CGSize, scale: CGFloat) -> CGImage? {
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setShouldAntialias(false)
        context.setAllowsAntialiasing(false)
        // Top-left origin, y down.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.addPath(path(polygons, scale: scale))
        context.fillPath(using: .winding)
        return context.makeImage()
    }
}
