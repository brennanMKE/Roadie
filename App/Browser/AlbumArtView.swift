import MusicBackendKit
import MusicLibraryKit
import SwiftUI

/// A square thumbnail from the shared `ArtworkCache`. The placeholder shows for items without art, while the image
/// loads, and when the cache has none.
struct AlbumArtView: View {
    @Environment(PlayerModel.self) private var player
    let ref: ArtworkRef?
    let side: CGFloat
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ArtworkPlaceholder(side: side)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        // Cancelled when the row scrolls away or the ref changes; the cache keeps fetching for the next appearance.
        .task(id: ref) {
            image = nil
            guard let ref else { return }
            image = await player.artwork.image(for: ref)?.image
        }
    }
}

struct ArtworkPlaceholder: View {
    let side: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(.quaternary)
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: side * 0.4))
                    .foregroundStyle(.secondary)
            }
            .frame(width: side, height: side)
            .accessibilityLabel("No artwork")
    }
}
