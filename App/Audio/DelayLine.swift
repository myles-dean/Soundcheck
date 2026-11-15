import Foundation

/// Holds a stream back by a fixed number of frames (interleaved, the first two channels), so a
/// quicker speaker plays together with a slower one. Made off the audio thread, with `release()`
/// to free it; `process` doesn't allocate or lock.
struct DelayLine {
    let frames: Int
    private let size: Int
    private let buffer: UnsafeMutablePointer<Float>?
    private var written = 0

    init(frames: Int, maxBlock: Int) {
        self.frames = max(frames, 0)
        var size = 1
        while size < self.frames + maxBlock { size <<= 1 }
        self.size = size
        if self.frames > 0 {
            buffer = .allocate(capacity: size * 2)
            buffer?.initialize(repeating: 0, count: size * 2)
        } else {
            buffer = nil
        }
    }

    func release() { buffer?.deallocate() }

    mutating func process(_ data: UnsafeMutablePointer<Float>, frames count: Int, channels: Int) {
        guard let buffer, frames > 0 else { return }
        let mask = size - 1
        for frame in 0..<count {
            let slot = (written & mask) * 2
            let read = ((written - frames) & mask) * 2
            let index = frame * channels
            buffer[slot] = data[index]
            buffer[slot + 1] = channels > 1 ? data[index + 1] : data[index]
            data[index] = buffer[read]
            if channels > 1 { data[index + 1] = buffer[read + 1] }
            written += 1
        }
    }
}
