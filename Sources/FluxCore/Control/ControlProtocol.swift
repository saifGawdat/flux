import Foundation

/// The `flux` command-line tool talks to the running app over a Unix domain socket: one
/// JSON object per line each way. Only the user who runs Flux can connect.
public enum ControlProtocol {
    public static let version = 1

    /// `~/Library/Application Support/Flux/control.sock`, or `$FLUX_SOCKET`.
    public static var defaultSocketURL: URL {
        if let override = ProcessInfo.processInfo.environment["FLUX_SOCKET"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flux", isDirectory: true)
            .appendingPathComponent("control.sock")
    }

    /// Requests and responses larger than this are refused.
    public static let maxMessageSize = 4 * 1024 * 1024
}

public struct ControlRequest: Codable, Sendable, Equatable {
    public enum Command: String, Codable, Sendable, CaseIterable {
        case ping, add, list, status, pause, resume, cancel, remove, limit, queues, export, stats
        case startQueue = "start-queue"
        case stopQueue = "stop-queue"
    }

    public var version: Int?
    public var command: Command
    /// Download IDs (or unique prefixes of them), "all", or a queue name.
    public var targets: [String]?
    /// Links to add.
    public var entries: [LinkListEntry]?
    /// Queue name for `add`.
    public var queue: String?
    /// `add`: don't start yet.
    public var paused: Bool?
    /// `remove`: also move finished files to the Trash.
    public var trash: Bool?
    /// `list`/`export`: include History.
    public var includeHistory: Bool?
    /// `limit`: bytes per second; 0 turns the limit off.
    public var speedLimit: Int64?
    /// `export`: file format.
    public var format: LinkListFormat?
    /// `stats`: how far back.
    public var period: Statistics.Period?

    public init(
        _ command: Command, targets: [String]? = nil, entries: [LinkListEntry]? = nil, queue: String? = nil,
        paused: Bool? = nil, trash: Bool? = nil, includeHistory: Bool? = nil, speedLimit: Int64? = nil,
        format: LinkListFormat? = nil, period: Statistics.Period? = nil
    ) {
        self.period = period
        self.version = ControlProtocol.version
        self.command = command
        self.targets = targets
        self.entries = entries
        self.queue = queue
        self.paused = paused
        self.trash = trash
        self.includeHistory = includeHistory
        self.speedLimit = speedLimit
        self.format = format
    }
}

public struct ControlResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public var error: String?
    /// One line for people ("Added 3 downloads").
    public var message: String?
    public var downloads: [DownloadSummary]?
    public var queues: [QueueSummary]?
    /// `export`: the file's contents.
    public var text: String?
    /// IDs of downloads the command created or affected.
    public var ids: [String]?
    /// The global speed limit after the command, bytes per second (nil = none).
    public var speedLimit: Int64?
    /// `stats`.
    public var stats: StatsSummary?

    public init(ok: Bool = true, error: String? = nil, message: String? = nil, downloads: [DownloadSummary]? = nil,
                queues: [QueueSummary]? = nil, text: String? = nil, ids: [String]? = nil, speedLimit: Int64? = nil,
                stats: StatsSummary? = nil) {
        self.stats = stats
        self.ok = ok
        self.error = error
        self.message = message
        self.downloads = downloads
        self.queues = queues
        self.text = text
        self.ids = ids
        self.speedLimit = speedLimit
    }

    public static func failure(_ message: String) -> ControlResponse { ControlResponse(ok: false, error: message) }
}

/// Statistics as the command line sees them.
public struct StatsSummary: Codable, Sendable, Equatable {
    public struct Site: Codable, Sendable, Equatable {
        public var host: String
        public var bytes: Int64
        public var finished: Int
        public var failed: Int
    }

    public struct Bar: Codable, Sendable, Equatable {
        public var start: Date
        public var bytes: Int64
    }

    public var period: Statistics.Period
    public var since: Date
    public var totalBytes: Int64
    public var finished: Int
    public var failed: Int
    public var peakBytesPerSecond: Double
    public var sites: [Site]
    public var bars: [Bar]

    public init(_ stats: Statistics, siteLimit: Int = 10) {
        period = stats.period
        since = stats.start
        totalBytes = stats.totalBytes
        finished = stats.finished
        failed = stats.failed
        peakBytesPerSecond = stats.peakSpeed
        sites = stats.sites.prefix(siteLimit).map { Site(host: $0.host, bytes: $0.bytes, finished: $0.finished, failed: $0.failed) }
        bars = stats.bars.map { Bar(start: $0.start, bytes: $0.bytes) }
    }
}

/// A download as the command line sees it.
public struct DownloadSummary: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var url: String
    public var status: String
    public var receivedBytes: Int64
    public var totalBytes: Int64?
    public var bytesPerSecond: Double
    public var path: String?
    public var error: String?
    public var queue: String?
    public var detail: String?
    public var inHistory: Bool

    public init(_ item: DownloadManager.Item, queueName: String?) {
        let r = item.record
        id = r.id.uuidString.lowercased()
        name = r.displayName
        url = r.url.absoluteString
        status = r.status.rawValue
        receivedBytes = r.status == .completed ? (r.totalBytes ?? r.receivedBytes) : r.receivedBytes
        totalBytes = r.totalBytes
        bytesPerSecond = item.bytesPerSecond
        path = (r.finalPath ?? r.extractedPath)?.path
        error = r.errorMessage
        queue = queueName
        detail = item.detail
        inHistory = r.isArchived
    }

    public var shortID: String { String(id.prefix(8)) }
    public var isFinished: Bool { ["completed", "failed", "cancelled"].contains(status) }
}

public struct QueueSummary: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var isMain: Bool
    public var isRunning: Bool
    public var schedule: String?
    public var waiting: Int
    public var active: Int
}

public enum ControlError: LocalizedError, Equatable {
    case notRunning
    case alreadyRunning
    case pathTooLong(String)
    case pathInUse(String)
    case system(String)
    case badResponse
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .notRunning: "Flux isn’t running."
        case .alreadyRunning: "Another copy of Flux is already accepting commands."
        case .pathTooLong(let path): "The socket path is too long: \(path)"
        case .pathInUse(let path): "Something other than Flux’s socket is at \(path)."
        case .system(let what): what
        case .badResponse: "Flux sent a reply this version of the flux tool doesn’t understand."
        case .tooLarge: "The message is too large."
        }
    }

    static func errno(_ what: String) -> ControlError {
        .system("\(what): \(String(cString: strerror(Darwin.errno)))")
    }
}
