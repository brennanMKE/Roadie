import LibraryBrowser
import MusicBackendKit
import SwiftUI

/// Names a new playlist or renames one (#0135). Return confirms, Escape cancels; the name must not be blank.
struct PlaylistNameSheet: View {
    let sheet: PlaylistsModel.NameSheet
    let onCommit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(sheet.title).font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 280)
                .onSubmit(commit)
                .accessibilityIdentifier("library.playlist.name")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(sheet.confirmTitle, action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .onAppear { name = sheet.initialName }
    }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
        dismiss()
    }
}

/// The name sheet, the delete confirmation and the failure bar for the Playlists list (#0135).
struct PlaylistEditingModifier: ViewModifier {
    @Bindable var model: PlaylistsModel
    /// "New Playlist…" from Add to Playlist: the name and the items to add to the new playlist (#0136).
    var onCreateAdding: (String, [MediaID]) -> Void = { _, _ in }

    func body(content: Content) -> some View {
        content
            .sheet(item: $model.nameSheet) { sheet in
                PlaylistNameSheet(sheet: sheet) { name in
                    switch sheet {
                    case .create(let items) where !items.isEmpty:
                        onCreateAdding(name, items)
                    case .create:
                        Task { await model.create(named: name) }
                    case .rename(let playlist):
                        Task { await model.rename(playlist, to: name) }
                    }
                }
            }
            .confirmationDialog(
                deleteTitle, isPresented: deleteBinding, titleVisibility: .visible, presenting: model.pendingDelete
            ) { playlist in
                Button("Delete", role: .destructive) { Task { await model.delete(playlist) } }
                    .accessibilityIdentifier("library.playlist.delete")
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This removes the playlist from Music Assistant for every app. Tracks stay in the library.")
            }
    }

    private var deleteTitle: String { Self.deleteTitle(model.pendingDelete) }

    static func deleteTitle(_ playlist: LibraryPlaylist?) -> String {
        "Delete \u{201C}\(playlist?.name ?? "")\u{201D}?"
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } })
    }
}

/// A one-line failure under a list, with a close button.
struct PlaylistMessageBar: View {
    let model: PlaylistsModel

    var body: some View {
        if let message = model.message {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                Text(message).font(.caption).lineLimit(2)
                Spacer()
                Button("Dismiss", systemImage: "xmark") { model.dismissMessage() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.bar)
            .accessibilityIdentifier("library.playlists.message")
        }
    }
}
