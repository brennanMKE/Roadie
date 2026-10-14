import CAtomics
import Foundation

/// Single-producer / single-consumer ring of mono samples. All storage is allocated in `init`;
/// `write` neither allocates nor locks. One monotonic counter is the only shared word.
public final class VisSampleRing: @unchecked Sendable {
    public let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    /// Total samples written, published with release / read with acquire.
    private let counter: UnsafeMutablePointer<Int64>
    /// Producer-private copy of the counter.
    private var produced: Int = 0

    /// `capacity` is rounded up to a power of two.
    public init(capacity: Int = 16_384) {
        var c = 2
        while c < capacity { c <<= 1 }
        self.capacity = c
        mask = c - 1
        storage = .allocate(capacity: c)
        storage.initialize(repeating: 0, count: c)
        counter = .allocate(capacity: 1)
        counter.initialize(to: 0)
    }

    deinit {
        storage.deallocate()
        counter.deallocate()
    }

    /// Monotonic total of samples written.
    public var writeCount: Int { Int(ca_load_acquire(counter)) }

    /// Largest span the producer writes before publishing the counter, so an unpublished write is
    /// never more than this far ahead of `writeCount`.
    public var maxChunk: Int { capacity / 4 }

    /// Producer thread only. Data is published in slices of at most `maxChunk`. A write larger than
    /// `capacity` keeps just its tail (the dropped head is never written; do not rely on reading it).
    public func write(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        var src = samples
        var n = count
        if n > capacity {
            let skip = n - capacity
            src += skip
            produced += skip
            n = capacity
        }
        let chunk = maxChunk
        while n > 0 {
            let len = min(n, chunk)
            let index = produced & mask
            let first = min(len, capacity - index)
            memcpy(storage + index, src, first * MemoryLayout<Float>.stride)
            if len > first {
                memcpy(storage, src + first, (len - first) * MemoryLayout<Float>.stride)
            }
            produced += len
            ca_store_release(counter, Int64(produced))
            src += len
            n -= len
        }
    }

    /// True if the region starting at `begin` cannot have been touched by the producer, given the
    /// current published count plus at most one in-flight slice.
    func isIntact(begin: Int) -> Bool {
        writeCount - begin <= capacity - maxChunk
    }

    /// Consumer thread only. Copies the newest `count` samples (oldest first) into `out`.
    /// Returns false if fewer than `count` exist yet, `count` exceeds `capacity - maxChunk`, or the
    /// producer may have overwritten the region during the copy (torn read); the caller keeps its
    /// previous frame.
    @discardableResult
    public func copyLatest(count: Int, into out: UnsafeMutablePointer<Float>) -> Bool {
        copy(count: count, endingAt: writeCount, into: out)
    }

    /// Consumer thread only. Copies `count` samples ending at absolute index `end` (exclusive), oldest first.
    /// False if `end > writeCount`, `end < count`, `count > capacity - maxChunk`, or the region may have
    /// been overwritten during the copy (same check as `copyLatest`).
    @discardableResult
    public func copy(count: Int, endingAt end: Int, into out: UnsafeMutablePointer<Float>) -> Bool {
        guard count > 0, count <= capacity - maxChunk else { return false }
        guard end >= count, end <= writeCount else { return false }
        let begin = end - count
        let index = begin & mask
        let first = min(count, capacity - index)
        memcpy(out, storage + index, first * MemoryLayout<Float>.stride)
        if count > first {
            memcpy(out + first, storage, (count - first) * MemoryLayout<Float>.stride)
        }
        ca_fence_acquire()
        return isIntact(begin: begin)
    }
}
