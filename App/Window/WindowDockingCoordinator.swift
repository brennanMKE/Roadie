import AppKit
import SkinKit
import WindowDocking

/// Owns where the skinned windows sit: snaps and docks them while the user drags, keeps docked edges when a window
/// changes size, saves positions, restores them at launch and brings strays back on screen. The geometry is the pure
/// `WindowDocking` engine (ports of Webamp's `snapUtils.ts`, `resizeUtils.ts` and the layout rules of
/// `actionCreators/windows.ts`); this class only converts between AppKit frames and the engine's boxes.
///
/// Whether a window is open or shaded and the playlist's size stay in `PlayerModel` (they already persist there); the
/// coordinator persists positions.
@MainActor
final class WindowDockingCoordinator {
    private let model: PlayerModel
    private let store: WindowLayoutStore
    private var controllers: [WindowKind: SkinWindowController] = [:]
    private var screenObserver: NSObjectProtocol?

    private var session: DragSession?
    /// The dragged window's origin at mouse-down (AppKit space).
    private var dragStartOrigin = NSPoint.zero

    init(model: PlayerModel, store: WindowLayoutStore? = nil) {
        self.model = model
        self.store = store ?? WindowLayoutStore(defaults: model.defaults)
    }

    /// The skinned windows register once; the coordinator then receives their title-bar drags and size changes.
    func register(_ controller: SkinWindowController) {
        controller.coordinator = self
        controllers[controller.kind.windowKind] = controller
    }

    // MARK: Desktop space

    private var desktop: DesktopSpace { DesktopSpace(primaryTop: NSScreen.screens.first?.frame.maxY ?? 0) }
    private var screenBoxes: [Box] { NSScreen.screens.map { desktop.box($0.visibleFrame) } }
    private static let unbounded = Box(x: -100_000, y: -100_000, width: 200_000, height: 200_000)
    private var primaryBox: Box { screenBoxes.first ?? Self.unbounded }

    /// What limits a drag: the area the screens span (so a window can cross from one display to the next; only the
    /// outer edges attract) and the screens each window's title bar must stay on.
    private var dragLimits: DragLimits {
        DragLimits(screens: screenBoxes, primary: primaryBox, titleBarHeights: controllers.mapValues(\.dragStripHeight))
    }

    private func isVisible(_ controller: SkinWindowController) -> Bool {
        controller.window.isVisible && !controller.window.isMiniaturized
    }

    private func dockedWindows() -> [DockedWindow] {
        WindowKind.allCases.compactMap { kind in
            guard let controller = controllers[kind], isVisible(controller) else { return nil }
            return DockedWindow(kind: kind, box: desktop.box(controller.window.frame))
        }
    }

    private func move(_ kind: WindowKind, toTopLeft position: Offset) {
        guard let window = controllers[kind]?.window else { return }
        let box = Box(x: position.x, y: position.y, width: window.frame.width, height: window.frame.height)
        window.keepingChildWindowsInPlace { window.setFrameOrigin(desktop.rect(box).origin) }
    }

    // MARK: Dragging

    func dragBegan(_ controller: SkinWindowController) {
        dragStartOrigin = controller.window.frame.origin
        session = DragSession(dragging: controller.kind.windowKind, windows: dockedWindows())
    }

    func drag(_ controller: SkinWindowController, to proposedOrigin: NSPoint) {
        guard let session else {
            controller.window.setFrameOrigin(proposedOrigin)
            return
        }
        // AppKit's y grows upward, the engine's downward.
        let delta = Offset(x: proposedOrigin.x - dragStartOrigin.x, y: -(proposedOrigin.y - dragStartOrigin.y))
        for (kind, position) in session.positions(forMouseDelta: delta, limits: dragLimits) {
            move(kind, toTopLeft: position)
        }
    }

    func dragEnded(_ controller: SkinWindowController) {
        // The safety net for the persisted layout: no moving window is left with its title bar off every screen.
        if let session {
            let kinds = Set(session.moving.map(\.kind))
            let moving = dockedWindows().filter { kinds.contains($0.kind) }
            let limits = dragLimits
            if let shift = LayoutRules.dragRecovery(
                moving: moving, titleBarHeights: limits.titleBarHeights, screens: limits.screens, primary: limits.primary)
            {
                for window in moving {
                    move(window.kind, toTopLeft: Offset(x: window.box.x + shift.x, y: window.box.y + shift.y))
                }
            }
        }
        session = nil
        layoutDidChange()
    }

    // MARK: Showing

    /// The top-left (AppKit space) for `controller`'s window as it is shown under `reference`: its current spot when it
    /// has one that covers no visible skinned window, else directly under `reference` (`LayoutRules.showPosition`).
    func showPosition(for controller: SkinWindowController, below reference: NSWindow) -> NSPoint {
        let kind = controller.kind.windowKind
        let frame = controller.window.frame
        let current = desktop.box(frame)
        let saved = controller.isPositioned ? Offset(x: current.x, y: current.y) : nil
        let position = LayoutRules.showPosition(
            size: frame.size, saved: saved, below: desktop.box(reference.frame),
            visible: dockedWindows().filter { $0.kind != kind }, titleBarHeight: controller.dragStripHeight,
            screens: screenBoxes, primary: primaryBox)
        let box = Box(x: position.x, y: position.y, width: frame.width, height: frame.height)
        let rect = desktop.rect(box)
        return NSPoint(x: rect.minX, y: rect.maxY)
    }

    /// Moves `controller`'s window to `showPosition(for:below:)`, marks it positioned and saves the layout.
    func place(_ controller: SkinWindowController, below reference: NSWindow) {
        controller.window.setFrameTopLeftPoint(showPosition(for: controller, below: reference))
        controller.isPositioned = true
        layoutDidChange()
    }

    // MARK: Child windows

    /// Attaches `controller`'s window to its parent's (`WindowKind.parentWindow`) when the parent is on screen, and any
    /// visible windows whose parent it is, so Stage Manager keeps the skinned windows in one set (#0120). Idempotent;
    /// `show` calls it before and after ordering the window in.
    func attachChildWindows(around controller: SkinWindowController) {
        for (kind, child) in controllers {
            guard let parentKind = kind.parentWindow, let parent = controllers[parentKind] else { continue }
            let involved = child === controller ? isVisible(parent) : parent === controller && isVisible(child)
            guard involved, isVisible(parent), child.window.parent !== parent.window else { continue }
            parent.window.addChildWindow(child.window, ordered: .above)
        }
    }

    /// Called as any skinned window minimizes: detaches every child window first, so only that window goes to the Dock,
    /// as before #0120. AppKit would otherwise hide the children with a minimized parent (or the family with a
    /// minimized child), and on macOS 27 the group came back moved and overlapping.
    func skinnedWindowWillMinimize() {
        for controller in controllers.values { detachFromParent(controller) }
    }

    /// Called when a skinned window comes back from the Dock: reattaches the child windows that are on screen.
    func skinnedWindowDidDeminimize() {
        for controller in controllers.values { attachChildWindows(around: controller) }
    }

    /// Detaches `controller`'s window from its parent before it is hidden or closed.
    func detachFromParent(_ controller: SkinWindowController) {
        controller.window.parent?.removeChildWindow(controller.window)
    }

    // MARK: Z-order

    /// Brings the visible skinned windows forward together, directly beneath `controller`'s window and in their current
    /// order (Winamp's owned windows; Webamp's `windowOrder`). Ordering only: nothing is made key, nothing outside the
    /// group is touched, windows on other Spaces stay there.
    func raiseGroup(around controller: SkinWindowController) {
        guard isVisible(controller) else { return }
        var kinds: [ObjectIdentifier: WindowKind] = [:]
        for (kind, other) in controllers where isVisible(other) && other.window.isOnActiveSpace {
            kinds[ObjectIdentifier(other.window)] = kind
        }
        let frontToBack = NSApp.orderedWindows.compactMap { kinds[ObjectIdentifier($0)] }
        let steps = WindowStacking.raise(
            group: Set(kinds.values), key: controller.kind.windowKind, frontToBack: frontToBack,
            parent: { [controllers] kind in
                // Only an attached child is held above its parent.
                guard let parent = kind.parentWindow, controllers[kind]?.window.parent === controllers[parent]?.window
                else { return nil }
                return parent
            })
        for step in steps {
            guard let window = controllers[step.window]?.window, let anchor = controllers[step.below]?.window else { continue }
            window.order(.below, relativeTo: anchor.windowNumber)
        }
    }

    // MARK: Size changes

    /// Runs `change` (which resizes `controller`'s window, keeping its top-left corner) and moves the windows that were
    /// docked below or to the right of it by the size difference, so the group stays docked (Webamp's
    /// `withWindowGraphIntegrity`).
    func resize(_ controller: SkinWindowController, _ change: () -> Void) {
        let before = dockedWindows()
        let graph = WindowGraph.generate(before)
        change()
        var sizeDiff: [WindowKind: (width: CGFloat, height: CGFloat)] = [:]
        for window in before {
            guard let current = controllers[window.kind]?.window.frame.size else { continue }
            sizeDiff[window.kind] = (current.width - window.box.width, current.height - window.box.height)
        }
        let diff = WindowGraph.positionDiff(graph: graph, sizeDiff: sizeDiff)
        for window in before {
            guard let offset = diff[window.kind], offset != .zero else { continue }
            move(window.kind, toTopLeft: Offset(x: window.box.x + offset.x, y: window.box.y + offset.y))
        }
        layoutDidChange()
    }

    // MARK: Persistence

    /// Saves the position of every window that has one.
    func layoutDidChange() {
        var windows: [WindowKind: WindowLayout.Entry] = [:]
        for (kind, controller) in controllers where controller.isPositioned {
            let box = desktop.box(controller.window.frame)
            windows[kind] = WindowLayout.Entry(left: box.x, top: box.y)
        }
        store.save(WindowLayout(windows: windows))
    }

    /// Places the windows from the saved layout; with none, from the frames the old frame autosave left (once), else
    /// the main window and any open ones stack and centre on the primary screen. Windows with no position stay
    /// unpositioned and sit under their reference when first shown. Call once, before the first window shows.
    func restoreOrDefaultLayout() {
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.ensureOnScreen() } }
        }
        if let layout = store.load() {
            for (kind, entry) in layout.windows { place(kind, Offset(x: entry.left, y: entry.top)) }
        } else if !seedFromLegacyFrames() {
            stackDefaultLayout()
        }
    }

    private func place(_ kind: WindowKind, _ topLeft: Offset) {
        guard let controller = controllers[kind] else { return }
        move(kind, toTopLeft: topLeft)
        controller.isPositioned = true
    }

    /// The frames `setFrameAutosaveName` saved before the coordinator existed ("x y w h ..."); read once, then removed.
    private func seedFromLegacyFrames() -> Bool {
        var found = false
        for (kind, controller) in controllers {
            let key = "NSWindow Frame \(controller.kind.legacyAutosaveName)"
            guard let text = model.defaults.string(forKey: key) else { continue }
            model.defaults.removeObject(forKey: key)
            let numbers = text.split(separator: " ").prefix(4).compactMap { Double($0) }
            guard numbers.count == 4 else { continue }
            let rect = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
            place(kind, Offset(x: desktop.box(rect).x, y: desktop.box(rect).y))
            found = true
        }
        return found
    }

    private func stackDefaultLayout() {
        let shown = WindowKind.allCases.filter { kind in
            switch kind {
            case .main: true
            case .equalizer: model.isEQWindowOpen
            case .playlist: model.isPlaylistWindowOpen
            }
        }
        stack(shown)
    }

    /// Stacks `kinds` in order and centres the group on the primary screen's work area.
    private func stack(_ kinds: [WindowKind]) {
        var sizes: [WindowKind: CGSize] = [:]
        for kind in kinds { sizes[kind] = controllers[kind]?.window.frame.size }
        let positions = LayoutRules.stackedAndCentered(sizes: sizes, order: kinds, in: primaryBox)
        for (kind, position) in positions { place(kind, position) }
    }

    // MARK: Recovery

    /// Brings windows that are off every screen back: shift the group if it fits, else reset the playlist's size and
    /// stack and centre (Webamp's `ensureWindowsAreOnScreen`). Runs after launch and when the displays change.
    func ensureOnScreen() {
        let windows = dockedWindows()
        guard let recovery = LayoutRules.recovery(windows: windows, screens: screenBoxes, primary: primaryBox) else { return }
        switch recovery {
        case .shift(let offset):
            for window in windows {
                move(window.kind, toTopLeft: Offset(x: window.box.x + offset.x, y: window.box.y + offset.y))
            }
        case .reset:
            model.playlist.setSteps(.zero)
            controllers[.playlist]?.applyLayout()
            stack(windows.map(\.kind))
        }
        layoutDidChange()
    }
}

extension NSWindow {
    /// Runs `change`, which moves or resizes this window, and puts its child windows back where they were: AppKit
    /// moves child windows with their parent, but the docking engine places every skinned window itself (#0120).
    func keepingChildWindowsInPlace(_ change: () -> Void) {
        let children = (childWindows ?? []).map { ($0, $0.frame.origin) }
        change()
        for (child, origin) in children where child.frame.origin != origin { child.setFrameOrigin(origin) }
    }
}
