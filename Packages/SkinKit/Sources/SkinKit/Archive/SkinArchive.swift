import Foundation
import ZIPFoundation

/// Read-only view of a `.wsz` archive with case-insensitive lookup by base file name.
///
/// Skins may keep their files at the archive root or inside a single subfolder,
/// so lookup ignores directories and matches only on the last path component.
public struct SkinArchive: Sendable {
    /// Lowercased file name (e.g. "main.bmp") -> file contents.
    public let files: [String: Data]

    /// Caps for untrusted archives (Quick Look renders every `.wsz` Finder shows, unasked). Entries over
    /// `maxEntryBytes`, with an extension outside `allowedExtensions`, or past `maxTotalBytes` are skipped.
    public struct Limits: Sendable {
        public var maxEntryBytes: Int = 8 << 20
        public var maxTotalBytes: Int = 64 << 20
        public var allowedExtensions: Set<String> = ["bmp", "png", "txt", "cur", "ani", "ini", "xml"]
        public static let `default` = Limits()
        public init(maxEntryBytes: Int = 8 << 20, maxTotalBytes: Int = 64 << 20, allowedExtensions: Set<String>? = nil) {
            self.maxEntryBytes = maxEntryBytes
            self.maxTotalBytes = maxTotalBytes
            if let allowedExtensions { self.allowedExtensions = allowedExtensions }
        }
    }

    private struct LimitExceeded: Error {}

    public init(url: URL, limits: Limits = .default) throws(SkinError) {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw .unreadableArchive(error.localizedDescription)
        }

        var files: [String: Data] = [:]
        var total = 0
        for entry in archive where entry.type == .file {
            if total >= limits.maxTotalBytes { break }
            let name = (entry.path as NSString).lastPathComponent.lowercased()
            // Winamp only materializes one file per case-insensitive name; first one wins.
            guard !name.isEmpty, files[name] == nil else { continue }
            guard limits.allowedExtensions.contains((name as NSString).pathExtension),
                entry.uncompressedSize <= UInt64(limits.maxEntryBytes)
            else { continue }
            var data = Data()
            do {
                // The central directory is as untrusted as the data: enforce the caps while inflating too.
                _ = try archive.extract(entry, skipCRC32: true) { chunk in
                    data.append(chunk)
                    if data.count > limits.maxEntryBytes || total + data.count > limits.maxTotalBytes { throw LimitExceeded() }
                }
            } catch {
                continue
            }
            total += data.count
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
