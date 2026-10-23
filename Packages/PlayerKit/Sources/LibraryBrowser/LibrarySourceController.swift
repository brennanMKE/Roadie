import Foundation
import MusicBackendKit
import MusicLibraryKit
import Observation
import os

/// Owns the active `MusicBackend` and everything the app builds from it: the Library window's browser model,
/// the thumbnail cache and the now-playing subscription. `select(_:persist:)` is the only thing that swaps a
/// backend. It never connects or disconnects one, so switching leaves playback and every source's settings alone.
@MainActor @Observable
public final class LibrarySourceController {
    public static let defaultsKey = "LibrarySource"

    /// In fallback order; #0063 prepends Music Assistant.
    public let sources: [LibrarySource]
    /// The source in use. May differ from `preferredID` while the fallback (#0067) is active.
    public private(set) var selectedID: String
    /// The user's choice, persisted under `defaultsKey`. Only `select(_:persist: true)` changes it.
    public private(set) var preferredID: String
    public var selected: LibrarySource { sources.first { $0.id == selectedID }! }
    public private(set) var backend: any MusicBackend
    public private(set) var library: LibraryBrowserModel
    public private(set) var artwork: ArtworkCache
    /// Increments per switch (tests; #0067).
    public private(set) var generation = 0
    /// Live outer now-playing streams (tests).
    public var nowPlayingSubscriberCount: Int { subscribers.count }

    /// Installed on every browser model the controller builds, with that model's source id. For the fallback (#0067).
    @ObservationIgnored public var onBackendFailure:
        (@MainActor (String, MusicBackendError, LibraryBrowserModel.FailurePhase) -> Void)?

    private struct Subscriber {
        var output: OutputDevice.ID
        var continuation: AsyncStream<NowPlaying>.Continuation
        var inner: Task<Void, Never>?
    }

    @ObservationIgnored private var subscribers: [UUID: Subscriber] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    private let pageSize: Int
    private let searchDelay: Duration
    private let searchLimit: Int
    private let artworkLimitBytes: Int
    private let artworkLimitCount: Int
    private static let log = Logger(subsystem: "co.sstools.roadie", category: "LibrarySource")

    public init(
        sources: [LibrarySource], defaultSourceID: String, defaults: UserDefaults = .standard,
        pageSize: Int = 100, searchDelay: Duration = .milliseconds(300), searchLimit: Int = 50,
        artworkLimitBytes: Int = ArtworkCache.defaultLimitBytes, artworkLimitCount: Int = ArtworkCache.defaultLimitCount
    ) {
        precondition(Set(sources.map(\.id)).count == sources.count, "library source ids must be distinct")
        let id = LibrarySourceSelection.resolve(
            stored: defaults.string(forKey: Self.defaultsKey), available: sources, fallback: defaultSourceID)
        self.sources = sources
        self.defaults = defaults
        self.pageSize = pageSize
        self.searchDelay = searchDelay
        self.searchLimit = searchLimit
        self.artworkLimitBytes = artworkLimitBytes
        self.artworkLimitCount = artworkLimitCount
        selectedID = id
        preferredID = id
        let backend = sources.first { $0.id == id }!.backend
        self.backend = backend
        library = LibraryBrowserModel(backend: backend, pageSize: pageSize, searchDelay: searchDelay, searchLimit: searchLimit)
        artwork = ArtworkCache(backend: backend, limitBytes: artworkLimitBytes, limitCount: artworkLimitCount)
        installFailureHook(on: library, id: id)
        Self.log.info("source \(id, privacy: .public)")
    }

    /// The one entry point. false (and no change) for an unknown id, or for the current source when
    /// there is nothing to persist. `persist: false` moves the browser without touching `preferredID` or defaults
    /// (the fallback's switches). Tears down the old browser model, builds a new browser model and artwork
    /// cache, and re-points every live now-playing stream. Never connects or disconnects a backend.
    @discardableResult
    public func select(_ id: String, persist: Bool = true) -> Bool {
        guard let source = sources.first(where: { $0.id == id }) else { return false }
        if id == selectedID {
            // The user confirming the fallback source as their choice.
            guard persist, preferredID != id else { return false }
            preferredID = id
            defaults.set(id, forKey: Self.defaultsKey)
            return true
        }
        selectedID = id
        rebuild(for: source)
        if persist {
            preferredID = id
            defaults.set(id, forKey: Self.defaultsKey)
        }
        Self.log.info("switched to \(id, privacy: .public)")
        return true
    }

    /// Rebuilds the browser model and artwork cache of the source in use, for the same backend, when its settings
    /// changed under it (#0063: the active Music Assistant server). Touches neither `preferredID` nor defaults and
    /// never connects or disconnects. false, with nothing changed, when `id` is not the source in use.
    @discardableResult
    public func reload(_ id: String) -> Bool {
        guard id == selectedID, let source = sources.first(where: { $0.id == id }) else { return false }
        rebuild(for: source)
        Self.log.info("reloaded \(id, privacy: .public)")
        return true
    }

    private func rebuild(for source: LibrarySource) {
        library.disappeared()
        backend = source.backend
        library = LibraryBrowserModel(
            backend: source.backend, pageSize: pageSize, searchDelay: searchDelay, searchLimit: searchLimit)
        installFailureHook(on: library, id: source.id)
        artwork = ArtworkCache(backend: source.backend, limitBytes: artworkLimitBytes, limitCount: artworkLimitCount)
        generation += 1
        for key in Array(subscribers.keys) { resubscribe(key) }
    }

    /// Forwards the active backend's `nowPlaying(on:)` and follows `select`. Ends when the subscriber cancels.
    public func nowPlaying(on output: OutputDevice.ID) -> AsyncStream<NowPlaying> {
        let (stream, continuation) = AsyncStream<NowPlaying>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let key = UUID()
        subscribers[key] = Subscriber(output: output, continuation: continuation, inner: nil)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.end(key) }
        }
        resubscribe(key)
        return stream
    }

    private func installFailureHook(on model: LibraryBrowserModel, id: String) {
        model.onBackendFailure = { [weak self] error, phase in self?.onBackendFailure?(id, error, phase) }
    }

    private func resubscribe(_ key: UUID) {
        guard var subscriber = subscribers[key] else { return }
        subscriber.inner?.cancel()
        let backend = backend
        let output = subscriber.output
        let continuation = subscriber.continuation
        subscriber.inner = Task {
            for await snapshot in await backend.nowPlaying(on: output) {
                guard !Task.isCancelled else { return }
                continuation.yield(snapshot)
            }
        }
        subscribers[key] = subscriber
    }

    private func end(_ key: UUID) {
        subscribers.removeValue(forKey: key)?.inner?.cancel()
    }
}
