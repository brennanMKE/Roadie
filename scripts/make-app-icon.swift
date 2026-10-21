#!/usr/bin/env swift
// make-app-icon.swift — build App/Assets.xcassets/AppIcon.appiconset from the square artwork in Design/AppIcon.png.
//
// macOS icon grid: on a 1024 canvas the rounded-rect body is 824 × 824 at a 100 pt inset, corner radius 185.4, with
// Apple's drop shadow (black 50 %, blur 28, 12 down). The artwork is scaled to fill the body and clipped to it.
// Usage: scripts/make-app-icon.swift [Design/AppIcon.png]   (an image tool; it doesn't build or launch the app)

import AppKit

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
    ?? repo.appendingPathComponent("Design/AppIcon.png")
guard let art = NSImage(contentsOf: source)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("make-app-icon: can't read \(source.path)\n".data(using: .utf8)!)
    exit(1)
}
let set = repo.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px) / 1024
    let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = CGPath(roundedRect: body, cornerWidth: 185.4 * s, cornerHeight: 185.4 * s, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 28 * s, color: CGColor(gray: 0, alpha: 0.5))
    ctx.addPath(path)
    ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.draw(art, in: body)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(points * scale).write(to: set.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: set.appendingPathComponent("Contents.json"))
let catalog = repo.appendingPathComponent("App/Assets.xcassets/Contents.json")
try #"{"info":{"author":"xcode","version":1}}"#.data(using: .utf8)!.write(to: catalog)
print("==> \(set.path)")
