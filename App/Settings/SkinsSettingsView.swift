import SwiftUI

/// Settings › Skins: choose the skins folder and watch its index.
struct SkinsSettingsView: View {
    @Environment(SkinLibraryModel.self) private var model
    @State private var confirmingReset = false

    var body: some View {
        Form {
            Section("Folder") {
                LabeledContent("Skins folder") {
                    Text(model.folderText)
                        .truncationMode(.middle)
                        .lineLimit(1)
                        .foregroundStyle(model.hasFolder ? .primary : .secondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("skins.folder")
                }
                Button("Choose…") { model.chooseFolder() }
                    .accessibilityIdentifier("skins.choose")
            }

            Section {
                Text(model.countsText)
                    .accessibilityIdentifier("skins.counts")
                if let status = model.statusText {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                if let lastScan = model.lastScan {
                    LabeledContent("Last scan", value: lastScan.formatted(date: .abbreviated, time: .shortened))
                }
                if model.isIndexing {
                    if let fraction = model.progressFraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    if let text = model.progressText {
                        Text(text).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    if model.isIndexing {
                        Button("Cancel") { model.cancel() }
                    } else {
                        Button("Scan") { model.scan() }
                            .disabled(!model.hasFolder)
                            .accessibilityIdentifier("skins.scan")
                        Button("Rescan All") { model.scan(full: true) }
                            .disabled(!model.hasFolder)
                    }
                    Spacer()
                    if confirmingReset {
                        Text("Delete the index?").font(.caption).foregroundStyle(.secondary)
                        Button("Reset", role: .destructive) {
                            confirmingReset = false
                            model.resetIndex()
                        }
                        .accessibilityIdentifier("skins.reset")
                        Button("Keep") { confirmingReset = false }
                    } else {
                        Button("Reset Index…") { confirmingReset = true }
                            .disabled(model.isIndexing)
                    }
                }
                if let message = model.errorMessage {
                    Text(message).foregroundStyle(.red)
                }
            } header: {
                Text("Index")
            } footer: {
                Text("Skins are indexed in the background; only new or changed files are read again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
