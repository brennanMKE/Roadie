import SkinKit
import XCTest

@testable import Roadie

/// `SkinCursorController.stepFrame` (#0219), the animated cursor's step, driven with explicit steps. The timer and
/// `NSCursor.set()` around it need an animated `SkinCursor`, whose init is internal to SkinKit.
final class SkinCursorControllerTests: XCTestCase {
    func testCursorStepWrapsAndClampsFrames() {
        let steps = [
            SkinCursor.Step(frame: 0, duration: 0.1), SkinCursor.Step(frame: 1, duration: 0.25),
            SkinCursor.Step(frame: 5, duration: 0),
        ]
        let first = SkinCursorController.stepFrame(at: 0, steps: steps, frameCount: 2)
        XCTAssertEqual(first.index, 0)
        XCTAssertEqual(first.frame, 0)
        XCTAssertEqual(first.interval, 0.1, accuracy: 1e-9)
        let second = SkinCursorController.stepFrame(at: 1, steps: steps, frameCount: 2)
        XCTAssertEqual(second.frame, 1)
        XCTAssertEqual(second.interval, 0.25, accuracy: 1e-9)
        let clamped = SkinCursorController.stepFrame(at: 2, steps: steps, frameCount: 2)
        XCTAssertEqual(clamped.frame, 1, "a step past the last frame shows the last one")
        XCTAssertEqual(clamped.interval, 1.0 / 60, accuracy: 1e-9, "a zero duration waits one 60 Hz frame")
        let wrapped = SkinCursorController.stepFrame(at: 4, steps: steps, frameCount: 2)
        XCTAssertEqual(wrapped.index, 1)
        XCTAssertEqual(wrapped.frame, 1)
    }
}
