import Foundation

public enum Segmenter {
    /// Splits the unfinished segment with the most bytes left in half so another
    /// connection can take the back half. Returns the new segment's index, or nil
    /// when nothing is large enough to be worth splitting.
    @discardableResult
    public static func splitLargest(_ segments: inout [Segment], minPieceSize: Int64) -> Int? {
        var best: Int?
        for i in segments.indices where !segments[i].isComplete && !segments[i].isOpenEnded {
            if let b = best, segments[b].remaining >= segments[i].remaining { continue }
            best = i
        }
        guard let index = best else { return nil }
        let seg = segments[index]
        let remaining = seg.remaining
        guard remaining >= 2 * max(1, minPieceSize) else { return nil }
        let newStart = seg.offset + remaining / 2
        segments[index].end = newStart - 1
        segments.append(Segment(start: newStart, end: seg.end))
        return segments.count - 1
    }

    /// True when the segments are all complete and tile `[0, total)` exactly —
    /// no gaps, no overlaps. Checked before a part file becomes the final file.
    public static func coversExactly(_ segments: [Segment], total: Int64) -> Bool {
        if total == 0 { return segments.allSatisfy(\.isComplete) }
        let sorted = segments.filter { $0.end >= $0.start }.sorted { $0.start < $1.start }
        var next: Int64 = 0
        for seg in sorted {
            guard seg.isComplete, seg.start == next else { return false }
            next = seg.end + 1
        }
        return next == total
    }
}

/// Rolling-window throughput estimate.
struct SpeedMeter {
    private var samples: [(time: TimeInterval, bytes: Int64)] = []
    private var pending: Int64 = 0
    private var startedAt: TimeInterval?
    let window: TimeInterval

    init(window: TimeInterval = 4) { self.window = window }

    mutating func add(_ bytes: Int64) { pending += bytes }

    mutating func tick(now: TimeInterval, interval: TimeInterval) -> Double {
        let started = startedAt ?? (now - interval)
        startedAt = started
        samples.append((now, pending))
        pending = 0
        samples.removeAll { now - $0.time >= window }
        let span = min(window, now - started)
        guard span > 0 else { return 0 }
        return Double(samples.reduce(0) { $0 + $1.bytes }) / span
    }

    mutating func reset() {
        samples.removeAll()
        pending = 0
        startedAt = nil
    }
}
