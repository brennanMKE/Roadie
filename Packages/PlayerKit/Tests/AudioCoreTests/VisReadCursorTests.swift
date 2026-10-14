import Testing
@testable import AudioCore

@Suite struct VisReadCursorTests {
    let rate = 48_000.0
    let dt = 1.0 / 60
    let window = 1024
    let readable = 24_576

    /// 3 s of ticks with 4800-sample deliveries every 6 ticks. Returns (writeCount, end) per tick.
    func simulate(seconds: Double = 3) -> [(write: Int, end: Int)] {
        var cursor = VisReadCursor(window: window, readable: readable)
        var write = 0
        var out: [(Int, Int)] = []
        for tick in 0..<Int(seconds * 60) {
            if tick % 6 == 0 { write += 4800 }
            if let end = cursor.next(writeCount: write, elapsed: dt, sampleRate: rate) { out.append((write, end)) }
        }
        return out
    }

    @Test func returnsNilUntilWindowFilled() {
        var cursor = VisReadCursor(window: window, readable: readable)
        #expect(cursor.next(writeCount: 1000, elapsed: dt, sampleRate: rate) == nil)
        #expect(cursor.next(writeCount: 1024, elapsed: dt, sampleRate: rate) == 1024)
    }

    @Test func steadyTicksYieldDistinctAdvancingWindows() {
        let ticks = simulate()
        let steady = ticks.dropFirst(30)   // 0.5 s warm-up covers learning the delivery size
        var previous: Int?
        for (write, end) in steady {
            #expect(end <= write)
            #expect(end >= write - readable + window)
            if let previous {
                #expect(end > previous)
                #expect((799...801).contains(end - previous))
            }
            previous = end
        }
        #expect(Set(steady.map(\.end)).count == steady.count)
    }

    @Test func cursorNeverRunsDry() {
        for (write, end) in simulate().dropFirst(30) { #expect(write - end > 0) }
    }

    @Test func largestDeliveryTracksBursts() {
        var cursor = VisReadCursor(window: window, readable: readable)
        _ = cursor.next(writeCount: 1024, elapsed: dt, sampleRate: rate)
        _ = cursor.next(writeCount: 2048, elapsed: dt, sampleRate: rate)
        #expect(cursor.largestDelivery == 1024)
        let before = cursor.next(writeCount: 2048, elapsed: dt, sampleRate: rate)!
        let after = cursor.next(writeCount: 6848, elapsed: dt, sampleRate: rate)!
        #expect(cursor.largestDelivery == 4800)
        // The lag grows to cover the bigger delivery.
        #expect(after - before < 800 + 4800)
        #expect(6848 - after >= 4800)
    }

    @Test func resyncsAfterUITimeStall() {
        var cursor = VisReadCursor(window: window, readable: readable)
        var write = 0
        for tick in 0..<120 {
            if tick % 6 == 0 { write += 4800 }
            _ = cursor.next(writeCount: write, elapsed: dt, sampleRate: rate)
        }
        let lag = min(cursor.largestDelivery + Int(cursor.slackSeconds * rate), readable - window)
        write += 4800   // audio kept flowing while the main thread stalled for a second
        let resumed = cursor.next(writeCount: write, elapsed: 1.0, sampleRate: rate)!
        #expect(resumed == write - lag)
        #expect(resumed != write)
        let following = cursor.next(writeCount: write, elapsed: dt, sampleRate: rate)!
        #expect(following - resumed == 800)
    }

    @Test func stalledAudioRepeatsNewestWindow() {
        var cursor = VisReadCursor(window: window, readable: readable)
        var write = 0
        for tick in 0..<120 {
            if tick % 6 == 0 { write += 4800 }
            _ = cursor.next(writeCount: write, elapsed: dt, sampleRate: rate)
        }
        var ends: [Int] = []
        for _ in 0..<60 { ends.append(cursor.next(writeCount: write, elapsed: dt, sampleRate: rate)!) }
        #expect(ends.suffix(20).allSatisfy { $0 == write })
    }
}
