import CoreGraphics
import Foundation
import SkinKit

// Usage: skintool [-v|--verbose] [--png <out> [--state webamp|idle] [--scale N] [--compare <refdir>] [--no-region]]
//                 <skin.wsz | folder>
// Prints one line per skin: ok / partial (warnings) / failed (reason). -v adds the fallbacks used.
// --png also renders the main window headless (no AppKit, no window) to <out> (a file for one skin, a folder
// for a folder, <basename>.png each); --compare diffs each render against <refdir>/<basename>.png and writes
// <out>/<basename>.diff.png. Comparison numbers are reported, never gated.
// Exit status: 0 only if every skin is ok and every render succeeded, 1 otherwise (64 usage, 66 no such file).

func standardError(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

let options: SkintoolOptions
switch SkintoolOptions.parse(Array(CommandLine.arguments.dropFirst())) {
case .success(let parsed): options = parsed
case .failure(let error):
    standardError("skintool: \(error)\n\(SkintoolOptions.usage)")
    exit(64)
}

let root = URL(filePath: options.input)
var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
    standardError("skintool: no such file: \(options.input)")
    exit(66)
}

let isDir = isDirectory.boolValue
var skins: [URL] = []
if isDir {
    let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    while let url = enumerator?.nextObject() as? URL {
        if ["wsz", "zip"].contains(url.pathExtension.lowercased()) { skins.append(url) }
    }
    skins.sort { $0.path < $1.path }
} else {
    skins = [root]
}

if let out = options.png, isDir {
    try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
}

func render(_ skin: Skin, name: String, url: URL) -> Bool {
    guard let out = options.png else { return true }
    let target = isDir ? URL(filePath: out).appending(path: "\(name).png") : URL(filePath: out)
    let state: MainWindowState = options.state == .idle ? .idle : .webampScreenshot
    let image = MainWindowRenderer.render(skin: skin, state: state, scale: options.scale, clipToRegion: !options.noRegion)
    do {
        try PNGWriter.write(image, to: target)
    } catch {
        print("failed   \(url.lastPathComponent): PNG write to \(target.path): \(error)")
        return false
    }
    print("png      \(name) -> \(target.path)")
    if let refdir = options.compare {
        let referenceURL = URL(filePath: refdir).appending(path: "\(name).png")
        guard let reference = PNGWriter.read(referenceURL) else {
            print("noref    \(name)")
            return true
        }
        let vis = MainWindowLayout.visualizer
        let result = ImageDiff.compare(ours: image, reference: reference, tolerance: 2, ignoring: [vis])
        let diffName = isDir ? target.deletingLastPathComponent().appending(path: "\(name).diff.png")
            : target.deletingPathExtension().appendingPathExtension("diff.png")
        try? PNGWriter.write(ImageDiff.diffImage(ours: image, reference: reference), to: diffName)
        print(
            "diff     \(name): exact \(result.differing)/\(result.compared) px differ, ±2 \(result.beyondTolerance); "
                + "excluding vis \(result.differingOutsideIgnored) / \(result.beyondToleranceOutsideIgnored); "
                + "\(result.skippedTransparent) skipped transparent")
    }
    return true
}

var counts = (ok: 0, partial: 0, failed: 0)
var renderFailed = false
for url in skins {
    do {
        let skin = try SkinParser.parse(url: url)
        let notes = options.verbose && !skin.fallbacks.isEmpty ? "\n         fallbacks: \(skin.fallbacks.joined(separator: "; "))" : ""
        if skin.warnings.isEmpty {
            counts.ok += 1
            print("ok       \(url.lastPathComponent)\(notes)")
        } else {
            counts.partial += 1
            print("partial  \(url.lastPathComponent): \(skin.warnings.joined(separator: "; "))\(notes)")
        }
        if !render(skin, name: url.deletingPathExtension().lastPathComponent, url: url) { renderFailed = true }
    } catch {
        counts.failed += 1
        print("failed   \(url.lastPathComponent): \(error)")
    }
}
print("\n\(skins.count) skins: \(counts.ok) ok, \(counts.partial) partial, \(counts.failed) failed")
exit(counts.ok == skins.count && !renderFailed ? 0 : 1)
