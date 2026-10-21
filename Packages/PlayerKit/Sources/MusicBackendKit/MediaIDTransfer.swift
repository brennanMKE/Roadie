import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// Library items dragged inside SkinAmp (#0136). Declared in the app's Info.plist.
    public static let skinAmpMediaID = UTType(exportedAs: "com.brennanmke.skinamp.media-id")
}

/// Tracks and albums dragged from a Library list onto a playlist (#0136); shared with the playlist editor window.
public struct MediaIDTransfer: Codable, Hashable, Sendable, Transferable {
    public var ids: [MediaID]

    public init(_ ids: [MediaID]) { self.ids = ids }

    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .skinAmpMediaID)
    }
}
