import Foundation
import PlayerKitTestFixtures
import Testing
@testable import MusicAssistantKit

/// `URLSessionWebSocketTransport` against a WebSocket server on 127.0.0.1 (#0214).
@Suite(.timeLimit(.minutes(1)))
struct WebSocketTransportTests {
    private func connected() async throws
        -> (LoopbackWebSocketServer, LoopbackWebSocketServer.Connection, any MAWebSocketTransport, URLSession)
    {
        let server = try await LoopbackWebSocketServer()
        let session = URLSession(configuration: .ephemeral)
        let transport = URLSessionWebSocketTransportFactory(session: session).makeTransport(url: server.baseURL)
        try await transport.connect()
        try await transport.send("hello")
        let connection = try #require(await server.nextConnection())
        return (server, connection, transport, session)
    }

    @Test func maTransportSendsAndReceivesFrames() async throws {
        let base = try #require(URL(string: "http://127.0.0.1:8095/prefix/?x=1"))
        #expect(URLSessionWebSocketTransport.socketURL(for: base)?.absoluteString == "ws://127.0.0.1:8095/prefix/ws")

        let (server, connection, transport, session) = try await connected()
        defer { session.invalidateAndCancel() }
        #expect(await connection.next() == .text("hello"))
        try await connection.send(text: "{\"server_id\":\"a\"}")
        let text = try await transport.receive()
        #expect(text == .text("{\"server_id\":\"a\"}"))
        try await connection.send(binary: Data("{\"b\":1}".utf8))
        let binary = try await transport.receive()
        #expect(binary == .text("{\"b\":1}"))
        await server.stop()
    }

    @Test func maTransportReportsServerClose() async throws {
        let (server, connection, transport, session) = try await connected()
        defer { session.invalidateAndCancel() }
        _ = await connection.next()
        try await connection.close(code: 1001)
        let frame = try await transport.receive()
        #expect(frame == .closed(code: 1001))
        await server.stop()
    }

    @Test func maTransportPingsAndCloses() async throws {
        let (server, connection, transport, session) = try await connected()
        defer { session.invalidateAndCancel() }
        _ = await connection.next()
        try await transport.ping()
        await transport.close(code: 1000)
        #expect(await connection.next() == .close(code: 1000))

        // Cancelling a pending receive closes the task too.
        let (server2, connection2, transport2, session2) = try await connected()
        defer { session2.invalidateAndCancel() }
        _ = await connection2.next()
        let receiving = Task { try await transport2.receive() }
        try await Task.sleep(for: .milliseconds(100))
        receiving.cancel()
        #expect(await connection2.next() == .close(code: 1000))
        switch await receiving.result {
        case .success(let frame): #expect(frame == .closed(code: 1000))
        case .failure(let error): #expect(error is CancellationError, "\(error)")
        }
        await server.stop()
        await server2.stop()
    }

    @Test func maTransportMapsRefusedConnection() async throws {
        let refusing = try RefusingPort()
        // Bounded even if the refusal doesn't come: a timeout still has to map to a transport error.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let base = try #require(URL(string: "http://127.0.0.1:\(refusing.port)"))
        let transport = URLSessionWebSocketTransportFactory(session: session).makeTransport(url: base)
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
