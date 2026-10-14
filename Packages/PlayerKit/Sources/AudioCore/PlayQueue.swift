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
    /// Position of `currentIndex` in `shuffleOrder`; -1 when there is no current track.
    private var shufflePosition = -1
    /// The order used for the next pass (repeat all), so peeking and advancing agree.
    private var nextPass: [Int] = []

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
        tracks.remove(at: index)

        if isShuffled {
            if let p = shuffleOrder.firstIndex(of: index) {
                shuffleOrder.remove(at: p)
                if p < shufflePosition { shufflePosition -= 1 }
            }
            shuffleOrder = shuffleOrder.map { $0 > index ? $0 - 1 : $0 }
            nextPass.removeAll { $0 == index }
            nextPass = nextPass.map { $0 > index ? $0 - 1 : $0 }
        }

        if tracks.isEmpty {
            currentIndex = nil
            shufflePosition = -1
        } else if wasCurrent {
            if isShuffled {
                shufflePosition = min(shufflePosition, shuffleOrder.count - 1)
                currentIndex = shuffleOrder[shufflePosition]
            } else {
                currentIndex = min(index, tracks.count - 1)
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
        var newPosition = [Int](repeating: 0, count: tracks.count)
        for (new, old) in newOrder.enumerated() { newPosition[old] = new }
        let old = tracks
        tracks = newOrder.map { old[$0] }
        currentIndex = currentIndex.map { newPosition[$0] }
        shuffleOrder = shuffleOrder.map { newPosition[$0] }
        nextPass = nextPass.map { newPosition[$0] }
        return true
    }

    public mutating func removeAll() {
        tracks.removeAll()
        currentIndex = nil
        shuffleOrder = []
        nextPass = []
        shufflePosition = -1
    }

    public mutating func select(_ index: Int) {
        guard tracks.indices.contains(index) else { return }
        currentIndex = index
        if isShuffled {
            // Picking a row starts a fresh pass headed by that track.
            var rest = Array(tracks.indices).filter { $0 != index }
            rest.shuffle()
            shuffleOrder = [index] + rest
            shufflePosition = 0
        }
    }

    // MARK: Navigation

    @discardableResult
    public mutating func next() -> Track? {
        guard let target = nextTarget(wrap: repeatMode == .all) else { return nil }
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
    }

    private func endTarget() -> Target? {
        guard let current = currentIndex else { return nil }
        if repeatMode == .one { return Target(index: current, position: shufflePosition) }
        return nextTarget(wrap: repeatMode == .all)
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
        if target.rollover {
            shuffleOrder = nextPass
            nextPass = Array(tracks.indices).shuffled()
        }
        currentIndex = target.index
        if isShuffled { shufflePosition = target.position }
    }
}
