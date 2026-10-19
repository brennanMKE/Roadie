import CoreLocation
import CoreWLAN
import Foundation
import MusicAssistantKit

/// The Wi-Fi network name behind `WiFiNetworkProvider` (#0075). macOS returns the name only to an app with Location
/// access, so the `CLLocationManager` is created lazily on first use, never in `init`, and permission is requested
/// only by `requestAuthorization()`, which only Settings' "Use Current Network" calls. The name is never logged.
@MainActor
final class SystemWiFiNetwork: NSObject, WiFiNetworkProvider, CLLocationManagerDelegate {
    private var manager: CLLocationManager?
    private var pending: [CheckedContinuation<WiFiAuthorization, Never>] = []

    private var locationManager: CLLocationManager {
        if let manager { return manager }
        let created = CLLocationManager()
        created.delegate = self
        manager = created
        return created
    }

    var authorization: WiFiAuthorization {
        switch locationManager.authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .authorizedAlways, .authorizedWhenInUse: .authorized
        @unknown default: .denied
        }
    }

    func currentSSID() -> String? {
        guard authorization == .authorized else { return nil }
        return CWWiFiClient.shared().interface()?.ssid()
    }

    func requestAuthorization() async -> WiFiAuthorization {
        let now = authorization
        guard now == .notDetermined else { return now }
        return await withCheckedContinuation { continuation in
            pending.append(continuation)
            // A second call while one is waiting shares the same system request.
            if pending.count == 1 { locationManager.requestWhenInUseAuthorization() }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // The manager was created on the main thread, so its delegate is called there.
        MainActor.assumeIsolated { self.authorizationChanged() }
    }

    private func authorizationChanged() {
        let now = authorization
        // The first callback reports the initial (undetermined) state; wait for the user's answer.
        guard now != .notDetermined, !pending.isEmpty else { return }
        let waiting = pending
        pending = []
        for continuation in waiting { continuation.resume(returning: now) }
    }
}
