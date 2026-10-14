import Foundation

public enum AudioCoreError: Error, LocalizedError {
    case engineStart(underlying: any Error)
    case unresolvableSource(Track.Source)
    case outputDevice(underlying: any Error)

    public var errorDescription: String? {
        switch self {
        case .engineStart(let underlying):
            "Could not start the audio engine: \(underlying.localizedDescription)"
        case .unresolvableSource:
            "This track is not available as a local file."
        case .outputDevice(let underlying):
            "Could not switch the audio output device: \(underlying.localizedDescription)"
        }
    }
}

/// Adopted by errors a `TrackResolver` can throw when they know whether the whole source is unavailable
/// (the player stops) or only this track is unplayable (the player skips it, like Winamp). Errors that
/// do not conform count as per-track.
public protocol SourceScopedError: Error {
    var affectsWholeSource: Bool { get }
}

extension AudioCoreError: SourceScopedError {
    public var affectsWholeSource: Bool {
        switch self {
        case .engineStart, .outputDevice: true
        case .unresolvableSource: false
        }
    }
}
