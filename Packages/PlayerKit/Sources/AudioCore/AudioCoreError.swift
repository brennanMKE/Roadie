import Foundation

public enum AudioCoreError: Error, LocalizedError {
    case engineStart(underlying: any Error)
    case unresolvableSource(Track.Source)

    public var errorDescription: String? {
        switch self {
        case .engineStart(let underlying):
            "Could not start the audio engine: \(underlying.localizedDescription)"
        case .unresolvableSource:
            "This track is not available as a local file."
        }
    }
}
