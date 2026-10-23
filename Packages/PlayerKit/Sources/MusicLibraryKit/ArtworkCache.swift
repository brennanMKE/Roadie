import Foundation
import ImageIO
import MusicBackendKit
import os

/// A bounded in-memory cache of decoded thumbnails over `MusicBackend.artwork(_:maxPixels:)`.
/// Least-recently-used eviction by bytes and count, one fetch per ref however many callers ask,
/// and a memory of refs that have no art so the placeholder shows without a second request.
/// It never builds a URL or sees a token; the backend does the fetching.
public actor ArtworkCache {
    /// One size for every list cell: 200 px covers a 100 pt cell at 2x.
    public static let thumbnailPixels = 200
    public static let defaultLimitBytes = 32 * 1024 * 1024
    public static let defaultLimitCount = 400

    public struct Statistics: Hashable, Sendable {
        public var hits = 0
        public var misses = 0
        public var fetches = 0
        public var failures = 0
        public var evictions = 0
        public var count = 0
        public var bytes = 0
    }

    private struct Entry {
        var artwork: Artwork
        var lastUsed: UInt64
    }

    public nonisolated let maxPixels: Int
    private let backend: any MusicBackend
    private let limitBytes: Int
    private let limitCount: Int
    private var entries: [ArtworkRef: Entry] = [:]
    private var inFlight: [ArtworkRef: Task<Artwork?, Never>] = [:]
    private var missing: Set<ArtworkRef> = []
    private var tick: UInt64 = 0
    private var stats = Statistics()
    private static let log = Logger(subsystem: "co.sstools.roadie", category: "ArtworkCache")

    public init(
        backend: any MusicBackend, maxPixels: Int = thumbnailPixels,
        limitBytes: Int = defaultLimitBytes, limitCount: Int = defaultLimitCount
    ) {
        self.backend = backend
        self.maxPixels = maxPixels
        self.limitBytes = limitBytes
        self.limitCount = max(1, limitCount)
    }

    public var statistics: Statistics { stats }

    /// The thumbnail for `ref`, or nil when there is none (show the placeholder). Never throws: a failure is a nil.
    /// Concurrent calls for the same ref share one fetch; a caller that is cancelled stops caring, the fetch
    /// finishes and the result is cached for the next caller.
    public func image(for ref: ArtworkRef) async -> Artwork? {
        if let artwork = touch(ref) {
            stats.hits += 1
            return artwork
        }
        if missing.contains(ref) {
            stats.hits += 1
            return nil
        }
        if let task = inFlight[ref] { return await task.value }
        stats.misses += 1
        let task = Task { await self.run(ref) }
        inFlight[ref] = task
        return await task.value
    }

    /// Without fetching or marking use.
    public func cached(_ ref: ArtworkRef) -> Artwork? { entries[ref]?.artwork }

    /// Forgets images and misses. In-flight fetches finish and insert, which is correct.
    public func clear() {
        entries = [:]
        missing = []
        stats.count = 0
        stats.bytes = 0
    }

    // MARK: Fetching

    private func run(_ ref: ArtworkRef) async -> Artwork? {
        stats.fetches += 1
        let result = await fetch(ref)
        inFlight[ref] = nil
        return result
    }

    private func fetch(_ ref: ArtworkRef) async -> Artwork? {
        do {
            let data = try await backend.artwork(ref, maxPixels: maxPixels)
            guard let image = Self.decode(data, maxPixels: maxPixels) else {
                remember(missing: ref)
                Self.log.debug("artwork not decodable, \(self.stats.failures, privacy: .public) failures")
                return nil
            }
            let artwork = Artwork(image: image)
            insert(ref, artwork)
            return artwork
        } catch let error as MusicBackendError {
            switch error {
            case .notFound, .unsupported: remember(missing: ref)
            default: stats.failures += 1
            }
            Self.log.debug("artwork failed, \(self.stats.failures, privacy: .public) failures")
            return nil
        } catch {
            stats.failures += 1
            return nil
        }
    }

    private func remember(missing ref: ArtworkRef) {
        stats.failures += 1
        if missing.count >= limitCount { missing = [] }
        missing.insert(ref)
    }

    private static func decode(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: Storage

    private func touch(_ ref: ArtworkRef) -> Artwork? {
        guard var entry = entries[ref] else { return nil }
        tick += 1
        entry.lastUsed = tick
        entries[ref] = entry
        return entry.artwork
    }

    private func insert(_ ref: ArtworkRef, _ artwork: Artwork) {
        if let old = entries[ref] { stats.bytes -= old.artwork.byteCount }
        tick += 1
        entries[ref] = Entry(artwork: artwork, lastUsed: tick)
        stats.bytes += artwork.byteCount
        while entries.count > 1, stats.bytes > limitBytes || entries.count > limitCount {
            guard let oldest = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed }) else { break }
            // The entry just inserted is the newest, so it goes last (and a lone oversized image stays).
            stats.bytes -= oldest.value.artwork.byteCount
            entries[oldest.key] = nil
            stats.evictions += 1
        }
        stats.count = entries.count
    }
}
