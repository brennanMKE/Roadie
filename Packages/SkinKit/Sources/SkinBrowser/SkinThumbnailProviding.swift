import CoreGraphics
import Foundation
import SkinLibrary

/// Where the browser gets cell images. The app adapts #0034's `SkinThumbnailCache` (which keeps its own memory LRU,
/// de-duplicates in-flight renders by hash and renders off the main actor); tests use a stub.
public protocol SkinThumbnailProviding: Sendable {
    /// nil when the skin cannot be rendered (show the placeholder). Called off the main actor.
    func thumbnail(for record: SkinRecord, at url: URL) async -> CGImage?
    /// Forgets the thumbnail of a skin that left the index (#0131).
    func remove(hash: String) async
}

extension SkinThumbnailProviding {
    public func remove(hash: String) async {}
}
