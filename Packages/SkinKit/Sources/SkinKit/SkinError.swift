import Foundation

public enum SkinError: Error, Sendable, CustomStringConvertible {
    case unreadableArchive(String)
    case modernSkin
    case noBitmaps

    public var description: String {
        switch self {
        case .unreadableArchive(let reason): "Unreadable archive: \(reason)"
        case .modernSkin: "Modern (Winamp 3/5) skin; not supported"
        case .noBitmaps: "No classic skin bitmaps found"
        }
    }
}
