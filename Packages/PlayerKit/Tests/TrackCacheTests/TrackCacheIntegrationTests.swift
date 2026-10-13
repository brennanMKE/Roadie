import AVFoundation
import AudioCore
import Foundation
import PlexKit
import Testing
@testable import TrackCache

/// Opt-in: runs only when `PLEX_URL` and `PLEX_TOKEN` are set (never in the VM guest). Prints a byte
/// count only, never the token or the client.
struct TrackCacheIntegrationTests {
    static var environment: (url: URL, token: PlexToken)? {
        let env = ProcessInfo.processInfo.environment
        guard let urlString = env["PLEX_URL"], let url = URL(string: urlString),
              let token = env["PLEX_TOKEN"], !token.isEmpty else { return nil }
        return (url, PlexToken(token))
    }

    @Test(.enabled(if: TrackCacheIntegrationTests.environment != nil))
    func downloadsOneTrackFromTheServer() async throws {
        let env = try #require(Self.environment)
        let client = PlexClient(baseURL: env.url, token: env.token, clientIdentifier: "skinamp-integration-test")
        let machine = try await client.identity().machineIdentifier
        let music = try #require(try await client.musicSections().first)
        let page = try await client.tracks(in: music.id, page: .init(size: 1))
        let plex = try #require(page.items.first)
        let part = try #require(plex.primaryPart)
        let track = try Track(plexTrack: plex, machineIdentifier: machine)

        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = TrackCache(directory: dir, downloader: PlexPartDownloader(clientProvider: { client }))
        let resolver = PlexTrackResolver(cache: cache, savedMachineIdentifier: { machine })
        let url = try await resolver.localURL(for: track)
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        #expect(size == part.size.map(Int64.init))
        _ = try AVAudioFile(forReading: url)   // opens the header only; nothing plays
        print("integration: downloaded \(size ?? 0) bytes")
    }
}
