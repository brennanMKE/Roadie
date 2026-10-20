import Foundation

public enum SendspinError: Error, Equatable, Sendable, LocalizedError {
    /// The proxy closed with 4001 (bad or expired token). Carries the close reason, never the token.
    case unauthorized(String?)
    case handshake(String)
    case roleRejected
    case malformed(type: String)
    case timeout(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "Music Assistant refused the Sendspin connection (token)."
        case .handshake(let detail): "The Sendspin handshake failed (\(detail))."
        case .roleRejected: "Music Assistant did not accept SkinAmp as a Sendspin player."
        case .malformed(let type): "Music Assistant sent a malformed Sendspin message (\(type))."
        case .timeout(let what): "Music Assistant did not answer in time (\(what))."
        case .transport(let detail): "The Sendspin connection failed (\(detail))."
        }
    }
}
