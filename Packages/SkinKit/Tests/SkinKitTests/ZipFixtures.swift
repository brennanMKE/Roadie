import CoreGraphics
import Foundation
import ZIPFoundation
@testable import SkinKit

/// Writes small synthetic `.wsz` archives into a fresh temp folder.
enum ZipFixtures {
    static func tempURL(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skinamp-ql-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    @discardableResult
    static func zip(_ files: [(String, Data)], named name: String = "test.wsz") throws -> URL {
        let url = tempURL(name)
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in files {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        return url
    }

    /// Every sheet of `TestSkin.make()` as PNGs, plus `extra` files.
    static func skinFiles(omitting: Set<String> = ["NUMS_EX"], extra: [(String, Data)] = []) -> [(String, Data)] {
        let skin = TestSkin.make(omitting: omitting)
        var files: [(String, Data)] = skin.sheets.sorted { $0.key < $1.key }.compactMap { name, image in
            PNGWriter.data(image).map { ("\(name.lowercased()).png", $0) }
        }
        files.append(contentsOf: extra)
        return files
    }
}
