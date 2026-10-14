import CoreGraphics
import Foundation

/// The playlist window's geometry from Webamp's css/playlist-window.css, PlaylistWindow/*.tsx, ResizeTarget.tsx and
/// VerticalSlider.tsx, in skin pixels with a top-left origin. The window is `275 + 25w` by `116 + 29h` for resize
/// steps `(w, h)`. Pure and headless so the numbers can be tested; the SwiftUI layer only draws what this says.
public struct PlaylistLayout: Sendable, Equatable {
    /// Resize steps beyond the 275x116 base; never negative (ResizeTarget clamps at 0).
    public struct Steps: Sendable, Hashable {
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = max(width, 0)
            self.height = max(height, 0)
        }

        public static let zero = Steps(width: 0, height: 0)
    }

    public static let baseSize = CGSize(width: 275, height: 116)
    public static let stepSize = CGSize(width: 25, height: 29)
    public static let rowHeight: CGFloat = 13
    public static let topHeight: CGFloat = 20
    public static let bottomHeight: CGFloat = 38
    public static let leftWidth: CGFloat = 12
    public static let rightWidth: CGFloat = 20
    public static let titleBarHeight: CGFloat = 20
    /// The shade-mode height (#0031).
    public static let shadeHeight: CGFloat = 14

    public let steps: Steps

    public init(steps: Steps) {
        self.steps = steps
    }

    private var width: CGFloat { Self.baseSize.width + Self.stepSize.width * CGFloat(steps.width) }
    private var height: CGFloat { Self.baseSize.height + Self.stepSize.height * CGFloat(steps.height) }

    /// 275 + 25w by 116 + 29h (selectors.ts getWPixelSize).
    public var size: CGSize { CGSize(width: width, height: height) }

    /// One sprite drawn into `rect`; a tiled one repeats from the rect's top-left corner and is clipped to it.
    public struct Piece: Sendable, Equatable {
        public let sprite: String
        public let rect: CGRect
        public let tiled: Bool
    }

    /// Left to right: corner 25, [spacer 12 when w is even], fill, title 100, [spacer 13 when w is even], fill,
    /// corner 25. The fills are equal and always whole 25-px tiles. `selected` picks the `_SELECTED` sprites.
    public func topRow(selected: Bool) -> [Piece] {
        let suffix = selected ? "_SELECTED" : ""
        let tile = "PLAYLIST_TOP_TILE" + suffix
        let spacers = steps.width % 2 == 0
        let fill = (width - 25 - 100 - 25 - (spacers ? 25 : 0)) / 2
        var pieces: [Piece] = []
        var x: CGFloat = 0
        func add(_ sprite: String, _ w: CGFloat, tiled: Bool) {
            pieces.append(Piece(sprite: sprite, rect: CGRect(x: x, y: 0, width: w, height: Self.topHeight), tiled: tiled))
            x += w
        }
        add(selected ? "PLAYLIST_TOP_LEFT_SELECTED" : "PLAYLIST_TOP_LEFT_CORNER", 25, tiled: false)
        if spacers { add(tile, 12, tiled: true) }
        add(tile, fill, tiled: true)
        add("PLAYLIST_TITLE_BAR" + suffix, 100, tiled: false)
        if spacers { add(tile, 13, tiled: true) }
        add(tile, fill, tiled: true)
        add(selected ? "PLAYLIST_TOP_RIGHT_CORNER_SELECTED" : "PLAYLIST_TOP_RIGHT_CORNER", 25, tiled: false)
        return pieces
    }

    private var middleHeight: CGFloat { height - Self.topHeight - Self.bottomHeight }

    /// PLAYLIST_LEFT_TILE, tiled vertically.
    public var leftTile: Piece {
        Piece(
            sprite: "PLAYLIST_LEFT_TILE",
            rect: CGRect(x: 0, y: Self.topHeight, width: Self.leftWidth, height: middleHeight), tiled: true)
    }

    /// PLAYLIST_RIGHT_TILE, tiled vertically.
    public var rightTile: Piece {
        Piece(
            sprite: "PLAYLIST_RIGHT_TILE",
            rect: CGRect(x: width - Self.rightWidth, y: Self.topHeight, width: Self.rightWidth, height: middleHeight),
            tiled: true)
    }

    /// Back to front: the bottom tile across, the 125 left corner and the 150 right corner over it.
    public var bottomRow: [Piece] {
        let y = height - Self.bottomHeight
        return [
            Piece(sprite: "PLAYLIST_BOTTOM_TILE", rect: CGRect(x: 0, y: y, width: width, height: Self.bottomHeight), tiled: true),
            Piece(sprite: "PLAYLIST_BOTTOM_LEFT_CORNER", rect: CGRect(x: 0, y: y, width: 125, height: Self.bottomHeight), tiled: false),
            Piece(
                sprite: "PLAYLIST_BOTTOM_RIGHT_CORNER", rect: CGRect(x: width - 150, y: y, width: 150, height: Self.bottomHeight),
                tiled: false),
        ]
    }

    /// The 75x38 visualizer background, only when the window is wider than two steps (`showVisualizer`).
    public var visualizerBackground: CGRect? {
        steps.width > 2 ? CGRect(x: width - 225, y: height - Self.bottomHeight, width: 75, height: Self.bottomHeight) : nil
    }

    // MARK: Tracks

    /// The track list: `.playlist-middle-center` (padding 3px 0).
    public var trackArea: CGRect {
        CGRect(x: Self.leftWidth, y: Self.topHeight + 3, width: width - Self.leftWidth - Self.rightWidth, height: middleHeight - 6)
    }

    /// `floor((58 + 29h) / 13)`: 4, 6, 8, 11... Webamp uses the unpadded height, so the last row can be clipped.
    public var visibleRows: Int { Int((middleHeight / Self.rowHeight).rounded(.down)) }

    /// `.playlist-track-durations > div { padding-right: 3px }`.
    public var durationRightInset: CGFloat { 3 }

    // MARK: Scroll bar

    public static let scrollHandleHeight: CGFloat = 18

    /// The slider's track: 8 wide, `58 + 29h` tall, 5 px in from the right tile.
    public var scrollTrack: CGRect {
        CGRect(x: width - Self.rightWidth + 5, y: Self.topHeight, width: 8, height: middleHeight)
    }

    /// `VerticalSlider`: `floor((height - handle) * value)` below the track's top.
    public func scrollHandleY(value: Double) -> CGFloat {
        let clamped = min(max(value, 0), 1)
        return scrollTrack.minY + CGFloat(((scrollTrack.height - Self.scrollHandleHeight) * clamped).rounded(.down))
    }

    /// `moveToPosition`: the pointer minus where the handle is held, over the span the handle can travel, clamped.
    /// `grabOffset` is the pointer's distance below the handle's top (half the handle when the track was pressed).
    public func scrollValue(forPointerY y: CGFloat, grabOffset: CGFloat) -> Double {
        let span = scrollTrack.height - Self.scrollHandleHeight
        guard span > 0 else { return 0 }
        return Double(min(max((y - scrollTrack.minY - grabOffset) / span, 0), 1))
    }

    // MARK: Buttons and displays

    public var closeButton: CGRect { CGRect(x: width - 11, y: 3, width: 9, height: 9) }
    /// The shade button (#0031 hook).
    public var shadeButton: CGRect { CGRect(x: width - 21, y: 3, width: 9, height: 9) }
    public var titleButtonRects: [CGRect] { [shadeButton, closeButton] }
    public var resizeTarget: CGRect { CGRect(x: width - 20, y: height - 20, width: 20, height: 20) }
    public var scrollUpButton: CGRect { CGRect(x: width - 15, y: height - 36, width: 8, height: 5) }
    public var scrollDownButton: CGRect { CGRect(x: width - 15, y: height - 30, width: 8, height: 5) }
    /// 18 text cells (bottom-right: left 7, top 10).
    public var runningTimeOrigin: CGPoint { CGPoint(x: width - 143, y: height - 28) }
    /// Five 5x6 cells at x + 1, 7, 12, 20, 25 (bottom-right: left 66, top 23).
    public var miniTimeOrigin: CGPoint { CGPoint(x: width - 84, y: height - 15) }
    public static let miniTimeCellXs: [CGFloat] = [1, 7, 12, 20, 25]
    /// The mini time: 6 tall, five cells ending at x 30.
    public var miniTimeHitArea: CGRect { CGRect(x: miniTimeOrigin.x, y: miniTimeOrigin.y, width: 31, height: 6) }
    /// Previous, play, pause, stop, next, eject: 10x10, left to right.
    public var actionButtons: [CGRect] {
        (0..<6).map { CGRect(x: width - 147 + 10 * CGFloat($0), y: height - 16, width: 10, height: 10) }
    }

    // MARK: Menus

    public enum Menu: CaseIterable, Sendable { case add, remove, selection, misc, list }

    public struct MenuEntry: Sendable, Equatable {
        /// The unselected sprite; `+ "_SELECTED"` while hovered.
        public let sprite: String
        public let rect: CGRect
    }

    /// 22x18 at `y = height - 30`; x 14, 43, 72, 101, `width - 44`.
    public func menuButton(_ menu: Menu) -> CGRect {
        let x: CGFloat =
            switch menu {
            case .add: 14
            case .remove: 43
            case .selection: 72
            case .misc: 101
            case .list: width - 44
            }
        return CGRect(x: x, y: height - 30, width: 22, height: 18)
    }

    private static func spriteNames(_ menu: Menu) -> [String] {
        switch menu {
        case .add: ["PLAYLIST_ADD_URL", "PLAYLIST_ADD_DIR", "PLAYLIST_ADD_FILE"]
        case .remove: ["PLAYLIST_REMOVE_MISC", "PLAYLIST_REMOVE_ALL", "PLAYLIST_CROP", "PLAYLIST_REMOVE_SELECTED"]
        case .selection: ["PLAYLIST_INVERT_SELECTION", "PLAYLIST_SELECT_ZERO", "PLAYLIST_SELECT_ALL"]
        case .misc: ["PLAYLIST_SORT_LIST", "PLAYLIST_FILE_INFO", "PLAYLIST_MISC_OPTIONS"]
        case .list: ["PLAYLIST_NEW_LIST", "PLAYLIST_SAVE_LIST", "PLAYLIST_LOAD_LIST"]
        }
    }

    /// Entries stacked upward from the button (css `ul { bottom: 0 }`): the last one sits on the button.
    public func menuEntries(_ menu: Menu) -> [MenuEntry] {
        let names = Self.spriteNames(menu)
        let button = menuButton(menu)
        return names.enumerated().map { index, name in
            MenuEntry(
                sprite: name,
                rect: CGRect(x: button.minX, y: button.minY - 18 * CGFloat(names.count - 1 - index), width: 22, height: 18))
        }
    }

    /// 3 px wide at `x - 3`, bottom-aligned with the button, 54 tall (72 for remove).
    public func menuBar(_ menu: Menu) -> Piece {
        let button = menuButton(menu)
        let barHeight: CGFloat = menu == .remove ? 72 : 54
        let sprite =
            switch menu {
            case .add: "PLAYLIST_ADD_MENU_BAR"
            case .remove: "PLAYLIST_REMOVE_MENU_BAR"
            case .selection: "PLAYLIST_SELECT_MENU_BAR"
            case .misc: "PLAYLIST_MISC_MENU_BAR"
            case .list: "PLAYLIST_LIST_BAR"
            }
        return Piece(
            sprite: sprite, rect: CGRect(x: button.minX - 3, y: button.maxY - barHeight, width: 3, height: barHeight), tiled: false)
    }

    // MARK: Resizing

    /// ResizeTarget.tsx: start + round(delta / segment), floored at 0. JS `Math.round` rounds halves up, so
    /// -0.5 gives 0: `floor(x + 0.5)`, not `.rounded()`.
    public static func steps(from start: Steps, draggedBy delta: CGSize) -> Steps {
        func round(_ value: CGFloat) -> Int { Int((value + 0.5).rounded(.down)) }
        return Steps(
            width: start.width + round(delta.width / stepSize.width),
            height: start.height + round(delta.height / stepSize.height))
    }

    /// Inverse of `size`, for restoring a frame; floors and clamps at 0.
    public static func steps(forPixelSize size: CGSize) -> Steps {
        Steps(
            width: Int(((size.width - baseSize.width) / stepSize.width).rounded(.down)),
            height: Int(((size.height - baseSize.height) / stepSize.height).rounded(.down)))
    }
}
