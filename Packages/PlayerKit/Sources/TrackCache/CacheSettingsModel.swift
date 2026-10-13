import Foundation
import Observation

/// What the Settings > Cache tab shows and does. The view is thin; this is what the tests drive.
@MainActor
@Observable
public final class CacheSettingsModel {
    public nonisolated static let limitDefaultsKey = "TrackCacheLimitBytes"
    public nonisolated static let limitChoices: [Int64] = [
        500_000_000, 1_000_000_000, 2_000_000_000, 5_000_000_000, 10_000_000_000, 20_000_000_000,
    ]

    /// The saved limit, or `TrackCache.defaultLimitBytes`. Used by the app before the cache exists.
    public nonisolated static func storedLimit(in defaults: UserDefaults = .standard) -> Int64 {
        let saved = defaults.object(forKey: limitDefaultsKey) as? NSNumber
        if let value = saved?.int64Value, value > 0 { return value }
        return TrackCache.defaultLimitBytes
    }

    /// "2 GB" style text, decimal units (what `limitChoices` are).
    public nonisolated static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useAll]
        return formatter.string(fromByteCount: bytes)
    }

    @ObservationIgnored private let cache: TrackCache
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var limitTask: Task<Void, Never>?
    /// Persists, then tells the cache (which evicts at once) and refreshes.
    public var limitBytes: Int64 {
        didSet {
            guard limitBytes != oldValue else { return }
            let newValue = limitBytes
            defaults.set(newValue, forKey: Self.limitDefaultsKey)
            let previous = limitTask
            limitTask = Task { [cache] in
                await previous?.value
                await cache.setLimit(newValue)
                await self.refresh()
            }
        }
    }

    public private(set) var usageBytes: Int64 = 0
    public private(set) var fileCount = 0
    public private(set) var isClearing = false
    public private(set) var errorMessage: String?

    public var usageText: String { usageBytes == 0 ? "0 bytes" : Self.format(usageBytes) }
    public var limitText: String { Self.format(limitBytes) }
    public var canClear: Bool { fileCount > 0 && !isClearing }

    public init(cache: TrackCache, defaults: UserDefaults = .standard) {
        self.cache = cache
        self.defaults = defaults
        self.limitBytes = Self.storedLimit(in: defaults)
    }

    public func refresh() async {
        let stats = await cache.stats()
        usageBytes = stats.totalBytes
        fileCount = stats.fileCount
    }

    public func clearCache() async {
        guard !isClearing else { return }
        isClearing = true
        errorMessage = nil
        do {
            try await cache.clear()
        } catch {
            errorMessage = error.localizedDescription
        }
        isClearing = false
        await refresh()
    }

    /// Awaits the pending limit change, for tests.
    public func waitForPending() async {
        await limitTask?.value
    }
}
