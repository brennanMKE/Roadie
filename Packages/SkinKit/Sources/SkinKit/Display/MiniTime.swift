import CoreGraphics

/// Webamp's MiniTime.tsx: five text.bmp characters. Stopped shows five spaces (getTimeObj(null), utils.ts 28-37);
/// paused blinks (mini-time.css 7-10, same cadence as the big time); remaining mode leads with "-".
public enum MiniTime {
    public static let blank = [" ", " ", " ", " ", " "]

    /// ["-" or " ", mTens, mOnes, sTens, sOnes] from `status.digits` / `status.showsMinus`; " " for nil digits.
    public static func characters(_ status: MainWindowStatus) -> [String] {
        let digits = status.digits
        func cell(_ value: Int?) -> String { value.map(String.init) ?? " " }
        return [
            status.showsMinus ? "-" : " ",
            cell(digits.minutesTens), cell(digits.minutesOnes), cell(digits.secondsTens), cell(digits.secondsOnes),
        ]
    }
}

extension Skin {
    /// A 30x6 image: each character's 5x6 text.bmp glyph at `MainShadeLayout.miniTimeCellX`; nil without a TEXT sheet.
    /// The space glyph is the skin's own text background, which is why blinking draws `MiniTime.blank` rather than
    /// nothing (Webamp's "background-character" trick, MiniTime.tsx 11-26).
    public func miniTimeImage(_ characters: [String]) -> CGImage? {
        guard let sheet = sheets[TextFont.sheet] else { return nil }
        guard let context = CGContext(
            data: nil, width: MainShadeLayout.miniTimeImageWidth, height: TextFont.cellHeight,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .none
        for (index, character) in characters.prefix(MainShadeLayout.miniTimeCellX.count).enumerated() {
            guard let name = TextFont.cells(for: character).first ?? nil,
                  let entry = SkinSprites.byName[name],
                  let glyph = sheet.cropping(to: entry.sprite.rect)
            else { continue }
            context.draw(
                glyph,
                in: CGRect(
                    x: MainShadeLayout.miniTimeCellX[index], y: 0, width: TextFont.cellWidth, height: TextFont.cellHeight))
        }
        return context.makeImage()
    }
}
