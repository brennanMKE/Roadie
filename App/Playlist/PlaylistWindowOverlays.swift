import AppKit
import AudioCore
import MusicBackendKit
import os
import SkinKit
import UniformTypeIdentifiers

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
        resize.widthOnly = shaded
        func frame(_ rect: CGRect) -> NSRect {
            NSRect(x: rect.minX * scale, y: height - rect.maxY * scale, width: rect.width * scale, height: rect.height * scale)
        }
        list.frame = frame(layout.trackArea)
        resize.frame = frame(shaded ? PlaylistShadeLayout.resizeFrame(width: layout.size.width) : layout.resizeTarget)
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
    /// Whether ⌥ is held: a drop then replaces the list (#0228). `NSDraggingInfo` carries no modifier flags.
    var isOptionDown: () -> Bool = { NSEvent.modifierFlags.contains(.option) }

    init(model: PlayerModel) {
        self.model = model
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL, LibraryDropDecoder.mediaIDType])
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// Not an accessibility element, so the SwiftUI rows under it are the ones XCUITest finds; a click on a row's centre
    /// still lands here (#0199).
    override func isAccessibilityElement() -> Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var scale: CGFloat { MainActor.assumeIsolated { model.scale } }

    private func skinPoint(_ event: NSEvent) -> CGPoint {
        skinPoint(windowPoint: event.locationInWindow)
    }

    private func skinPoint(windowPoint: NSPoint) -> CGPoint {
        let point = convert(windowPoint, from: nil)
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

    /// The row menu (#0179). Control-click stays a command-click in `mouseDown`.
    override func rightMouseDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            window?.makeFirstResponder(self)
            let playlist = model.playlist
            playlist.openMenu = nil
            guard let index = row(atY: skinPoint(event).y) else { return }
            if !playlist.isSelected(index) { playlist.click(index) }   // Finder-style: right-click selects the row
            NSMenu.popUpContextMenu(PlaylistContextMenus.rowMenu(model), with: event, for: self)
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
            // A bare Q toggles the play-next queue (#0179); the menu bar's Quit takes command-Q first.
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !event.isARepeat, modifiers.isDisjoint(with: [.command, .control, .option, .shift]),
               event.charactersIgnoringModifiers?.lowercased() == "q" {
                model.playlist.toggleQueueForSelection()
                return
            }
            switch event.keyCode {
            case 51, 117: model.playlist.removeSelected()        // delete, forward delete
            case 36, 76: model.playlist.playFirstSelected()      // return, enter
            default: super.keyDown(with: event)
            }
        }
    }

    // MARK: File drops (#0183) and Library drops (#0184)

    private static let dropLog = Logger(subsystem: "co.sstools.roadie", category: "LibraryDrop")

    private func dragOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        let plan = LibraryDropDecoder.plan(
            pasteboard: sender.draggingPasteboard, mask: sender.draggingSourceOperationMask, replacing: isOptionDown())
        MainActor.assumeIsolated {
            if model.playlist.dropCue != plan?.cue { model.playlist.dropCue = plan?.cue }
        }
        return plan?.operation ?? []
    }

    private func clearDropCue() {
        MainActor.assumeIsolated { model.playlist.dropCue = nil }
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { clearDropCue() }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { clearDropCue() }
    override func draggingEnded(_ sender: NSDraggingInfo) { clearDropCue() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pasteboard = sender.draggingPasteboard
        let types = (pasteboard.types?.map(\.rawValue) ?? []).joined(separator: ",")
        let mask = sender.draggingSourceOperationMask.rawValue
        let items = pasteboard.pasteboardItems?.count ?? 0
        Self.dropLog.debug("drag entered: types=\(types, privacy: .public) mask=\(mask) items=\(items)")
        return dragOperation(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragOperation(sender) }

    /// Files and folders go in before the row under the pointer, or at the end below the last row (Winamp). A remote
    /// queue's row means nothing in the local queue, so there the drop appends as before.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        clearDropCue()
        let pasteboard = sender.draggingPasteboard
        let replacing = isOptionDown()
        if LibraryDropDecoder.hasMediaID(pasteboard) {
            guard let ids = LibraryDropDecoder.mediaIDs(from: pasteboard), !ids.isEmpty else {
                Self.dropLog.error("drop: media-id type present but no data decoded")
                MainActor.assumeIsolated { model.post(StatusNotice(text: "Couldn't read the dragged items")) }
                return false
            }
            return MainActor.assumeIsolated {
                // Library items go through the selected output's backend and its gates (a folder library on a speaker
                // is refused with a notice). Music Assistant can't place items, so there they append (#0173 decision 4).
                let row = row(atY: skinPoint(windowPoint: sender.draggingLocation).y) ?? model.playlist.count
                Self.dropLog.info("drop: \(ids.count) id(s) at row \(row), \(replacing ? "replace" : "insert", privacy: .public)")
                model.dropLibraryItems(ids, at: row, replacing: replacing)
                return true
            }
        }
        let urls = LibraryDropDecoder.fileURLs(from: pasteboard)
        guard !urls.isEmpty else { return false }
        return MainActor.assumeIsolated {
            let playlist = model.playlist
            let row: Int? = playlist.remote != nil || replacing
                ? nil
                : (row(atY: skinPoint(windowPoint: sender.draggingLocation).y) ?? playlist.count)
            Self.dropLog.info("drop: \(urls.count) file(s), \(replacing ? "replace" : "insert", privacy: .public)")
            return model.open(urls, replace: replacing, at: row)
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
    /// In shade mode only the width changes (Webamp's `PlaylistResizeTarget widthOnly`).
    var widthOnly = false

    init(model: PlayerModel) {
        self.model = model
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.handle)
        setAccessibilityLabel("Resize")
        setAccessibilityIdentifier(AXID.PL.resize)
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
            let delta = CGSize(width: (mouse.x - startMouse.x) / scale, height: widthOnly ? 0 : (startMouse.y - mouse.y) / scale)
            model.playlist.setSteps(PlaylistLayout.steps(from: startSteps, draggedBy: delta))
        }
    }
}
