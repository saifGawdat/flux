import Foundation

enum Format {
    static func bytes(_ n: Int64) -> String {
        byteFormatter.string(fromByteCount: n)
    }

    /// "0 KB", not "Zero KB".
    // Configured once, then only read; formatting is thread-safe.
    nonisolated(unsafe) private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    static func speed(_ bytesPerSecond: Double) -> String {
        bytes(Int64(bytesPerSecond)) + "/s"
    }

    /// "1 MB/s", or "Unlimited".
    static func limit(_ bytesPerSecond: Int64?) -> String {
        bytesPerSecond.map { bytes($0) + "/s" } ?? "Unlimited"
    }

    /// "1,234,567,890 bytes"
    static func exactBytes(_ n: Int64) -> String {
        n.formatted(.number) + (n == 1 ? " byte" : " bytes")
    }

    /// "4:05" or "1:02:03".
    static func clock(_ seconds: Double) -> String {
        Duration.seconds(seconds.rounded()).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    static func duration(_ seconds: Double) -> String {
        Duration.seconds(seconds.rounded()).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }

    /// "at 02:00", "tomorrow at 02:00", "Friday at 02:00".
    static func when(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "at \(time)" }
        if calendar.isDateInTomorrow(date) { return "tomorrow at \(time)" }
        return "\(date.formatted(.dateTime.weekday(.wide))) at \(time)"
    }

}
