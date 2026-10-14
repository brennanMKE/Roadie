import Foundation

extension SkinSprites {
    /// Webamp's FALLBACKS table (js/components/Skin.tsx). Requested sprite name -> substitute.
    public static let fallbacks: [String: String] = [
        "MAIN_BALANCE_BACKGROUND": "MAIN_VOLUME_BACKGROUND",
        "MAIN_BALANCE_THUMB": "MAIN_VOLUME_THUMB",
        "MAIN_BALANCE_THUMB_ACTIVE": "MAIN_VOLUME_THUMB_SELECTED",
        "EQ_MAXIMIZE_BUTTON_ACTIVE": "EQ_MAXIMIZE_BUTTON_ACTIVE_FALLBACK",
        // Not Webamp's: it has no fallback for the shade strip, so a skin without eq_ex.bmp shows a transparent one.
        // Both are 275x14, so the title bar stands in.
        "EQ_SHADE_BACKGROUND": "EQ_TITLE_BAR",
        "EQ_SHADE_BACKGROUND_SELECTED": "EQ_TITLE_BAR_SELECTED",
    ]

    /// Sheets whose absence is covered by a fallback or unused in v1; missing ones are noted, not warned.
    static let optionalSheets: Set<String> = ["BALANCE", "NUMBERS", "NUMS_EX", "EQ_EX", "GEN"]

    /// Sprite name -> (plain, ex) pair for every NUMBERS / NUMS_EX sprite.
    private static let numberPairs: [String: (plain: String, ex: String)] = {
        var result: [String: (plain: String, ex: String)] = [:]
        for sprite in sheets["NUMBERS"] ?? [] {
            let pair = (plain: sprite.name, ex: sprite.name + "_EX")
            result[pair.plain] = pair
            result[pair.ex] = pair
        }
        return result
    }()

    /// For a NUMBERS or NUMS_EX sprite, the (plain, ex) pair of names; nil for every other sprite.
    /// "DIGIT_3" and "DIGIT_3_EX" both give ("DIGIT_3", "DIGIT_3_EX").
    static func numberPair(for name: String) -> (plain: String, ex: String)? {
        numberPairs[name]
    }
}
