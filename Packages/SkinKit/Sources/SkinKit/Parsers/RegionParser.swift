import Foundation

/// Port of Webamp's `regionParser` (js/regionParser.ts). Webamp is MIT licensed; see NOTICE.
public enum RegionParser {
    /// `region.txt` is read as UTF-8, lossily: comments in real skins are Windows-1252, but digits,
    /// brackets and `=` are ASCII.
    public static func parse(_ data: Data) -> SkinRegion {
        parse(text: String(decoding: data, as: UTF8.self))
    }

    static func parse(text: String) -> SkinRegion {
        var sections: [String: [SkinRegion.Polygon]] = [:]
        for (name, properties) in IniParser.parse(text) {
            guard let numPoints = properties["numpoints"], !numPoints.isEmpty,
                  let pointList = properties["pointlist"], !pointList.isEmpty
            else { continue }
            let counts = numPoints.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            // Points can be separated by spaces or by commas.
            let values = pointList.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" }).map(String.init)
            let points = pairs(values)
            var cursor = 0
            var polygons: [SkinRegion.Polygon] = []
            for count in counts {
                guard let num = Int(count) else { continue }  // Webamp: NaN, an empty slice, no advance
                if num < 3 {
                    cursor += max(num, 0)  // What use is a polygon with less than three sides?
                    continue
                }
                let start = min(cursor, points.count)
                let slice = points[start..<min(cursor + num, points.count)]
                if slice.isEmpty { continue }  // more polygons than points
                polygons.append(Array(slice))
                cursor += num
            }
            if !polygons.isEmpty { sections[name] = polygons }
        }
        return SkinRegion(sections: sections)
    }

    /// Pairs consecutive values. A dangling odd value is dropped (Webamp emits `x,undefined`, which the
    /// browser ignores); so is a pair that is not a number. Fractions are truncated.
    private static func pairs(_ values: [String]) -> [SkinRegion.Point] {
        var points: [SkinRegion.Point] = []
        var index = 0
        while index + 1 < values.count {
            if let x = integer(values[index]), let y = integer(values[index + 1]) {
                points.append(SkinRegion.Point(x: x, y: y))
            }
            index += 2
        }
        return points
    }

    private static func integer(_ text: String) -> Int? {
        if let value = Int(text) { return value }
        if let value = Double(text), value.isFinite, abs(value) < 1e9 { return Int(value) }
        return nil
    }
}
