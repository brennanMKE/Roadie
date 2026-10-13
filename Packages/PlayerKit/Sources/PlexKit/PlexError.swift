import Foundation

/// Errors from the Plex client. No case carries a request, header or response body,
/// so the token cannot leak through an error message.
public enum PlexError: Error, Hashable, Sendable, LocalizedError {
    case invalidBaseURL
    /// No response at all (DNS, refused, timeout).
    case transport(URLError.Code)
    /// 401.
    case unauthorized
    /// 404.
    case notFound
    /// Any other non-2xx status.
    case httpStatus(Int)
    /// The server ignored `Accept: application/json` (an HTML login page, a proxy).
    case notJSON(contentType: String?)
    case decoding(path: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL: "The server address is not valid."
        case .transport(let code): "Could not reach the server (network error \(code.rawValue))."
        case .unauthorized: "The server rejected the sign-in."
        case .notFound: "The server has no such item."
        case .httpStatus(let status): "The server answered with status \(status)."
        case .notJSON: "The server did not answer with JSON."
        case .decoding(let path, _): "The server's answer could not be read (at \(path))."
        }
    }
}
