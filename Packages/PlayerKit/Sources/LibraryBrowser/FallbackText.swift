import Foundation

/// What the fallback tells the user, built from display names alone.
public enum FallbackText {
    /// The marquee notice for an automatic switch: "Using Local Folder" with detail "Music Assistant can't be reached" or
    /// "Music Assistant isn't set up"; "Back on Music Assistant" (no detail) on a restore. Every text fits the marquee (31 UTF-16 units).
    public static func notice(kind: LibraryFallbackPolicy.ActivationKind, status: FallbackStatus) -> FallbackNotice {
        switch kind {
        case .restore:
            return FallbackNotice(text: "Back on \(status.activeName)", detail: nil)
        case .user, .fallback:
            let detail: String? = switch status.reason {
            case .notConfigured?: "\(status.preferredName) isn't set up"
            case .unreachable?: "\(status.preferredName) can't be reached"
            case nil: nil
            }
            return FallbackNotice(text: "Using \(status.activeName)", detail: detail)
        }
    }

    /// Settings > Library: nil when the active source is the preferred one.
    public static func summary(_ status: FallbackStatus) -> String? {
        guard status.activeID != status.preferredID else { return nil }
        switch status.reason {
        case .notConfigured?: return "Using \(status.activeName): \(status.preferredName) isn't set up."
        case .unreachable?:
            return "Using \(status.activeName): \(status.preferredName) can't be reached. SkinAmp switches back when it is."
        case nil: return "Using \(status.activeName)."
        }
    }

    /// The Library window's subtitle.
    public static func subtitle(_ status: FallbackStatus) -> String {
        status.activeID == status.preferredID
            ? status.activeName : "\(status.activeName) (\(status.preferredName) unavailable)"
    }
}
