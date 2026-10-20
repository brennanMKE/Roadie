import AudioCore
import SendspinPlayback

/// Everything "This Mac" playback needs, built in the right order (player, then what shares it). The stack owns the
/// one `Player`, the local queue output and the Sendspin input (Music Assistant streaming to this Mac) that share it.
/// The app's composition root is the only place that builds it; every backend that plays through AudioCore shares
/// `output`.
@MainActor
public struct LocalPlaybackStack {
    public let player: Player
    public let output: LocalPlayerOutput
    public let sendspin: SendspinPlayer

    public init(player: Player, output: LocalPlayerOutput, sendspin: SendspinPlayer) {
        self.player = player
        self.output = output
        self.sendspin = sendspin
    }

    /// `Player()` (file resolver), its output and its Sendspin input. Opens no audio device, reads no settings, no
    /// Keychain, no network.
    public static func standard() -> LocalPlaybackStack {
        let player = Player()
        return LocalPlaybackStack(player: player, output: LocalPlayerOutput(player: player), sendspin: SendspinPlayer(player: player))
    }
}
