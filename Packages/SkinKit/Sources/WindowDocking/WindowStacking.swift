/// Which windows go beneath which when a skinned window comes to the front: Webamp's `windowOrder` after
/// `SET_FOCUSED_WINDOW` (reducers/windows.ts 109-119) expressed as AppKit `order(.below, relativeTo:)` steps.
public enum WindowStacking {
    public struct Placement<ID: Hashable>: Equatable {
        public let window: ID
        public let below: ID

        public init(window: ID, below: ID) {
            self.window = window
            self.below = below
        }
    }

    /// `frontToBack` is the app's on-screen windows, front first (windows that are not in `group` are passed through
    /// and ignored). Returns the steps that put every other member of `group` directly beneath `key`, keeping their
    /// relative order; apply them in order. Empty when `key` is not a member of `group` or is not on screen, or when no
    /// other member is on screen.
    public static func raise<ID: Hashable>(group: Set<ID>, key: ID, frontToBack: [ID]) -> [Placement<ID>] {
        guard group.contains(key), frontToBack.contains(key) else { return [] }
        var seen: Set<ID> = [key]
        var placements: [Placement<ID>] = []
        var anchor = key
        for window in frontToBack where group.contains(window) && seen.insert(window).inserted {
            placements.append(Placement(window: window, below: anchor))
            anchor = window
        }
        return placements
    }

    /// `raise(group:key:frontToBack:)` without the steps that would put a child window below its own parent, which
    /// AppKit can't do (a child window stays above its parent, #0120). `parent` gives each window's parent, nil for a
    /// window that has none.
    public static func raise<ID: Hashable>(
        group: Set<ID>, key: ID, frontToBack: [ID], parent: (ID) -> ID?
    ) -> [Placement<ID>] {
        raise(group: group, key: key, frontToBack: frontToBack).filter { parent($0.window) != $0.below }
    }
}
