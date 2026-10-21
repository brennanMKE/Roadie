import LibraryBrowser
import SwiftUI

struct LibrarySidebarView: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        let library = player.library
        let selection = Binding<LibrarySection?>(
            get: { library.section },
            set: { if let value = $0 { library.section = value } })
        List(library.sections, id: \.self, selection: selection) { section in
            row(for: section).tag(section)
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
        }
    }
}
