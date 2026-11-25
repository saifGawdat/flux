import Foundation

/// A named queue: downloads that wait until the queue is started, by hand or on a
/// schedule. Downloads without a queue are in the main queue, which always runs.
public struct DownloadQueue: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    /// How many of this queue's downloads may run at once; nil = only the overall limit.
    public var maxConcurrent: Int?
    /// Starts (and optionally stops) the queue automatically.
    public var schedule: QueueSchedule?
    /// Whether the queue is started. Owned by the manager: changed by Start/Stop and by the
    /// schedule, never by editing settings.
    public var isRunning: Bool

    public init(id: UUID = UUID(), name: String, maxConcurrent: Int? = nil, schedule: QueueSchedule? = nil, isRunning: Bool = false) {
        self.id = id
        self.name = name
        self.maxConcurrent = maxConcurrent
        self.schedule = schedule
        self.isRunning = isRunning
    }

    public static let concurrencyChoices = [1, 2, 3, 5]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Queue"
        maxConcurrent = try c.decodeIfPresent(Int.self, forKey: .maxConcurrent)
        schedule = try? c.decodeIfPresent(QueueSchedule.self, forKey: .schedule)
        isRunning = try c.decodeIfPresent(Bool.self, forKey: .isRunning) ?? false
    }
}

/// When a queue starts and stops by itself.
public struct QueueSchedule: Codable, Sendable, Equatable, Hashable {
    /// Weekdays the queue starts on, using `Calendar` numbering: 1 = Sunday … 7 = Saturday.
    public var days: Set<Int>
    /// Start time, minutes after midnight.
    public var start: Int
    /// Stop time, minutes after midnight. At or before `start` means the next day.
    /// nil = keep going until everything in the queue has finished.
    public var stop: Int?

    public static let everyDay: Set<Int> = Set(1...7)

    public init(days: Set<Int> = QueueSchedule.everyDay, start: Int, stop: Int? = nil) {
        self.days = days.filter { (1...7).contains($0) }
        self.start = Self.clampMinute(start)
        self.stop = stop.map(Self.clampMinute)
    }

    private static func clampMinute(_ minute: Int) -> Int { min(max(minute, 0), 24 * 60 - 1) }

    public enum Change: Sendable, Equatable {
        case start, stop
    }

    /// Scheduled starts and stops in the half-open interval (from, to], oldest first.
    public func changes(from: Date, to: Date, calendar: Calendar = .current) -> [(date: Date, change: Change)] {
        guard to > from, !days.isEmpty else { return [] }
        var result: [(Date, Change)] = []
        // A window that began the day before can stop inside the interval.
        guard var day = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: from)) else { return [] }
        let lastDay = calendar.startOfDay(for: to)
        while day <= lastDay {
            if days.contains(calendar.component(.weekday, from: day)) {
                let startDate = Self.time(start, on: day, calendar: calendar)
                if let startDate, startDate > from, startDate <= to { result.append((startDate, .start)) }
                if let stop, let startDate {
                    let stopDay = stop > start ? day : (calendar.date(byAdding: .day, value: 1, to: day) ?? day)
                    if let stopDate = Self.time(stop, on: stopDay, calendar: calendar), stopDate > startDate,
                       stopDate > from, stopDate <= to {
                        result.append((stopDate, .stop))
                    }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result.sorted { $0.0 < $1.0 }
    }

    /// True inside a start–stop window. Always false without a stop time: such a queue
    /// is started by its start time and then runs until it's empty or stopped.
    public func isInsideWindow(at date: Date, calendar: Calendar = .current) -> Bool {
        guard stop != nil, let weekAgo = calendar.date(byAdding: .day, value: -8, to: date) else { return false }
        return changes(from: weekAgo, to: date, calendar: calendar).last?.change == .start
    }

    /// The next scheduled start or stop after `date`.
    public func next(after date: Date, calendar: Calendar = .current) -> (date: Date, change: Change)? {
        guard let horizon = calendar.date(byAdding: .day, value: 8, to: date) else { return nil }
        return changes(from: date, to: horizon, calendar: calendar).first
    }

    private static func time(_ minute: Int, on day: Date, calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day)
    }
}

extension QueueSchedule {
    /// "Every day 2:00 AM–6:00 AM", "Weekdays at 01:30" (times in the user's format).
    public var summary: String {
        let when = stop.map { "\(Self.time(start))–\(Self.time($0))" } ?? "at \(Self.time(start))"
        return "\(Self.daysSummary(days)) \(when)"
    }

    /// Minutes after midnight as the user writes times ("2:00 AM", "02:00").
    public static func time(_ minute: Int) -> String {
        let date = Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    public static func daysSummary(_ days: Set<Int>) -> String {
        switch days {
        case everyDay: return "Every day"
        case [2, 3, 4, 5, 6]: return "Weekdays"
        case [1, 7]: return "Weekends"
        default:
            let symbols = Calendar.current.shortWeekdaySymbols
            return days.sorted().map { symbols[$0 - 1] }.joined(separator: ", ")
        }
    }
}
