import Foundation

/// Errors from the Music Assistant client. No case carries a URL, a host, a request, a frame or the token,
/// so none of them can leak through a message or a log line.
public enum MusicAssistantError: Error, Hashable, Sendable, LocalizedError {
    case invalidURL
    /// No answer at all (DNS, refused, timeout, dropped link).
    case transport(URLError.Code)
    /// The upgrade was refused, or the first message was not the server's info.
    case handshakeFailed
    case schemaUnsupported(server: Int, minSupported: Int)
    /// A different server answered at this address than the one configured.
    case serverMismatch
    /// Error 23.
    case tokenRejected
    /// Error 20.
    case unauthenticated
    case server(code: Int, details: String)
    case timeout(command: String)
    case disconnected
    case notConnected
    case decoding(command: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "The Music Assistant address is not valid."
        case .transport(.appTransportSecurityRequiresSecureConnection):
            "App Transport Security requires https for this address (network error -1022)."
        case .transport, .handshakeFailed, .timeout, .disconnected: "Can't reach the Music Assistant server."
        case .schemaUnsupported(let server, let minSupported):
            if server < MusicAssistantClient.minimumSchemaVersion {
                "This Music Assistant server is too old for Roadie (schema \(server); needs \(MusicAssistantClient.minimumSchemaVersion) or later)."
            } else {
                "This Music Assistant server is too new for Roadie (it needs clients newer than schema \(minSupported))."
            }
        case .serverMismatch: "A different Music Assistant server answered at this address."
        case .tokenRejected: "The Music Assistant token was rejected."
        case .unauthenticated: "Music Assistant needs a token before it will answer."
        case .server: "The Music Assistant server reported an error."
        case .notConnected: "Not connected to Music Assistant."
        case .decoding: "The Music Assistant server's answer could not be read."
        }
    }
}
