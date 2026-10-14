import CoreGraphics
import Foundation

/// One decoded skin cursor: a single frame for a `.cur`, several for a RIFF `.ani` saved under the `.cur` name.
public struct SkinCursor: @unchecked Sendable {   // CGImage is immutable, like Skin.sheets
    public struct Frame: @unchecked Sendable {
        /// RGBA, premultiplied, native pixels.
        public let image: CGImage
        /// In pixels, top-left origin (NSCursor's convention too).
        public let hotSpot: CGPoint

        public init(image: CGImage, hotSpot: CGPoint) {
            self.image = image
            self.hotSpot = hotSpot
        }

        /// Nearest-neighbour upscale for Retina representations; nil if the context cannot be made.
        public func upscaled(_ factor: Int) -> CGImage? {
            guard factor >= 1, factor <= 8 else { return nil }
            let width = image.width * factor
            let height = image.height * factor
            guard
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }
    }

    public struct Step: Sendable, Equatable {
        /// Index into `frames`.
        public let frame: Int
        /// Seconds (jiffies / 60); 0 for a static cursor.
        public let duration: TimeInterval

        public init(frame: Int, duration: TimeInterval) {
            self.frame = frame
            self.duration = duration
        }
    }

    /// Never empty.
    public let frames: [Frame]
    /// Never empty; `[Step(frame: 0, duration: 0)]` for a `.cur`.
    public let steps: [Step]

    public var isAnimated: Bool { steps.count > 1 }
    public var cycleDuration: TimeInterval { steps.reduce(0) { $0 + $1.duration } }

    init(frames: [Frame], steps: [Step]) {
        self.frames = frames
        self.steps = steps
    }
}

/// Every cursor a skin ships under a name Winamp uses.
public struct SkinCursors: @unchecked Sendable {
    /// Webamp's CURSORS (js/skinParser.js 10-34), in that order. No VOLBAR/WSCLOSE/WSWINBUT/WSMIN: Winamp never uses them.
    public static let names: [String] = [
        "CLOSE", "EQCLOSE", "EQNORMAL", "EQSLID", "EQTITLE", "MAINMENU", "MMENU", "MIN", "NORMAL", "PCLOSE", "PNORMAL",
        "POSBAR", "PSIZE", "PTBAR", "PVSCROLL", "PWINBUT", "PWSNORM", "PWSSIZE", "SONGNAME", "TITLEBAR", "VOLBAL",
        "WINBUT", "WSNORMAL", "WSPOSBAR",
    ]

    /// Uppercase name -> cursor.
    public let byName: [String: SkinCursor]
    /// "titlebar.cur" style names, sorted: present under a Winamp name but undecodable. Cosmetic, so not a skin warning.
    public let unreadable: [String]

    public static let empty = SkinCursors(byName: [:], unreadable: [])

    public var isEmpty: Bool { byName.isEmpty }

    public subscript(name: String) -> SkinCursor? { byName[name.uppercased()] }

    init(byName: [String: SkinCursor], unreadable: [String]) {
        self.byName = byName
        self.unreadable = unreadable
    }

    static func load(from archive: SkinArchive) -> SkinCursors {
        var found: [String: SkinCursor] = [:]
        var bad: [String] = []
        for name in names {
            guard let data = archive.file(name.lowercased(), extensions: ["cur"]) else { continue }
            if let cursor = CursorParser.parse(data) {
                found[name] = cursor
            } else {
                bad.append(name.lowercased() + ".cur")
            }
        }
        return SkinCursors(byName: found, unreadable: bad.sorted())
    }
}
