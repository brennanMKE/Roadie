// pixel-at.swift — print the RGBA of one pixel of a PNG (#0043).
// Usage: swift scripts/pixel-at.swift <png> <x> <y> [--of W H]
// With --of, (x, y) is in a W x H space and is mapped to (x*imageW/W, y*imageH/H), so a spot on the skin
// can be sampled from a thumbnail of any size.
import CoreGraphics
import Foundation
import ImageIO

let a = CommandLine.arguments
guard a.count >= 4, let x0 = Double(a[2]), let y0 = Double(a[3]) else { fatalError("usage: pixel-at.swift <png> <x> <y> [--of W H]") }
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else { print("unreadable"); exit(1) }
var x = x0, y = y0
if a.count >= 7, a[4] == "--of", let w = Double(a[5]), let h = Double(a[6]) {
    x = x0 * Double(image.width) / w
    y = y0 * Double(image.height) / h
}
let px = min(max(Int(x), 0), image.width - 1), py = min(max(Int(y), 0), image.height - 1)
var bytes = [UInt8](repeating: 0, count: 4)
bytes.withUnsafeMutableBytes { buffer in
    let context = CGContext(
        data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: -px, y: -(image.height - 1 - py), width: image.width, height: image.height))
}
print("\(bytes[0]) \(bytes[1]) \(bytes[2]) \(bytes[3])")
