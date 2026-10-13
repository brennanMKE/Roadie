import PlexKit
import SwiftUI

struct PlexSettingsView: View {
    @Environment(PlexSettingsModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextField("Server address", text: $model.address, prompt: Text("joe or 192.168.1.10"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("plex.address")
                Text("A hostname, an IP, or a link copied from Plex Web. Plain http is used unless you type https://.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    SecureField("Token", text: $model.tokenText, prompt: Text("Paste a Plex token"))
                        .onSubmit { model.commitToken() }
                        .accessibilityIdentifier("plex.token")
                    Button("Forget") { model.forgetToken() }
                        .disabled(!model.hasStoredToken)
                        .accessibilityIdentifier("plex.forget")
                }
            } header: {
                Text("Server")
            }

            Section {
                HStack {
                    Button("Test Connection") { model.testConnection() }
                        .disabled(!model.canTest)
                        .accessibilityIdentifier("plex.test")
                    if model.isTesting {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { model.cancelTest() }
                            .accessibilityIdentifier("plex.cancel")
                    }
                }
                statusLine
                    .accessibilityIdentifier("plex.status")
                if let note = model.changeNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.tokenStoreError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Connection")
            }

            if model.showsLibraryPicker {
                Section("Music library") {
                    Picker("Music library", selection: $model.librarySectionKey) {
                        if model.librarySectionKey == nil {
                            Text("Choose a library").tag(String?.none)
                        }
                        ForEach(model.musicSections, id: \.key) { section in
                            Text(section.title).tag(Optional(section.key))
                        }
                    }
                    .accessibilityIdentifier("plex.library")
                }
            } else if let selected = model.selectedSection {
                Section("Music library") {
                    LabeledContent("Music library", value: selected.title)
                        .accessibilityIdentifier("plex.library")
                }
            }
        }
        .formStyle(.grouped)
        .task { model.appeared() }
        .onDisappear { model.disappeared() }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch model.status {
        case .connected:
            Label(model.statusMessage ?? "", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case .failed:
            VStack(alignment: .leading, spacing: 2) {
                Label(model.statusMessage ?? "", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                if let detail = model.statusDetail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        case .idle, .testing:
            EmptyView()
        }
    }
}
