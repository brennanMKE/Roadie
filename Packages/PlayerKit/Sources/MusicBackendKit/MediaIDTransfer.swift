import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// Library items dragged inside Roadie (#0136). Declared in the app's Info.plist.
    public static let roadieMediaID = UTType(exportedAs: "co.sstools.roadie.media-id")
}

/// Tracks and albums dragged from a Library list onto a playlist (#0136); shared with the playlist editor window.
public struct MediaIDTransfer: Codable, Hashable, Sendable, Transferable {
    public var ids: [MediaID]

    public init(_ ids: [MediaID]) { self.ids = ids }

    /// The JSON a `CodableRepresentation` writes, as the playlist editor's AppKit drop reads it (#0184, #0188).
    /// nil when it doesn't decode.
    public static func decode(_ data: Data) -> MediaIDTransfer? {
        try? JSONDecoder().decode(MediaIDTransfer.self, from: data)
    }

    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .roadieMediaID)
    }
}
