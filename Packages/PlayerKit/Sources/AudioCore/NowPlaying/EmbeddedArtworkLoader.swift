import AVFoundation
import Foundation

/// Reads embedded cover art (ID3 APIC, iTunes covr) from a local audio file.
public enum EmbeddedArtworkLoader {
    public static func artworkData(for url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.commonMetadata) else { return nil }
        let items = AVMetadataItem.metadataItems(
            from: metadata, filteredByIdentifier: .commonIdentifierArtwork)
        guard let item = items.first else { return nil }
        return try? await item.load(.dataValue)
    }

    /// Default artwork source for the bridge: local files only. Plex art is injected by the app.
    @Sendable public static func artwork(for track: Track) async -> Data? {
        guard case .file(let url) = track.source else { return nil }
        return await artworkData(for: url)
    }
}
