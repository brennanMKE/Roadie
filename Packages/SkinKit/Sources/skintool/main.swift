import Foundation
import SkinKit

// Usage: skintool <skin.wsz | folder>
// Prints one line per skin: ok / partial (warnings) / failed (reason).

let arguments = CommandLine.arguments.dropFirst()
guard let path = arguments.first else {
    FileHandle.standardError.write(Data("usage: skintool <skin.wsz | folder>\n".utf8))
    exit(64)
}

let root = URL(filePath: path)
var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
    FileHandle.standardError.write(Data("skintool: no such file: \(path)\n".utf8))
    exit(66)
}

var skins: [URL] = []
if isDirectory.boolValue {
    let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    while let url = enumerator?.nextObject() as? URL {
        if ["wsz", "zip"].contains(url.pathExtension.lowercased()) { skins.append(url) }
    }
    skins.sort { $0.path < $1.path }
} else {
    skins = [root]
}

var counts = (ok: 0, partial: 0, failed: 0)
for url in skins {
    do {
        let skin = try SkinParser.parse(url: url)
        if skin.warnings.isEmpty {
            counts.ok += 1
            print("ok       \(url.lastPathComponent)")
        } else {
            counts.partial += 1
            print("partial  \(url.lastPathComponent): \(skin.warnings.joined(separator: "; "))")
        }
    } catch {
        counts.failed += 1
        print("failed   \(url.lastPathComponent): \(error)")
    }
}
print("\n\(skins.count) skins: \(counts.ok) ok, \(counts.partial) partial, \(counts.failed) failed")
