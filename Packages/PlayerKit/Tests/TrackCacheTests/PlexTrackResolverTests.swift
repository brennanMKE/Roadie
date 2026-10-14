import AudioCore
import Foundation
import PlexKit
import PlexKitStub
import Testing
@testable import TrackCache

struct PlexTrackResolverTests {
    static let secret = "tok-UNIT-TEST-SECRET-0013"
    static let identifier = "11111111-2222-3333-4444-555555555555"
    static let partPath = "/library/parts/5010/1791856627/file.m4a"
    static let bodySize = 65_536

    struct Fixture {
        let dir = makeTempDir()
        let handle = StubURLProtocol.handle()
        let cache: TrackCache
        let resolver: PlexTrackResolver
        let downloader: PlexPartDownloader
        let track: Track

        init(provider: PlexPartDownloader.ClientProvider? = nil, savedMachine: String? = fixtureMachineIdentifier,
             size: Int64? = Int64(PlexTrackResolverTests.bodySize)) throws {
            let client = PlexClient(
                baseURL: URL(string: "http://stub.local:32400")!, token: PlexToken(PlexTrackResolverTests.secret),
                clientIdentifier: PlexTrackResolverTests.identifier)
            downloader = PlexPartDownloader(clientProvider: provider ?? { client }, session: handle.session)
            cache = TrackCache(directory: dir, downloader: downloader)
            resolver = PlexTrackResolver(cache: cache, savedMachineIdentifier: { savedMachine })
            var track = try Track(plexTrack: fixtureTrack(), machineIdentifier: fixtureMachineIdentifier)
            if case .plex(let partKey, let cacheKey, _) = track.source {
                track.source = .plex(partKey: partKey, cacheKey: cacheKey, size: size)
            }
            self.track = track
        }

        func serve(status: Int = 200, body: Data? = nil, error: URLError? = nil, delay: TimeInterval = 0) {
            handle.register([StubURLProtocol.Route(
                path: PlexTrackResolverTests.partPath, status: status,
                headers: status == 200 ? ["Content-Type": "audio/mp4"] : [:],
                body: body ?? randomBytes(PlexTrackResolverTests.bodySize), error: error, delay: delay)])
        }

        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    private func header(_ request: StubURLProtocol.RecordedRequest, _ name: String) -> String? {
        request.headers.first { $0.key.lowercased() == name.lowercased() }?.value
    }

    @Test func plexTrackDownloadsWithTheTokenInTheHeader() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.serve()
        let url = try await f.resolver.localURL(for: f.track)
        #expect(try Data(contentsOf: url).count == Self.bodySize)
        let request = try #require(f.handle.recorded.first)
        #expect(f.handle.recorded.count == 1)
        #expect(header(request, "X-Plex-Token") == Self.secret)
        #expect(header(request, "Accept") == "*/*")
        #expect(header(request, "X-Plex-Client-Identifier") == Self.identifier)
        #expect(request.url.path == Self.partPath)
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(!items.contains { $0.name == "X-Plex-Token" })
        #expect(!request.url.absoluteString.contains(Self.secret))
    }

    @Test func nothingUnderTheCacheDirectoryContainsTheToken() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.serve()
        _ = try await f.resolver.localURL(for: f.track)
        #expect(!directoryContains(f.dir, Self.secret))
        #expect(FileManager.default.fileExists(atPath: f.dir.appendingPathComponent("index.json").path))
    }

    @Test func fileSourcesPassThrough() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let local = URL(fileURLWithPath: "/tmp/some-local-file.mp3")
        let track = Track(title: "t", artist: "a", duration: 1, source: .file(local))
        #expect(try await f.resolver.localURL(for: track) == local)
        #expect(f.handle.recorded.isEmpty)
    }

    @Test func httpStatusesMapToDownloadErrors() async throws {
        let f = try Fixture(size: nil); defer { f.cleanup() }
        let cases: [(Int, TrackCacheError)] = [
            (401, .download(.unauthorized)), (404, .download(.notFound)), (500, .download(.httpStatus(500))),
        ]
        for (status, expected) in cases {
            f.serve(status: status)
            await #expect(throws: expected) { try await f.resolver.localURL(for: f.track) }
        }
        #expect(await f.cache.entries().isEmpty)
        #expect(tempContents(f.dir).isEmpty)
    }

    @Test func transportErrorIsADownloadError() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.serve(error: URLError(.networkConnectionLost))
        await #expect(throws: TrackCacheError.download(.transport(.networkConnectionLost))) {
            try await f.resolver.localURL(for: f.track)
        }
    }

    @Test func sizeMismatchAgainstPartSize() async throws {
        let f = try Fixture(size: 100); defer { f.cleanup() }
        f.serve()
        await #expect(throws: TrackCacheError.sizeMismatch(expected: 100, actual: Int64(Self.bodySize))) {
            try await f.resolver.localURL(for: f.track)
        }
        #expect(await f.cache.entries().isEmpty)
    }

    @Test func noServerFailsBeforeAnyRequest() async throws {
        let f = try Fixture(provider: { nil }); defer { f.cleanup() }
        f.serve()
        await #expect(throws: TrackCacheError.noServer) { try await f.resolver.localURL(for: f.track) }
        #expect(f.handle.recorded.isEmpty)
    }

    @Test func serverMismatchFailsBeforeAnyRequest() async throws {
        let f = try Fixture(savedMachine: "ffffffffffffffffffffffffffffffffffffffff"); defer { f.cleanup() }
        f.serve()
        await #expect(throws: TrackCacheError.serverMismatch) { try await f.resolver.localURL(for: f.track) }
        #expect(f.handle.recorded.isEmpty)
    }

    @Test func cancellingTheResolveCancelsTheRequest() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.serve(delay: 1)
        let started = Date()
        let task = Task { try await f.resolver.localURL(for: f.track) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(await waitFor { tempContents(f.dir).isEmpty })
        #expect(await f.cache.stats().inFlight == 0)
    }

    @Test func errorsNeverContainTheToken() async throws {
        var texts: [String] = []
        func collect(_ error: any Error) {
            texts += [String(describing: error), String(reflecting: error), error.localizedDescription]
        }

        let f = try Fixture(size: nil); defer { f.cleanup() }
        for status in [401, 404, 500] {
            f.serve(status: status)
            do { _ = try await f.resolver.localURL(for: f.track); Issue.record("expected \(status) to fail") } catch { collect(error) }
        }
        f.serve(error: URLError(.networkConnectionLost))
        do { _ = try await f.resolver.localURL(for: f.track) } catch { collect(error) }

        let sized = try Fixture(size: 100); defer { sized.cleanup() }
        sized.serve()
        do { _ = try await sized.resolver.localURL(for: sized.track) } catch { collect(error) }

        let none = try Fixture(provider: { nil }); defer { none.cleanup() }
        do { _ = try await none.resolver.localURL(for: none.track) } catch { collect(error) }

        let other = try Fixture(savedMachine: "ffffffffffffffffffffffffffffffffffffffff"); defer { other.cleanup() }
        do { _ = try await other.resolver.localURL(for: other.track) } catch { collect(error) }

        texts += [String(reflecting: f.downloader), String(describing: f.downloader), String(reflecting: f.resolver)]
        #expect(texts.count > 10)
        for text in texts {
            #expect(!text.contains(Self.secret))
            #expect(!text.contains("X-Plex-Token"))
        }
    }

    // MARK: resolve(_:) (#0039)

    @Test func plexMissResolvesToAProgressiveDownload() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.serve()
        guard case .progressive(let source) = try await f.resolver.resolve(f.track) else {
            Issue.record("expected a progressive source")
            return
        }
        #expect(source.finalSize == Int64(Self.bodySize))
        #expect(source.pathExtension == "m4a")
        #expect(!String(describing: source).contains(Self.secret))
        // Reading it to the end completes and caches the part.
        let outcome = await withCheckedContinuation { continuation in
            Thread { continuation.resume(returning: source.waitForBytes(through: source.finalSize, timeout: 10)) }.start()
        }
        guard case .available = outcome else { Issue.record("expected .available"); return }
        let cached = await waitFor { await f.cache.entries().count == 1 }
        #expect(cached)
        source.close()
    }

    @Test func plexHitResolvesToTheFile() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.serve()
        _ = try await f.resolver.localURL(for: f.track)
        guard case .file(let url) = try await f.resolver.resolve(f.track) else {
            Issue.record("expected a file")
            return
        }
        #expect(url.lastPathComponent.hasSuffix(".m4a"))
        #expect(f.handle.recorded.count == 1)
    }

    @Test func fileSourcesResolveToTheFile() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let local = URL(fileURLWithPath: "/tmp/some-local-file.mp3")
        let track = Track(title: "t", artist: "a", duration: 1, source: .file(local))
        guard case .file(let url) = try await f.resolver.resolve(track) else {
            Issue.record("expected a file")
            return
        }
        #expect(url == local)
        #expect(f.handle.recorded.isEmpty)
    }

    @Test func missingSizeResolvesToTheFileAfterTheDownload() async throws {
        let f = try Fixture(size: nil); defer { f.cleanup() }
        f.serve()
        guard case .file(let url) = try await f.resolver.resolve(f.track) else {
            Issue.record("expected a file")
            return
        }
        #expect(try Data(contentsOf: url).count == Self.bodySize)
    }

    @Test func serverMismatchFailsResolveBeforeAnyRequest() async throws {
        let f = try Fixture(savedMachine: "ffffffffffffffffffffffffffffffffffffffff"); defer { f.cleanup() }
        f.serve()
        await #expect(throws: TrackCacheError.serverMismatch) { try await f.resolver.resolve(f.track) }
        #expect(f.handle.recorded.isEmpty)
    }

    @Test func aProgressiveDownloadNeverWritesTheTokenToDisk() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.serve()
        guard case .progressive(let source) = try await f.resolver.resolve(f.track) else {
            Issue.record("expected a progressive source")
            return
        }
        let outcome = await withCheckedContinuation { continuation in
            Thread { continuation.resume(returning: source.waitForBytes(through: source.finalSize, timeout: 10)) }.start()
        }
        guard case .available = outcome else { Issue.record("expected .available"); return }
        source.close()
        #expect(!directoryContains(f.dir, Self.secret))
        #expect(f.handle.recorded.allSatisfy { !$0.url.absoluteString.contains(Self.secret) })
    }
}
