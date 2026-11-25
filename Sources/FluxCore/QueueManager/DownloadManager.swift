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
        /// Other links to the same file.
        public var mirrors: [URL]
        /// Checksum the finished file must match.
        public var checksum: Checksum?
        /// This download's own speed cap, bytes per second.
        public var speedLimit: Int64?
        /// Named queue to wait in; nil = the main queue.
        public var queue: UUID?

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
            groupIndex: Int = 0,
            mirrors: [URL] = [],
            checksum: Checksum? = nil,
            speedLimit: Int64? = nil,
            queue: UUID? = nil
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
            self.mirrors = mirrors
            self.checksum = checksum
            self.speedLimit = speedLimit
            self.queue = queue
        }
    }

    private struct JobHandle {
        let job: any TransferJob
        let continuation: AsyncStream<TransferSnapshot>.Continuation
    }

    private let database: FluxDatabase
    private var jobOptions: DownloadJob.Options
    /// The global speed limit: one bucket every running download draws from.
    private let globalLimiter = SpeedLimiter()
    public private(set) var mediaTools: MediaTools
    private var items: [UUID: Item] = [:]
    private var jobs: [UUID: JobHandle] = [:]
    private var lastSequence: [UUID: UInt64] = [:]
    private var subscribers: [UUID: AsyncStream<Event>.Continuation] = [:]
    /// Finished downloads being filed, checked for duplicates or extracted.
    private var finishing: Set<UUID> = []
    private var isStarted = false
    /// The current time; injectable so tests can drive queue schedules.
    private let clock: @Sendable () -> Date
    /// Schedules are checked for starts and stops since this moment.
    private var lastScheduleCheck: Date
    private var scheduleTask: Task<Void, Never>?
    /// How often queue schedules are checked.
    public static let scheduleCheckInterval: Duration = .seconds(10)
    public private(set) var settings: FluxSettings

    /// Loads persisted state and recovers downloads interrupted by quit or crash.
    /// Call `start()` to begin scheduling.
    public init(
        database: FluxDatabase,
        jobOptions: DownloadJob.Options = .init(),
        mediaTools: MediaTools = .discover(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) async throws {
        self.database = database
        self.clock = clock
        self.lastScheduleCheck = clock()
        self.jobOptions = jobOptions
        self.mediaTools = mediaTools
        let settings = try await database.loadSettings()
        self.settings = settings
        globalLimiter.setLimit(settings.effectiveSpeedLimit)
        self.jobOptions.sharedLimiter = globalLimiter
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
        // Flux was closed when a window began: start queues that should be running now.
        let now = clock()
        var queues = settings.queues
        for index in queues.indices where queues[index].schedule?.isInsideWindow(at: now) == true {
            queues[index].isRunning = true
        }
        lastScheduleCheck = now
        if queues != settings.queues { await saveQueues(queues) }
        await schedule()
        scheduleTask?.cancel()
        scheduleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.scheduleCheckInterval)
                await self?.checkSchedules()
            }
        }
    }

    @discardableResult
    public func add(_ requests: [NewDownload]) async throws -> [UUID] {
        for request in requests {
            for url in [request.url] + request.mirrors where !LinkExtractor.isDownloadable(url) {
                throw FluxError.unsupportedURL(url.absoluteString)
            }
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
            record.mirrors = request.mirrors.filter { $0 != request.url }
            record.checksum = request.checksum
            record.speedLimit = request.speedLimit.flatMap { $0 > 0 ? $0 : nil }
            // Only Flux's own choice of folder may be changed by rules and categories.
            record.autoFile = request.directory == nil
            record.queueID = request.queue.flatMap { id in settings.queues.contains { $0.id == id } ? id : nil }
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

    // MARK: - History

    /// Takes downloads off the Downloads list; they stay in History. Only finished,
    /// failed or cancelled downloads can be archived.
    public func archive(_ ids: some Collection<UUID>) async {
        for id in ids {
            guard let status = items[id]?.record.status, status == .completed || status == .failed || status == .cancelled
            else { continue }
            await update(id) { $0.isArchived = true }
        }
    }

    /// Forgets everything in History. Files on disk are kept.
    public func clearHistory() async throws {
        let ids = items.values.filter(\.record.isArchived).map(\.id)
        try await remove(ids, trashFiles: false)
    }

    /// Caps the speed of individual downloads (nil removes the cap). Applies immediately.
    public func setSpeedLimit(_ bytesPerSecond: Int64?, for ids: some Collection<UUID>) async {
        let limit = bytesPerSecond.flatMap { $0 > 0 ? max($0, FluxSettings.minimumSpeedLimit) : nil }
        for id in ids where items[id] != nil {
            await update(id) { $0.speedLimit = limit }
            await jobs[id]?.job.setSpeedLimit(limit)
        }
    }

    /// Points a download at a new link, e.g. after the old one expired, keeping the data
    /// already downloaded. If the new link serves a different file (another size), the
    /// engine notices on the first request and starts over. A failed download is retried.
    public func updateLink(_ id: UUID, to url: URL) async throws {
        guard LinkExtractor.isDownloadable(url) else { throw FluxError.unsupportedURL(url.absoluteString) }
        try await edit(id, retry: true) {
            $0.url = url
            $0.mirrors.removeAll { $0 == url }
            // Validators belong to the old server; the size check still guards the data.
            $0.etag = nil
            $0.lastModified = nil
        }
    }

    /// Replaces a download's mirror links.
    public func setMirrors(_ mirrors: [URL], for id: UUID) async throws {
        for url in mirrors where !LinkExtractor.isDownloadable(url) {
            throw FluxError.unsupportedURL(url.absoluteString)
        }
        try await edit(id, retry: false) { record in
            var seen: Set<URL> = [record.url]
            record.mirrors = mirrors.filter { seen.insert($0).inserted }
        }
    }

    /// Sets (or clears) the checksum a download must match. For a finished download the
    /// file is checked right away and the result returned; otherwise it is checked when
    /// the download finishes and nil is returned.
    @discardableResult
    public func setChecksum(_ checksum: Checksum?, for id: UUID) async throws -> Bool? {
        guard let item = items[id] else { throw FluxError.unknownDownload(id) }
        guard item.record.status == .completed else {
            try await edit(id, retry: false) {
                $0.checksum = checksum
                $0.checksumVerified = false
            }
            return nil
        }
        var matches = false
        if let checksum {
            guard let file = item.record.finalPath, FileManager.default.fileExists(atPath: file.path) else {
                throw FluxError.fileMissing
            }
            matches = try await checksum.matches(file)
        }
        await update(id) {
            $0.checksum = checksum
            $0.checksumVerified = matches
        }
        return checksum == nil ? nil : matches
    }

    /// Changes what a download fetches. A running download is paused, changed and resumed;
    /// its job is rebuilt from the edited record.
    private func edit(_ id: UUID, retry: Bool, _ change: (inout DownloadRecord) -> Void) async throws {
        guard let item = items[id] else { throw FluxError.unknownDownload(id) }
        guard item.record.status != .completed else { throw FluxError.alreadyFinished }
        let wasRunning = item.record.status.isActive
        if wasRunning, let handle = jobs[id] {
            await apply(await handle.job.pause())
        }
        dropJob(id)
        let resume = wasRunning || (retry && item.record.status == .failed)
        await update(id) {
            change(&$0)
            if resume {
                $0.status = .queued
                $0.errorMessage = nil
            }
        }
        await schedule()
    }

    public func updateSettings(_ newValue: FluxSettings) async throws {
        var normalized = newValue.normalized()
        // Running or not is the manager's business (Start/Stop, schedules); edits keep it.
        for index in normalized.queues.indices {
            if let old = settings.queues.first(where: { $0.id == normalized.queues[index].id }) {
                normalized.queues[index].isRunning = old.isRunning
            }
        }
        let removedQueues = Set(settings.queues.map(\.id)).subtracting(normalized.queues.map(\.id))
        try await database.save(normalized)
        let limitChanged = normalized.effectiveSpeedLimit != settings.effectiveSpeedLimit
        settings = normalized
        if limitChanged {
            globalLimiter.setLimit(normalized.effectiveSpeedLimit)
            for (id, handle) in jobs {
                await handle.job.setSpeedLimit(items[id]?.record.speedLimit)
            }
        }
        broadcast(.settingsChanged(normalized))
        // Downloads of a deleted queue go back to the main queue.
        for item in items.values where item.record.queueID.map(removedQueues.contains) == true {
            await update(item.id) { $0.queueID = nil }
        }
        await schedule()
    }

    // MARK: - Queues

    /// Starts a named queue: its downloads begin, up to its own and the overall limit.
    public func startQueue(_ id: UUID) async {
        await setQueueRunning(id, true)
    }

    /// Stops a named queue. Its running downloads stop and wait, ready to continue when
    /// the queue starts again.
    public func stopQueue(_ id: UUID) async {
        await setQueueRunning(id, false)
    }

    /// Moves downloads to a named queue (nil = the main queue). A running download that
    /// lands in a stopped queue stops and waits there.
    public func move(_ ids: some Collection<UUID>, toQueue queue: UUID?) async {
        let target = queue.flatMap { id in settings.queues.contains { $0.id == id } ? id : nil }
        for id in ids where items[id] != nil && items[id]?.record.queueID != target {
            await update(id) { $0.queueID = target }
        }
        await enforceStoppedQueues()
        await schedule()
    }

    /// Applies scheduled starts and stops that fell due since the last check. Runs every
    /// few seconds while the manager is started.
    public func checkSchedules() async {
        let now = clock()
        defer { lastScheduleCheck = now }
        guard now > lastScheduleCheck else { return }
        var queues = settings.queues
        for index in queues.indices {
            guard let schedule = queues[index].schedule,
                  let last = schedule.changes(from: lastScheduleCheck, to: now).last else { continue }
            queues[index].isRunning = last.change == .start
            Log.manager.info("Queue \(queues[index].name, privacy: .public) \(last.change == .start ? "started" : "stopped", privacy: .public) by its schedule")
        }
        guard queues != settings.queues else { return }
        await saveQueues(queues)
        await enforceStoppedQueues()
        await schedule()
    }

    public func queue(_ id: UUID?) -> DownloadQueue? {
        id.flatMap { id in settings.queues.first { $0.id == id } }
    }

    private func setQueueRunning(_ id: UUID, _ running: Bool) async {
        guard let index = settings.queues.firstIndex(where: { $0.id == id }),
              settings.queues[index].isRunning != running else { return }
        var queues = settings.queues
        queues[index].isRunning = running
        await saveQueues(queues)
        await enforceStoppedQueues()
        await schedule()
    }

    private func saveQueues(_ queues: [DownloadQueue]) async {
        settings.queues = queues
        do { try await database.save(settings) } catch {
            Log.persistence.error("Failed to save queues: \(String(describing: error), privacy: .public)")
        }
        broadcast(.settingsChanged(settings))
    }

    /// A download may start when its queue is the main queue or a started named queue.
    private func queueIsRunning(_ id: UUID?) -> Bool {
        guard let id else { return true }
        return queue(id)?.isRunning ?? true
    }

    /// A queue started by a schedule without a stop time runs until nothing in it is
    /// waiting or downloading, then stops so later additions wait for the next start.
    private func stopFinishedScheduledQueues() async {
        let busy = Set(items.values.compactMap { item in
            item.record.status == .queued || item.record.status.isActive ? item.record.queueID : nil
        })
        var queues = settings.queues
        for index in queues.indices where queues[index].isRunning && queues[index].schedule != nil
            && queues[index].schedule?.stop == nil && !busy.contains(queues[index].id) {
            queues[index].isRunning = false
            Log.manager.info("Queue \(queues[index].name, privacy: .public) finished; stopped until its next start")
        }
        if queues != settings.queues { await saveQueues(queues) }
    }

    /// Running downloads in stopped queues stop and go back to waiting.
    private func enforceStoppedQueues() async {
        let stopped = items.values.filter { $0.record.status.isActive && !queueIsRunning($0.record.queueID) }
        for item in stopped {
            if let handle = jobs[item.id] { await apply(await handle.job.pause()) }
            await update(item.id) { $0.status = .queued }
        }
    }

    /// Re-scans for yt-dlp/ffmpeg (e.g. after the user installs them).
    public func refreshMediaTools(_ tools: MediaTools = .discover()) {
        mediaTools = tools
    }

    /// Checkpoints every running download so it resumes at next launch. Call before quitting.
    public func shutdown() async {
        isStarted = false
        scheduleTask?.cancel()
        scheduleTask = nil
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
        let active = items.values.filter { $0.record.status.isActive }
        var running = active.count
        guard running < settings.maxConcurrentDownloads else { return }
        var runningPerQueue: [UUID: Int] = [:]
        for item in active { if let queue = item.record.queueID { runningPerQueue[queue, default: 0] += 1 } }
        let candidates = items.values
            .filter { $0.record.status == .queued && queueIsRunning($0.record.queueID) }
            .sorted { DownloadRecord.queueOrder($0.record, $1.record) }
        for candidate in candidates where running < settings.maxConcurrentDownloads {
            let id = candidate.id
            guard items[id]?.record.status == .queued else { continue }
            if let queueID = candidate.record.queueID, let limit = queue(queueID)?.maxConcurrent {
                guard runningPerQueue[queueID, default: 0] < limit else { continue }
                runningPerQueue[queueID, default: 0] += 1
            }
            items[id]?.record.status = .connecting
            if let item = items[id] { broadcast(.updated(item)) }
            running += 1
            await job(for: id)?.start()
        }
        await stopFinishedScheduledQueues()
    }

    private func job(for id: UUID) -> (any TransferJob)? {
        if let handle = jobs[id] { return handle.job }
        guard let record = items[id]?.record else { return nil }
        let (stream, continuation) = AsyncStream.makeStream(of: TransferSnapshot.self)
        let report: @Sendable (TransferSnapshot) -> Void = { continuation.yield($0) }
        let job: any TransferJob = switch record.kind {
        case .file: DownloadJob(record: record, options: jobOptions, onUpdate: report)
        case .media: MediaJob(record: record, tools: mediaTools, limiter: globalLimiter, onUpdate: report)
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

    /// Merges a job snapshot. The job owns transfer state; the manager owns `priority`,
    /// `speedLimit` and `queueID`.
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
        record.speedLimit = current.record.speedLimit
        record.queueID = current.record.queueID
        let item = Item(
            record: record,
            bytesPerSecond: record.status.isActive ? snapshot.bytesPerSecond : 0,
            activeConnections: snapshot.activeConnections,
            detail: record.status.isActive ? snapshot.detail : nil)
        let statusChanged = current.record.status != record.status
        // Marked before any await, so nobody sees "finished" before filing has begun.
        let startFinishing = statusChanged && record.status == .completed && finishing.insert(id).inserted
        items[id] = item
        broadcast(.updated(item))

        if statusChanged || snapshot.isCheckpoint {
            await persist(record)
        }
        if statusChanged, !record.status.isActive {
            if record.status == .completed || record.status == .cancelled { dropJob(id) }
            await schedule()
        }
        if startFinishing {
            Task { await self.finishUp(id) }
        }
    }

    // MARK: - After a download finishes

    /// Files the download (rules, category folders), looks for an identical existing file,
    /// and extracts archives, in that order. Each step is optional and none of them can
    /// make a finished download fail: problems are recorded and shown instead.
    private func finishUp(_ id: UUID) async {
        defer {
            finishing.remove(id)
            showDetail(id, nil)
        }
        guard let record = items[id]?.record, record.status == .completed, var file = record.finalPath else { return }

        if record.autoFile, let destination = Filing.destination(for: record, settings: settings),
           destination.folder.standardizedFileURL.path != file.deletingLastPathComponent().standardizedFileURL.path {
            showDetail(id, "Moving to \(destination.folder.lastPathComponent)…")
            do {
                let moved = try await FileMover.move(file, into: destination.folder)
                file = moved
                await update(id) {
                    $0.finalPath = moved
                    $0.directory = destination.folder
                    $0.fileName = moved.lastPathComponent
                    $0.filedBy = destination.reason
                }
            } catch {
                Log.manager.error("Couldn't move \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        let known: [(url: URL, sha256: String?)] = items.values.compactMap { other in
            guard other.id != id, other.record.status == .completed, let path = other.record.finalPath,
                  other.record.totalBytes == record.totalBytes else { return nil }
            return (path, other.record.contentHash)
        }
        showDetail(id, "Checking for duplicates…")
        if let match = try? await DuplicateFinder.findDuplicate(of: file, known: known) {
            let trash = settings.duplicateAction == .trashNew
            if trash { try? FileManager.default.trashItem(at: file, resultingItemURL: nil) }
            await update(id) {
                $0.duplicateOf = match.existing
                $0.contentHash = match.sha256
                if trash { $0.finalPath = nil }
            }
            if trash { return }
        }

        if settings.extractArchives, ArchiveExtractor.canExtract(file) {
            showDetail(id, "Extracting…")
            do {
                let output = try await ArchiveExtractor.extract(file, source: record.url)
                let trashArchive = settings.trashArchivesAfterExtracting
                if trashArchive { try? FileManager.default.trashItem(at: file, resultingItemURL: nil) }
                await update(id) {
                    $0.extractedPath = output
                    $0.extractionError = nil
                    if trashArchive { $0.finalPath = nil }
                }
            } catch {
                await update(id) { $0.extractionError = error.localizedDescription }
            }
        }
    }

    /// Re-runs extraction for a finished archive (e.g. after a failure, or on demand).
    public func extract(_ id: UUID) async throws {
        guard let record = items[id]?.record, let file = record.finalPath,
              FileManager.default.fileExists(atPath: file.path) else { throw FluxError.fileMissing }
        showDetail(id, "Extracting…")
        defer { showDetail(id, nil) }
        do {
            let output = try await ArchiveExtractor.extract(file, source: record.url)
            await update(id) {
                $0.extractedPath = output
                $0.extractionError = nil
            }
        } catch {
            await update(id) { $0.extractionError = error.localizedDescription }
            throw error
        }
    }

    /// Shows a stage ("Extracting…") on a download without saving anything.
    private func showDetail(_ id: UUID, _ text: String?) {
        guard var item = items[id], item.detail != text else { return }
        item.detail = text
        items[id] = item
        broadcast(.updated(item))
    }

    /// True while a finished download is still being filed, checked or extracted.
    public func isFinishing(_ id: UUID) -> Bool { finishing.contains(id) }

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
