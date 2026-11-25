import Foundation

/// Bytes received from one site during one minute.
public struct TrafficSample: Codable, Sendable, Equatable, Hashable {
    /// Start of the minute, in whole minutes since 1970.
    public var minute: Int64
    public var host: String
    public var bytes: Int64

    public init(minute: Int64, host: String, bytes: Int64) {
        self.minute = minute
        self.host = host
        self.bytes = bytes
    }

    public init(date: Date, host: String, bytes: Int64) {
        self.init(minute: Self.minute(of: date), host: host, bytes: bytes)
    }

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(minute * 60)) }

    public static func minute(of date: Date) -> Int64 { Int64((date.timeIntervalSince1970 / 60).rounded(.down)) }
}

/// Turns download progress into per-minute traffic. Only bytes received while watching
/// count: the first update of a download, and a download that starts over, set a baseline.
public struct TrafficMeter: Sendable {
    private var lastReceived: [UUID: Int64] = [:]
    private var buckets: [MinuteHost: Int64] = [:]

    private struct MinuteHost: Hashable, Sendable {
        var minute: Int64
        var host: String
    }

    public init() {}

    public mutating func observe(_ record: DownloadRecord, at date: Date = Date()) {
        let received = record.receivedBytes
        defer { lastReceived[record.id] = received }
        guard let last = lastReceived[record.id], received > last else { return }
        let key = MinuteHost(minute: TrafficSample.minute(of: date), host: Self.site(of: record))
        buckets[key, default: 0] += received - last
    }

    public mutating func forget(_ ids: some Sequence<UUID>) {
        for id in ids { lastReceived[id] = nil }
    }

    /// The traffic gathered since the last drain.
    public mutating func drain() -> [TrafficSample] {
        defer { buckets = [:] }
        return buckets.map { TrafficSample(minute: $0.key.minute, host: $0.key.host, bytes: $0.value) }
            .sorted { ($0.minute, $0.host) < ($1.minute, $1.host) }
    }

    /// The site a download counts for: the page it came from, else the link's host,
    /// without "www.".
    public static func site(of record: DownloadRecord) -> String {
        site(of: record.referer ?? record.url)
    }

    public static func site(of url: URL) -> String {
        let host = url.host()?.lowercased() ?? "other"
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// The figures behind the Statistics view and `flux stats`.
public struct Statistics: Sendable, Equatable {
    public enum Period: String, CaseIterable, Identifiable, Sendable, Codable {
        case day, week, month

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .day: "24 Hours"
            case .week: "7 Days"
            case .month: "30 Days"
            }
        }

        /// Bars on the chart: hours for a day, days otherwise.
        public var bucket: Calendar.Component { self == .day ? .hour : .day }
        public var bucketCount: Int {
            switch self {
            case .day: 24
            case .week: 7
            case .month: 30
            }
        }
    }

    public struct Bar: Sendable, Equatable, Identifiable {
        public var start: Date
        public var bytes: Int64
        public var id: Date { start }
    }

    public struct Site: Sendable, Equatable, Identifiable {
        public var host: String
        /// Received during the period.
        public var bytes: Int64
        public var finished: Int
        public var failed: Int
        public var id: String { host }
    }

    public struct Kind: Sendable, Equatable, Identifiable {
        public var category: FileCategory
        public var files: Int
        public var bytes: Int64
        public var id: FileCategory { category }
    }

    public var period: Period
    public var start: Date
    public var bars: [Bar]
    public var totalBytes: Int64
    public var finished: Int
    public var failed: Int
    /// Fastest minute, in bytes per second.
    public var peakSpeed: Double
    public var sites: [Site]
    public var kinds: [Kind]

    /// Finished vs failed among downloads that stopped in the period; nil if none did.
    public var successRate: Double? {
        finished + failed == 0 ? nil : Double(finished) / Double(finished + failed)
    }

    public init(period: Period, records: [DownloadRecord], traffic: [TrafficSample],
                now: Date = Date(), calendar: Calendar = .current) {
        self.period = period
        // Bars end with the current hour or day.
        let currentBucket = calendar.dateInterval(of: period.bucket, for: now)?.start ?? now
        let starts = (0..<period.bucketCount).reversed().compactMap {
            calendar.date(byAdding: period.bucket, value: -$0, to: currentBucket)
        }
        let start = starts.first ?? now
        self.start = start
        let startMinute = TrafficSample.minute(of: start)
        let inPeriod = traffic.filter { $0.minute >= startMinute }

        var bytesPerBar = [Date: Int64]()
        var perMinute = [Int64: Int64]()
        var siteBytes = [String: Int64]()
        for sample in inPeriod {
            let bucket = calendar.dateInterval(of: period.bucket, for: sample.date)?.start ?? sample.date
            bytesPerBar[bucket, default: 0] += sample.bytes
            perMinute[sample.minute, default: 0] += sample.bytes
            siteBytes[sample.host, default: 0] += sample.bytes
        }
        bars = starts.map { Bar(start: $0, bytes: bytesPerBar[$0] ?? 0) }
        totalBytes = inPeriod.reduce(0) { $0 + $1.bytes }
        peakSpeed = Double(perMinute.values.max() ?? 0) / 60

        let stopped = records.filter { record in
            guard record.status == .completed || record.status == .failed else { return false }
            // Failed downloads have no completion date; when they were added stands in.
            return (record.completedAt ?? record.createdAt) >= start
        }
        let done = stopped.filter { $0.status == .completed }
        finished = done.count
        failed = stopped.count - done.count

        var sites = [String: Site]()
        for (host, bytes) in siteBytes { sites[host] = Site(host: host, bytes: bytes, finished: 0, failed: 0) }
        for record in stopped {
            let host = TrafficMeter.site(of: record)
            var site = sites[host] ?? Site(host: host, bytes: 0, finished: 0, failed: 0)
            if record.status == .completed { site.finished += 1 } else { site.failed += 1 }
            sites[host] = site
        }
        self.sites = sites.values.sorted { ($0.bytes, $0.finished, $1.host) > ($1.bytes, $1.finished, $0.host) }

        var kinds = [FileCategory: Kind]()
        for record in done {
            var kind = kinds[record.category] ?? Kind(category: record.category, files: 0, bytes: 0)
            kind.files += 1
            kind.bytes += record.totalBytes ?? record.receivedBytes
            kinds[record.category] = kind
        }
        self.kinds = kinds.values.sorted { ($0.bytes, $1.category.rawValue) > ($1.bytes, $0.category.rawValue) }
    }
}
