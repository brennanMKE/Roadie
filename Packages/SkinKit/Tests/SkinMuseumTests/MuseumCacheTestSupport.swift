import Foundation

@testable import SkinMuseum

/// A settable clock for cache tests.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)

    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

/// Answers screenshot GETs with fixed bytes after a short delay, counting calls per URL. Never touches the network.
final class ScreenshotTransport: MuseumTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [URL: Int] = [:]
    private let bytes: Int
    private let failure: URLError.Code?
    private let delay: Duration

    init(bytes: Int = 10, failure: URLError.Code? = nil, delay: Duration = .milliseconds(50)) {
        self.bytes = bytes
        self.failure = failure
        self.delay = delay
    }

    var totalCalls: Int { lock.withLock { counts.values.reduce(0, +) } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        lock.withLock { counts[url, default: 0] += 1 }
        try await Task.sleep(for: delay)
        if let failure { throw URLError(failure) }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(repeating: 0x89, count: bytes), response)
    }
}

func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("MuseumCacheTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func md5(_ n: Int) -> String { String(format: "%032x", n) }

func screenshotURL(_ md5: String) -> URL { URL(string: "https://r2.webampskins.org/screenshots/\(md5).png")! }
