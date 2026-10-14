import SkinLibrary
import SwiftUI

/// A skin's main-window thumbnail from `PlayerModel.skinThumbnails`, drawn nearest-neighbour at `width` points.
/// Nothing references it until the skin browser (#0035) lands; it is the cell that browser uses.
struct SkinThumbnailView: View {
    @Environment(PlayerModel.self) private var player
    /// The index row's content hash; nil (a failed row) shows the placeholder without a request.
    let hash: String?
    let url: URL?
    let width: CGFloat
    @State private var image: CGImage?

    private var height: CGFloat { width * 116 / 275 }

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(275.0 / 116.0, contentMode: .fit)
            } else {
                SkinThumbnailPlaceholder()
            }
        }
        .frame(width: width, height: height)
        // Cancelled when the cell scrolls away or the hash changes; a render already started still lands in the cache.
        .task(id: hash) {
            image = nil
            guard let hash, let url else { return }
            image = await player.skinThumbnails.thumbnail(hash: hash, url: url)?.image
        }
    }
}

struct SkinThumbnailPlaceholder: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(.quaternary)
            .overlay {
                Image(systemName: "paintpalette")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("No thumbnail")
    }
}
