import Foundation
import PlayerKitTestFixtures
import Testing
@testable import SendspinKit

/// `URLSessionSendspinTransport` against a WebSocket server on 127.0.0.1 (#0214).
@Suite(.timeLimit(.minutes(1)))
struct SendspinTransportTests {
    private func connected() async throws
        -> (LoopbackWebSocketServer, LoopbackWebSocketServer.Connection, URLSessionSendspinTransport)
    {
        let server = try await LoopbackWebSocketServer()
        let url = try #require(URL(string: "ws://127.0.0.1:\(server.port)/sendspin"))
        let transport = URLSessionSendspinTransport(url: url, session: URLSession(configuration: .ephemeral))
        try await transport.connect()
        try await transport.send(text: "hello")
        let connection = try #require(await server.nextConnection())
        return (server, connection, transport)
    }

    @Test func transportSendsAndReceivesFrames() async throws {
        let (server, connection, transport) = try await connected()
        defer { server.stop() }
        #expect(await connection.next() == .text("hello"))

        try await connection.send(text: "{\"type\":\"server/hello\"}")
        let text = try await transport.receive()
        #expect(text == .text("{\"type\":\"server/hello\"}"))
        try await connection.send(binary: Data([1, 2, 3]))
        let binary = try await transport.receive()
        #expect(binary == .binary(Data([1, 2, 3])))

        await transport.close(code: 1000)
        #expect(await connection.next() == .close(code: 1000))
    }

    @Test func transportMapsCloseCode() async throws {
        let (server, connection, transport) = try await connected()
        defer { server.stop() }
        _ = await connection.next()
        try await connection.close(code: 1001)
        let frame = try await transport.receive()
        guard case .closed(let code, _) = frame else {
            Issue.record("expected a close, got \(frame)")
            return
        }
        #expect(code == 1001)
    }

    @Test func transportMapsRefusedConnection() async throws {
        let server = try await LoopbackWebSocketServer()
        let port = server.port
        server.stop()
        let url = try #require(URL(string: "ws://127.0.0.1:\(port)/sendspin"))
        let transport = URLSessionSendspinTransport(url: url, session: URLSession(configuration: .ephemeral))
        try await transport.connect()
        do {
            let frame = try await transport.receive()
            Issue.record("expected a transport error, got \(frame)")
        } catch let error as SendspinError {
            guard case .transport(let message) = error else {
                Issue.record("expected .transport, got \(error)")
                return
            }
            #expect(message.hasPrefix("URLError"))
        }
    }

    @Test func cancelledReceiveCloses() async throws {
        let (server, connection, transport) = try await connected()
        defer { server.stop() }
        _ = await connection.next()
        let receiving = Task { try await transport.receive() }
        try await Task.sleep(for: .milliseconds(100))
        receiving.cancel()
        // The cancel closes the task: the server sees a normal close, and the pending receive ends.
        #expect(await connection.next() == .close(code: 1000))
        let result = await receiving.result
        if case .success(let frame) = result {
            #expect(frame == .closed(code: 1000, reason: nil))
        }
    }

    @Test func factoryMakesAURLSessionTransport() throws {
        let factory = URLSessionSendspinTransportFactory(session: URLSession(configuration: .ephemeral))
        let url = try #require(URL(string: "ws://127.0.0.1:1/sendspin"))
        #expect(factory.makeTransport(url: url) is URLSessionSendspinTransport)
    }
}
