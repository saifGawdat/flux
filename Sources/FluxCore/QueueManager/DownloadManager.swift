import Foundation

/// The single owner of all downloads. UIs (and later the CLI over IPC) send intents and
/// observe `events()`; there is exactly one engine.
public actor DownloadManager {
    public struct Item: Sendable, Identifiable, Equatable {
        public var record: DownloadRecord
        public var bytesPerSecond: Double
        public var activeConnections: Int
        /// Current stage for display, e.g. "Merging video and audio…".
        public var detail: String?
        public var id: UUID { record.id }
    }

    public enum Event: Sendable {
        /// Full state; always the first event of a subscription.
        case reset([Item], FluxSettings)
        case updated(Item)
        case removed([UUID])
        case settingsChanged(FluxSettings)
    }

    public struct NewDownload: Sendable {
        public var url: URL
        public var directory: URL?
        public var fileName: String?
        public var connections: Int?
        public var priority: DownloadPriority
        public var startImmediately: Bool
        /// nil = decide automatically from the link.
        public var kind: DownloadKind?
        /// nil = use the default from settings.
        public var mediaFormat: MediaFormat?
        /// Known title (e.g. from a playlist listing), shown until the extractor reports one.
        public var title: String?
        public var thumbnailURL: URL?
        /// Sent as `Referer` (images found on a page).
        public var referer: URL?
        /// Playlist or gallery this download belongs to, and its position there.
        public var group: DownloadGroup?
        public var groupIndex: Int

        public init(
            url: URL,
            directory: URL? = nil,
            fileName: String? = nil,
            connections: Int? = nil,
            priority: DownloadPriority = .normal,
            startImmediately: Bool = true,
            kind: DownloadKind? = nil,
            mediaFormat: MediaFormat? = nil,
            title: String? = nil,
            thumbnailURL: URL? = nil,
            referer: URL? = nil,
            group: DownloadGroup? = nil,
            groupIndex: Int = 0
        ) {
            self.url = url
            self.directory = directory
            self.fileName = fileName
            self.connections = connections
            self.priority = priority
            self.startImmediately = startImmediately
            self.kind = kind
            self.mediaFormat = mediaFormat
            self.title = title
            self.thumbnailURL = thumbnailURL
            self.referer = referer
            self.group = group
            self.groupIndex = groupIndex
        }
    }

    private struct JobHandle {
        let job: any TransferJob
        let continuation: AsyncStream<TransferSnapshot>.Continuation
    }

    private let database: FluxDatabase
    private let jobOptions: DownloadJob.Options
    public private(set) var mediaTools: MediaTools
    private var items: [UUID: Item] = [:]
    private var jobs: [UUID: JobHandle] = [:]
    private var lastSequence: [UUID: UInt64] = [:]
    private var subscribers: [UUID: AsyncStream<Event>.Continuation] = [:]
    private var isStarted = false
    public private(set) var settings: FluxSettings

    /// Loads persisted state and recovers downloads interrupted by quit or crash.
    /// Call `start()` to begin scheduling.
    public init(
        database: FluxDatabase,
        jobOptions: DownloadJob.Options = .init(),
        mediaTools: MediaTools = .discover()
    ) async throws {
        self.database = database
        self.jobOptions = jobOptions
        self.mediaTools = mediaTools
        let settings = try await database.loadSettings()
        self.settings = settings
        var recovered: [DownloadRecord] = []
        for var record in try await database.loadDownloads() {
            if record.status.isActive {
                record.status = settings.resumeOnLaunch ? .queued : .paused
                recovered.append(record)
            }
            items[record.id] = Item(record: record, bytesPerSecond: 0, activeConnections: 0, detail: nil)
        }
        for record in recovered { try await database.save(record) }
        if !recovered.isEmpty {
            Log.manager.info("Recovered \(recovered.count) interrupted download(s)")
        }
    }

    // MARK: - Observation

    public func events() -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
        let key = UUID()
        subscribers[key] = continuation
        continuation.yield(.reset(orderedItems, settings))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(key) }
        }
        return stream
    }

    public var allItems: [Item] { orderedItems }

    public func item(_ id: UUID) -> Item? { items[id] }

    private var orderedItems: [Item] {
        items.values.sorted { DownloadRecord.listOrder($0.record, $1.record) }
    }

    private func unsubscribe(_ key: UUID) { subscribers[key] = nil }

    private func broadcast(_ event: Event) {
        for continuation in subscribers.values { continuation.yield(event) }
    }

    // MARK: - Intents

    public func start() async {
        isStarted = true
        await schedule()
    }

    @discardableResult
    public func add(_ requests: [NewDownload]) async throws -> [UUID] {
        for request in requests where !LinkExtractor.isDownloadable(request.url) {
            throw FluxError.unsupportedURL(request.url.absoluteString)
        }
        // One timestamp for the batch: a playlist keeps its order in the list and queue.
        let now = Date()
        var records: [DownloadRecord] = []
        for request in requests {
            let kind = request.kind ?? (MediaRouting.prefersMedia(request.url) ? .media : .file)
            var record = DownloadRecord(
                url: request.url,
                directory: request.directory ?? settings.downloadDirectory,
                fileName: request.fileName,
                maxConnections: request.connections ?? settings.connectionsPerDownload,
                priority: request.priority,
                kind: kind,
                mediaFormat: request.mediaFormat ?? settings.defaultMediaFormat,
                createdAt: request.group == nil ? Date() : now)
            record.status = request.startImmediately ? .queued : .paused
            if let title = request.title, !title.isEmpty {
                record.title = title
                if kind == .media, request.fileName == nil { record.fileName = FileNaming.sanitize(title) }
            }
            record.thumbnailURL = request.thumbnailURL.flatMap { Thumbnails.remote($0.absoluteString) }
            record.referer = request.referer
            record.group = request.group
            record.groupIndex = request.groupIndex
            records.append(record)
        }
        try await database.save(records)
        for record in records {
            let item = Item(record: record, bytesPerSecond: 0, activeConnections: 0, detail: nil)
            items[record.id] = item
            broadcast(.updated(item))
        }
        await schedule()
        return records.map(\.id)
    }

    public func pause(_ ids: some Collection<UUID>) async throws {
        for id in ids {
            guard let item = items[id] else { throw FluxError.unknownDownload(id) }
            switch item.record.status {
            case .connecting, .downloading:
                if let handle = jobs[id] { await apply(await handle.job.pause()) }
            case .queued:
                await update(id) { $0.status = .paused }
            default:
                break
            }
        }
        await schedule()
    }

    /// Resumes paused downloads and retries failed or cancelled ones.
    public func resume(_ ids: some Collection<UUID>) async throws {
        for id in ids {
            guard let item = items[id] else { throw FluxError.unknownDownload(id) }
            guard item.record.status.canResume else { continue }
            await update(id) {
                $0.status = .queued
                $0.errorMessage = nil
            }
        }
        await schedule()
    }

    /// Stops the download and deletes its partial data; the entry stays in the list.
    public func cancel(_ ids: some Collection<UUID>) async throws {
        for id in ids {
            guard let item = items[id] else { throw FluxError.unknownDownload(id) }
            guard item.record.status.canCancel else { continue }
            if let handle = jobs[id] {
                await apply(await handle.job.cancel())
                dropJob(id)
            } else {
                if let part = item.record.partFileURL { try? FileManager.default.removeItem(at: part) }
                await update(id) {
                    $0.status = .cancelled
                    $0.segments = []
                    $0.partFileName = nil
                    $0.totalBytes = nil
                    $0.supportsRanges = false
                }
            }
        }
        await schedule()
    }

    /// Removes entries from the list. Partial data is always deleted; finished files are
    /// moved to the Trash only when `trashFiles` is true.
    public func remove(_ ids: some Collection<UUID>, trashFiles: Bool) async throws {
        var removed: [UUID] = []
        for id in ids {
            guard let item = items[id] else { continue }
            if let handle = jobs[id] {
                _ = await handle.job.cancel()
                dropJob(id)
            } else if let part = item.record.partFileURL {
                try? FileManager.default.removeItem(at: part)
            }
            if trashFiles, let path = item.record.finalPath, FileManager.default.fileExists(atPath: path.path) {
                try FileManager.default.trashItem(at: path, resultingItemURL: nil)
            }
            items[id] = nil
            lastSequence[id] = nil
            removed.append(id)
        }
        try await database.deleteDownloads(removed)
        if !removed.isEmpty { broadcast(.removed(removed)) }
        await schedule()
    }

    public func setPriority(_ priority: DownloadPriority, for ids: some Collection<UUID>) async {
        for id in ids where items[id] != nil {
            await update(id) { $0.priority = priority }
        }
        await schedule()
    }

    public func updateSettings(_ newValue: FluxSettings) async throws {
        let normalized = newValue.normalized()
        try await database.save(normalized)
        settings = normalized
        broadcast(.settingsChanged(normalized))
        await schedule()
    }

    /// Re-scans for yt-dlp/ffmpeg (e.g. after the user installs them).
    public func refreshMediaTools(_ tools: MediaTools = .discover()) {
        mediaTools = tools
    }

    /// Checkpoints every running download so it resumes at next launch. Call before quitting.
    public func shutdown() async {
        isStarted = false
        for (id, handle) in jobs {
            var record = await handle.job.suspendForShutdown()
            if let current = items[id] { record.priority = current.record.priority }
            items[id]?.record = record
            await persist(record)
            handle.continuation.finish()
        }
        jobs.removeAll()
        Log.manager.info("Shutdown complete")
    }

    // MARK: - Scheduling

    private func schedule() async {
        guard isStarted else { return }
        var running = items.values.filter { $0.record.status.isActive }.count
        guard running < settings.maxConcurrentDownloads else { return }
        let candidates = items.values
            .filter { $0.record.status == .queued }
            .sorted { DownloadRecord.queueOrder($0.record, $1.record) }
        for candidate in candidates where running < settings.maxConcurrentDownloads {
            let id = candidate.id
            guard items[id]?.record.status == .queued else { continue }
            items[id]?.record.status = .connecting
            if let item = items[id] { broadcast(.updated(item)) }
            running += 1
            await job(for: id)?.start()
        }
    }

    private func job(for id: UUID) -> (any TransferJob)? {
        if let handle = jobs[id] { return handle.job }
        guard let record = items[id]?.record else { return nil }
        let (stream, continuation) = AsyncStream.makeStream(of: TransferSnapshot.self)
        let report: @Sendable (TransferSnapshot) -> Void = { continuation.yield($0) }
        let job: any TransferJob = switch record.kind {
        case .file: DownloadJob(record: record, options: jobOptions, onUpdate: report)
        case .media: MediaJob(record: record, tools: mediaTools, onUpdate: report)
        }
        jobs[id] = JobHandle(job: job, continuation: continuation)
        lastSequence[id] = 0
        Task { [weak self] in
            for await snapshot in stream {
                await self?.apply(snapshot)
            }
        }
        return job
    }

    private func dropJob(_ id: UUID) {
        jobs.removeValue(forKey: id)?.continuation.finish()
    }

    /// Merges a job snapshot. The job owns transfer state; the manager owns `priority`.
    private func apply(_ snapshot: TransferSnapshot) async {
        let id = snapshot.record.id
        guard let current = items[id], snapshot.sequence > (lastSequence[id] ?? 0)
        else { return }
        lastSequence[id] = snapshot.sequence
        if snapshot.landedOnWebPage, current.record.kind == .file {
            await switchToMedia(id)
            return
        }
        var record = snapshot.record
        record.priority = current.record.priority
        let item = Item(
            record: record,
            bytesPerSecond: record.status.isActive ? snapshot.bytesPerSecond : 0,
            activeConnections: snapshot.activeConnections,
            detail: record.status.isActive ? snapshot.detail : nil)
        items[id] = item
        broadcast(.updated(item))

        let statusChanged = current.record.status != record.status
        if statusChanged || snapshot.isCheckpoint {
            await persist(record)
        }
        if statusChanged, !record.status.isActive {
            if record.status == .completed || record.status == .cancelled { dropJob(id) }
            await schedule()
        }
    }

    /// A "file" link turned out to be a web page: hand it to the media extractor.
    private func switchToMedia(_ id: UUID) async {
        dropJob(id)
        guard mediaTools.ytdlp != nil else {
            await update(id) {
                $0.status = .failed
                $0.errorMessage = "This link opens a web page. To download videos from pages, install yt-dlp: brew install yt-dlp ffmpeg"
            }
            await schedule()
            return
        }
        Log.manager.info("Download \(id, privacy: .public) is a web page; switching to media extraction")
        await update(id) {
            $0.kind = .media
            $0.mediaFormat = $0.mediaFormat ?? self.settings.defaultMediaFormat
            $0.status = .queued
            $0.errorMessage = nil
            $0.segments = []
            $0.totalBytes = nil
            $0.partFileName = nil
            $0.supportsRanges = false
        }
        // It was counted as active; the slot is free again.
        await schedule()
    }

    private func update(_ id: UUID, _ change: (inout DownloadRecord) -> Void) async {
        guard var item = items[id] else { return }
        change(&item.record)
        if !item.record.status.isActive {
            item.bytesPerSecond = 0
            item.detail = nil
        }
        items[id] = item
        broadcast(.updated(item))
        await persist(item.record)
    }

    private func persist(_ record: DownloadRecord) async {
        do {
            try await database.save(record)
        } catch {
            Log.persistence.error("Failed to save download \(record.id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
