import LibraryBrowser
import MusicBackendKit
import SwiftUI

struct LibrarySidebarView: View {
    @Environment(PlayerModel.self) private var player

    /// A section, or one Discover row (#0143).
    private enum Item: Hashable {
        case section(LibrarySection)
        case discoverRow(RecommendationRow.ID)
    }

    var body: some View {
        let library = player.library
        let selection = Binding<Item?>(
            get: {
                if library.section == .discover, let id = library.discover?.selectedRowID { return .discoverRow(id) }
                return .section(library.section)
            },
            set: { item in
                switch item {
                case .section(let section): library.section = section
                case .discoverRow(let id): library.select(discoverRow: id)
                case nil: break
                }
            })
        List(selection: selection) {
            ForEach(library.sections, id: \.self) { section in
                row(for: section).tag(Item.section(section))
            }
            if let discover = library.discover {
                DiscoverSidebarSection(discover: discover) { row in
                    Label(row.name, systemImage: MDIIcon.symbol(row.icon))
                        .help(row.providerName ?? row.subtitle ?? "")
                        .tag(Item.discoverRow(row.id))
                        .accessibilityIdentifier("library.discover.\(row.itemID)")
                }
            }
        }
        .accessibilityIdentifier("library.sections")
        .navigationSplitViewColumnWidth(min: 140, ideal: 160, max: 220)
    }

    @ViewBuilder
    private func row(for section: LibrarySection) -> some View {
        switch section {
        case .artists: Label("Artists", systemImage: "music.mic")
        case .albums: Label("Albums", systemImage: "square.stack")
        case .playlists: Label("Playlists", systemImage: "music.note.list")
        case .discover: Label("Discover", systemImage: MDIIcon.fallback)
        }
    }
}
