import CoreGraphics
import Foundation

public enum SkinParser {
    /// Parses a `.wsz` file. Never traps on malformed input; throws `SkinError` or
    /// returns a partial skin with warnings.
    public static func parse(url: URL) throws(SkinError) -> Skin {
        try parse(archive: SkinArchive(url: url))
    }

    public static func parse(archive: SkinArchive) throws(SkinError) -> Skin {
        if archive.files["skin.xml"] != nil {
            throw .modernSkin
        }

        var sheets: [String: CGImage] = [:]
        var warnings: [String] = []
        for sheet in SkinSprites.sheets.keys.sorted() {
            guard let data = archive.file(sheet, extensions: ["bmp", "png"]) else {
                warnings.append("Missing \(sheet.lowercased()).bmp")
                continue
            }
            guard let image = BitmapLoader.image(from: data) else {
                warnings.append("Undecodable \(sheet.lowercased()).bmp")
                continue
            }
            sheets[sheet] = image
        }
        guard !sheets.isEmpty else { throw .noBitmaps }

        var visColors: [RGBColor] = []
        if let data = archive.file("viscolor", extensions: ["txt"]) {
            visColors = VisColorParser.parse(data)
        }
        if visColors.count != 24 {
            warnings.append("viscolor.txt missing or incomplete (\(visColors.count)/24)")
        }

        // TODO: pledit.txt, region.txt, TEXT font sprites, cursors, base-skin fallback.
        return Skin(sheets: sheets, visColors: visColors, warnings: warnings)
    }
}

