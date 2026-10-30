import AppKit
import Foundation
import UniformTypeIdentifiers
import Testing
@testable import MusicBackendKit

struct MediaIDTransferTests {
    /// The playlist editor's AppKit drop decodes the pasteboard data as JSON (#0184); this pins that shape.
    @Test func mediaIDTransferRoundTripsThroughJSON() throws {
        let transfer = MediaIDTransfer([MediaID(.track, "t/1.flac"), MediaID(.album, "library://album/27")])
        let data = try JSONEncoder().encode(transfer)
        let decoded = try JSONDecoder().decode(MediaIDTransfer.self, from: data)
        #expect(decoded.ids == transfer.ids)
    }

    /// The editor reads each pasteboard item, not just the pasteboard's first (#0188).
    @Test func mediaIDTransferDecodesFromAPasteboardItem() throws {
        let transfer = MediaIDTransfer([MediaID(.artist, "The Beatles"), MediaID(.album, "library://album/27")])
        let type = NSPasteboard.PasteboardType(UTType.roadieMediaID.identifier)
        let item = NSPasteboardItem()
        #expect(item.setData(try JSONEncoder().encode(transfer), forType: type))
        let data = try #require(item.data(forType: type))
        #expect(MediaIDTransfer.decode(data)?.ids == transfer.ids)
        #expect(MediaIDTransfer.decode(Data("nope".utf8)) == nil)
    }

    /// The drag representation is the exported type (#0214).
    @Test func mediaIDTransferExportsItsType() {
        _ = MediaIDTransfer.transferRepresentation
        #expect(UTType.roadieMediaID.identifier == "co.sstools.roadie.media-id")
        #expect(MediaIDTransfer([]).ids.isEmpty)
    }
}
