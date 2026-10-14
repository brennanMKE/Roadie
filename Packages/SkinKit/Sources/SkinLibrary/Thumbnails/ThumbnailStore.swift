import CoreGraphics
import Foundation
import ImageIO

/// The on-disk layout of the thumbnail cache: `<root>/r<version>/<hash>-275x116.png`, plus an empty
/// `<hash>-275x116.failed` marker for skins that cannot be parsed. Internal; `SkinThumbnailCache` is the API.
struct ThumbnailStore: Sendable {
    let root: URL
    let version: Int
    private static let suffix = "-275x116"

    var versionDirectory: URL { root.appending(path: "r\(version)", directoryHint: .isDirectory) }

    func url(for hash: String) -> URL { versionDirectory.appending(path: hash + Self.suffix + ".png") }
    func markerURL(for hash: String) -> URL { versionDirectory.appending(path: hash + Self.suffix + ".failed") }

    /// Creates `r<version>/` and removes every other `r*` sibling (older renderer versions).
    @discardableResult
    func prepare() -> Int {
        let fm = FileManager.default
        try? fm.createDirectory(at: versionDirectory, withIntermediateDirectories: true)
        var removed = 0
        let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for child in children where child.lastPathComponent.hasPrefix("r") && child.lastPathComponent != "r\(version)" {
            if (try? fm.removeItem(at: child)) != nil { removed += 1 }
        }
        return removed
    }

    /// Decodes on the calling (worker) thread, not lazily at draw time.
    func readPNG(_ hash: String) -> CGImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        guard let source = CGImageSourceCreateWithURL(url(for: hash) as CFURL, options as CFDictionary) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }

    /// Atomic write; recreates the directories once when they have been purged mid-session.
    func write(_ data: Data, hash: String) throws {
        do {
            try data.write(to: url(for: hash), options: .atomic)
        } catch {
            try FileManager.default.createDirectory(at: versionDirectory, withIntermediateDirectories: true)
            try data.write(to: url(for: hash), options: .atomic)
        }
    }

    func writeFailedMarker(_ hash: String) {
        let fm = FileManager.default
        if !fm.createFile(atPath: markerURL(for: hash).path, contents: nil) {
            try? fm.createDirectory(at: versionDirectory, withIntermediateDirectories: true)
            _ = fm.createFile(atPath: markerURL(for: hash).path, contents: nil)
        }
    }

    func hasFailedMarker(_ hash: String) -> Bool { FileManager.default.fileExists(atPath: markerURL(for: hash).path) }

    func removeAll() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    /// Deletes the oldest PNGs until the total is at most 75 % of `limitBytes` (only when it is over the limit).
    /// Markers are zero bytes and are left alone. Returns (files removed, bytes remaining).
    @discardableResult
    func sweep(limitBytes: Int64) -> (removed: Int, remaining: Int64) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: versionDirectory, includingPropertiesForKeys: keys)) ?? []
        var entries: [(url: URL, size: Int64, date: Date)] = []
        for file in files where file.pathExtension == "png" {
            let values = try? file.resourceValues(forKeys: Set(keys))
            entries.append((file, Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? .distantPast))
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > limitBytes else { return (0, total) }
        let target = limitBytes / 4 * 3
        var removed = 0
        for entry in entries.sorted(by: { $0.date < $1.date }) where total > target {
            if (try? FileManager.default.removeItem(at: entry.url)) != nil {
                total -= entry.size
                removed += 1
            }
        }
        return (removed, total)
    }
}
