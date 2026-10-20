import AppKit
import MusicAssistantKit
import SwiftUI

/// Settings › Music Assistant: the list of servers and the editor for the selected one. All logic is in the model.
struct MusicAssistantSettingsView: View {
    @Environment(MusicAssistantSettingsModel.self) private var model
    @Environment(MusicAssistantSelectionController.self) private var selection
    @Environment(MusicAssistantDiscoveryModel.self) private var discovery
    @Environment(SendspinController.self) private var sendspin
    @State private var networkDraft = ""

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                List(selection: $model.selectedID) {
                    ForEach(model.servers) { server in
                        ServerRow(
                            server: server, status: model.status[server.id] ?? .untested,
                            outcome: selection.lastOutcomes[server.id], inUse: server.id == model.activeID
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
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        "SkinAmp picks a server automatically: servers tied to the current Wi-Fi network first, then the list from the top. Tailscale servers are tried like any other."
                    )
                    HStack {
                        Text(selection.reasonText)
                            .accessibilityIdentifier("ma.reason")
                        if selection.isResolving { ProgressView().controlSize(.mini) }
                        Spacer()
                        Button("Check Now") { Task { await selection.resolveNow() } }
                            .disabled(selection.isResolving)
                            .accessibilityIdentifier("ma.checkNow")
                    }
                }
            }

            DiscoveredServersSection()

            thisMacSection

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
                networksSection
            }
        }
        .formStyle(.grouped)
        .task { model.appeared() }
        .onDisappear { model.disappeared() }
        // #0104: discovery runs only while this tab is on screen.
        .task { discovery.start() }
        .onDisappear { discovery.stop() }
    }

    /// This Mac as a Music Assistant player over Sendspin (#0109).
    private var thisMacSection: some View {
        @Bindable var sendspin = sendspin
        return Section {
            Toggle("Play Music Assistant on this Mac", isOn: $sendspin.isEnabled)
                .accessibilityIdentifier("ma.sendspin.enabled")
            Text(sendspin.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("ma.sendspin.status")
        } header: {
            Text("This Mac")
        } footer: {
            Text("Music Assistant streams to SkinAmp over Sendspin. Group This Mac with other speakers in Music Assistant.")
        }
    }

    /// The selected server's Wi-Fi network names (#0075).
    private var networksSection: some View {
        Section {
            ForEach(model.networks, id: \.self) { name in
                HStack {
                    Text(name)
                    Spacer()
                    Button("Remove", systemImage: "minus.circle") { model.removeNetwork(name) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Network name", text: $networkDraft)
                    .autocorrectionDisabled()
                    .onSubmit(addDraft)
                    .accessibilityIdentifier("ma.networkName")
                Button("Add", action: addDraft)
                    .disabled(networkDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Use Current Network") { Task { await model.useCurrentNetwork() } }
                    .accessibilityIdentifier("ma.useCurrentNetwork")
            }
            if let message = model.locationMessage {
                Text(message.text).font(.caption).foregroundStyle(.secondary)
                if message == .needsLocationAccess {
                    Button("Open Location Settings\u{2026}") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        } header: {
            Text("Wi-Fi Networks")
        } footer: {
            Text("On these networks this server is tried first.")
        }
    }

    private func addDraft() {
        model.addNetwork(networkDraft)
        networkDraft = ""
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
    /// The selection's last probe of this server (#0075), shown when no Test Connection result is newer.
    var outcome: MusicAssistantServerRanking.Outcome?
    var inUse: Bool

    var body: some View {
        HStack {
            statusDot
                .help(outcome == .mismatch ? "Different server at this address" : "")
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
        case .untested:
            switch outcome {
            case .reachable: Circle().fill(.green).frame(width: 8, height: 8)
            case .unreachable, .timedOut: Circle().fill(.gray).frame(width: 8, height: 8)
            case .mismatch, .schemaUnsupported: Circle().fill(.orange).frame(width: 8, height: 8)
            case nil: Circle().strokeBorder(.gray).frame(width: 8, height: 8)
            }
        }
    }
}
