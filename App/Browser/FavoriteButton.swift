import LibraryBrowser
import MusicBackendKit
import SwiftUI

/// The heart at the end of a Library row (#0141): filled when favorited, otherwise shown only while the row is
/// hovered. VoiceOver always has it. Nothing when the source has no favorites.
struct FavoriteButton: View {
    let id: MediaID
    let stored: Bool?
    var rowHovered = false
    @Environment(PlayerModel.self) private var player

    var body: some View {
        let favorites = player.library.favorites
        if favorites.isAvailable {
            let on = favorites.isFavorite(id, stored: stored)
            Button {
                player.setFavorite([id: stored], to: !on)
            } label: {
                Image(systemName: on ? "heart.fill" : "heart")
                    .foregroundStyle(on ? Color.pink : Color.secondary)
            }
            .buttonStyle(.borderless)
            .opacity(on || rowHovered ? 1 : 0)
            .help(on ? "Unfavorite" : "Favorite")
            .accessibilityLabel("Favorite")
            .accessibilityValue(on ? "On" : "Off")
            .accessibilityAddTraits(.isToggle)
            .accessibilityIdentifier("library.track.favorite")
        }
    }
}

/// Adds the hover-revealed heart after a row's content.
struct FavoriteRow<Content: View>: View {
    let id: MediaID
    let stored: Bool?
    @ViewBuilder var content: Content
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            content
            FavoriteButton(id: id, stored: stored, rowHovered: hovered)
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}

/// The context-menu item: "Favorite" unless every item already is, then "Unfavorite".
struct FavoriteMenuItem: View {
    /// Each item with its own `isFavorite`.
    let items: [MediaID: Bool?]
    @Environment(PlayerModel.self) private var player

    var body: some View {
        let favorites = player.library.favorites
        if favorites.isAvailable {
            let target = FavoritesModel.target(for: items.map { favorites.isFavorite($0.key, stored: $0.value) })
            Button(target ? "Favorite" : "Unfavorite") { player.setFavorite(items, to: target) }
                .disabled(items.isEmpty)
        }
    }
}
