import Foundation
import MusicBackendKit

/// Which backend owns an output. Commands and now-playing follow the selected output, not the Library's source:
/// This Mac is the local backend (AudioCore through `LocalPlayerOutput`, no connection needed) and every other id
/// is a remote player (Music Assistant).
@MainActor
public final class PlaybackRouter {
    public let local: any MusicBackend
    public let remote: any MusicBackend

    public init(local: any MusicBackend, remote: any MusicBackend) {
        self.local = local
        self.remote = remote
    }

    public func backend(for output: OutputDevice.ID) -> any MusicBackend {
        output == OutputDevice.thisMacID ? local : remote
    }
}
