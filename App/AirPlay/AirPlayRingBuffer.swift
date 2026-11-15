// AirPlay audio sender for Soundcheck.
//
// A single-producer, single-consumer ring of 16-bit stereo frames indexed by absolute stream
// position. The producer (a real-time audio thread) only copies and does atomic stores; the
// consumer (the session's sender thread) reads whatever part of a packet has arrived and gets
// silence for the rest.

import Foundation
import Synchronization

final class AirPlayRingBuffer: @unchecked Sendable {
    /// Frames held (2^18 ≈ 5.9 s at 44.1 kHz). Producers may write up to this far ahead of what's
    /// being sent.
    static let capacity = 1 << 18
    /// Gaps up to this long are filled with silence; longer jumps restart the buffer.
    private static let maxGapFill: UInt64 = 44_100

    private let storage: UnsafeMutablePointer<Int16>
    private let mask = UInt64(AirPlayRingBuffer.capacity - 1)
    /// Frames in [validStart, writeEnd) hold audio (or gap silence). Written by the producer only.
    private let validStart = Atomic<UInt64>(0)
    private let writeEnd = Atomic<UInt64>(0)

    init() {
        storage = .allocate(capacity: Self.capacity * 2)
        storage.initialize(repeating: 0, count: Self.capacity * 2)
    }

    deinit { storage.deallocate() }

    /// Copies frames in, wrapping around the ring.
    private func copyIn(_ source: UnsafePointer<Int16>?, frames: Int, at position: UInt64) {
        var done = 0
        while done < frames {
            let slot = Int((position + UInt64(done)) & mask)
            let run = min(frames - done, Self.capacity - slot)
            if let source {
                (storage + slot * 2).update(from: source + done * 2, count: run * 2)
            } else {
                (storage + slot * 2).update(repeating: 0, count: run * 2)
            }
            done += run
        }
    }

    /// Producer side. Real-time safe: no locks or allocation (at most a bounded memset).
    func write(_ samples: UnsafePointer<Int16>, frames: Int, position: UInt64) {
        guard frames > 0 else { return }
        var source = samples
        var count = frames
        var start = position
        if count > Self.capacity {
            let skip = count - Self.capacity
            source += skip * 2
            start += UInt64(skip)
            count = Self.capacity
        }
        let end = writeEnd.load(ordering: .relaxed)
        var valid = validStart.load(ordering: .relaxed)
        if end == valid {
            valid = start // empty: start here
        } else if start > end {
            let gap = start - end
            if gap <= Self.maxGapFill { copyIn(nil, frames: Int(gap), at: end) } else { valid = start }
        } else if start < valid {
            valid = start // rewound past what's held: start over
        }
        copyIn(source, frames: count, at: start)
        let newEnd = start + UInt64(count)
        if newEnd > UInt64(Self.capacity) { valid = max(valid, newEnd - UInt64(Self.capacity)) }
        validStart.store(valid, ordering: .releasing)
        writeEnd.store(newEnd, ordering: .releasing)
    }

    /// Consumer side: fills `frames` frames from `position` into `destination`, with silence for
    /// any that haven't been written (or were overwritten). Returns how many were real audio.
    @discardableResult
    func read(into destination: UnsafeMutablePointer<Int16>, frames: Int, position: UInt64) -> Int {
        destination.update(repeating: 0, count: frames * 2)
        let end = writeEnd.load(ordering: .acquiring)
        let valid = validStart.load(ordering: .acquiring)
        let lo = max(position, valid)
        let hi = min(position + UInt64(frames), end)
        guard lo < hi else { return 0 }
        var done = lo
        while done < hi {
            let slot = Int(done & mask)
            let run = min(Int(hi - done), Self.capacity - slot)
            (destination + Int(done - position) * 2).update(from: storage + slot * 2, count: run * 2)
            done += UInt64(run)
        }
        // If the producer lapped us while copying, those frames are garbage: silence them.
        let endAfter = writeEnd.load(ordering: .acquiring)
        if endAfter > UInt64(Self.capacity) {
            let oldest = endAfter - UInt64(Self.capacity)
            if lo < oldest {
                let bad = min(hi, oldest) - lo
                (destination + Int(lo - position) * 2).update(repeating: 0, count: Int(bad) * 2)
                return Int(hi - lo - bad)
            }
        }
        return Int(hi - lo)
    }
}
