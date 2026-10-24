import Foundation

public enum RepeatMode: Sendable, CaseIterable {
    case off, all, one
}

extension RepeatMode {
    /// The main window's repeat button is a two-state toggle (Winamp 2 / Webamp): off <-> all. From `.one` it turns repeat off.
    public var toggled: RepeatMode { self == .off ? .all : .off }
}

public struct PlayQueue: Equatable, Sendable {
    public private(set) var tracks: [Track]
    public private(set) var currentIndex: Int?
    public var repeatMode: RepeatMode = .off
    public private(set) var isShuffled = false
    public var current: Track? { currentIndex.map { tracks[$0] } }

    /// Permutation of `tracks.indices` while shuffled; empty otherwise.
    private var shuffleOrder: [Int] = []
    /// Position of `currentIndex` in `shuffleOrder`, except while `isPlayingFromUpNext`: then it is the last pass entry
    /// played (where the queue began, one step back if that entry was removed, so -1 is possible); -1 when there is no
    /// current track.
    private var shufflePosition = -1
    /// The order used for the next pass (repeat all), so peeking and advancing agree.
    private var nextPass: [Int] = []
    /// Winamp's play-next queue (#0177): entry ids (`Track.id`), played in order before list or shuffle order resumes.
    /// Ids, not indices, so reorders keep it; removals drop their ids. Never holds an id that isn't in `tracks`.
    public private(set) var upNext: [Track.ID] = []
    /// The current entry was reached from `upNext`. While shuffled, `shufflePosition` then stays where the queue began
    /// (so it no longer points at `currentIndex`), which is what lets the pass resume from there.
    private var isPlayingFromUpNext = false

    public init(tracks: [Track] = []) {
        self.tracks = tracks
    }

    // MARK: Mutation

    public mutating func append(_ new: [Track]) {
        guard !new.isEmpty else { return }
        let start = tracks.count
        tracks.append(contentsOf: new)
        guard isShuffled else { return }
        var rng = SystemRandomNumberGenerator()
        for index in start..<tracks.count {
            let lower = min(shufflePosition + 1, shuffleOrder.count)
            shuffleOrder.insert(index, at: Int.random(in: lower...shuffleOrder.count, using: &rng))
            nextPass.insert(index, at: Int.random(in: 0...nextPass.count, using: &rng))
        }
    }

    public mutating func remove(at index: Int) {
        guard tracks.indices.contains(index) else { return }
        let wasCurrent = currentIndex == index
        let removedID = tracks[index].id
        tracks.remove(at: index)
        upNext.removeAll { $0 == removedID }

        if isShuffled {
            if let p = shuffleOrder.firstIndex(of: index) {
                shuffleOrder.remove(at: p)
                // Removing the anchor's own slot also steps back, so `shufflePosition` stays "the last pass entry
                // played" and the entry that slid into the slot is the one `shufflePosition + 1` resumes at.
                if p <= shufflePosition { shufflePosition -= 1 }
            }
            shuffleOrder = shuffleOrder.map { $0 > index ? $0 - 1 : $0 }
            nextPass.removeAll { $0 == index }
            nextPass = nextPass.map { $0 > index ? $0 - 1 : $0 }
        }

        if tracks.isEmpty {
            currentIndex = nil
            shufflePosition = -1
            isPlayingFromUpNext = false
        } else if wasCurrent {
            if let id = upNext.first, let head = tracks.firstIndex(where: { $0.id == id }) {
                // Keep `shufflePosition` (possibly -1): the pass resumes at `shufflePosition + 1` after the queue.
                upNext.removeFirst()
                currentIndex = head
                isPlayingFromUpNext = true
            } else if isShuffled {
                // Play the pass entry after the last one played: after the track the queue began from rather than
                // replaying it, or the entry that slid into the removed current's slot.
                shufflePosition = min(max(shufflePosition + 1, 0), shuffleOrder.count - 1)
                currentIndex = shuffleOrder[shufflePosition]
                isPlayingFromUpNext = false
            } else {
                currentIndex = min(index, tracks.count - 1)
                isPlayingFromUpNext = false
            }
        } else if let c = currentIndex, c > index {
            currentIndex = c - 1
        }
    }

    /// Removes every index in `indices`, highest first, so each removal reuses `remove(at:)`'s shuffle bookkeeping and
    /// current-track rule. One mutation, so observers see one change.
    public mutating func remove(at indices: IndexSet) {
        for index in indices.reversed() { remove(at: index) }
    }

    /// Keeps only the tracks at `keeping` (Webamp's crop).
    public mutating func crop(keeping: Set<Int>) {
        remove(at: IndexSet(tracks.indices.filter { !keeping.contains($0) }))
    }

    /// Moves the tracks at `selected` by `offset` rows, keeping their order (port of Webamp's `moveSelected` with
    /// `dragSelected`'s clamp: the block cannot leave either end). The current track keeps its identity and the shuffle
    /// bookkeeping stays a permutation of `tracks.indices`. Returns false when nothing moved.
    @discardableResult
    public mutating func move(_ selected: Set<Int>, by offset: Int) -> Bool {
        let selected = selected.filter { tracks.indices.contains($0) }
        guard let first = selected.min(), let last = selected.max() else { return false }
        let clamped = min(max(offset, -first), tracks.count - 1 - last)
        guard clamped != 0 else { return false }
        // newOrder[newPosition] = oldIndex.
        var newOrder = [Int](repeating: 0, count: tracks.count)
        var next = 0
        for i in newOrder.indices {
            let from = i - clamped
            if tracks.indices.contains(from) && selected.contains(from) {
                newOrder[i] = from
            } else {
                while next < tracks.count && selected.contains(next) { next += 1 }
                newOrder[i] = next
                next += 1
            }
        }
        apply(newOrder)
        return true
    }

    /// Reorders the list so `newOrder[newPosition] = oldIndex`. The current track keeps its identity and a shuffled
    /// pass keeps its play order over the new indices. Returns false (and changes nothing) unless `newOrder` is a
    /// permutation of `tracks.indices` other than the identity.
    @discardableResult
    public mutating func reorder(_ newOrder: [Int]) -> Bool {
        guard newOrder.count == tracks.count, newOrder != Array(tracks.indices) else { return false }
        var seen = [Bool](repeating: false, count: tracks.count)
        for index in newOrder {
            guard tracks.indices.contains(index), !seen[index] else { return false }
            seen[index] = true
        }
        apply(newOrder)
        return true
    }

    /// Stable sort by `key` in Finder order (`localizedStandardCompare`: case-insensitive, "t2" before "t10").
    @discardableResult
    public mutating func sort(by key: (Track) -> String) -> Bool {
        let keyed = tracks.enumerated().map { (key: key($0.element), index: $0.offset) }
        let sorted = keyed.sorted { a, b in
            switch a.key.localizedStandardCompare(b.key) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.index < b.index
            }
        }
        return reorder(sorted.map(\.index))
    }

    @discardableResult
    public mutating func reverse() -> Bool {
        reorder(Array(tracks.indices.reversed()))
    }

    /// Permutes the list itself (Winamp's Randomize List); separate from shuffle mode, which only changes play order.
    @discardableResult
    public mutating func randomize<G: RandomNumberGenerator>(using rng: inout G) -> Bool {
        reorder(Array(tracks.indices).shuffled(using: &rng))
    }

    @discardableResult
    public mutating func randomize() -> Bool {
        var rng = SystemRandomNumberGenerator()
        return randomize(using: &rng)
    }

    private mutating func apply(_ newOrder: [Int]) {
        var newPosition = [Int](repeating: 0, count: tracks.count)
        for (new, old) in newOrder.enumerated() { newPosition[old] = new }
        let old = tracks
        tracks = newOrder.map { old[$0] }
        currentIndex = currentIndex.map { newPosition[$0] }
        shuffleOrder = shuffleOrder.map { newPosition[$0] }
        nextPass = nextPass.map { newPosition[$0] }
    }

    public mutating func removeAll() {
        tracks.removeAll()
        currentIndex = nil
        shuffleOrder = []
        nextPass = []
        shufflePosition = -1
        upNext = []
        isPlayingFromUpNext = false
    }

    public mutating func select(_ index: Int) {
        guard tracks.indices.contains(index) else { return }
        currentIndex = index
        isPlayingFromUpNext = false
        let id = tracks[index].id
        upNext.removeAll { $0 == id }
        if isShuffled {
            // Picking a row starts a fresh pass headed by that track.
            var rest = Array(tracks.indices).filter { $0 != index }
            rest.shuffle()
            shuffleOrder = [index] + rest
            shufflePosition = 0
        }
    }

    // MARK: Up next

    /// 1-based place of `id` in `upNext`, nil when not queued.
    public func upNextPosition(of id: Track.ID) -> Int? {
        upNext.firstIndex(of: id).map { $0 + 1 }
    }

    /// Appends the ids not already queued, in the given order (Q, the Queue button). Unknown ids are ignored.
    public mutating func appendUpNext(_ ids: [Track.ID]) {
        let known = Set(tracks.map(\.id))
        for id in ids where known.contains(id) && !upNext.contains(id) { upNext.append(id) }
    }

    /// Puts `ids` at the front of `upNext`, in the given order, taking them out of where they were (Play Next, #0181).
    public mutating func prependUpNext(_ ids: [Track.ID]) {
        let known = Set(tracks.map(\.id))
        var front: [Track.ID] = []
        for id in ids where known.contains(id) && !front.contains(id) { front.append(id) }
        guard !front.isEmpty else { return }
        let moved = Set(front)
        upNext = front + upNext.filter { !moved.contains($0) }
    }

    public mutating func removeFromUpNext(_ ids: [Track.ID]) {
        let gone = Set(ids)
        upNext.removeAll { gone.contains($0) }
    }

    /// When every id is queued, dequeues them all; otherwise appends the ones that aren't (#0174 row 3 default).
    public mutating func toggleUpNext(_ ids: [Track.ID]) {
        let known = Set(tracks.map(\.id))
        let relevant = ids.filter { known.contains($0) }
        guard !relevant.isEmpty else { return }
        if relevant.allSatisfy({ upNext.contains($0) }) {
            removeFromUpNext(relevant)
        } else {
            appendUpNext(relevant)
        }
    }

    public mutating func clearUpNext() {
        upNext = []
    }

    // MARK: Navigation

    @discardableResult
    public mutating func next() -> Track? {
        guard let target = upNextTarget() ?? nextTarget(wrap: repeatMode == .all) else { return nil }
        commit(target)
        return current
    }

    @discardableResult
    public mutating func previous() -> Track? {
        guard let target = previousTarget(wrap: repeatMode == .all) else { return nil }
        commit(target)
        return current
    }

    @discardableResult
    public mutating func advanceAfterTrackEnd() -> Track? {
        guard let target = endTarget() else { return nil }
        commit(target)
        return current
    }

    public func indexAfterCurrentEnds() -> Int? {
        endTarget()?.index
    }

    // MARK: Shuffle

    public mutating func setShuffle<G: RandomNumberGenerator>(_ on: Bool, using rng: inout G) {
        guard on != isShuffled else { return }
        isShuffled = on
        isPlayingFromUpNext = false
        guard on else {
            shuffleOrder = []
            nextPass = []
            shufflePosition = -1
            return
        }
        var order = Array(tracks.indices).shuffled(using: &rng)
        if let c = currentIndex, let p = order.firstIndex(of: c) {
            order.swapAt(0, p)
            shufflePosition = 0
        } else {
            shufflePosition = -1
        }
        shuffleOrder = order
        nextPass = Array(tracks.indices).shuffled(using: &rng)
    }

    public mutating func setShuffle(_ on: Bool) {
        var rng = SystemRandomNumberGenerator()
        setShuffle(on, using: &rng)
    }

    // MARK: Private

    private struct Target {
        var index: Int
        var position: Int
        var rollover = false
        var fromUpNext = false
    }

    /// The head of `upNext`, keeping `shufflePosition` (it stays where the queue began).
    private func upNextTarget() -> Target? {
        guard let id = upNext.first, let index = tracks.firstIndex(where: { $0.id == id }) else { return nil }
        return Target(index: index, position: shufflePosition, fromUpNext: true)
    }

    private func endTarget() -> Target? {
        guard let current = currentIndex else { return nil }
        if repeatMode == .one { return Target(index: current, position: shufflePosition) }
        return upNextTarget() ?? nextTarget(wrap: repeatMode == .all)
    }

    private func nextTarget(wrap: Bool) -> Target? {
        guard !tracks.isEmpty else { return nil }
        if isShuffled {
            let p = shufflePosition + 1
            if p < shuffleOrder.count { return Target(index: shuffleOrder[p], position: p) }
            guard wrap, let first = nextPass.first else { return nil }
            return Target(index: first, position: 0, rollover: true)
        }
        guard let c = currentIndex else { return Target(index: 0, position: -1) }
        if c + 1 < tracks.count { return Target(index: c + 1, position: -1) }
        return wrap ? Target(index: 0, position: -1) : nil
    }

    private func previousTarget(wrap: Bool) -> Target? {
        guard let c = currentIndex else { return nil }
        if isShuffled {
            if isPlayingFromUpNext && shuffleOrder.indices.contains(shufflePosition) {
                // Back to the track the queue began from.
                return Target(index: shuffleOrder[shufflePosition], position: shufflePosition)
            }
            if shufflePosition > 0 {
                return Target(index: shuffleOrder[shufflePosition - 1], position: shufflePosition - 1)
            }
            guard wrap, let last = shuffleOrder.last else { return nil }
            return Target(index: last, position: shuffleOrder.count - 1)
        }
        if c > 0 { return Target(index: c - 1, position: -1) }
        return wrap ? Target(index: tracks.count - 1, position: -1) : nil
    }

    private mutating func commit(_ target: Target) {
        if target.fromUpNext {
            upNext.removeFirst()
            isPlayingFromUpNext = true
            currentIndex = target.index
            return
        }
        isPlayingFromUpNext = false
        if target.rollover {
            shuffleOrder = nextPass
            nextPass = Array(tracks.indices).shuffled()
        }
        currentIndex = target.index
        if isShuffled { shufflePosition = target.position }
    }
}
