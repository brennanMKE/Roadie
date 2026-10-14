import AppKit
import SkinKit

/// The playlist window's two AppKit input views, laid over the SwiftUI content by `SkinWindowController`. They are
/// siblings of the hosting view, not SwiftUI children, because `scaleEffect` does not scale an `NSView` and SwiftUI
/// gestures carry neither click counts nor modifier keys.
@MainActor
final class PlaylistWindowOverlays {
    let list: PlaylistListInputView
    let resize: PlaylistResizeView

    init(model: PlayerModel) {
        list = PlaylistListInputView(model: model)
        resize = PlaylistResizeView(model: model)
    }

    func install(in container: NSView) {
        container.addSubview(list)
        container.addSubview(resize)
    }

    /// Positions the views over the track list and the resize corner. `container` is not flipped, so y is measured up.
    func layout(_ layout: PlaylistLayout, scale: CGFloat, height: CGFloat, shaded: Bool) {
        list.isHidden = shaded
        resize.isHidden = shaded
        func frame(_ rect: CGRect) -> NSRect {
            NSRect(x: rect.minX * scale, y: height - rect.maxY * scale, width: rect.width * scale, height: rect.height * scale)
        }
        list.frame = frame(layout.trackArea)
        resize.frame = frame(layout.resizeTarget)
    }
}

/// Mouse and keyboard input for the track list: click, command-click, shift-click, double-click to play, dragging the
/// selection up and down, the scroll wheel, Delete / Return / Select All. Coordinates are divided by the window scale
/// so every number below is in skin pixels, as Webamp's are.
final class PlaylistListInputView: NSView {
    private unowned let model: PlayerModel
    /// Pointer y (skin pixels, from this view's top) where the drag began, and the rows moved so far.
    private var dragStartY: CGFloat?
    private var lastDiff = 0

    init(model: PlayerModel) {
        self.model = model
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var scale: CGFloat { MainActor.assumeIsolated { model.scale } }

    private func skinPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x / scale, y: point.y / scale)
    }

    /// The row under skin-y `y`, nil below the last row.
    @MainActor private func row(atY y: CGFloat) -> Int? {
        guard y >= 0 else { return nil }
        let range = model.playlist.visibleRange
        let index = range.lowerBound + Int((y / PlaylistLayout.rowHeight).rounded(.down))
        return range.contains(index) ? index : nil
    }

    /// An open menu's entries stack upward over the bottom of the track list (the add menu reaches 66 px above the
    /// window's bottom, the list ends 41 px above it); presses there go to the SwiftUI menu underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard hit === self else { return hit }
        return MainActor.assumeIsolated {
            let playlist = model.playlist
            guard let menu = playlist.openMenu else { return self }
            let layout = playlist.layout
            let local = convert(point, from: superview)
            let skin = CGPoint(x: layout.trackArea.minX + local.x / scale, y: layout.trackArea.minY + local.y / scale)
            let rects = layout.menuEntries(menu).map(\.rect) + [layout.menuBar(menu).rect]
            return rects.contains { $0.contains(skin) } ? nil : self
        }
    }

    override func mouseDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            window?.makeFirstResponder(self)
            let playlist = model.playlist
            playlist.openMenu = nil
            dragStartY = nil
            lastDiff = 0
            let point = skinPoint(event)
            // A press below the last row clears the selection (the list container's onClick={selectZero}).
            guard let index = row(atY: point.y) else {
                playlist.selectNone()
                return
            }
            if event.clickCount >= 2 {
                playlist.playRow(index)
                return
            }
            let flags = event.modifierFlags
            if flags.contains(.shift) {
                playlist.shiftClick(index)
            } else if flags.contains(.command) || flags.contains(.control) {
                playlist.commandClick(index)
            } else {
                // A press on a selected row keeps the selection so the whole block can be dragged.
                if !playlist.isSelected(index) { playlist.click(index) }
                dragStartY = point.y
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard let dragStartY else { return }
            let point = skinPoint(event)
            // Outside the list the drag is ignored (TrackList.tsx).
            guard point.x >= 0, point.y >= 0, point.x <= bounds.width / scale, point.y <= bounds.height / scale else { return }
            let diff = Int(((point.y - dragStartY) / PlaylistLayout.rowHeight).rounded(.down))
            if diff != lastDiff {
                model.playlist.dragSelected(by: diff - lastDiff)
                lastDiff = diff
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragStartY = nil
    }

    override func scrollWheel(with event: NSEvent) {
        MainActor.assumeIsolated {
            // Webamp's deltaY is positive toward later rows; AppKit's is positive when content moves down.
            let delta = event.hasPreciseScrollingDeltas
                ? -event.scrollingDeltaY / scale
                : -event.scrollingDeltaY * PlaylistLayout.rowHeight
            model.playlist.wheel(delta: delta)
        }
    }

    override func keyDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            switch event.keyCode {
            case 51, 117: model.playlist.removeSelected()        // delete, forward delete
            case 36, 76: model.playlist.playFirstSelected()      // return, enter
            default: super.keyDown(with: event)
            }
        }
    }

    /// Edit > Select All (the menu bar's command-A) reaches the first responder.
    override func selectAll(_ sender: Any?) {
        MainActor.assumeIsolated { model.playlist.selectAll() }
    }
}

/// The 20x20 resize corner. A drag changes the window in Winamp's 25x29 steps; the screen delta (flipped so down is
/// positive) is divided by the scale to get skin pixels.
final class PlaylistResizeView: NSView {
    private unowned let model: PlayerModel
    private var startMouse = NSPoint.zero
    private var startSteps = PlaylistLayout.Steps.zero

    init(model: PlayerModel) {
        self.model = model
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            model.playlist.openMenu = nil
            startMouse = NSEvent.mouseLocation
            startSteps = model.playlist.steps
        }
    }

    override func mouseDragged(with event: NSEvent) {
        MainActor.assumeIsolated {
            let mouse = NSEvent.mouseLocation
            let scale = model.scale
            let delta = CGSize(width: (mouse.x - startMouse.x) / scale, height: (startMouse.y - mouse.y) / scale)
            model.playlist.setSteps(PlaylistLayout.steps(from: startSteps, draggedBy: delta))
        }
    }
}
