import Foundation

public enum MuseumError: Error, Equatable, Sendable, LocalizedError {
    /// Any `URLError` (not connected, timeout, host not found, …).
    case offline
    case http(Int)
    case graphQL(String)
    case decoding
    case checksumMismatch
    case tooLarge
    case noFolder

    public var errorDescription: String? {
        switch self {
        case .offline: "The Winamp Skin Museum can't be reached. Check your internet connection."
        case .http(let status): "The Winamp Skin Museum returned an error (HTTP \(status))."
        case .graphQL(let message): "The Winamp Skin Museum reported an error: \(message)"
        case .decoding: "The Winamp Skin Museum sent a response Roadie doesn't understand."
        case .checksumMismatch: "The download was corrupted."
        case .tooLarge: "The skin is too large to download."
        case .noFolder: "Choose a skins folder to download skins into."
        }
    }
}
