import Foundation

enum Format {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

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
}
