import Foundation

@testable import SkinMuseum

/// Answers from committed fixtures, in order (the last reply repeats), and records every request. Never touches the network.
final class StubMuseumTransport: MuseumTransport, @unchecked Sendable {
    enum Reply {
        case fixture(String, status: Int = 200, headers: [String: String] = [:])
        case status(Int, headers: [String: String] = [:])
        case failure(URLError.Code)
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var recorded: [URLRequest] = []

    init(_ replies: Reply...) {
        self.replies = replies
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply: Reply = lock.withLock {
            recorded.append(request)
            return replies.count > 1 ? replies.removeFirst() : replies[0]
        }
        let url = request.url!
        switch reply {
        case let .fixture(name, status, headers):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (try Self.fixture(name), response)
        case let .status(status, headers):
            return (Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
        case let .failure(code):
            throw URLError(code)
        }
    }

    static func fixture(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    /// The decoded JSON body of request `index`.
    func body(_ index: Int = 0) throws -> [String: Any] {
        guard let data = requests[index].httpBody else { throw CocoaError(.fileReadUnknown) }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}
