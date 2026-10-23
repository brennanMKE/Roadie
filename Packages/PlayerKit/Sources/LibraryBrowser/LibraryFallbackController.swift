import Foundation
import MusicBackendKit
import Observation
import os

public struct FallbackStatus: Hashable, Sendable {
    public var preferredID: String
    public var preferredName: String
    public var activeID: String
    public var activeName: String
    public var reason: FallbackReason?

    public init(preferredID: String, preferredName: String, activeID: String, activeName: String, reason: FallbackReason?) {
        self.preferredID = preferredID
        self.preferredName = preferredName
        self.activeID = activeID
        self.activeName = activeName
        self.reason = reason
    }
}

public struct FallbackNotice: Hashable, Sendable {
    public var text: String
    public var detail: String?

    public init(text: String, detail: String?) {
        self.text = text
        self.detail = detail
    }
}

/// Drives `LibraryFallbackPolicy`: owns the clock, the probe tasks and the retry timers, and turns the policy's
/// effects into `LibrarySourceController.select(_:persist:)` calls and notices. It is the only caller of `select`
/// besides the Settings picker (through `userSelected`). It never writes defaults, disconnects a backend or
/// touches a token, and it does no I/O until a source is configured and something fails or changes.
@MainActor @Observable
public final class LibraryFallbackController {
    public private(set) var status: FallbackStatus
    /// The policy, for tests; views read `status`.
    public private(set) var policy: LibraryFallbackPolicy
    /// Called for every automatic switch (never for `userSelected`).
    @ObservationIgnored public var onNotice: (@MainActor (FallbackNotice) -> Void)?

    @ObservationIgnored private let sources: LibrarySourceController
    @ObservationIgnored private let uptime: () -> Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var probeTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var timerTasks: [String: Task<Void, Never>] = [:]
    private static let log = Logger(subsystem: "co.sstools.roadie", category: "LibraryFallback")

    public var timerCount: Int { timerTasks.count }
    public var probeCount: Int { probeTasks.count }

    public convenience init(sources: LibrarySourceController, schedule: RetrySchedule = .default) {
        self.init(sources: sources, schedule: schedule, clock: ContinuousClock())
    }

    public init<C: Clock>(sources: LibrarySourceController, schedule: RetrySchedule = .default, clock: C)
    where C.Duration == Duration {
        self.sources = sources
        let begin = clock.now
        uptime = { begin.duration(to: clock.now) }
        sleep = { try await clock.sleep(for: $0) }
        let policy = LibraryFallbackPolicy(
            order: sources.sources.map(\.id), preferred: sources.preferredID, schedule: schedule)
        self.policy = policy
        status = Self.status(of: policy, sources)
        sources.onBackendFailure = { [weak self] id, error, phase in self?.backendFailed(id, error, phase) }
    }

    // MARK: Triggers

    /// Call once after construction. Reads only `isConfigured` (defaults); no I/O.
    public func start() { handle(.start) }

    /// The Settings picker's setter: the choice becomes preferred and active, and retries stop.
    public func userSelected(_ id: String) { handle(.userSelected(id)) }

    /// A setting changed (`UserDefaults.didChangeNotification`): re-read what is configured.
    public func settingsChanged() { handle(.configuredChanged) }

    /// A Retry button, or the Mac waking up.
    public func retryNow() { handle(.retryRequested) }

    /// A failure the app saw outside the browser (a play that threw). Only `.unreachable` and `.unauthorized` matter.
    public func report(_ error: any Error, from sourceID: String) {
        guard sourceID == sources.selectedID, let error = error as? MusicBackendError else { return }
        switch error {
        case .unreachable, .unauthorized: handle(.failureReported(sourceID))
        default: break
        }
    }

    /// Cancels every probe and timer.
    public func stop() {
        for task in probeTasks.values { task.cancel() }
        for task in timerTasks.values { task.cancel() }
        probeTasks = [:]
        timerTasks = [:]
    }

    // MARK: Engine

    private func backendFailed(_ id: String, _ error: MusicBackendError, _ phase: LibraryBrowserModel.FailurePhase) {
        // A task on a model the user has since switched away from can still fail; that says nothing now.
        guard id == sources.selectedID else { return }
        switch phase {
        case .connect:
            switch error {
            case .notConfigured(let message): handle(.probeResult(id, .notConfigured(message)))
            case .unreachable, .unauthorized, .backend:
                handle(.probeResult(id, .unreachable(error.errorDescription ?? "The music source can't be reached.")))
            default: break
            }
        case .browse:
            switch error {
            case .unreachable, .unauthorized: handle(.failureReported(id))
            default: break
            }
        }
    }

    private func handle(_ event: LibraryFallbackPolicy.Event) {
        let sources = sources
        let effects = policy.handle(
            event, configured: { id in sources.sources.first { $0.id == id }?.isConfigured() ?? false }, now: uptime())
        status = Self.status(of: policy, sources)
        apply(effects)
    }

    private func apply(_ effects: [LibraryFallbackPolicy.Effect]) {
        for effect in effects {
            switch effect {
            case .activate(let id, let kind):
                sources.select(id, persist: kind == .user)
                if kind != .user {
                    Self.log.info("\(kind == .restore ? "restored" : "fallback to", privacy: .public) \(id, privacy: .public)")
                    onNotice?(FallbackText.notice(kind: kind, status: status))
                }
            case .probe(let id):
                guard let probe = sources.sources.first(where: { $0.id == id })?.probe else { continue }
                Self.log.debug("probe \(id, privacy: .public)")
                probeTasks[id]?.cancel()
                probeTasks[id] = Task {
                    let outcome = await probe()
                    guard !Task.isCancelled else { return handleProbeEnd(id, outcome: nil) }
                    handleProbeEnd(id, outcome: outcome)
                }
            case .schedule(let id, let delay):
                Self.log.debug("schedule \(id, privacy: .public)")
                timerTasks[id]?.cancel()
                let sleep = sleep
                timerTasks[id] = Task {
                    try? await sleep(delay)
                    guard !Task.isCancelled else { return }
                    timerTasks[id] = nil
                    handle(.probeDue(id))
                }
            case .cancelSchedule(let id):
                timerTasks.removeValue(forKey: id)?.cancel()
            }
        }
    }

    private func handleProbeEnd(_ id: String, outcome: SourceProbeOutcome?) {
        probeTasks[id] = nil
        if let outcome { handle(.probeResult(id, outcome)) } else { handle(.probeAborted(id)) }
    }

    private static func status(of policy: LibraryFallbackPolicy, _ sources: LibrarySourceController) -> FallbackStatus {
        func name(_ id: String) -> String { sources.sources.first { $0.id == id }?.displayName ?? id }
        return FallbackStatus(
            preferredID: policy.preferred, preferredName: name(policy.preferred),
            activeID: policy.active, activeName: name(policy.active), reason: policy.reason)
    }
}
