import Foundation

public enum MAWebSocketFrame: Sendable, Hashable {
    case text(String)
    case closed(code: Int?)
}

/// The seam between the client and `URLSessionWebSocketTask`. The stub target replays recorded messages through it.
public protocol MAWebSocketTransport: Sendable {
    /// The HTTP upgrade. Throws `MusicAssistantError.transport` or `.handshakeFailed`.
    func connect() async throws
    func send(_ text: String) async throws
    /// Server pings are answered inside; only text messages and the close surface here.
    func receive() async throws -> MAWebSocketFrame
    /// Resolves on the pong; throws on failure.
    func ping() async throws
    func close(code: Int) async
}

public protocol MAWebSocketTransportFactory: Sendable {
    /// `url` is the server's HTTP base URL; the transport derives `ws(s)://host:port/ws` from it.
    func makeTransport(url: URL) -> any MAWebSocketTransport
}

public struct URLSessionWebSocketTransportFactory: MAWebSocketTransportFactory {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func makeTransport(url: URL) -> any MAWebSocketTransport {
        URLSessionWebSocketTransport(baseURL: url, session: session)
    }
}

/// Wraps one `URLSessionWebSocketTask`. `URLSession` answers the server's pings itself.
/// The task is created in `init`, never replaced, and only touched through its thread-safe methods.
public final class URLSessionWebSocketTransport: MAWebSocketTransport, @unchecked Sendable {
    private let task: URLSessionWebSocketTask?

    init(baseURL: URL, session: URLSession) {
        task = Self.socketURL(for: baseURL).map { session.webSocketTask(with: $0) }
    }

    /// `https` becomes `wss` (TLS, including a Tailscale `tailscale serve` address) and `http` becomes `ws`; a path
    /// prefix is kept and `/ws` appended; the query is dropped.
    static func socketURL(for baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        switch components.scheme?.lowercased() {
        case "https", "wss": components.scheme = "wss"
        default: components.scheme = "ws"
        }
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/ws"
        components.query = nil
        return components.url
    }

    public func connect() async throws {
        guard let task else { throw MusicAssistantError.invalidURL }
        // The upgrade is confirmed by the first successful receive(); a refusal surfaces there.
        task.resume()
    }

    public func send(_ text: String) async throws {
        guard let task else { throw MusicAssistantError.invalidURL }
        do {
            try await task.send(.string(text))
        } catch {
            throw Self.map(error)
        }
    }

    public func receive() async throws -> MAWebSocketFrame {
        guard let task else { throw MusicAssistantError.invalidURL }
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await withTaskCancellationHandler {
                try await task.receive()
            } onCancel: {
                task.cancel(with: .normalClosure, reason: nil)
            }
        } catch {
            if task.closeCode != .invalid { return .closed(code: task.closeCode.rawValue) }
            throw Self.map(error)
        }
        switch message {
        case .string(let text): return .text(text)
        case .data(let data): return .text(String(decoding: data, as: UTF8.self))
        @unknown default: return .text("")
        }
    }

    public func ping() async throws {
        guard let task else { throw MusicAssistantError.invalidURL }
        // The client's pong timeout cancels this, and its task group waits for it to end: closing the task makes
        // URLSession fail the pending pong handler, so a pong that never comes cannot hang the heartbeat.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                task.sendPing { error in
                    if let error {
                        continuation.resume(throwing: Self.map(error))
                    } else {
                        continuation.resume()
                    }
                }
            }
        } onCancel: {
            task.cancel(with: .normalClosure, reason: nil)
        }
    }

    public func close(code: Int) async {
        task?.cancel(with: .normalClosure, reason: nil)
    }

    private static func map(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        if let urlError = error as? URLError {
            return urlError.code == .badServerResponse ? MusicAssistantError.handshakeFailed : MusicAssistantError.transport(urlError.code)
        }
        return MusicAssistantError.disconnected
    }
}
