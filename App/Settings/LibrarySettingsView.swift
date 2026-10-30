import MusicAssistantKit
import AppKit
import FolderBackendKit
import LibraryBrowser
import SwiftUI

/// Settings › Library: which source the Library window browses, then the local music folder.
struct LibrarySettingsView: View {
    @Environment(FolderSettingsModel.self) private var model
    @Environment(LibrarySourceController.self) private var sources
    @Environment(LibraryFallbackController.self) private var fallback
    @Environment(MusicAssistantSelectionController.self) private var selection

    var body: some View {
        Form {
            Section {
                Picker("Library source", selection: Binding(get: { sources.preferredID }, set: { fallback.userSelected($0) })) {
                    ForEach(sources.sources) { source in
                        Text(source.isConfigured() ? source.displayName : "\(source.displayName) (not set up)")
                            .tag(source.id)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .accessibilityIdentifier("library.source")
                if sources.preferredID == "musicAssistant", let status = selection.statusText {
                    // Which Music Assistant server is in use and why (#0075); nothing before the first check (#0092).
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("library.maReason")
                }
                if let summary = FallbackText.summary(fallback.status) {
                    HStack {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("library.sourceStatus")
                        Spacer()
                        Button("Retry Now") { fallback.retryNow() }
                            .accessibilityIdentifier("library.sourceRetry")
                    }
                }
            } header: {
                Text("Source")
            } footer: {
                Text("The Library window browses this source. Playback continues when you switch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                Text("Organize it as Artist/Album/Track. Singles can sit directly in the artist's folder; discs as \"Disc 1\", \"Disc 2\" subfolders.")
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
        if let url = chooseMusicFolder(startingAt: model.folderURL) { model.choose(url) }
    }
}

/// The music-folder picker shared by Settings › Library and the Welcome window (#0169).
@MainActor
func chooseMusicFolder(startingAt folder: URL?) -> URL? {
    #if DEBUG
    // UI tests (#0209): `-RoadieUITest 1 -RoadieChooseFolder <path>` answers the panel with that folder.
    if UserDefaults.standard.bool(forKey: RoadieConfiguration.Argument.uiTest),
        let path = UserDefaults.standard.string(forKey: RoadieConfiguration.Argument.chooseFolder)
    {
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    #endif
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = folder
    panel.message = "Choose your music folder"
    panel.prompt = "Choose"
    // The app is unsandboxed, so the URL is directly readable; no security-scoped bookmark.
    return panel.runModal() == .OK ? panel.url : nil
}
