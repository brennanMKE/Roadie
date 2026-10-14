import Foundation
import PlexKit
import PlexKitStub
import Testing
@testable import TrackCache

/// `PlexPartDownloader` over `StubURLProtocol`: progress per flush, and range requests that carry the token only
/// in a header.
struct PlexPartDownloaderTests {
    static let secret = "tok-UNIT-TEST-SECRET-0039"
    static let partKey = "/library/parts/5010/1791856627/file.m4a"

    struct Fixture {
        let handle = StubURLProtocol.handle()
        let downloader: PlexPartDownloader

        init() {
            let client = PlexClient(
                baseURL: URL(string: "http://stub.local:32400")!, token: PlexToken(PlexPartDownloaderTests.secret),
                clientIdentifier: "11111111-2222-3333-4444-555555555555")
            downloader = PlexPartDownloader(clientProvider: { client }, session: handle.session)
        }

        func serve(status: Int = 200, body: Data) {
            handle.register([StubURLProtocol.Route(
                path: PlexPartDownloaderTests.partKey, status: status, headers: ["Content-Type": "audio/mp4"], body: body)])
        }
    }

    final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int64] = []
        func add(_ value: Int64) { lock.lock(); values.append(value); lock.unlock() }
        var all: [Int64] { lock.lock(); defer { lock.unlock() }; return values }
    }

    private func header(_ request: StubURLProtocol.RecordedRequest, _ name: String) -> String? {
        request.headers.first { $0.key.lowercased() == name.lowercased() }?.value
    }

    @Test func progressIsReportedPerFlushAndAtTheEnd() async throws {
        let f = Fixture()
        let body = randomBytes(600 * 1024)
        f.serve(body: body)
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("part")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let seen = Collected()
        let total = try await f.downloader.download(partKey: Self.partKey, to: url, progress: { seen.add($0) })
        #expect(total == Int64(body.count))
        let values = seen.all
        #expect(values.count >= 2)
        #expect(values == values.sorted() && Set(values).count == values.count)
        #expect(values.last == total)
    }

    @Test func rangeRequestsCarryTheTokenInTheHeaderAndTheRange() async throws {
        let f = Fixture()
        let body = randomBytes(1000)
        f.serve(status: 206, body: body.subdata(in: 100..<300))
        let data = try await f.downloader.fetch(partKey: Self.partKey, range: 100..<300)
        #expect(data.count == 200)
        let request = try #require(f.handle.recorded.first)
        #expect(header(request, "Range") == "bytes=100-299")
        #expect(header(request, "X-Plex-Token") == Self.secret)
        #expect(!request.url.absoluteString.contains(Self.secret))
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(!items.contains { $0.name == "X-Plex-Token" })
    }

    @Test func aFullBodyAnswersARangeRequestWithTheSlice() async throws {
        let f = Fixture()
        let body = randomBytes(1000)
        f.serve(status: 200, body: body)
        let data = try await f.downloader.fetch(partKey: Self.partKey, range: 100..<300)
        #expect(data == body.subdata(in: 100..<300))
    }

    @Test func rangeStatusesMapToDownloadErrors() async throws {
        let f = Fixture()
        let cases: [(Int, TrackCacheError)] = [
            (401, .download(.unauthorized)), (404, .download(.notFound)), (416, .download(.httpStatus(416))),
        ]
        for (status, expected) in cases {
            f.serve(status: status, body: Data())
            await #expect(throws: expected) { try await f.downloader.fetch(partKey: Self.partKey, range: 0..<10) }
        }
    }

    @Test func aShortRangeBodyIsAnError() async throws {
        let f = Fixture()
        f.serve(status: 206, body: randomBytes(50))
        await #expect(throws: TrackCacheError.download(.transport(.badServerResponse))) {
            try await f.downloader.fetch(partKey: Self.partKey, range: 0..<100)
        }
    }

    @Test func errorsAndDescriptionsNeverContainTheToken() async throws {
        let f = Fixture()
        var texts: [String] = []
        for status in [401, 404, 416, 500] {
            f.serve(status: status, body: Data())
            do { _ = try await f.downloader.fetch(partKey: Self.partKey, range: 0..<10); Issue.record("expected failure") } catch {
                texts += [String(describing: error), String(reflecting: error), error.localizedDescription]
            }
        }
        texts += [String(describing: f.downloader), String(reflecting: f.downloader)]
        for text in texts { #expect(!text.contains(Self.secret)) }
    }
}
