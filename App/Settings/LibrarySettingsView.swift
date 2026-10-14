import AppKit
import FolderBackendKit
import SwiftUI

/// Settings › Library. Today only the local music folder; the source picker (#0063) goes above it.
struct LibrarySettingsView: View {
    @Environment(FolderSettingsModel.self) private var model

    var body: some View {
        Form {
            Section {
                LabeledContent("Folder") {
                    Text(model.pathText)
                        .truncationMode(.middle)
                        .lineLimit(1)
                        .foregroundStyle(model.hasFolder ? .primary : .secondary)
                        .textSelection(.enabled)
                }
                .accessibilityIdentifier("library.folder")
                HStack {
                    Button("Choose\u{2026}") { chooseFolder() }
                        .accessibilityIdentifier("library.choose")
                    Button("Clear") { model.clear() }
                        .disabled(!model.hasFolder)
                        .accessibilityIdentifier("library.clear")
                }
            } header: {
                Text("Music Folder")
            } footer: {
                Text("Organize it as Artist/Album/Track, like a Plex library. Singles can sit directly in the artist's folder; discs as \"Disc 1\", \"Disc 2\" subfolders.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Index") {
                HStack {
                    Text(model.statusText)
                        .foregroundStyle(model.isFailed ? .red : .secondary)
                        .accessibilityIdentifier("library.status")
                    if model.isIndexing {
                        ProgressView().controlSize(.small)
                    }
                }
                Button("Reindex") { model.reindex() }
                    .disabled(!model.hasFolder || model.isIndexing)
                    .accessibilityIdentifier("library.reindex")
                if let message = model.errorMessage {
                    Text(message).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .task { model.appeared() }
        .onDisappear { model.disappeared() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.folderURL
        panel.message = "Choose your music folder"
        panel.prompt = "Choose"
        // The app is unsandboxed, so the URL is directly readable; no security-scoped bookmark.
        if panel.runModal() == .OK, let url = panel.url { model.choose(url) }
    }
}
