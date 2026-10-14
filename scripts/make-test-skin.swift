// make-test-skin.swift — write a tiny classic skin for the Quick Look checks (#0043).
// Usage: swift scripts/make-test-skin.swift <out.wsz>
// main.png 275x116 #FF00FF, titlebar.png 275x29 #0000FF, cbuttons.png 136x36 #00FF00, zipped flat with /usr/bin/zip.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func writePNG(_ path: String, _ w: Int, _ h: Int, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) {
    let context = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("PNG write failed: \(path)") }
}

guard CommandLine.arguments.count == 2 else { fatalError("usage: make-test-skin.swift <out.wsz>") }
let out = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("make-test-skin-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
writePNG(dir.appendingPathComponent("main.png").path, 275, 116, 1, 0, 1)
writePNG(dir.appendingPathComponent("titlebar.png").path, 275, 29, 0, 0, 1)
writePNG(dir.appendingPathComponent("cbuttons.png").path, 136, 36, 0, 1, 0)
try? FileManager.default.removeItem(at: out)
let zip = Process()
zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
zip.currentDirectoryURL = dir
zip.arguments = ["-q", "-j", out.path, "main.png", "titlebar.png", "cbuttons.png"]
try zip.run()
zip.waitUntilExit()
guard zip.terminationStatus == 0 else { fatalError("zip failed") }
try? FileManager.default.removeItem(at: dir)
