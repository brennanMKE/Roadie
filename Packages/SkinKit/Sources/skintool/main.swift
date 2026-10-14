import Foundation
import SkinKit

// Usage: skintool [-v|--verbose] <skin.wsz | folder>
// Prints one line per skin: ok / partial (warnings) / failed (reason). -v adds the fallbacks used.
// Exit status: 0 only if every skin is ok, 1 otherwise (64 usage, 66 no such file).

var arguments = Array(CommandLine.arguments.dropFirst())
let verbose = arguments.contains { $0 == "-v" || $0 == "--verbose" }
arguments.removeAll { $0 == "-v" || $0 == "--verbose" }
guard let path = arguments.first else {
    FileHandle.standardError.write(Data("usage: skintool [-v|--verbose] <skin.wsz | folder>\n".utf8))
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
        let notes = verbose && !skin.fallbacks.isEmpty ? "\n         fallbacks: \(skin.fallbacks.joined(separator: "; "))" : ""
        if skin.warnings.isEmpty {
            counts.ok += 1
            print("ok       \(url.lastPathComponent)\(notes)")
        } else {
            counts.partial += 1
            print("partial  \(url.lastPathComponent): \(skin.warnings.joined(separator: "; "))\(notes)")
        }
    } catch {
        counts.failed += 1
        print("failed   \(url.lastPathComponent): \(error)")
    }
}
print("\n\(skins.count) skins: \(counts.ok) ok, \(counts.partial) partial, \(counts.failed) failed")
exit(counts.ok == skins.count ? 0 : 1)
