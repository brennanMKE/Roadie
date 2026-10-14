// ql-thumb.swift — ask Quick Look for a thumbnail through the public QLThumbnailGenerator API (#0043).
// Usage: swift scripts/ql-thumb.swift <file> <maxPoints> <out.png>
// Exit 0 and writes a PNG only if a thumbnail of type .thumbnail (not .icon) came back from an extension.
import AppKit
import Foundation
import QuickLookThumbnailing

let a = CommandLine.arguments
guard a.count == 4, let side = Double(a[2]) else { fatalError("usage: ql-thumb.swift <file> <maxPoints> <out.png>") }
let request = QLThumbnailGenerator.Request(
    fileAt: URL(fileURLWithPath: a[1]), size: CGSize(width: side, height: side), scale: 1,
    representationTypes: [.thumbnail, .icon])
var code: Int32 = 3
QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
    if let representation {
        let type = representation.type == .thumbnail ? "thumbnail" : "icon"
        print("ql-thumb: type=\(type) size=\(representation.cgImage.width)x\(representation.cgImage.height)")
        if representation.type == .thumbnail {
            let rep = NSBitmapImageRep(cgImage: representation.cgImage)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: a[3]))
            code = 0
        } else { code = 4 }
    } else {
        print("ql-thumb: error \(String(describing: error))")
        code = 5
    }
    exit(code)
}
DispatchQueue.global().asyncAfter(deadline: .now() + 40) { print("ql-thumb: timeout"); exit(6) }
RunLoop.main.run()
