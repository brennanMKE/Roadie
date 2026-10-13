import Foundation
import Testing
import PlexKit

/// Opt-in: runs only when `PLEX_URL` and `PLEX_TOKEN` are set. Never prints the token or the client.
@Suite(.serialized)
struct PlexIntegrationTests {
    static var environment: (url: URL, token: PlexToken)? {
        let env = ProcessInfo.processInfo.environment
        guard let urlString = env["PLEX_URL"], let url = URL(string: urlString),
              let token = env["PLEX_TOKEN"], !token.isEmpty else { return nil }
        return (url, PlexToken(token))
    }

    private func client(token: Bool = true) throws -> PlexClient {
        let env = try #require(Self.environment)
        return PlexClient(baseURL: env.url, token: token ? env.token : nil,
                          clientIdentifier: "skinamp-integration-test")
    }

    @Test(.enabled(if: PlexIntegrationTests.environment != nil))
    func identityAndMusicSection() async throws {
        let identity = try await client().identity()
        #expect(!identity.machineIdentifier.isEmpty)
        #expect(try await client().musicSections().isEmpty == false)
        await #expect(throws: PlexError.unauthorized) {
            _ = try await client(token: false).librarySections()
        }
    }

    @Test(.enabled(if: PlexIntegrationTests.environment != nil))
    func firstArtistPageAndChildren() async throws {
        let client = try client()
        let music = try #require(try await client.musicSections().first)
        let artists = try await client.artists(in: music.id, page: .init(size: 3))
        #expect(artists.items.count <= 3)
        #expect(artists.totalSize >= artists.items.count)
        let artist = try #require(artists.items.first)
        let albums = try await client.albums(of: artist.id)
        let album = try #require(albums.items.first)
        let tracks = try await client.tracks(of: album.id)
        #expect((tracks.items.first?.primaryPart?.size ?? 0) > 0)
        print("integration: \(artists.totalSize) artists, \(albums.items.count) albums for first artist")
    }

    @Test(.enabled(if: PlexIntegrationTests.environment != nil))
    func connectionTestSucceedsAgainstTheServer() async throws {
        let env = try #require(Self.environment)
        let test = PlexConnectionTest(clientIdentifier: "skinamp-integration-test")
        let connection = try await test.run(baseURL: env.url, token: env.token)
        #expect(!connection.musicSections.isEmpty)
        #expect(!connection.identity.machineIdentifier.isEmpty)
        do {
            _ = try await test.run(baseURL: env.url, token: PlexToken("not-a-real-token"))
            Issue.record("expected the bad token to fail")
        } catch let failure as PlexConnectionFailure {
            #expect(failure == .unauthorized)
        }
        print("integration: connection test ok, \(connection.musicSections.count) music section(s)")
    }

    @Test(.enabled(if: PlexIntegrationTests.environment != nil))
    func resourcesListTheServer() async throws {
        let env = try #require(Self.environment)
        let machine = try await client().identity().machineIdentifier
        let account = PlexAccountClient(clientIdentifier: "skinamp-integration-test")
        let servers = try await account.resources(token: env.token)
        #expect(!servers.isEmpty)
        let ours = try #require(servers.first { $0.clientIdentifier == machine })
        #expect(ours.connections.contains { $0.isHTTPS })
        print("integration: \(servers.count) server(s), \(ours.connections.count) connection(s) for ours")
    }
}
