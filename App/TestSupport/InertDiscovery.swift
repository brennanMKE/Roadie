import Foundation
import MusicAssistantKit

/// Discovery off (#0194, `RoadieConfiguration.discovery == false`): Bonjour that never reports.
struct InertServiceBrowser: MusicAssistantServiceBrowser {
    func hosts() -> AsyncStream<MusicAssistantDiscoveredHost> { AsyncStream { _ in } }
}

/// No Wi-Fi name and no permission request, so nothing prompts for Location.
@MainActor
final class InertWiFiNetwork: WiFiNetworkProvider {
    var authorization: WiFiAuthorization { .notDetermined }
    func currentSSID() -> String? { nil }
    func requestAuthorization() async -> WiFiAuthorization { .notDetermined }
}

/// A network that never changes.
struct InertNetworkEvents: NetworkChangeSource {
    func changes() -> AsyncStream<Void> { AsyncStream { _ in } }
}
