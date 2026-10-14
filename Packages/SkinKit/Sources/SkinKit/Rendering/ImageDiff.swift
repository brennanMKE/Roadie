import CoreGraphics
import Foundation

/// Pixel comparison of a render against a reference screenshot.
public enum ImageDiff {
    public struct Result: Equatable, Sendable {
        /// Pixels compared (alpha non-zero in both images).
        public var compared = 0
        /// Pixels whose RGB differs at all.
        public var differing = 0
        /// Pixels that differ by more than `tolerance` in some channel.
        public var beyondTolerance = 0
        /// Pixels skipped because alpha is 0 in either image.
        public var skippedTransparent = 0
        /// `differing` / `beyondTolerance` again, not counting pixels inside the `ignoring` rects.
        public var differingOutsideIgnored = 0
        public var beyondToleranceOutsideIgnored = 0

        public init() {}
    }

    /// Both images are drawn into device-RGB RGBA8 buffers of `ours`' size; a taller `reference` (the Museum's
    /// 275x348 stack) is cropped to its top rows. `ignoring` rects (device pixels) are still counted in the first
    /// pair of numbers and excluded from the `OutsideIgnored` pair.
    public static func compare(ours: CGImage, reference: CGImage, tolerance: UInt8 = 2, ignoring: [CGRect] = []) -> Result {
        let width = ours.width, height = ours.height
        let a = pixels(ours, width: width, height: height)
        let b = pixels(reference, width: width, height: height)
        var result = Result()
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if a[i + 3] == 0 || b[i + 3] == 0 {
                    result.skippedTransparent += 1
                    continue
                }
                result.compared += 1
                var maxDelta = 0
                for c in 0..<3 { maxDelta = max(maxDelta, abs(Int(a[i + c]) - Int(b[i + c]))) }
                guard maxDelta > 0 else { continue }
                let ignored = ignoring.contains { $0.contains(CGPoint(x: x, y: y)) }
                result.differing += 1
                if !ignored { result.differingOutsideIgnored += 1 }
                if maxDelta > Int(tolerance) {
                    result.beyondTolerance += 1
                    if !ignored { result.beyondToleranceOutsideIgnored += 1 }
                }
            }
        }
        return result
    }

    /// `ours` with every differing pixel painted magenta.
    public static func diffImage(ours: CGImage, reference: CGImage) -> CGImage {
        let width = ours.width, height = ours.height
        var a = pixels(ours, width: width, height: height)
        let b = pixels(reference, width: width, height: height)
        for i in stride(from: 0, to: a.count, by: 4) where a[i + 3] != 0 && b[i + 3] != 0 {
            if a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2] {
                a[i] = 255; a[i + 1] = 0; a[i + 2] = 255; a[i + 3] = 255
            }
        }
        return a.withUnsafeMutableBytes { raw in
            CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
    }

    /// Premultiplied RGBA8, `width` x `height`, the image's top-left corner at (0, 0); it is cropped, not scaled.
    private static func pixels(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.interpolationQuality = .none
            // CG is y up: place the image so its top row lands on the buffer's top row.
            context.draw(image, in: CGRect(x: 0, y: height - image.height, width: image.width, height: image.height))
        }
        return bytes
    }
}
