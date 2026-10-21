import Foundation
import MusicBackendKit

/// The command names a Music Assistant server offers (#0137), from `GET <base>/api-docs/commands.json` (no auth).
/// Optional features (reorder, save queue) are offered only when their command is in the set; empty when the
/// probe failed, so nothing optional is offered.
public struct MAServerCommands: Hashable, Sendable {
    public private(set) var names: Set<String>

    public init(_ names: Set<String> = []) { self.names = names }

    public static let empty = MAServerCommands()

    public var isEmpty: Bool { names.isEmpty }

    public func contains(_ command: String) -> Bool { names.contains(command) }

    /// After the server answered error 12 for `command`: absent for the rest of the session.
    public mutating func remove(_ command: String) { names.remove(command) }

    /// Only the `command` field of each entry; anything else in the document is ignored.
    public static func parse(_ data: Data) -> MAServerCommands {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return .empty }
        return MAServerCommands(Set(entries.compactMap { $0["command"] as? String }))
    }

    public static func url(base: URL) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/api-docs/commands.json"
        components.query = nil
        return components.url
    }

    /// Never throws: a transport error, a non-200 status or an unreadable body all yield `.empty`.
    public static func probe(
        transport: any MAHTTPTransport, base: URL, timeout: Duration = .seconds(10)
    ) async -> MAServerCommands {
        guard let url = url(base: base),
              let response = try? await transport.get(url, headers: [:], timeout: timeout),
              response.status == 200
        else { return .empty }
        return parse(response.body)
    }

    /// Error 12: "Invalid or unsupported command."
    public static let unsupportedCommandCode = 12

    /// The capability a missing command takes away, for `MusicBackendError.unsupported`.
    static func capability(of command: String) -> BackendCapabilities {
        command.contains("playlist") ? .playlists : []
    }
}

extension MusicAssistantBackend {
    /// The commands the connected server offers, once the connect-time probe has finished.
    public var commands: MAServerCommands { serverCommands }

    public func supports(_ command: String) -> Bool { serverCommands.contains(command) }

    /// Waits for the connect-time probe (tests, and callers that must know before offering a control).
    public func awaitCommandProbe() async {
        await commandProbe?.value
    }

    /// Starts the probe for the server just connected to; a cached result for the same identity is reused.
    func startCommandProbe(base: URL, identity: String) {
        commandProbe?.cancel()
        if let cached = probedCommands[identity] {
            serverCommands = cached
            commandProbe = nil
            return
        }
        serverCommands = .empty
        let http = self.http
        commandProbe = Task { [weak self] in
            let found = await MAServerCommands.probe(transport: http, base: base)
            guard !Task.isCancelled else { return }
            await self?.installCommands(found, identity: identity)
        }
    }

    private func installCommands(_ found: MAServerCommands, identity: String) {
        serverCommands = found
        if !found.isEmpty { probedCommands[identity] = found }
    }

    /// Sends `request`; a server error 12 removes the command for the session and reads as `.unsupported`.
    public func perform(_ request: MARequest) async throws -> MAJSON {
        guard let client else { throw MusicBackendError.notConnected }
        do {
            return try await client.call(request)
        } catch {
            throw noteUnsupported(error, command: request.command)
        }
    }

    /// Error mapping with the code-12 rule: callers of `client.call` route their errors through this.
    func noteUnsupported(_ error: any Error, command: String) -> any Error {
        if case MusicAssistantError.server(let code, _) = error, code == MAServerCommands.unsupportedCommandCode {
            serverCommands.remove(command)
            for key in probedCommands.keys { probedCommands[key]?.remove(command) }
            return MusicBackendError.unsupported(MAServerCommands.capability(of: command))
        }
        return Self.map(error)
    }
}
