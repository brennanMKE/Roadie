import CoreLocation
import MusicAssistantKit
import Network
import XCTest

@testable import Roadie

/// The system network wrappers' pure logic and the Music Assistant status line's choice (#0216). Nothing here
/// browses Bonjour, reads Wi-Fi, prompts for Location or monitors the network.
@MainActor
final class SystemNetworkWrapperTests: XCTestCase {
    func testServiceEndpointBecomesHost() {
        let ipv4 = NWEndpoint.hostPort(host: .ipv4(IPv4Address("192.168.1.20")!), port: 8095)
        let name = NWEndpoint.hostPort(host: .name("ma.local", nil), port: 9000)
        let ipv6 = NWEndpoint.hostPort(host: .ipv6(IPv6Address("fe80::1")!), port: 8095)
        let service = NWEndpoint.service(name: "MA", type: "_music-assistant._tcp", domain: "local.", interface: nil)

        // `_music-assistant._tcp` keeps the advertised port; the others' port is another service's.
        XCTAssertEqual(
            SystemServiceBrowser.host(of: ipv4, type: "_music-assistant._tcp"),
            MusicAssistantDiscoveredHost(host: "192.168.1.20", port: 8095))
        XCTAssertEqual(
            SystemServiceBrowser.host(of: name, type: "_music-assistant._tcp"),
            MusicAssistantDiscoveredHost(host: "ma.local", port: 9000))
        XCTAssertEqual(
            SystemServiceBrowser.host(of: ipv4, type: "_sendspin-server._tcp"),
            MusicAssistantDiscoveredHost(host: "192.168.1.20", port: nil))
        XCTAssertEqual(
            SystemServiceBrowser.host(of: name, type: "_sendspin-server._tcp"),
            MusicAssistantDiscoveredHost(host: "ma.local", port: nil))
        for type in ["_music-assistant._tcp", "_sendspin-server._tcp"] {
            XCTAssertNil(SystemServiceBrowser.host(of: ipv6, type: type), type)
            XCTAssertNil(SystemServiceBrowser.host(of: service, type: type), type)
            XCTAssertNil(SystemServiceBrowser.host(of: nil, type: type), type)
        }
    }

    func testNetworkEventsSkipFirstPath() {
        var filter = PathChangeFilter()
        let first = filter.isChange()
        XCTAssertFalse(first)
        for _ in 0..<3 {
            let later = filter.isChange()
            XCTAssertTrue(later)
        }
    }

    func testWifiAuthorizationMapping() {
        XCTAssertEqual(SystemWiFiNetwork.authorization(for: .notDetermined), .notDetermined)
        XCTAssertEqual(SystemWiFiNetwork.authorization(for: .denied), .denied)
        XCTAssertEqual(SystemWiFiNetwork.authorization(for: .restricted), .restricted)
        XCTAssertEqual(SystemWiFiNetwork.authorization(for: .authorizedAlways), .authorized)
    }

    func testWifiRequestsShareOnePrompt() async {
        var status = CLAuthorizationStatus.notDetermined
        var prompts = 0
        let wifi = SystemWiFiNetwork(status: { status }, request: { prompts += 1 })

        async let first = wifi.requestAuthorization()
        async let second = wifi.requestAuthorization()
        // Wait (bounded) until both calls are waiting on their continuation.
        let deadline = ContinuousClock.now + .seconds(5)
        while wifi.pendingCount < 2, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(wifi.pendingCount, 2)
        XCTAssertEqual(prompts, 1)

        // The initial (undetermined) callback resolves nothing; the user's answer resolves both.
        wifi.authorizationChanged()
        status = .authorizedAlways
        wifi.authorizationChanged()
        let results = await [first, second]
        XCTAssertEqual(results, [.authorized, .authorized])
        XCTAssertEqual(wifi.pendingCount, 0)
        XCTAssertEqual(prompts, 1)

        // Once decided, a request returns at once without prompting.
        let again = await wifi.requestAuthorization()
        XCTAssertEqual(again, .authorized)
        XCTAssertEqual(prompts, 1)
    }

    func testMismatchStatusOffersReplace() {
        XCTAssertTrue(MusicAssistantSettingsView.offersReplace(.failed(.serverMismatch(foundName: "Other"))))
        XCTAssertTrue(MusicAssistantSettingsView.offersReplace(.failed(.serverMismatch(foundName: nil))))
        let others: [MusicAssistantSettingsModel.Status] = [
            .untested, .testing, .connected(name: "Home", version: "2.5"), .failed(.tokenRejected),
            .failed(.needsToken(foundName: nil)), .failed(.unreachable("down")), .failed(.blockedByATS),
        ]
        for status in others { XCTAssertFalse(MusicAssistantSettingsView.offersReplace(status), "\(status)") }
    }
}
