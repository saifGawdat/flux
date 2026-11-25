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

public enum ChecksumState: Sendable, Equatable {
    /// No checksum was supplied.
    case none
    /// Checked when the download finishes.
    case pending
    case verified
    /// The finished file has a different checksum.
    case mismatch
}

/// Downloads added together from one playlist, image gallery or web page.
public struct DownloadGroup: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case playlist, images
    }

    public var id: UUID
    public var title: String
    public var kind: Kind

    public init(id: UUID = UUID(), title: String, kind: Kind) {
        self.id = id
        self.title = title
        self.kind = kind
    }
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
    public var kind: DownloadKind
    /// Output choice when `kind == .media`.
    public var mediaFormat: MediaFormat?
    /// Human title reported by the media extractor.
    public var title: String?
    /// Preview image reported by the media extractor (video thumbnail, cover art).
    public var thumbnailURL: URL?
    /// The playlist or gallery this download came from, if any.
    public var group: DownloadGroup?
    /// Position within `group` (playlist order).
    public var groupIndex: Int = 0
    /// Page the link was found on; sent as `Referer`, which some image hosts require.
    public var referer: URL?
    /// Other links serving the same file. Flux spreads connections across them and keeps
    /// going when one fails.
    public var mirrors: [URL] = []
    /// This download's own speed cap in bytes per second (the global limit also applies).
    public var speedLimit: Int64?
    /// The checksum the finished file must have, if the user supplied one.
    public var checksum: Checksum?
    /// The finished file matched `checksum`.
    public var checksumVerified = false
    /// The server stated the file size up front and the finished file has exactly that
    /// many bytes. False when the server never said how big the file is.
    public var sizeVerified = false
    /// The folder was Flux's default, not the user's choice: rules and category folders
    /// may move the finished file.
    public var autoFile = false
    /// What moved the finished file ("rule “Invoices”", "Videos"), for display.
    public var filedBy: String?
    /// SHA-256 of the finished file, once Flux has computed it.
    public var contentHash: String?
    /// An identical file that already existed when this download finished.
    public var duplicateOf: URL?
    /// What extracting this archive produced.
    public var extractedPath: URL?
    /// Why extracting this archive failed (the download itself is fine).
    public var extractionError: String?
    /// Cleared from the Downloads list; still listed in History.
    public var isArchived = false

    public init(
        id: UUID = UUID(),
        url: URL,
        directory: URL,
        fileName: String? = nil,
        maxConnections: Int = 8,
        priority: DownloadPriority = .normal,
        kind: DownloadKind = .file,
        mediaFormat: MediaFormat? = nil,
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
        self.kind = kind
        self.mediaFormat = mediaFormat
    }

    public var receivedBytes: Int64 { segments.reduce(0) { $0 + $1.received } }

    /// The main link followed by its mirrors, without duplicates.
    public var sources: [URL] {
        var seen = Set<URL>()
        return ([url] + mirrors).filter { seen.insert($0).inserted }
    }

    /// Where a supplied checksum stands.
    public var checksumState: ChecksumState {
        guard checksum != nil else { return .none }
        if checksumVerified { return .verified }
        return status == .completed ? .mismatch : .pending
    }

    /// What to show as the name: the media title once known, else the file name.
    public var displayName: String { kind == .media ? (title ?? fileName) : fileName }

    /// Search: name, media title, playlist/gallery title or link.
    public func matches(_ query: String) -> Bool {
        [fileName, title ?? "", group?.title ?? "", url.absoluteString, referer?.host() ?? ""]
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }

    /// List order: newest first; downloads of one group stay in playlist order.
    public static func listOrder(_ a: Self, _ b: Self) -> Bool {
        if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
        if a.groupIndex != b.groupIndex { return a.groupIndex < b.groupIndex }
        return a.id.uuidString < b.id.uuidString
    }

    /// Queue order: higher priority first, then oldest first, then playlist order.
    public static func queueOrder(_ a: Self, _ b: Self) -> Bool {
        if a.priority != b.priority { return a.priority > b.priority }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        if a.groupIndex != b.groupIndex { return a.groupIndex < b.groupIndex }
        return a.id.uuidString < b.id.uuidString
    }

    public var fractionCompleted: Double? {
        if status == .completed { return 1 }
        guard let total = totalBytes, total > 0 else { return nil }
        return min(1, Double(receivedBytes) / Double(total))
    }

    public var partFileURL: URL? { partFileName.map { directory.appendingPathComponent($0) } }

    public var sourceHost: String { url.host() ?? url.absoluteString }

    /// Remote preview images to try, best first. YouTube links get a thumbnail straight
    /// from the video ID, so it shows before yt-dlp has even started.
    public var previewImageURLs: [URL] {
        var urls: [URL] = []
        if kind == .media, let youTube = Thumbnails.youTube(for: url) { urls.append(youTube) }
        if let thumbnailURL, !urls.contains(thumbnailURL) { urls.append(thumbnailURL) }
        return urls
    }
}

public enum Thumbnails {
    /// 320 × 180 (16:9, no letterbox bars); exists for every public YouTube video.
    public static func youTube(for url: URL) -> URL? {
        guard let host = url.host()?.lowercased() else { return nil }
        var id: String?
        if host == "youtu.be" {
            id = url.pathComponents.dropFirst().first
        } else if host == "youtube.com" || host.hasSuffix(".youtube.com") {
            let parts = url.pathComponents
            if parts.count >= 3, ["shorts", "live", "embed", "v"].contains(parts[1]) {
                id = parts[2]
            } else {
                id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "v" }?.value
            }
        }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard let id, id.count == 11, id.allSatisfy(allowed.contains) else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")
    }

    /// Accepts only web URLs from extractor output ("NA" and local paths are ignored).
    static func remote(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host() != nil else { return nil }
        return url
    }
}
