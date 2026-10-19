import CoreGraphics
import Foundation

public enum SkinParser {
    /// Parses a `.wsz` file. Never traps on malformed input; throws `SkinError` or
    /// returns a partial skin with warnings.
    public static func parse(url: URL, limits: SkinArchive.Limits = .default) throws(SkinError) -> Skin {
        try parse(archive: SkinArchive(url: url, limits: limits))
    }

    public static func parse(archive: SkinArchive) throws(SkinError) -> Skin {
        if archive.files["skin.xml"] != nil {
            throw .modernSkin
        }

        var sheets: [String: CGImage] = [:]
        var warnings: [String] = []
        var fallbacks: [String] = []
        var missing: Set<String> = []
        var undecodable: Set<String> = []
        for sheet in SkinSprites.sheets.keys.sorted() {
            guard let data = archive.file(sheet, extensions: ["bmp", "png"]) else {
                missing.insert(sheet)
                continue
            }
            guard let image = BitmapLoader.image(from: data) else {
                warnings.append("Undecodable \(sheet.lowercased()).bmp")
                undecodable.insert(sheet)
                continue
            }
            sheets[sheet] = image
        }
        guard !sheets.isEmpty else { throw .noBitmaps }

        // Base-skin fallback: fill absent or undecodable sheets from the generated base. Warnings below still
        // read `missing`, so a skin without cbuttons.bmp stays partial.
        var generated: Set<String> = []
        for sheet in GeneratedBaseSkin.sheetNames.sorted() where sheets[sheet] == nil {
            if sheet == "NUMBERS", sheets["NUMS_EX"] != nil { continue }
            guard let image = GeneratedBaseSkin.sheet(sheet) else { continue }
            sheets[sheet] = image
            generated.insert(sheet)
            fallbacks.append("\(sheet.lowercased()).bmp \(undecodable.contains(sheet) ? "undecodable" : "missing"); generated base")
        }

        // Sheets that are required warn; optional ones are covered by a Webamp fallback (see Skin.resolve).
        for sheet in missing.sorted() where !SkinSprites.optionalSheets.contains(sheet) {
            warnings.append("Missing \(sheet.lowercased()).bmp")
        }
        if missing.contains("BALANCE"), sheets["VOLUME"] != nil {
            fallbacks.append("balance.bmp missing; balance slider uses volume.bmp")
        }
        if missing.contains("NUMBERS"), missing.contains("NUMS_EX") {
            warnings.append("Missing numbers.bmp and nums_ex.bmp")
        } else if missing.contains("NUMS_EX") {
            fallbacks.append("nums_ex.bmp missing; digits use numbers.bmp")
        } else if missing.contains("NUMBERS") {
            fallbacks.append("numbers.bmp missing; digits use nums_ex.bmp")
        }
        if missing.contains("EQ_EX") {
            fallbacks.append("eq_ex.bmp missing; EQ maximize button uses eqmain.bmp")
        }
        if missing.contains("GEN") {
            fallbacks.append("gen.bmp missing (not used in v1)")
        }

        var visColors = VisColorParser.defaults
        if let data = archive.file("viscolor", extensions: ["txt"]) {
            let parsed = VisColorParser.parseCounted(data)
            visColors = parsed.colors
            if parsed.parsedCount < 24 {
                fallbacks.append("viscolor.txt has \(parsed.parsedCount) of 24 colours; defaults for \(parsed.parsedCount == 23 ? "23" : "\(parsed.parsedCount)\u{2013}23")")
            }
        } else {
            fallbacks.append("viscolor.txt missing; Webamp defaults")
        }

        // A region file with no usable section is normal (all-comment files ship in real skins): no warning.
        let region = archive.file("region", extensions: ["txt"]).map(RegionParser.parse) ?? .empty

        var playlistStyle = PlaylistStyle.defaults
        if let data = archive.file("pledit", extensions: ["txt"]) {
            let parsed = PlaylistStyleParser.parse(data)
            playlistStyle = parsed.style
            fallbacks.append(contentsOf: parsed.fallbacks)
        } else {
            fallbacks.append("pledit.txt missing; Webamp default playlist colours")
        }

        // Unreadable cursors are cosmetic: recorded in `cursors.unreadable`, never a warning.
        let cursors = SkinCursors.load(from: archive)

        return Skin(
            sheets: sheets, visColors: visColors, region: region, playlistStyle: playlistStyle, warnings: warnings,
            fallbacks: fallbacks, cursors: cursors, generatedSheets: generated)
    }
}

