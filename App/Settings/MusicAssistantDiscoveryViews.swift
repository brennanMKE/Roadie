import MusicAssistantKit
import SwiftUI

/// Settings › Music Assistant: servers found on this network that are not configured yet (#0104).
struct DiscoveredServersSection: View {
    @Environment(MusicAssistantDiscoveryModel.self) private var discovery
    @Environment(MusicAssistantSettingsModel.self) private var settings

    var body: some View {
        Section {
            if discovery.offers.isEmpty {
                if discovery.isSearching || !discovery.hasSearched {
                    ProgressView("Looking for Music Assistant servers…").controlSize(.small)
                } else {
                    Text("No other servers found.").foregroundStyle(.secondary)
                }
            }
            ForEach(discovery.offers) { offer in
                DiscoveredServerRow(offer: offer, action: "Add") {
                    settings.addDiscoveredServer(offer)
                    discovery.refreshOffers()
                }
            }
        } header: {
            Text("On This Network")
        } footer: {
            Text("After adding, paste the server's token and press Test Connection. The token is sent only to the server that was tested.")
        }
        .onChange(of: settings.servers) { discovery.refreshOffers() }
    }
}

/// The Library's "no server reachable" state: find servers on this network on request (#0104).
struct LibraryDiscoveryBanner: View {
    @Environment(MusicAssistantDiscoveryModel.self) private var discovery
    @Environment(MusicAssistantSettingsModel.self) private var settings
    @Environment(\.openSettings) private var openSettings
    @State private var started = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("No Music Assistant server reachable on this network.")
                Spacer()
                if started && discovery.isSearching { ProgressView().controlSize(.small) }
                Button("Find Servers on This Network") {
                    if started {
                        discovery.searchAgain()
                    } else {
                        started = true
                        discovery.start()
                    }
                }
                .disabled(started && (discovery.isSearching || !discovery.hasSearched))
                .accessibilityIdentifier("library.findServers")
            }
            if started {
                ForEach(discovery.offers) { offer in
                    DiscoveredServerRow(offer: offer, action: "Add…") {
                        settings.addDiscoveredServer(offer)
                        discovery.refreshOffers()
                        openSettings()
                    }
                }
                if discovery.offers.isEmpty && discovery.hasSearched && !discovery.isSearching {
                    Text("No servers found.").foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(.bar)
        .onDisappear { if started { discovery.stop() } }
    }
}

private struct DiscoveredServerRow: View {
    let offer: MusicAssistantDiscoveredServer
    let action: String
    let add: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(offer.name ?? "Music Assistant")
                Text(offer.url.host() ?? "").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action, action: add)
                .accessibilityIdentifier("ma.discovered.add")
        }
    }
}
