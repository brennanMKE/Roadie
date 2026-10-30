import LibraryBrowser
import MusicBackendKit
import SwiftUI

/// The Radio section (#0147): the library's stations. Double-click plays; the toolbar adds a stream URL.
struct RadioListView: View {
    let library: LibraryBrowserModel
    var list: PagedList<LibraryRadio>? = nil
    @Environment(PlayerModel.self) private var player
    @State private var selected: MediaID?

    var body: some View {
        let list = list ?? library.radios
        PagedListView(
            list: list, rows: list.items, pagingID: \.id, emptyText: "No radio stations",
            selectedID: selected, onSelect: { selected = $0.id }
        ) { radio in
            RadioRow(radio: radio)
        }
        .contextMenu(forSelectionType: MediaID.self) { ids in
            Button("Play") { play(ids) }.disabled(ids.isEmpty)
            Divider()
            FavoriteMenuItem(items: Dictionary(
                list.items.filter { ids.contains($0.id) }.map { ($0.id, $0.isFavorite) },
                uniquingKeysWith: { first, _ in first }))
        } primaryAction: { ids in
            play(ids)
        }
        .accessibilityIdentifier("library.radio")
    }

    private func play(_ ids: Set<MediaID>) {
        player.playFromLibrary(Self.request(ids, in: (list ?? library.radios).items))
    }

    /// One station plays at a time: the first selected in list order. nil when none is in `stations`.
    static func request(_ ids: Set<MediaID>, in stations: [LibraryRadio]) -> PlayRequest? {
        guard let id = stations.first(where: { ids.contains($0.id) })?.id else { return nil }
        return PlayRequest(items: [id], mode: .replace())
    }
}

struct RadioRow: View {
    let radio: LibraryRadio

    var body: some View {
        FavoriteRow(id: radio.id, stored: radio.isFavorite) {
            HStack(spacing: 8) {
                AlbumArtView(ref: radio.artwork, side: 28)
                Text(radio.name).lineLimit(1)
                Spacer(minLength: 0)
            }
        }
    }
}

/// "Add Radio URL…" (`builtin/add_radio`).
struct AddRadioSheet: View {
    let library: LibraryBrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var name = ""
    @State private var error: String?
    @State private var adding = false

    var body: some View {
        Form {
            TextField("Stream URL", text: $url, prompt: Text("https://"))
                .accessibilityIdentifier("library.radio.add.url")
            TextField("Name", text: $name, prompt: Text("Optional"))
            if let error {
                Text(error).foregroundStyle(.red).font(.caption)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!Self.canAdd(url: url, adding: adding))
            }
        }
        .padding()
        .frame(width: 380)
    }

    /// Add is on for an http(s) URL with a host, while no add is in flight.
    static func canAdd(url: String, adding: Bool) -> Bool {
        !adding && RadioURLInput.parse(url) != nil
    }

    private func add() {
        adding = true
        Task {
            error = await library.addRadio(url: url, name: name)
            adding = false
            if error == nil {
                library.section = .radio
                dismiss()
            }
        }
    }
}
