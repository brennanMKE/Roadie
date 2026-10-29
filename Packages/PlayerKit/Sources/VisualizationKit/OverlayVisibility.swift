import Foundation

/// When the song overlay and the cursor hide (design §1.4). Times are passed in by the caller. Keys don't feed it.
public struct OverlayVisibility: Sendable {
    public enum Hold: Hashable, Sendable { case notPlaying, voiceOver, browser, help, menu, pointerOnOverlay, notice }

    /// nil or <= 0 means never hide.
    public var idleTimeout: TimeInterval?
    public private(set) var isOverlayVisible = true
    public private(set) var isCursorHidden = false
    public private(set) var holds: Set<Hold> = []

    private var lastActivity: TimeInterval
    private var pointerInside = true

    public init(idleTimeout: TimeInterval?, now: TimeInterval) {
        self.idleTimeout = idleTimeout
        self.lastActivity = now
    }

    /// Window opened or entered full screen.
    public mutating func show(at now: TimeInterval) {
        reveal(at: now)
    }

    public mutating func pointerMoved(at now: TimeInterval, inside: Bool) {
        pointerInside = inside
        reveal(at: now)
    }

    /// The cursor is never hidden while the pointer is outside; the overlay still hides on time.
    public mutating func pointerExited(at now: TimeInterval) {
        pointerInside = false
        isCursorHidden = false
    }

    /// Any hold shows the overlay and cursor and stops the countdown; releasing the last restarts it from `now`.
    public mutating func setHolds(_ holds: Set<Hold>, at now: TimeInterval) {
        let wasHeld = !self.holds.isEmpty
        self.holds = holds
        if !holds.isEmpty {
            isOverlayVisible = true
            isCursorHidden = false
        } else if wasHeld {
            lastActivity = now
        }
    }

    public mutating func tick(at now: TimeInterval) {
        guard let deadline = nextDeadline, now >= deadline else { return }
        isOverlayVisible = false
        isCursorHidden = pointerInside
    }

    /// lastActivity + timeout; nil while held or when it never hides.
    public var nextDeadline: TimeInterval? {
        guard holds.isEmpty, let idleTimeout, idleTimeout > 0 else { return nil }
        return lastActivity + idleTimeout
    }

    private mutating func reveal(at now: TimeInterval) {
        lastActivity = now
        isOverlayVisible = true
        isCursorHidden = false
    }
}
