import AudioCore
import Foundation
import Observation
import os

/// Saves the "This Mac" queue to a `QueueStore` a moment after it changes, and immediately on `flush()` (quit).
@MainActor
public final class QueueAutosaver {
    private let output: LocalPlayerOutput
    private let store: QueueStore
    private let delay: Duration
    private var started = false
    private var pending: Task<Void, Never>?
    /// The last off-main write; the next one waits for it so an older snapshot can never land after a newer one.
    private var lastWrite: Task<Void, Never>?
    /// The queue as it was when saving started; a quit with no change since leaves the file as found
    /// (an unreadable or newer-version file is not replaced by an empty queue).
    private var baseline: QueueSnapshot?
    private let log = Logger(subsystem: "co.sstools.roadie", category: "QueueAutosaver")

    /// Saves started so far (tests).
    public private(set) var saveCount = 0

    public init(output: LocalPlayerOutput, store: QueueStore, delay: Duration = .seconds(1)) {
        self.output = output
        self.store = store
        self.delay = delay
    }

    /// Observes the player's queue; each change (re)starts the delay, then one save. Safe to call once.
    public func start() {
        guard !started else { return }
        started = true
        baseline = output.queueSnapshot()
        observe()
    }

    /// Cancels a pending save and writes now (quit).
    public func flush() {
        pending?.cancel()
        pending = nil
        let snapshot = output.queueSnapshot()
        if saveCount == 0, snapshot == baseline { return }
        saveCount += 1
        do { try store.save(snapshot) } catch {
            log.error("could not save the queue: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Writes the current queue now, even when it has not changed since `start()` (a restore that dropped items).
    public func saveNow() {
        pending?.cancel()
        pending = nil
        saveCount += 1
        do { try store.save(output.queueSnapshot()) } catch {
            log.error("could not save the queue: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func observe() {
        withObservationTracking {
            _ = output.player.queue
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.queueChanged()
                self.observe()
            }
        }
    }

    private func queueChanged() {
        pending?.cancel()
        let delay = delay
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        let snapshot = output.queueSnapshot()
        let store = store
        let previous = lastWrite
        let log = log
        saveCount += 1
        lastWrite = Task.detached(priority: .utility) {
            await previous?.value
            do { try store.save(snapshot) } catch {
                log.error("could not save the queue: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
