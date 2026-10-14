import CoreGraphics
import Foundation
import SkinBrowser
import SkinLibrary

/// #0034's disk-backed cache as the browser's thumbnail provider. The cache keys by content hash, keeps its own
/// memory LRU, serves newest requests first and renders off the main actor.
struct SkinThumbnailAdapter: SkinThumbnailProviding {
    let cache: SkinThumbnailCache

    func thumbnail(for record: SkinRecord, at url: URL) async -> CGImage? {
        guard record.status != .failed else { return nil }
        return await cache.thumbnail(hash: record.hash, url: url)?.image
    }
}
