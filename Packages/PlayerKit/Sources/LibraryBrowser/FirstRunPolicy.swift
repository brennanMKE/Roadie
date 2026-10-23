import Foundation

/// What the app knows at launch about earlier use (#0169). Read BEFORE the default skins folder is applied.
public struct FirstRunState: Hashable, Sendable {
    /// `FirstRunPolicy.defaultsKey`; 0 when never set.
    public var completedVersion: Int
    /// `skinsFolderPath` set.
    public var hasSkinsFolder: Bool
    /// `lastSkinPath` set.
    public var hasLastSkin: Bool
    /// A music folder is stored.
    public var hasMusicFolder: Bool
    /// At least one verified Music Assistant server.
    public var hasVerifiedServer: Bool

    public init(
        completedVersion: Int = 0, hasSkinsFolder: Bool = false, hasLastSkin: Bool = false, hasMusicFolder: Bool = false,
        hasVerifiedServer: Bool = false
    ) {
        self.completedVersion = completedVersion
        self.hasSkinsFolder = hasSkinsFolder
        self.hasLastSkin = hasLastSkin
        self.hasMusicFolder = hasMusicFolder
        self.hasVerifiedServer = hasVerifiedServer
    }
}

public enum FirstRunDecision: Hashable, Sendable {
    /// Already done: nothing to do.
    case skip
    /// An existing user (settings from 0.0.1): record the version, show nothing.
    case markCompleted
    /// A fresh install: show the Welcome window.
    case welcome
}

/// Whether to show the Welcome window at launch. Pure: the app reads the defaults and acts on the decision.
/// "Configured" means a key is present, not that its path is reachable.
public enum FirstRunPolicy {
    public static let defaultsKey = "firstRunVersion"
    public static let currentVersion = 1

    public static func decide(_ state: FirstRunState) -> FirstRunDecision {
        if state.completedVersion >= currentVersion { return .skip }
        if state.hasSkinsFolder || state.hasLastSkin || state.hasMusicFolder || state.hasVerifiedServer { return .markCompleted }
        return .welcome
    }
}
