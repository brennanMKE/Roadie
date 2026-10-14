import Foundation

public struct MAHTTPResponse: Sendable, Hashable {
    public var status: Int
    public var contentType: String?
    public var body: Data

    public init(status: Int, contentType: String? = nil, body: Data = Data()) {
        self.status = status
        self.contentType = contentType
        self.body = body
    }
}

/// `GET /info` and the image proxy: the only two things the client fetches over HTTP. Neither carries the token.
public protocol MAHTTPTransport: Sendable {
    /// Throws `URLError` when nothing answers.
    func get(_ url: URL, headers: [String: String], timeout: Duration) async throws -> MAHTTPResponse
}

public struct URLSessionHTTPTransport: MAHTTPTransport {
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    public init() {}

    public func get(_ url: URL, headers: [String: String], timeout: Duration) async throws -> MAHTTPResponse {
        var request = URLRequest(url: url)
        request.timeoutInterval = ReconnectPolicy.seconds(timeout)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return MAHTTPResponse(status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type"), body: data)
    }
}
