// Debug only (#0194): Release builds don't ship `MusicAssistantKitStub`'s fixtures, and never enter test mode.
#if DEBUG
import Foundation
import MusicAssistantKit
import MusicAssistantKitStub

/// What the app's scripted configuration (#0194, `RoadieConfiguration.MusicAssistantMode.scripted`) seeds around
/// #0197's server: one verified server at the recordings' scrubbed host and a fixed fake token. The server answers
/// `auth` with the recorded success for any token (only `badToken` refuses).
extension ScriptedMusicAssistant {
    /// Every scenario name `-RoadieMAScenario` accepts.
    static var scenarios: [String] { Scenario.allCases.map(\.rawValue) }
    /// The token seeded into the in-memory token store.
    static let token = MusicAssistantToken("roadie-test-token")
    /// The recordings' scrubbed host.
    static let serverURL = URL(string: "http://ma.example:8095")!
    /// The recorded `server_id` (`info-http.json`, `server-info.json`), so the seeded server is verified.
    static let serverID = "0123456789abcdef0123456789abcdef"

    /// One verified server at `serverURL`, as Test Connection would have saved it.
    static func verifiedServer(id: UUID = UUID()) -> MusicAssistantServerConfiguration {
        MusicAssistantServerConfiguration(
            id: id, name: "Scripted Music Assistant",
            address: MusicAssistantServerAddress(baseURL: serverURL, serverID: serverID))
    }

    /// The scenario named `name`; an unknown name stops the app, since a test that asked for it can't run.
    static func scenario(named name: String) -> Scenario {
        guard let scenario = Scenario(rawValue: name) else {
            fatalError("Unknown Music Assistant scenario \"\(name)\"; known: \(scenarios.joined(separator: ", "))")
        }
        return scenario
    }
}
#endif
