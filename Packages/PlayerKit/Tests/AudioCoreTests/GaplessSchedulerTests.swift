import Foundation
import Testing
@testable import AudioCore

@Suite struct GaplessSchedulerTests {
    let a = UUID(), b = UUID(), c = UUID()

    @Test func completionAdvancesToNextItem() {
        var s = GaplessScheduler()
        let first = s.append(trackID: a, frameLength: 1000)
        let second = s.append(trackID: b, frameLength: 500)
        #expect(second.startFrame == 1000)
        #expect(s.complete(first.token) == .advanced(to: b))
        #expect(s.items.first?.startFrame == 1000)
        #expect(s.currentTrackID == b)
    }

    @Test func positionAccountsForStartFrameAndSeekOffset() {
        var s = GaplessScheduler()
        let first = s.append(trackID: a, frameLength: 1000)
        _ = s.append(trackID: b, frameLength: 4000, seekOffset: 2.0)
        _ = s.complete(first.token)
        #expect(s.position(atNodeSampleTime: 1500, nodeSampleRate: 1000) == 2.5)
        // Before the callback arrives the position clamps to the item.
        #expect(s.position(atNodeSampleTime: 99_999, nodeSampleRate: 1000) == 6.0)
        #expect(s.position(atNodeSampleTime: 0, nodeSampleRate: 1000) == 2.0)
    }

    @Test func staleTokenIsIgnoredAfterInvalidate() {
        var s = GaplessScheduler()
        let old = s.append(trackID: a, frameLength: 100)
        s.invalidate()
        let fresh = s.append(trackID: a, frameLength: 100)
        #expect(fresh.startFrame == 0)
        #expect(s.complete(old.token) == .stale)
        #expect(s.items == [fresh])
    }

    @Test func stopFiresCallbacksForEveryDiscardedItem() {
        var s = GaplessScheduler()
        let first = s.append(trackID: a, frameLength: 100)
        let second = s.append(trackID: b, frameLength: 100)
        s.invalidate()
        #expect(s.complete(first.token) == .stale)
        #expect(s.complete(second.token) == .stale)
        #expect(s.items.isEmpty)
    }

    @Test func outOfOrderCompletionIsStale() {
        var s = GaplessScheduler()
        _ = s.append(trackID: a, frameLength: 100)
        let second = s.append(trackID: b, frameLength: 100)
        #expect(s.complete(second.token) == .stale)
        #expect(s.items.count == 2)
    }

    @Test func lastItemCompletionReportsEnd() {
        var s = GaplessScheduler()
        let only = s.append(trackID: a, frameLength: 100)
        #expect(s.complete(only.token) == .reachedEnd)
        #expect(s.items.isEmpty)
    }

    @Test func nodeFramesScalesWithSampleRate() {
        typealias S = GaplessScheduler
        #expect(S.nodeFrames(fileFrames: 22050, fileSampleRate: 44100, nodeSampleRate: 48000) == 24000)
        #expect(S.nodeFrames(fileFrames: 24000, fileSampleRate: 48000, nodeSampleRate: 44100) == 22050)
        #expect(S.nodeFrames(fileFrames: 48000, fileSampleRate: 96000, nodeSampleRate: 48000) == 24000)
        #expect(S.nodeFrames(fileFrames: 12345, fileSampleRate: 44100, nodeSampleRate: 44100) == 12345)
    }

    @Test func reconcileKeepsScheduleWhenNextUnchanged() {
        #expect(SchedulingDecision.reconcile(queueNext: b, scheduledNext: b) == .keep)
        #expect(SchedulingDecision.reconcile(queueNext: nil, scheduledNext: nil) == .keep)
    }

    @Test func reconcileRestartsWhenNextChanged() {
        #expect(SchedulingDecision.reconcile(queueNext: c, scheduledNext: b) == .restartCurrent)
        #expect(SchedulingDecision.reconcile(queueNext: nil, scheduledNext: b) == .restartCurrent)
    }

    @Test func reconcileWithNothingScheduled() {
        #expect(SchedulingDecision.reconcile(queueNext: b, scheduledNext: nil) == .scheduleNext)
    }
}
