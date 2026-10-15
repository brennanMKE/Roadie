import MusicAssistantKit
import SwiftUI

/// Settings › Music Assistant: the list of servers and the editor for the selected one. All logic is in the model.
struct MusicAssistantSettingsView: View {
    @Environment(MusicAssistantSettingsModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                List(selection: $model.selectedID) {
                    ForEach(model.servers) { server in
                        ServerRow(
                            server: server, status: model.status[server.id] ?? .untested, inUse: server.id == model.activeID
                        )
                        .tag(server.id)
                    }
                    .onMove { model.move(fromOffsets: $0, toOffset: $1) }
                }
                .frame(minHeight: 84)
                .accessibilityIdentifier("ma.servers")
                HStack {
                    Button("Add Server", systemImage: "plus") { model.addServer() }
                        .accessibilityIdentifier("ma.add")
                    Button("Remove Server", systemImage: "minus") {
                        if let id = model.selectedID { model.removeServer(id) }
                    }
                    .disabled(model.selectedID == nil)
                    .accessibilityIdentifier("ma.remove")
                }
                .labelStyle(.iconOnly)
            } header: {
                Text("Servers")
            } footer: {
                Text("SkinAmp uses the first tested server in this list.")
            }

            if model.selected != nil {
                Section {
                    TextField("Name", text: $model.name)
                        .accessibilityIdentifier("ma.name")
                    TextField("Address", text: $model.addressText, prompt: Text("homeassistant.local:8095"))
                        .autocorrectionDisabled()
                        .onSubmit { model.commitAddress() }
                        .accessibilityIdentifier("ma.address")
                    if let problem = model.addressProblem {
                        Text(problem.message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text("A host name or IP address. Plain http works on your local network, including Tailscale IP addresses; any other address needs https.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        SecureField("Token", text: $model.tokenText, prompt: Text(tokenPrompt))
                            .onSubmit { model.submitToken() }
                            .accessibilityIdentifier("ma.token")
                        Button("Remove Token") { model.removeToken() }
                            .disabled(model.selectedHasStoredToken != true)
                            .accessibilityIdentifier("ma.removeToken")
                    }
                    if let error = model.tokenStoreError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    HStack {
                        Button("Test Connection") { model.testConnection() }
                            .disabled(!model.canTest)
                            .accessibilityIdentifier("ma.test")
                        if model.isTesting {
                            ProgressView().controlSize(.small)
                            Button("Cancel") { model.cancelTest() }
                        }
                    }
                    statusLine
                    Text(identityText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Selected Server")
                }
            }
        }
        .formStyle(.grouped)
        .task { model.appeared() }
        .onDisappear { model.disappeared() }
    }

    private var tokenPrompt: String {
        model.selectedHasStoredToken == true ? "Saved in Keychain" : "Long-lived token from Music Assistant \u{203A} Profile"
    }

    private var identityText: String {
        if case .connected(let name, _) = model.selectedStatus, let name { return "Verified: \(name)" }
        return model.selected?.isVerified == true ? "Verified: \(model.selected?.name ?? "")" : "Not tested yet"
    }

    @ViewBuilder
    private var statusLine: some View {
        if let message = model.statusMessage {
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(failed ? Color.red : Color.secondary)
                    .accessibilityIdentifier("ma.status")
                if case .failed(.serverMismatch) = model.selectedStatus {
                    Text("Replacing forgets this server's token. Enter the token of the server that answers now.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Replace With This Server\u{2026}") { model.replaceIdentity() }
                        .accessibilityIdentifier("ma.replace")
                }
            }
        }
    }

    private var failed: Bool {
        if case .failed = model.selectedStatus { return true }
        return false
    }
}

private struct ServerRow: View {
    var server: MusicAssistantServerConfiguration
    var status: MusicAssistantSettingsModel.Status
    var inUse: Bool

    var body: some View {
        HStack {
            statusDot
            VStack(alignment: .leading) {
                Text(server.name)
                Text(server.hasNoAddress ? "No address" : server.address.baseURL.host ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if inUse {
                Text("In Use")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.green.opacity(0.2), in: Capsule())
            }
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        switch status {
        case .testing: ProgressView().controlSize(.mini)
        case .connected: Circle().fill(.green).frame(width: 8, height: 8)
        case .failed: Circle().fill(.red).frame(width: 8, height: 8)
        case .untested: Circle().fill(.gray).frame(width: 8, height: 8)
        }
    }
}
