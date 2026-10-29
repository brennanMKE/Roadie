/// Moves between presets: order, back/forward history, lock and failures (design §5.3).
public struct PresetNavigator: Sendable {
    public enum Order: String, Sendable { case random, sequential }

    static let historyLimit = 64
    static let recentLimit = 8

    public private(set) var presets: [VisualizationPreset]
    public private(set) var current: VisualizationPreset?
    /// Changing the order keeps the current preset and the history.
    public var order: Order
    public var isLocked: Bool

    private var back: [String] = []
    private var forward: [String] = []
    /// Ids shown most recently, newest (the current one) last, for random's no-repeat rule.
    private var recent: [String] = []
    private var failed: Set<String> = []
    private var rng: SplitMix64

    /// `presets` are expected already ordered (`PresetCatalog.ordered`).
    public init(presets: [VisualizationPreset], order: Order, isLocked: Bool, startingAt id: String?, seed: UInt64) {
        self.presets = presets
        self.order = order
        self.isLocked = isLocked
        self.rng = SplitMix64(seed: seed)
        let start = presets.first { $0.id == id } ?? presets.first
        self.current = start
        if let start { recent = [start.id] }
    }

    public var usable: [VisualizationPreset] { presets.filter { !failed.contains($0.id) } }

    /// Forward history first, else a new one by the order.
    public mutating func next() -> VisualizationPreset? {
        guard usable.count >= 2, let current else { return nil }
        while let id = forward.popLast() {
            if let preset = preset(id), preset.id != current.id {
                pushBack(current.id)
                return show(preset)
            }
        }
        guard let target = pickByOrder() else { return nil }
        pushBack(current.id)
        return show(target)
    }

    /// Back history, else the usable preset before the current one in list order.
    public mutating func previous() -> VisualizationPreset? {
        guard usable.count >= 2, let current else { return nil }
        while let id = back.popLast() {
            if let preset = preset(id), preset.id != current.id {
                forward.append(current.id)
                return show(preset)
            }
        }
        guard let target = neighbour(of: current, step: -1) else { return nil }
        return show(target)
    }

    /// Auto-advance: nil while locked; truncates forward history.
    public mutating func advanceAutomatically() -> VisualizationPreset? {
        guard !isLocked else { return nil }
        forward.removeAll()
        return next()
    }

    /// Jumps to `id`; nil for an unknown or failed id.
    public mutating func select(id: String) -> VisualizationPreset? {
        guard let target = preset(id) else { return nil }
        if let current, current.id != target.id { pushBack(current.id) }
        forward.removeAll()
        return show(target)
    }

    /// The id is skipped by every move from now on. If it's current, current stays.
    public mutating func markFailed(id: String) {
        failed.insert(id)
    }

    /// A new list: current kept if still present, else the first; history and failures pruned.
    public mutating func replacePresets(_ presets: [VisualizationPreset]) {
        self.presets = presets
        let ids = Set(presets.map(\.id))
        back.removeAll { !ids.contains($0) }
        forward.removeAll { !ids.contains($0) }
        recent.removeAll { !ids.contains($0) }
        failed.formIntersection(ids)
        if let id = current?.id, let kept = presets.first(where: { $0.id == id }) {
            current = kept
        } else {
            current = presets.first
            if let first = presets.first { recent.append(first.id) }
        }
    }

    // MARK: - Private

    private func preset(_ id: String) -> VisualizationPreset? {
        guard !failed.contains(id) else { return nil }
        return presets.first { $0.id == id }
    }

    private mutating func show(_ preset: VisualizationPreset) -> VisualizationPreset {
        current = preset
        recent.append(preset.id)
        let cap = Self.recentLimit + 1
        if recent.count > cap { recent.removeFirst(recent.count - cap) }
        return preset
    }

    private mutating func pushBack(_ id: String) {
        back.append(id)
        if back.count > Self.historyLimit { back.removeFirst(back.count - Self.historyLimit) }
    }

    private mutating func pickByOrder() -> VisualizationPreset? {
        guard let current else { return nil }
        switch order {
        case .sequential:
            return neighbour(of: current, step: 1)
        case .random:
            let candidates = usable.filter { $0.id != current.id }
            let window = min(Self.recentLimit, presets.count / 2)
            // The current preset (last in `recent`) plus the `window` shown before it.
            let excluded = Set(recent.suffix(window + 1))
            var pool = candidates.filter { !excluded.contains($0.id) }
            if pool.isEmpty { pool = candidates }
            guard !pool.isEmpty else { return nil }
            return pool[Int.random(in: 0..<pool.count, using: &rng)]
        }
    }

    /// The next usable preset `step` (±1) from `preset` in list order, wrapping.
    private func neighbour(of preset: VisualizationPreset, step: Int) -> VisualizationPreset? {
        guard let start = presets.firstIndex(where: { $0.id == preset.id }) else {
            return usable.first { $0.id != preset.id }
        }
        var index = start
        for _ in 0..<presets.count {
            index = (index + step + presets.count) % presets.count
            let candidate = presets[index]
            if candidate.id != preset.id, !failed.contains(candidate.id) { return candidate }
        }
        return nil
    }
}
