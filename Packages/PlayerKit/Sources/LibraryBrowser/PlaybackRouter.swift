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

/// Whether local audio may start on the selected output (#0084). Local files play only on This Mac; while a
/// speaker is selected, opening, adding or dropping them is refused with a notice and the output is left alone.
public enum LocalPlaybackGate {
    public static let switchToThisMac = "Switch the output to This Mac to play local files."

    /// nil when local files may play on `output`, else the notice text.
    public static func refusal(forLocalFilesOn output: OutputDevice.ID) -> String? {
        output == OutputDevice.thisMacID ? nil : switchToThisMac
    }

    /// `playFromLibrary`'s rule: a source without `.remoteOutputs` can only play on This Mac.
    public static func refusal(source: BackendCapabilities, output: OutputDevice.ID) -> String? {
        output == OutputDevice.thisMacID || source.contains(.remoteOutputs) ? nil : switchToThisMac
    }
}
