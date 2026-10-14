import Foundation
import MusicBackendKit
import Testing
@testable import MusicAssistantKit

/// Opt-in: runs only when `MA_URL` and `MA_TOKEN` are set, which they never are in the VM. Prints counts only.
struct MusicAssistantIntegrationTests {
    static var environment: (url: String, token: String)? {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["MA_URL"], let token = env["MA_TOKEN"], !token.isEmpty else { return nil }
        return (url, token)
    }

    @Test(.enabled(if: MusicAssistantIntegrationTests.environment != nil))
    func connectsListsOnePageAndOutputsAgainstARealServer() async throws {
        let env = try #require(Self.environment)
        let base = try #require(URL(string: env.url))
        let secret = env.token
        let address = MusicAssistantServerAddress(baseURL: base)
        let backend = MusicAssistantBackend(address: { address }, token: { _ in MusicAssistantToken(secret) })
        try await backend.connect()
        let page = try await backend.artists(page: PageRequest(offset: 0, limit: 5))
        let outputs = try await backend.outputs()
        print("music assistant integration: \(page.items.count) artists on the first page, \(outputs.count) outputs")
        await backend.disconnect()
    }
}
