import AudioCore

/// Everything "This Mac" playback needs, built in the right order (player, then the output over it). The app's
/// composition root is the only place that builds it; every backend that plays through AudioCore shares `output`.
/// #0066 adds Music Assistant's Sendspin input here.
@MainActor
public struct LocalPlaybackStack {
    public let player: Player
    public let output: LocalPlayerOutput

    public init(player: Player, output: LocalPlayerOutput) { self.player = player; self.output = output }

    /// `Player()` (file resolver) and its output. Opens no audio device, reads no settings, no Keychain, no network.
    public static func standard() -> LocalPlaybackStack {
        let player = Player()
        return LocalPlaybackStack(player: player, output: LocalPlayerOutput(player: player))
    }
}
