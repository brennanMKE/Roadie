import Foundation
import MusicBackendKit
import PlexKit
import PlexKitStub
import Testing

@MainActor
struct PlexBackendSecrecyTests {
    @Test func errorsDescriptionsAndFilesNeverContainTheToken() async throws {
        let f = try BackendFixture(); defer { f.cleanup() }
        var texts: [String] = []
        func collect(_ error: any Error) {
            texts += [String(describing: error), String(reflecting: error), error.localizedDescription]
        }

        // Failures from every stage.
        do { _ = try await f.backend.artists(page: .first) } catch { collect(error) }
        f.handle.register([.init(path: "/identity", error: URLError(.cannotConnectToHost))])
        do { try await f.backend.connect() } catch { collect(error) }
        f.handle.register([
            try .json(.identity, path: "/identity"),
            .init(path: "/library/sections", status: 401, headers: ["Content-Type": "text/html"], body: Data("<html/>".utf8)),
        ])
        do { try await f.backend.connect() } catch { collect(error) }
        try f.register([
            .init(path: "/library/sections/5/all", status: 500),
            .init(path: "/photo/:/transcode", status: 404),
        ])
        try await f.backend.connect()
        do { _ = try await f.backend.artists(page: .first) } catch { collect(error) }
        do { _ = try await f.backend.artwork(ArtworkRef("/x"), maxPixels: 10) } catch { collect(error) }
        do { _ = try await f.backend.playlists(page: .first) } catch { collect(error) }
        do { try await f.backend.play([MediaID(.track, "1")], on: OutputDevice.thisMacID, mode: .replace()) } catch { collect(error) }
        do { try await f.backend.play([MediaID(.track, "1")], on: .init(rawValue: "x"), mode: .replace()) } catch { collect(error) }

        texts.append(String(reflecting: f.backend))
        texts.append(String(describing: f.backend))
        let settings = SettingsBox.standard()
        texts += [String(describing: settings), String(reflecting: settings)]
        var dump = ""
        Swift.dump(settings, to: &dump)
        texts.append(dump)

        #expect(texts.count > 10)
        for text in texts {
            #expect(!text.contains(testSecret))
            #expect(!text.contains("X-Plex-Token"))
        }
        #expect(!directoryContains(f.dir, testSecret))
        #expect(f.handle.recorded.allSatisfy { !$0.url.absoluteString.contains(testSecret) })
    }
}
