import Foundation
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
}
