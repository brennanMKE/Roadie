import AudioCore
import CoreGraphics
import Foundation
import ImageIO
import MusicBackendKit
import UniformTypeIdentifiers

/// Album art for the folder backend: an image file next to the tracks, or art embedded in a track.
/// ImageIO and CoreGraphics only, no AppKit.
enum FolderArtwork {
    /// In priority order; matched case-insensitively against the folder listing.
    static let coverNames = [
        "cover.jpg", "cover.jpeg", "cover.png", "folder.jpg", "folder.jpeg", "folder.png",
        "front.jpg", "front.png", "album.jpg", "album.png",
    ]

    static func isImageName(_ name: String) -> Bool {
        coverNames.contains(name.lowercased())
    }

    /// `file:<relativePath>` for the best image file of the album, nil when it has none.
    static func imageRef(in album: FolderWalk.Album) -> ArtworkRef? {
        guard let folder = album.folderPath else { return nil }
        let lowered = Dictionary(album.images.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        for name in coverNames {
            if let actual = lowered[name] { return ArtworkRef(rawValue: "file:\(folder)/\(actual)") }
        }
        // An image inside Disc 1/ is used only when the album folder has none.
        if let nested = album.nestedImage { return ArtworkRef(rawValue: "file:\(nested)") }
        return nil
    }

    /// The bytes of `ref`, scaled to `maxPixels` on the long side when larger. Throws `.backend` for a
    /// missing file, no embedded art or a path outside `root`.
    static func data(for ref: ArtworkRef, root: URL, maxPixels: Int) async throws -> Data {
        let missing = MusicBackendError.backend("The album art is missing.")
        let raw: Data
        if ref.rawValue.hasPrefix("file:") {
            let relative = String(ref.rawValue.dropFirst("file:".count))
            guard let url = resolve(relative, root: root), let data = try? Data(contentsOf: url) else { throw missing }
            raw = data
        } else if ref.rawValue.hasPrefix("embedded:") {
            let relative = String(ref.rawValue.dropFirst("embedded:".count))
            guard let url = resolve(relative, root: root),
                  let data = await EmbeddedArtworkLoader.artworkData(for: url) else { throw missing }
            raw = data
        } else {
            throw missing
        }
        return scaled(raw, maxPixels: maxPixels) ?? raw
    }

    /// nil for an empty path or one with a `..` component.
    private static func resolve(_ relative: String, root: URL) -> URL? {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else { return nil }
        return URL(fileURLWithPath: root.path + "/" + relative)
    }

    /// The input unchanged when both sides fit (returned as nil here); otherwise a JPEG thumbnail.
    private static func scaled(_ data: Data, maxPixels: Int) -> Data? {
        guard maxPixels > 0, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        guard max(width, height) > maxPixels else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
