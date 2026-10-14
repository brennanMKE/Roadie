import CoreGraphics
import Testing
@testable import WindowDocking

struct DesktopSpaceTests {
    @Test func desktopSpaceFlipsAgainstThePrimaryTop() {
        let space = DesktopSpace(primaryTop: 900)
        let rect = CGRect(x: 100, y: 700, width: 275, height: 116)
        #expect(space.box(rect) == Box(x: 100, y: 84, width: 275, height: 116))
        #expect(space.rect(space.box(rect)) == rect)
        // A screen above the primary has a negative y.
        #expect(space.box(CGRect(x: 0, y: 1000, width: 275, height: 116)).y == -216)
    }
}
