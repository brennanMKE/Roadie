import Foundation
import PlayerKitTestFixtures
import Testing
@testable import MusicAssistantKit

/// `URLSessionWebSocketTransport` against a WebSocket server on 127.0.0.1 (#0214).
@Suite(.timeLimit(.minutes(1)))
struct WebSocketTransportTests {
    private func connected() async throws
        -> (LoopbackWebSocketServer, LoopbackWebSocketServer.Connection, any MAWebSocketTransport)
    {
        let server = try await LoopbackWebSocketServer()
        let factory = URLSessionWebSocketTransportFactory(session: URLSession(configuration: .ephemeral))
        let transport = factory.makeTransport(url: server.baseURL)
        try await transport.connect()
        try await transport.send("hello")
        let connection = try #require(await server.nextConnection())
        return (server, connection, transport)
    }

    @Test func maTransportSendsAndReceivesFrames() async throws {
        let base = try #require(URL(string: "http://127.0.0.1:8095/prefix/?x=1"))
        #expect(URLSessionWebSocketTransport.socketURL(for: base)?.absoluteString == "ws://127.0.0.1:8095/prefix/ws")

        let (server, connection, transport) = try await connected()
        defer { server.stop() }
        #expect(await connection.next() == .text("hello"))
        try await connection.send(text: "{\"server_id\":\"a\"}")
        let text = try await transport.receive()
        #expect(text == .text("{\"server_id\":\"a\"}"))
        try await connection.send(binary: Data("{\"b\":1}".utf8))
        let binary = try await transport.receive()
        #expect(binary == .text("{\"b\":1}"))
    }

    @Test func maTransportReportsServerClose() async throws {
        let (server, connection, transport) = try await connected()
        defer { server.stop() }
        _ = await connection.next()
        try await connection.close(code: 1001)
        let frame = try await transport.receive()
        #expect(frame == .closed(code: 1001))
    }

    @Test func maTransportPingsAndCloses() async throws {
        let (server, connection, transport) = try await connected()
        defer { server.stop() }
        _ = await connection.next()
        try await transport.ping()
        await transport.close(code: 1000)
        #expect(await connection.next() == .close(code: 1000))

        // Cancelling a pending receive closes the task too.
        let (server2, connection2, transport2) = try await connected()
        defer { server2.stop() }
        _ = await connection2.next()
        let receiving = Task { try await transport2.receive() }
        try await Task.sleep(for: .milliseconds(100))
        receiving.cancel()
        #expect(await connection2.next() == .close(code: 1000))
        _ = await receiving.result
    }

    @Test func maTransportMapsRefusedConnection() async throws {
        let server = try await LoopbackWebSocketServer()
        let base = server.baseURL
        server.stop()
        let transport = URLSessionWebSocketTransportFactory(session: URLSession(configuration: .ephemeral))
            .makeTransport(url: base)
        try await transport.connect()
        do {
            let frame = try await transport.receive()
            Issue.record("expected a transport error, got \(frame)")
        } catch let error as MusicAssistantError {
            switch error {
            case .transport, .handshakeFailed: break
            default: Issue.record("expected .transport, got \(error)")
            }
        }
    }
}
