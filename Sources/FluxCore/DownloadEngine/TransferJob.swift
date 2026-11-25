import Foundation

/// Progress report from any transfer engine (direct file or media extraction).
public struct TransferSnapshot: Sendable {
    public let record: DownloadRecord
    public let bytesPerSecond: Double
    public let activeConnections: Int
    /// Strictly increasing per job; consumers drop anything not newer than what they have.
    public let sequence: UInt64
    /// Byte counts in `record` are durable on disk and safe to persist.
    public let isCheckpoint: Bool
    /// Short human-readable stage, e.g. "Merging video and audio…".
    public let detail: String?
    /// A file download got an HTML page back: the link is a page, not a file.
    public let landedOnWebPage: Bool

    public init(
        record: DownloadRecord,
        bytesPerSecond: Double,
        activeConnections: Int,
        sequence: UInt64,
        isCheckpoint: Bool,
        detail: String? = nil,
        landedOnWebPage: Bool = false
    ) {
        self.record = record
        self.bytesPerSecond = bytesPerSecond
        self.activeConnections = activeConnections
        self.sequence = sequence
        self.isCheckpoint = isCheckpoint
        self.detail = detail
        self.landedOnWebPage = landedOnWebPage
    }
}

/// One download, whatever engine performs it. `DownloadManager` drives only this.
public protocol TransferJob: Actor {
    nonisolated var id: UUID { get }
    func start() async
    /// Stops, keeping progress for a later resume.
    func pause() async -> TransferSnapshot
    /// Stops and deletes partial data.
    func cancel() async -> TransferSnapshot
    /// Stops for app termination without changing status; returns durable state.
    func suspendForShutdown() async -> DownloadRecord
}
