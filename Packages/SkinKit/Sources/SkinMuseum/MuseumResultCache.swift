import Foundation

/// Result pages on disk, keyed by `MuseumQuery.cacheKey`, with a TTL and entry/byte caps.
/// A file's modification date is its store time; eviction drops the oldest first.
public actor MuseumResultCache {
    public static let defaultTTL: TimeInterval = 24 * 60 * 60

    private let directory: URL
    private let ttl: TimeInterval
    private let maxEntries: Int
    private let maxBytes: Int
    private let now: @Sendable () -> Date
    private let fileManager = FileManager.default

    public init(
        directory: URL, ttl: TimeInterval = MuseumResultCache.defaultTTL, maxEntries: Int = 500,
        maxBytes: Int = 20 * 1024 * 1024, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.ttl = ttl
        self.maxEntries = maxEntries
        self.maxBytes = maxBytes
        self.now = now
    }

    /// Keys are sha256 hex; anything else never becomes a path.
    private func fileURL(_ key: String) -> URL? {
        guard key.utf8.count == 64, key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            return nil
        }
        return directory.appendingPathComponent("\(key).json")
    }

    public func page(for key: String) -> (page: MuseumPage, isStale: Bool)? {
        guard let url = fileURL(key),
              let data = try? Data(contentsOf: url),
              let page = try? JSONDecoder().decode(MuseumPage.self, from: data),
              let stored = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return nil }
        return (page, now().timeIntervalSince(stored) > ttl)
    }

    public func store(_ page: MuseumPage, for key: String) {
        guard let url = fileURL(key), let data = try? JSONEncoder().encode(page) else { return }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes([.modificationDate: now()], ofItemAtPath: url.path)
        } catch {
            return
        }
        evict()
    }

    private func evict() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)
        else { return }
        var entries = files.filter { $0.pathExtension == "json" }.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return (url: url, date: values?.contentModificationDate ?? .distantPast, size: values?.fileSize ?? 0)
        }
        entries.sort { $0.date < $1.date }
        var total = entries.reduce(0) { $0 + $1.size }
        var index = 0
        while index < entries.count, entries.count - index > maxEntries || total > maxBytes {
            try? fileManager.removeItem(at: entries[index].url)
            total -= entries[index].size
            index += 1
        }
    }
}
