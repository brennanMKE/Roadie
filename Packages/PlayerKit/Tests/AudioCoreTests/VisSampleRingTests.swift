import Testing
@testable import AudioCore

@Suite struct VisSampleRingTests {
    func write(_ ring: VisSampleRing, _ values: [Float]) {
        values.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: $0.count) }
    }

    func latest(_ ring: VisSampleRing, _ n: Int) -> [Float]? {
        var out = [Float](repeating: -1, count: n)
        let ok = out.withUnsafeMutableBufferPointer { ring.copyLatest(count: n, into: $0.baseAddress!) }
        return ok ? out : nil
    }

    @Test func wraparoundKeepsOrder() {
        let ring = VisSampleRing(capacity: 2048)
        #expect(latest(ring, 1024) == nil)
        var next = 0
        for chunk in [100, 1024, 4096, 100, 1024, 656] {
            write(ring, (next..<(next + chunk)).map(Float.init))
            next += chunk
        }
        #expect(next == 7000)
        #expect(ring.writeCount == 7000)
        #expect(latest(ring, 1024) == (5976..<7000).map(Float.init))
    }

    @Test func tooFewSamplesReturnsFalse() {
        let ring = VisSampleRing(capacity: 2048)
        write(ring, [Float](repeating: 1, count: 1023))
        #expect(latest(ring, 1024) == nil)
        write(ring, [1])
        #expect(latest(ring, 1024) != nil)
    }

    @Test func oversizedWriteKeepsTail() {
        let ring = VisSampleRing(capacity: 1024)
        write(ring, (0..<3000).map(Float.init))
        #expect(ring.writeCount == 3000)
        #expect(latest(ring, 768) == (2232..<3000).map(Float.init))
    }

    @Test func tornReadBoundaryIsCapacityMinusMaxChunk() {
        let ring = VisSampleRing(capacity: 1024)
        #expect(ring.maxChunk == 256)
        write(ring, [Float](repeating: 1, count: 512))
        #expect(ring.isIntact(begin: 0))
        write(ring, [Float](repeating: 1, count: 256))
        #expect(ring.writeCount == 768)
        #expect(ring.isIntact(begin: 0))
        write(ring, [1])
        #expect(!ring.isIntact(begin: 0))
        // A request larger than capacity - maxChunk is refused outright.
        #expect(latest(ring, 769) == nil)
        #expect(latest(ring, 768) != nil)
    }

    func ending(_ ring: VisSampleRing, _ n: Int, at end: Int) -> [Float]? {
        var out = [Float](repeating: -1, count: n)
        let ok = out.withUnsafeMutableBufferPointer { ring.copy(count: n, endingAt: end, into: $0.baseAddress!) }
        return ok ? out : nil
    }

    @Test func copyEndingAtReadsOlderRegion() {
        let ring = VisSampleRing(capacity: 8192)
        var next = 0
        for chunk in [1000, 2500, 999, 2501] {
            write(ring, (next..<(next + chunk)).map(Float.init))
            next += chunk
        }
        #expect(next == 7000)
        #expect(ending(ring, 1024, at: 5000) == (3976..<5000).map(Float.init))
    }

    @Test func copyEndingAtRejectsFutureAndTooShort() {
        let ring = VisSampleRing(capacity: 8192)
        write(ring, (0..<3000).map(Float.init))
        #expect(ending(ring, 1024, at: 3001) == nil)
        #expect(ending(ring, 1024, at: 1000) == nil)
        #expect(ending(ring, 1024, at: 3000) != nil)
    }

    @Test func copyEndingAtDetectsOverwrite() {
        let ring = VisSampleRing(capacity: 2048)   // maxChunk 512, readable 1536
        write(ring, (0..<4000).map(Float.init))
        #expect(ending(ring, 1024, at: 3500) == (2476..<3500).map(Float.init))
        #expect(ending(ring, 1024, at: 2400) == nil)
    }

    @Test func copyLatestStillMatchesCopyEndingAtWriteCount() {
        let ring = VisSampleRing(capacity: 4096)
        write(ring, (0..<5000).map(Float.init))
        #expect(latest(ring, 1024) == ending(ring, 1024, at: ring.writeCount))
    }
}
