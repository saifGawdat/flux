import Foundation

public enum DownloadStatus: String, Codable, Sendable, CaseIterable {
    case queued, connecting, downloading, paused, completed, failed, cancelled

    /// A connection is (or is about to be) open.
    public var isActive: Bool { self == .connecting || self == .downloading }
    public var canPause: Bool { isActive || self == .queued }
    public var canResume: Bool { self == .paused || self == .failed || self == .cancelled }
    public var canCancel: Bool { self != .completed && self != .cancelled }
}

public enum DownloadPriority: Int, Codable, Sendable, CaseIterable, Comparable {
    case low = -1, normal = 0, high = 1

    public var title: String {
        switch self {
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        }
    }

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// A contiguous byte range of the remote file, fetched by one connection.
public struct Segment: Codable, Sendable, Equatable {
    public var start: Int64
    /// Inclusive end offset. `Int64.max` means "until the server closes" (unknown size).
    public var end: Int64
    /// Bytes already written, counted from `start`.
    public var received: Int64

    public init(start: Int64, end: Int64, received: Int64 = 0) {
        self.start = start
        self.end = end
        self.received = received
    }

    public var isOpenEnded: Bool { end == .max }
    public var offset: Int64 { start + received }
    public var remaining: Int64 { isOpenEnded ? .max : max(0, end - offset + 1) }
    public var isComplete: Bool { remaining == 0 }
}

public struct DownloadRecord: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var url: URL
    public var fileName: String
    /// The user chose the name, so server-suggested names must not replace it.
    public var userNamedFile: Bool
    public var directory: URL
    public var totalBytes: Int64?
    public var supportsRanges: Bool
    public var etag: String?
    public var lastModified: String?
    public var segments: [Segment]
    public var status: DownloadStatus
    public var errorMessage: String?
    public var priority: DownloadPriority
    public var maxConnections: Int
    public var partFileName: String?
    public var finalPath: URL?
    public var createdAt: Date
    public var completedAt: Date?

    public init(
        id: UUID = UUID(),
        url: URL,
        directory: URL,
        fileName: String? = nil,
        maxConnections: Int = 8,
        priority: DownloadPriority = .normal,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.url = url
        self.fileName = FileNaming.sanitize(fileName ?? FileNaming.fileName(from: url))
        self.userNamedFile = fileName != nil
        self.directory = directory
        self.totalBytes = nil
        self.supportsRanges = false
        self.segments = []
        self.status = .queued
        self.priority = priority
        self.maxConnections = max(1, maxConnections)
        self.createdAt = createdAt
    }

    public var receivedBytes: Int64 { segments.reduce(0) { $0 + $1.received } }

    public var fractionCompleted: Double? {
        if status == .completed { return 1 }
        guard let total = totalBytes, total > 0 else { return nil }
        return min(1, Double(receivedBytes) / Double(total))
    }

    public var partFileURL: URL? { partFileName.map { directory.appendingPathComponent($0) } }

    public var sourceHost: String { url.host() ?? url.absoluteString }
}
