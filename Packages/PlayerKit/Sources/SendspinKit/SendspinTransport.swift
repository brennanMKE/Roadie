import Foundation

public enum SendspinFrame: Sendable, Equatable {
    case text(String)
    case binary(Data)
    case closed(code: Int?, reason: String?)
}

/// The seam between the session and `URLSessionWebSocketTask`; tests use a scripted stub.
public protocol SendspinTransport: Sendable {
    func connect() async throws
    func send(text: String) async throws
    func receive() async throws -> SendspinFrame
    func close(code: Int) async
}

public protocol SendspinTransportFactory: Sendable {
    /// `url` is the full `ws(s)://…/sendspin` URL.
    func makeTransport(url: URL) -> any SendspinTransport
}

public struct URLSessionSendspinTransportFactory: SendspinTransportFactory {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func makeTransport(url: URL) -> any SendspinTransport {
        URLSessionSendspinTransport(url: url, session: session)
    }
}

/// One `URLSessionWebSocketTask`, created in `init` and never replaced. URLSession answers pings itself.
public final class URLSessionSendspinTransport: SendspinTransport, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(url: URL, session: URLSession) {
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = 4 * 1024 * 1024
    }

    public func connect() async throws { task.resume() }

    public func send(text: String) async throws {
        do {
            try await task.send(.string(text))
        } catch {
            throw Self.map(error)
        }
    }

    public func receive() async throws -> SendspinFrame {
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await withTaskCancellationHandler {
                try await task.receive()
            } onCancel: { [task] in
                task.cancel(with: .normalClosure, reason: nil)
            }
        } catch {
            if task.closeCode != .invalid {
                let reason = task.closeReason.map { String(decoding: $0, as: UTF8.self) }
                return .closed(code: task.closeCode.rawValue, reason: reason)
            }
            throw Self.map(error)
        }
        switch message {
        case .string(let text): return .text(text)
        case .data(let data): return .binary(data)
        @unknown default: return .binary(Data())
        }
    }

    public func close(code: Int) async {
        task.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure, reason: nil)
    }

    private static func map(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        if let urlError = error as? URLError { return SendspinError.transport("URLError \(urlError.code.rawValue)") }
        return SendspinError.transport("disconnected")
    }
}
