import Darwin
import Foundation

/// Downloads one file over one or more HTTP connections. See docs/ARCHITECTURE.md (D1–D5).
///
/// The actor executes on a private serial queue that is also the URLSession delegate
/// queue, so delegate callbacks enter the actor synchronously and in arrival order.
public actor DownloadJob {
    public struct Snapshot: Sendable {
        public let record: DownloadRecord
        public let bytesPerSecond: Double
        public let activeConnections: Int
        /// Strictly increasing per job; consumers drop anything not newer than what they have.
        public let sequence: UInt64
        /// The part file was fsync'ed: `record`'s byte counts are durable and safe to persist.
        public let isCheckpoint: Bool
    }

    public struct Options: Sendable {
        /// A segment is only split when both halves would be at least this large.
        public var minPieceSize: Int64 = 1 << 20
        public var maxRetries = 8
        public var maxRestarts = 3
        public var requestTimeout: TimeInterval = 30
        public var userAgent = "Flux/1.0"
        public var progressInterval: Duration = .milliseconds(500)
        public var checkpointInterval: TimeInterval = 2
        public var retryBaseDelay: Double = 1
        public init() {}
    }

    private struct ActiveTask {
        let task: URLSessionDataTask
        /// Segment index, or -1 while the first (probing) response is pending.
        var index: Int
    }

    public nonisolated let id: UUID
    private nonisolated let queue: DispatchSerialQueue
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let options: Options
    private let onUpdate: @Sendable (Snapshot) -> Void
    private let delegateQueue: OperationQueue

    private var record: DownloadRecord
    private var session: URLSession?
    private var tasks: [Int: ActiveTask] = [:]
    private var fd: Int32 = -1
    private var resolvedURL: URL?
    private var isRunning = false
    private var generation = 0
    private var consecutiveFailures = 0
    private var restarts = 0
    private var connectionLimit = 1
    private var meter = SpeedMeter()
    private var currentRate: Double = 0
    private var ticker: Task<Void, Never>?
    private var lastCheckpoint: TimeInterval = 0
    private var sequence: UInt64 = 0

    public init(record: DownloadRecord, options: Options = Options(), onUpdate: @escaping @Sendable (Snapshot) -> Void) {
        self.id = record.id
        self.record = record
        self.options = options
        self.onUpdate = onUpdate
        let queue = DispatchSerialQueue(label: "app.flux.job.\(record.id.uuidString)")
        self.queue = queue
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        self.delegateQueue = delegateQueue
    }

    // MARK: - Controls

    public var currentRecord: DownloadRecord { record }

    public func start() {
        guard !isRunning, record.status != .completed else { return }
        isRunning = true
        generation += 1
        consecutiveFailures = 0
        restarts = 0
        connectionLimit = record.maxConnections
        record.errorMessage = nil
        record.status = .connecting
        meter.reset()
        currentRate = 0
        lastCheckpoint = ProcessInfo.processInfo.systemUptime

        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = record.maxConnections + 1
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = options.requestTimeout
        config.httpAdditionalHeaders = ["User-Agent": options.userAgent]
        session = URLSession(configuration: config, delegate: SessionDelegate(job: self), delegateQueue: delegateQueue)
        startTicker()

        let partExists = record.partFileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        if record.supportsRanges, !record.segments.isEmpty, partExists, openPartFile(fresh: false) {
            Log.engine.info("Resuming \(self.id, privacy: .public) at \(self.record.receivedBytes) bytes")
            if record.segments.allSatisfy(\.isComplete) {
                finalize()
                return
            }
            fillConnections()
        } else {
            restartFresh()
        }
        emit()
    }

    /// Stops all connections, keeping progress so the download can resume.
    @discardableResult
    public func pause() -> Snapshot {
        stop(status: .paused)
        return makeSnapshot(checkpoint: true)
    }

    /// Stops and deletes the partial file. Resuming afterwards starts from zero.
    @discardableResult
    public func cancel() -> Snapshot {
        stop(status: .cancelled)
        discardPartialData()
        return makeSnapshot(checkpoint: true)
    }

    /// Stops for app termination without changing the status, so the download is
    /// recognized as interrupted (and resumed) at next launch. Returns durable state.
    public func suspendForShutdown() -> DownloadRecord {
        if isRunning {
            let status = record.status
            stop(status: status, notify: false)
        }
        return record
    }

    // MARK: - Lifecycle

    private func stop(status: DownloadStatus, message: String? = nil, notify: Bool = true) {
        if isRunning {
            isRunning = false
            generation += 1
            cancelAllTasks()
            session?.invalidateAndCancel()
            session = nil
            stopTicker()
            syncAndCloseFile()
        }
        if record.status != .completed {
            record.status = status
            record.errorMessage = message
        }
        currentRate = 0
        if notify { emit(checkpoint: true) }
    }

    private func fail(_ message: String) {
        Log.engine.error("Download \(self.id, privacy: .public) failed: \(message, privacy: .public)")
        stop(status: .failed, message: message)
    }

    private func discardPartialData() {
        closeFile()
        if let part = record.partFileURL { try? FileManager.default.removeItem(at: part) }
        record.partFileName = nil
        record.segments = []
        record.totalBytes = nil
        record.supportsRanges = false
        record.etag = nil
        record.lastModified = nil
    }

    /// Throws away all progress and issues a fresh `bytes=0-` request.
    private func restartFresh() {
        cancelAllTasks()
        discardPartialData()
        record.status = .connecting
        resolvedURL = nil
        launch(index: -1)
    }

    private func restartAfterInconsistency(_ reason: String) {
        restarts += 1
        Log.engine.notice("Restarting \(self.id, privacy: .public): \(reason, privacy: .public)")
        if restarts > options.maxRestarts {
            fail(reason)
        } else {
            restartFresh()
            emit()
        }
    }

    // MARK: - Connections

    private func launch(index: Int) {
        guard let session else { return }
        var request = URLRequest(url: resolvedURL ?? record.url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if index < 0 {
            request.setValue("bytes=0-", forHTTPHeaderField: "Range")
        } else {
            let seg = record.segments[index]
            let end = seg.isOpenEnded ? "" : String(seg.end)
            request.setValue("bytes=\(seg.offset)-\(end)", forHTTPHeaderField: "Range")
            // If the file changed, If-Range makes the server answer 200 with the whole new
            // file rather than a 206 slice that would mix two versions.
            if let etag = record.etag, !etag.hasPrefix("W/") {
                request.setValue(etag, forHTTPHeaderField: "If-Range")
            } else if let lastModified = record.lastModified {
                request.setValue(lastModified, forHTTPHeaderField: "If-Range")
            }
        }
        let task = session.dataTask(with: request)
        tasks[task.taskIdentifier] = ActiveTask(task: task, index: index)
        task.resume()
    }

    /// Keeps `connectionLimit` connections busy: resume idle segments first, then split.
    private func fillConnections() {
        guard isRunning, record.supportsRanges else { return }
        var busy = Set(tasks.values.map(\.index))
        while tasks.count < connectionLimit {
            if let idle = record.segments.indices.first(where: { !record.segments[$0].isComplete && !busy.contains($0) }) {
                launch(index: idle)
                busy.insert(idle)
            } else if let fresh = Segmenter.splitLargest(&record.segments, minPieceSize: options.minPieceSize) {
                launch(index: fresh)
                busy.insert(fresh)
            } else {
                break
            }
        }
    }

    private func cancelAllTasks() {
        let all = tasks.values
        tasks.removeAll()
        for active in all { active.task.cancel() }
    }

    private func segmentFinished() {
        if !record.segments.isEmpty, record.segments.allSatisfy(\.isComplete), tasks.isEmpty {
            finalize()
        } else {
            fillConnections()
        }
    }

    private func handleError(_ message: String, retryable: Bool) {
        consecutiveFailures += 1
        if !tasks.isEmpty {
            // Other connections are healthy, so the server is likely limiting connections.
            connectionLimit = max(1, tasks.count)
        }
        guard retryable, consecutiveFailures <= options.maxRetries else {
            fail(message)
            return
        }
        let delay = min(30, options.retryBaseDelay * pow(2, Double(consecutiveFailures - 1)))
        Log.engine.notice("Download \(self.id, privacy: .public): \(message, privacy: .public); retry in \(delay)s")
        let gen = generation
        Task {
            try? await Task.sleep(for: .seconds(delay))
            self.retry(generation: gen)
        }
        emit()
    }

    private func retry(generation gen: Int) {
        guard isRunning, generation == gen else { return }
        if !record.supportsRanges || record.segments.isEmpty {
            restartFresh()
        } else {
            fillConnections()
        }
        emit()
    }

    private static func isRetryable(_ error: Error?) -> Bool {
        guard let urlError = error as? URLError else { return true }
        switch urlError.code {
        case .badURL, .unsupportedURL, .fileDoesNotExist, .userAuthenticationRequired,
             .appTransportSecurityRequiresSecureConnection, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .serverCertificateHasBadDate, .clientCertificateRejected, .clientCertificateRequired,
             .secureConnectionFailed:
            return false
        default:
            return true
        }
    }

    private static func isRetryable(status: Int) -> Bool {
        status >= 500 || status == 408 || status == 429
    }

    // MARK: - URLSession events (called synchronously from SessionDelegate)

    fileprivate func didReceive(
        response: URLResponse,
        task: URLSessionDataTask,
        session: URLSession,
        completion: @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard session === self.session, let active = tasks[task.taskIdentifier] else {
            completion(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            tasks[task.taskIdentifier] = nil
            completion(.cancel)
            fail("The server didn't send an HTTP response")
            return
        }
        let status = http.statusCode
        let contentRange = http.value(forHTTPHeaderField: "Content-Range").flatMap(ContentRange.parse)

        if active.index < 0 {
            let isEmptyFile = status == 416 && ContentRange.isEmptyResource(http.value(forHTTPHeaderField: "Content-Range"))
            guard (200..<300).contains(status) || isEmptyFile else {
                tasks[task.taskIdentifier] = nil
                completion(.cancel)
                handleError(Self.describe(status: status), retryable: Self.isRetryable(status: status))
                return
            }
            adoptFirstResponse(http, contentRange: contentRange)
            guard openPartFile(fresh: true) else {
                tasks[task.taskIdentifier] = nil
                completion(.cancel)
                return // openPartFile already failed the job
            }
            if isEmptyFile {
                tasks[task.taskIdentifier] = nil
                completion(.cancel)
                finalize()
                return
            }
            tasks[task.taskIdentifier]?.index = 0
            record.status = .downloading
            completion(.allow)
            fillConnections()
            emit(checkpoint: true)
            return
        }

        let seg = record.segments[active.index]
        switch status {
        case 206:
            guard let cr = contentRange, cr.start == seg.offset else {
                completion(.cancel)
                restartAfterInconsistency("The server returned an unexpected byte range")
                return
            }
            if let total = cr.total, let expected = record.totalBytes, total != expected {
                completion(.cancel)
                restartAfterInconsistency("The file size changed on the server")
                return
            }
            record.status = .downloading
            completion(.allow)
        case 200:
            completion(.cancel)
            restartAfterInconsistency("The file changed on the server")
        default:
            tasks[task.taskIdentifier] = nil
            completion(.cancel)
            handleError(Self.describe(status: status), retryable: Self.isRetryable(status: status))
        }
    }

    fileprivate func didReceive(data: Data, task: URLSessionDataTask, session: URLSession) {
        guard session === self.session,
              let active = tasks[task.taskIdentifier],
              active.index >= 0, active.index < record.segments.count
        else { return }
        let index = active.index
        // Never write past the segment end, whatever the server sends.
        let count = Int(min(Int64(data.count), record.segments[index].remaining))
        if count > 0 {
            guard write(data, count: count, at: record.segments[index].offset) else {
                fail("Couldn't write to disk: \(String(cString: strerror(errno)))")
                return
            }
            record.segments[index].received += Int64(count)
            meter.add(Int64(count))
            consecutiveFailures = 0
        }
        if record.segments[index].isComplete {
            // The segment may have been shortened by a split; stop reading past its end.
            tasks[task.taskIdentifier] = nil
            task.cancel()
            segmentFinished()
        }
    }

    fileprivate func didComplete(task: URLSessionTask, error: Error?, session: URLSession) {
        guard session === self.session, let active = tasks.removeValue(forKey: task.taskIdentifier) else { return }
        if active.index < 0 {
            handleError(error?.localizedDescription ?? "No response from the server", retryable: Self.isRetryable(error))
            return
        }
        let index = active.index
        if error == nil, record.segments[index].isOpenEnded {
            // An unknown-length stream ended cleanly: now we know the size.
            let received = record.segments[index].received
            record.segments[index].end = received - 1
            record.totalBytes = received
        }
        if record.segments[index].isComplete {
            segmentFinished()
            return
        }
        handleError(error?.localizedDescription ?? "The connection closed before the data was complete",
                    retryable: Self.isRetryable(error))
    }

    private static func describe(status: Int) -> String {
        let reason = HTTPURLResponse.localizedString(forStatusCode: status)
        switch status {
        case 401, 403: return "Access denied (HTTP \(status)). The link may have expired."
        case 404, 410: return "File not found on the server (HTTP \(status))."
        default: return "Server error: HTTP \(status) \(reason)"
        }
    }

    // MARK: - First response

    private func adoptFirstResponse(_ http: HTTPURLResponse, contentRange: ContentRange?) {
        resolvedURL = http.url
        record.etag = http.value(forHTTPHeaderField: "ETag")
        record.lastModified = http.value(forHTTPHeaderField: "Last-Modified")

        if !record.userNamedFile {
            var name = http.value(forHTTPHeaderField: "Content-Disposition")
                .flatMap(FileNaming.fileName(fromContentDisposition:))
                ?? FileNaming.fileName(from: http.url ?? record.url)
            name = FileNaming.ensureExtension(name, mimeType: http.mimeType)
            record.fileName = FileNaming.sanitize(name)
        }

        if http.statusCode == 206, let cr = contentRange, cr.start == 0, let total = cr.total {
            record.supportsRanges = true
            record.totalBytes = total
            record.segments = [Segment(start: 0, end: total - 1)]
        } else {
            record.supportsRanges = false
            let length: Int64 = switch http.statusCode {
            case 206: -1 // partial content with unknown total: stream until close
            case 416: 0 // empty resource
            default: http.expectedContentLength
            }
            record.totalBytes = length >= 0 ? length : nil
            record.segments = [Segment(start: 0, end: length >= 0 ? length - 1 : .max)]
        }
    }

    // MARK: - Files

    private func openPartFile(fresh: Bool) -> Bool {
        do {
            try FileManager.default.createDirectory(at: record.directory, withIntermediateDirectories: true)
        } catch {
            fail("Can't create the destination folder: \(error.localizedDescription)")
            return false
        }
        if fresh {
            if let total = record.totalBytes,
               let free = try? record.directory
                   .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                   .volumeAvailableCapacityForImportantUsage,
               free < total {
                let needed = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
                fail("Not enough disk space (\(needed) needed).")
                return false
            }
            record.partFileName = "\(record.fileName).\(id.uuidString.prefix(8)).fluxpart"
        }
        guard let path = record.partFileURL?.path else { return false }
        closeFile()
        fd = open(path, fresh ? (O_RDWR | O_CREAT | O_TRUNC) : O_RDWR, 0o644)
        guard fd >= 0 else {
            if fresh { fail("Can't create the file: \(String(cString: strerror(errno)))") }
            return false
        }
        if fresh, let total = record.totalBytes, total > 0 {
            _ = ftruncate(fd, off_t(total)) // sparse preallocation: segments write anywhere
        }
        return true
    }

    private func write(_ data: Data, count: Int, at offset: Int64) -> Bool {
        guard fd >= 0 else { return false }
        let fd = self.fd
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var done = 0
            while done < count {
                let n = pwrite(fd, base + done, count - done, off_t(offset) + off_t(done))
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                done += n
            }
            return true
        }
    }

    private func syncAndCloseFile() {
        if fd >= 0 { fsync(fd) }
        closeFile()
    }

    private func closeFile() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    /// Validates the part file and atomically moves it into place.
    private func finalize() {
        stopTicker()
        syncAndCloseFile()
        guard let part = record.partFileURL else {
            fail("The partial file is missing.")
            return
        }
        guard let total = record.totalBytes, Segmenter.coversExactly(record.segments, total: total) else {
            restartAfterInconsistency("Downloaded pieces didn't add up to the whole file")
            return
        }
        if record.supportsRanges == false || total == 0 {
            _ = truncate(part.path, off_t(total))
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value
        guard size == total else {
            restartAfterInconsistency("The file on disk has the wrong size")
            return
        }

        var destination: URL?
        for _ in 0..<5 {
            let candidate = FileNaming.uniqueURL(for: record.fileName, in: record.directory)
            // rename(2) within one folder is atomic, and RENAME_EXCL never overwrites.
            if renamex_np(part.path, candidate.path, UInt32(RENAME_EXCL)) == 0 {
                destination = candidate
                break
            }
            if errno != EEXIST { break }
        }
        guard let destination else {
            fail("Couldn't move the finished file into place: \(String(cString: strerror(errno)))")
            return
        }
        DownloadMetadata.apply(to: destination, source: record.url)

        record.partFileName = nil
        record.finalPath = destination
        record.fileName = destination.lastPathComponent
        record.status = .completed
        record.completedAt = Date()
        record.errorMessage = nil
        isRunning = false
        generation += 1
        session?.finishTasksAndInvalidate()
        session = nil
        currentRate = 0
        Log.engine.info("Completed \(self.id, privacy: .public): \(total) bytes")
        emit(checkpoint: true)
    }

    // MARK: - Progress

    private func startTicker() {
        stopTicker()
        let interval = options.progressInterval
        ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self.tick(interval: interval)
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private func tick(interval: Duration) {
        guard isRunning else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let seconds = Double(interval.components.seconds) + Double(interval.components.attoseconds) / 1e18
        currentRate = meter.tick(now: now, interval: seconds)
        var checkpoint = false
        if now - lastCheckpoint >= options.checkpointInterval, fd >= 0 {
            fsync(fd)
            lastCheckpoint = now
            checkpoint = true
        }
        emit(checkpoint: checkpoint)
    }

    private func makeSnapshot(checkpoint: Bool) -> Snapshot {
        sequence += 1
        return Snapshot(
            record: record,
            bytesPerSecond: isRunning ? currentRate : 0,
            activeConnections: tasks.count,
            sequence: sequence,
            isCheckpoint: checkpoint
        )
    }

    private func emit(checkpoint: Bool = false) {
        onUpdate(makeSnapshot(checkpoint: checkpoint))
    }
}

/// Forwards URLSession callbacks into the job. They arrive on the job's own executor
/// queue (the delegate queue's `underlyingQueue`), so `assumeIsolated` is valid.
private final class SessionDelegate: NSObject, URLSessionDataDelegate, Sendable {
    let job: DownloadJob

    init(job: DownloadJob) { self.job = job }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        job.assumeIsolated { $0.didReceive(response: response, task: dataTask, session: session, completion: completionHandler) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        job.assumeIsolated { $0.didReceive(data: data, task: dataTask, session: session) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        job.assumeIsolated { $0.didComplete(task: task, error: error, session: session) }
    }
}
