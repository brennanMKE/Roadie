// capture-roadie-windows.swift — guest-side helper for scripts/make-screenshots.sh (#0168).
//
// Runs inside the Tart guest only.
//   capture-roadie-windows wallpaper <RRGGBB>   set every screen's desktop picture to that plain colour
//   capture-roadie-windows capture <out.png> [x] capture the screen and crop it to Roadie's docked window stack
//
// The crop is the union of Roadie's on-screen windows whose left edge is at x (default: the leftmost Roadie
// window's): main, equalizer and playlist, docked in a column. The PNG has one pixel per point: Roadie draws one skin pixel as two points, so it is twice the skin's
// native size. Scaling (only on a Retina display) is nearest-neighbour so the pixels stay crisp.
// `capture` prints "<width>x<height>" of the written PNG.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("cannot write \(url.path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fail("cannot write \(url.path)") }
}

func context(width: Int, height: Int) -> CGContext {
    guard let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("no bitmap context") }
    ctx.interpolationQuality = .none
    return ctx
}

let args = CommandLine.arguments
guard args.count >= 3 else { fail("usage: capture-roadie-windows wallpaper <RRGGBB> | capture <out.png> [left x]") }

switch args[1] {
case "wallpaper":
    guard args[2].count == 6, let rgb = UInt32(args[2], radix: 16) else { fail("colour must be RRGGBB") }
    let ctx = context(width: 64, height: 64)
    ctx.setFillColor(
        red: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255,
        blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("wallpaper-\(args[2]).png")
    writePNG(ctx.makeImage()!, to: url)
    for screen in NSScreen.screens {
        do {
            try NSWorkspace.shared.setDesktopImageURL(
                url, for: screen, options: [.imageScaling: NSImageScaling.scaleAxesIndependently.rawValue])
        } catch { fail("setDesktopImageURL: \(error)") }
    }

case "capture":
    let outURL = URL(fileURLWithPath: args[2])
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    let bounds: [CGRect] = info.compactMap { entry in
        guard (entry[kCGWindowOwnerName as String] as? String) == "Roadie",
            (entry[kCGWindowLayer as String] as? Int) == 0,
            let dict = entry[kCGWindowBounds as String] as? NSDictionary,
            let rect = CGRect(dictionaryRepresentation: dict),
            rect.width >= 100, rect.height >= 20
        else { return nil }
        return rect
    }
    for rect in bounds { FileHandle.standardError.write(Data("roadie window \(rect)\n".utf8)) }
    // The stack's left edge: given (where make-screenshots.sh placed it), else the leftmost Roadie window's.
    guard let left = args.count == 4 ? Double(args[3]).map({ CGFloat($0) }) : bounds.map(\.minX).min()
    else { fail("no on-screen Roadie windows") }
    let stack = bounds.filter { abs($0.minX - left) < 1 }
    guard !stack.isEmpty else { fail("no Roadie window at x = \(left)") }
    let union = stack.dropFirst().reduce(stack[0]) { $0.union($1) }

    // Whole main display; window bounds are top-down points from the main display's top-left.
    let shot = FileManager.default.temporaryDirectory.appendingPathComponent("roadie-screen.png")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-x", "-m", "-t", "png", shot.path]
    try? task.run()
    task.waitUntilExit()
    guard task.terminationStatus == 0,
        let source = CGImageSourceCreateWithURL(shot as CFURL, nil),
        let screen = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fail("screencapture failed") }
    try? FileManager.default.removeItem(at: shot)
    let points = CGDisplayBounds(CGMainDisplayID())
    let scale = CGFloat(screen.width) / points.width
    let crop = CGRect(
        x: (union.minX - points.minX) * scale, y: (union.minY - points.minY) * scale,
        width: union.width * scale, height: union.height * scale
    ).integral
    guard let cropped = screen.cropping(to: crop) else { fail("crop \(crop) is off the screen") }
    let width = Int(union.width.rounded()), height = Int(union.height.rounded())
    let ctx = context(width: width, height: height)
    ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
    writePNG(ctx.makeImage()!, to: outURL)
    print("\(width)x\(height)")

default:
    fail("unknown command \(args[1])")
}
