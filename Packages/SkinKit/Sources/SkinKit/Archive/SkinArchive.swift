import Foundation
import ZIPFoundation

/// Read-only view of a `.wsz` archive with case-insensitive lookup by base file name.
///
/// Skins may keep their files at the archive root or inside a single subfolder,
/// so lookup ignores directories and matches only on the last path component.
public struct SkinArchive: Sendable {
    /// Lowercased file name (e.g. "main.bmp") -> file contents.
    public let files: [String: Data]

    public init(url: URL) throws(SkinError) {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw .unreadableArchive(error.localizedDescription)
        }

        var files: [String: Data] = [:]
        for entry in archive where entry.type == .file {
            let name = (entry.path as NSString).lastPathComponent.lowercased()
            // Winamp only materializes one file per case-insensitive name; first one wins.
            guard !name.isEmpty, files[name] == nil else { continue }
            var data = Data()
            do {
                _ = try archive.extract(entry, skipCRC32: true) { data.append($0) }
            } catch {
                continue
            }
            files[name] = data
        }
        self.files = files
    }

    public init(files: [String: Data]) {
        self.files = Dictionary(files.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    /// Returns the first file matching `baseName` with one of `extensions`, case-insensitively.
    public func file(_ baseName: String, extensions: [String]) -> Data? {
        for ext in extensions {
            if let data = files["\(baseName.lowercased()).\(ext.lowercased())"] { return data }
        }
        return nil
    }
}
