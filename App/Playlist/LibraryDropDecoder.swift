import AppKit
import MusicBackendKit
import UniformTypeIdentifiers

/// Reads a drop on the playlist editor's track list (#0183, #0184, #0188): Library media ids and file URLs. Split out
/// of `PlaylistListInputView` so the pasteboard reading is unit tested against real `NSPasteboard`s (#0210).
enum LibraryDropDecoder {
    /// What a Library row's `.draggable(MediaIDTransfer)` puts on the pasteboard (JSON, `CodableRepresentation`).
    static let mediaIDType = NSPasteboard.PasteboardType(UTType.roadieMediaID.identifier)

    nonisolated(unsafe) static let fileURLOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]

    /// The operation to offer: copy if the source allows it, else whatever it allows (a SwiftUI source sets the mask).
    static func operation(for mask: NSDragOperation) -> NSDragOperation {
        for op in [NSDragOperation.copy, .generic, .move] where mask.contains(op) { return op }
        return []
    }

    /// The media-id type on the pasteboard or on any of its items (a SwiftUI drag puts each item on its own).
    static func hasMediaID(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.types?.contains(mediaIDType) == true { return true }
        return (pasteboard.pasteboardItems ?? []).contains { $0.types.contains(mediaIDType) }
    }

    /// Every item's ids in item order, else the pasteboard's own data. nil when nothing decodes.
    static func mediaIDs(from pasteboard: NSPasteboard) -> [MediaID]? {
        var ids: [MediaID] = []
        var decoded = false
        for item in pasteboard.pasteboardItems ?? [] {
            guard let data = item.data(forType: mediaIDType), let transfer = MediaIDTransfer.decode(data) else { continue }
            decoded = true
            ids += transfer.ids
        }
        if decoded { return ids }
        guard let data = pasteboard.data(forType: mediaIDType) else { return nil }
        return MediaIDTransfer.decode(data)?.ids
    }

    /// Whether the pasteboard holds file URLs.
    static func hasFileURLs(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: fileURLOptions)
    }

    /// The file URLs in pasteboard order, audio or not; the caller filters them.
    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: fileURLOptions) as? [URL]) ?? []
    }
}
