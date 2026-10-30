import Foundation
import Network

/// A WebSocket server on 127.0.0.1 for the transport tests (#0214). Nothing leaves the machine.
public final class LoopbackWebSocketServer: @unchecked Sendable {
    public enum Message: Sendable, Equatable {
        case text(String)
        case binary(Data)
        /// The client's close frame; `code` is nil when it had none.
        case close(code: UInt16?)
    }

    /// One accepted client.
    public final class Connection: @unchecked Sendable {
        private let connection: NWConnection
        private let messages: AsyncStream<Message>
        private let continuation: AsyncStream<Message>.Continuation

        init(_ connection: NWConnection, queue: DispatchQueue) {
            self.connection = connection
            (messages, continuation) = AsyncStream<Message>.makeStream()
            connection.start(queue: queue)
            receiveNext()
        }

        /// The next frame from the client; nil once the connection ended.
        public func next() async -> Message? {
            var iterator = messages.makeAsyncIterator()
            return await iterator.next()
        }

        public func send(text: String) async throws {
            try await send(Data(text.utf8), NWProtocolWebSocket.Metadata(opcode: .text))
        }

        public func send(binary: Data) async throws {
            try await send(binary, NWProtocolWebSocket.Metadata(opcode: .binary))
        }

        /// Sends a close frame with `code` (1000…1015 as protocol codes, else an application code).
        public func close(code: UInt16) async throws {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
            metadata.closeCode = NWProtocolWebSocket.CloseCode.Defined(rawValue: code).map { .protocolCode($0) }
                ?? .applicationCode(code)
            try await send(nil, metadata)
        }

        func cancel() { connection.cancel() }

        private func send(_ data: Data?, _ metadata: NWProtocolWebSocket.Metadata) async throws {
            let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                connection.send(
                    content: data, contentContext: context, isComplete: true,
                    completion: .contentProcessed { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    })
            }
        }

        private func receiveNext() {
            connection.receiveMessage { [weak self] content, context, _, error in
                guard let self else { return }
                guard error == nil,
                      let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                        as? NWProtocolWebSocket.Metadata
                else {
                    continuation.finish()
                    return
                }
                switch metadata.opcode {
                case .text:
                    continuation.yield(.text(String(decoding: content ?? Data(), as: UTF8.self)))
                case .binary:
                    continuation.yield(.binary(content ?? Data()))
                case .close:
                    let code: UInt16? = switch metadata.closeCode {
                    case .protocolCode(let defined): defined.rawValue
                    case .applicationCode(let value), .privateCode(let value): value
                    @unknown default: nil
                    }
                    continuation.yield(.close(code: code))
                    continuation.finish()
                    return
                default:
                    break
                }
                receiveNext()
            }
        }
    }

    public let port: UInt16
    /// `http://127.0.0.1:<port>`.
    public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "LoopbackWebSocketServer")
    private let connections: AsyncStream<Connection>
    private let connectionsContinuation: AsyncStream<Connection>.Continuation
    private let accepted = Accepted()

    public init() async throws {
        let parameters = NWParameters.tcp
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        (connections, connectionsContinuation) = AsyncStream<Connection>.makeStream()
        let queue = queue
        let continuation = connectionsContinuation
        let accepted = accepted
        listener.newConnectionHandler = { connection in
            guard !accepted.isStopped else {
                connection.cancel()
                return
            }
            let wrapped = Connection(connection, queue: queue)
            accepted.append(wrapped)
            continuation.yield(wrapped)
        }
        port = try await withCheckedThrowingContinuation { (ready: CheckedContinuation<UInt16, any Error>) in
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    listener?.stateUpdateHandler = nil
                    ready.resume(returning: listener?.port?.rawValue ?? 0)
                case .failed(let error):
                    listener?.stateUpdateHandler = nil
                    ready.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// The next client to connect; nil after `stop()`.
    public func nextConnection() async -> Connection? {
        var iterator = connections.makeAsyncIterator()
        return await iterator.next()
    }

    /// Stops listening and waits until the listener is cancelled; later clients are dropped.
    public func stop() async {
        accepted.stop()
        connectionsContinuation.finish()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [listener] in
                if case .cancelled = listener.state {
                    done.resume()
                    return
                }
                listener.stateUpdateHandler = { [weak listener] state in
                    switch state {
                    case .cancelled, .failed:
                        listener?.stateUpdateHandler = nil
                        done.resume()
                    default:
                        break
                    }
                }
                listener.cancel()
            }
        }
    }

    deinit {
        accepted.stop()
        listener.cancel()
    }

    private final class Accepted: @unchecked Sendable {
        private let lock = NSLock()
        private var connections: [Connection] = []
        private var stopped = false

        var isStopped: Bool { lock.withLock { stopped } }

        func append(_ connection: Connection) { lock.withLock { connections.append(connection) } }

        /// Cancels every accepted client; after this the listener drops new ones.
        func stop() {
            let all = lock.withLock { () -> [Connection] in
                stopped = true
                defer { connections = [] }
                return connections
            }
            all.forEach { $0.cancel() }
        }
    }
}

/// A 127.0.0.1 port with nothing bound to it, so a connection gets a RST (#0214): bound to port 0 for a free port,
/// then closed. Another test could take the port in between; that race is accepted.
public struct RefusingPort: Sendable {
    public let port: UInt16

    public init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.bind(fd, raw, length) == 0 && getsockname(fd, raw, &length) == 0
            }
        }
        guard bound else { throw POSIXError(.EADDRINUSE) }
        port = UInt16(bigEndian: address.sin_port)
    }
}
