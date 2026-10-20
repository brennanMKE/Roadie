import Foundation

/// When SkinAmp's Sendspin session should start, restart or stop (#0109). Pure, so the app's policy is tested here.
public enum SendspinAutoConnect {
    public enum Action: Equatable, Sendable { case start, restart, stop, none }

    /// - Parameters:
    ///   - enabled: Settings › Music Assistant › Play Music Assistant on this Mac.
    ///   - endpointURL: the base URL of the server the Music Assistant API is connected to; nil when not connected.
    ///   - runningURL: the base URL of the running session; nil when none runs.
    public static func decide(enabled: Bool, endpointURL: URL?, runningURL: URL?) -> Action {
        guard enabled, let endpointURL else { return runningURL == nil ? .none : .stop }
        guard let runningURL else { return .start }
        return runningURL == endpointURL ? .none : .restart
    }
}
