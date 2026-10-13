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

    /// Producer thread only. A write larger than `capacity` keeps just its tail.
    public func write(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        var src = samples
        var n = count
        var start = produced
        if n > capacity {
            let skip = n - capacity
            src += skip
            start += skip
            n = capacity
        }
        let index = start & mask
        let first = min(n, capacity - index)
        memcpy(storage + index, src, first * MemoryLayout<Float>.stride)
        if n > first {
            memcpy(storage, src + first, (n - first) * MemoryLayout<Float>.stride)
        }
        produced += count
        ca_store_release(counter, Int64(produced))
    }

    /// Consumer thread only. Copies the newest `count` samples (oldest first) into `out`.
    /// Returns false if fewer than `count` exist yet or the producer overwrote the region
    /// during the copy (torn read); the caller keeps its previous frame.
    @discardableResult
    public func copyLatest(count: Int, into out: UnsafeMutablePointer<Float>) -> Bool {
        guard count > 0, count <= capacity else { return false }
        let end = writeCount
        guard end >= count else { return false }
        let begin = end - count
        let index = begin & mask
        let first = min(count, capacity - index)
        memcpy(out, storage + index, first * MemoryLayout<Float>.stride)
        if count > first {
            memcpy(out + first, storage, (count - first) * MemoryLayout<Float>.stride)
        }
        return writeCount - begin <= capacity
    }
}
