import CoreGraphics
import Testing
@testable import SkinKit

@Suite struct PlaylistShadeLayoutTests {
    @Test func playlistShadeTrimsTitleToWidth() {
        #expect(PlaylistShadeLayout.title(name: nil, width: 275) == "[No file]")
        let long = String(repeating: "a", count: 50)
        #expect(PlaylistShadeLayout.title(name: long, width: 275) == String(repeating: "a", count: 40) + "\u{2026}")
        #expect(PlaylistShadeLayout.title(name: long, width: 325) == long)
        #expect(PlaylistShadeLayout.title(name: String(repeating: "a", count: 41), width: 275).count == 41)
    }

    @Test func playlistShadeTimeString() {
        #expect(PlaylistShadeLayout.timeString(61) == "1:01")
        #expect(PlaylistShadeLayout.timeString(600) == "10:00")
        #expect(PlaylistShadeLayout.timeString(0) == "0:00")
        #expect(PlaylistShadeLayout.timeString(nil) == "")
    }

    @Test func playlistShadeFramesFollowWidth() {
        for (width, shift) in [(CGFloat(275), CGFloat(0)), (325, 50)] {
            #expect(PlaylistShadeLayout.closeFrame(width: width) == CGRect(x: 264 + shift, y: 3, width: 9, height: 9))
            #expect(PlaylistShadeLayout.shadeFrame(width: width) == CGRect(x: 254 + shift, y: 3, width: 9, height: 9))
            #expect(PlaylistShadeLayout.resizeFrame(width: width) == CGRect(x: 246 + shift, y: 3, width: 9, height: 9))
            #expect(PlaylistShadeLayout.timeRightEdge(width: width) == 245 + shift)
        }
    }
}
