import CoreGraphics

public extension Skin {
    /// Sprite name of a time digit. `image(for:)` resolves it to `DIGIT_n_EX` when the skin has a
    /// NUMS_EX sheet, else `DIGIT_n` (#0020's fallback rule).
    func digitSpriteName(_ digit: Int) -> String { "DIGIT_\(digit)" }

    /// The minus sign geometry in main-window coordinates. Which sheet draws it is decided by
    /// `image(for:)`; the cell differs: NUMBERS has a 5x1 bar at (38, 32), NUMS_EX a 9x13 cell at (38, 26).
    /// `minusName`/`noMinusName` are the remaining/elapsed sprites at that spot.
    var minusFrame: CGRect {
        usesNumsEx ? CGRect(x: 38, y: 26, width: 9, height: 13) : CGRect(x: 38, y: 32, width: 5, height: 1)
    }
    var minusName: String { "MINUS_SIGN" }
    var noMinusName: String { "NO_MINUS_SIGN" }
}
