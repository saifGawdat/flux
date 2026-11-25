import Foundation
import os

/// A token bucket that any number of downloads draw from. Flux keeps one for the global
/// limit (shared by every running download) and one per download that has its own limit.
///
/// Callers report bytes *after* reading them and get back how long to wait before reading
/// more. The bucket may go into debt, so several connections reading at once all wait
/// their turn and the long-run average never exceeds the limit.
public final class SpeedLimiter: Sendable {
    private struct State {
        var rate: Double?
        var tokens: Double = 0
        var last: TimeInterval?
    }

    private let state: OSAllocatedUnfairLock<State>
    private let clock: @Sendable () -> TimeInterval

    /// - Parameter bytesPerSecond: nil means unlimited.
    public init(bytesPerSecond: Int64? = nil, clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
        state = OSAllocatedUnfairLock(initialState: State(rate: Self.rate(bytesPerSecond)))
    }

    public var bytesPerSecond: Int64? { state.withLock { $0.rate.map { Int64($0) } } }

    public func setLimit(_ bytesPerSecond: Int64?) {
        let rate = Self.rate(bytesPerSecond)
        state.withLock { s in
            guard s.rate != rate else { return }
            s.rate = rate
            // Start the new limit with an empty bucket and no debt.
            s.tokens = 0
            s.last = nil
        }
    }

    /// Takes `bytes` from the bucket and returns how many seconds to pause reading.
    @discardableResult
    public func consume(_ bytes: Int64) -> TimeInterval {
        let now = clock()
        return state.withLock { s in
            guard let rate = s.rate else { return 0 }
            Self.refill(&s, rate: rate, now: now)
            s.tokens -= Double(bytes)
            return s.tokens < 0 ? -s.tokens / rate : 0
        }
    }

    /// Seconds until the bucket is out of debt, without taking anything.
    public func delay() -> TimeInterval {
        let now = clock()
        return state.withLock { s in
            guard let rate = s.rate else { return 0 }
            Self.refill(&s, rate: rate, now: now)
            return s.tokens < 0 ? -s.tokens / rate : 0
        }
    }

    private static func refill(_ s: inout State, rate: Double, now: TimeInterval) {
        // A small burst allowance keeps the flow smooth without letting it run ahead.
        let capacity = max(rate * 0.25, 16 * 1024)
        if let last = s.last {
            s.tokens = min(capacity, s.tokens + rate * max(0, now - last))
        }
        s.last = now
    }

    private static func rate(_ bytesPerSecond: Int64?) -> Double? {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return nil }
        return Double(bytesPerSecond)
    }
}

extension Array where Element == SpeedLimiter {
    /// Charges every limiter; the slowest one decides the wait.
    func consume(_ bytes: Int64) -> TimeInterval {
        reduce(0) { Swift.max($0, $1.consume(bytes)) }
    }

    func delay() -> TimeInterval {
        reduce(0) { Swift.max($0, $1.delay()) }
    }

    /// The tightest limit in effect, if any.
    var tightestLimit: Int64? { compactMap(\.bytesPerSecond).min() }
}
