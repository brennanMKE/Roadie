import SkinBrowser
import SkinMuseum
import SwiftUI

/// The Museum's screenshot grid; the next page loads on scroll, never ahead of it (#0126).
struct MuseumGridView: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        let museum = player.museumBrowser
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 240), spacing: 12)], spacing: 12) {
                ForEach(museum.items) { skin in
                    MuseumCellView(skin: skin)
                        .onAppear { museum.loadMoreIfNeeded(current: skin) }
                }
            }
            .padding()
            footer(museum)
        }
        .accessibilityIdentifier("skins.museum.grid")
    }

    @ViewBuilder
    private func footer(_ museum: MuseumBrowserModel) -> some View {
        if let message = museum.loadMoreError {
            HStack {
                Text(message).foregroundStyle(.secondary)
                Button("Retry") { museum.retryLoadMore() }
            }
            .padding(.bottom)
        } else if museum.isLoadingMore {
            ProgressView().padding(.bottom)
        }
    }
}
