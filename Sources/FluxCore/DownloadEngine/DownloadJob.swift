import Darwin
import Foundation

/// Downloads one file over one or more HTTP connections. See docs/ARCHITECTURE.md (D1–D5).
///
/// The actor executes on a private serial queue that is also the URLSession delegate
/// queue, so delegate callbacks enter the actor synchronously and in arrival order.
public actor DownloadJob: TransferJob {
    public typealias Snapshot = TransferSnapshot

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
        /// Stop (and flag the snapshot) when a link returns an HTML page instead of a file.
        public var detectWebPages = true
        /// The global speed limit, shared by every running download.
        public var sharedLimiter: SpeedLimiter?
        /// Under a speed limit, one connection per this many bytes/s of allowed speed:
        /// more connections can't go faster; each only adds its own read-ahead burst.
        public var bytesPerSecondPerConnection: Int64 = 1_000_000
        public init() {}
    }

    private struct ActiveTask {
        let task: URLSessionDataTask
        /// Segment index, or -1 while the first (probing) response is pending.
        var index: Int
        /// Index into `sources`: which link (main or mirror) this connection uses.
        let source: Int
        /// Last byte this request asked for (inclusive); `Int64.max` for "to the end".
        var requestEnd: Int64
    }

    /// The main link or one of its mirrors.
    private struct Source {
        let url: URL
        /// Where the link redirected to, to skip the redirect on later connections.
        var resolved: URL?
        /// Why this source was dropped (wrong file, gone, refuses ranges).
        var dropped: String?
        var consecutiveFailures = 0
        var isUsable: Bool { dropped == nil }
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
    private var landedOnWebPage = false
    private var detail: String?
    private var sources: [Source] = []
    /// The source whose first response defined the file (size, validators). A different
    /// size from any other source means that source serves something else.
    private var referenceSource = 0
    /// The server stated the size before the data arrived (Content-Range or Content-Length).
    private var serverStatedSize = false
    private let ownLimiter = SpeedLimiter()
    /// Connections paused because a speed limit is reached (task identifiers). Only used
    /// for servers without ranges; ranged downloads are paced instead (see `paceNext`).
    private var throttled: Set<Int> = []
    /// Segments waiting for the speed limit before their next paced request.
    private var pacing: Set<Int> = []
    private var verification: Task<Void, Never>?
    /// Cleared when the server ignores `If-Range` for an unchanged file (see `didReceive`).
    private var sendIfRange = true

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
        ownLimiter.setLimit(record.speedLimit)
    }

    // MARK: - Controls

    public var currentRecord: DownloadRecord { record }

    public func start() {
        guard !isRunning, record.status != .completed else { return }
        isRunning = true
        landedOnWebPage = false
        generation += 1
        consecutiveFailures = 0
        restarts = 0
        connectionLimit = record.maxConnections
        record.errorMessage = nil
        record.status = .connecting
        detail = nil
        sources = record.sources.map { Source(url: $0) }
        referenceSource = 0
        sendIfRange = true
        // A resumable download with a known size got that size from the server.
        serverStatedSize = record.supportsRanges && record.totalBytes != nil
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

    /// Applies a new per-download limit and re-reads the shared one, immediately.
    public func setSpeedLimit(_ bytesPerSecond: Int64?) {
        record.speedLimit = bytesPerSecond
        ownLimiter.setLimit(bytesPerSecond)
        guard isRunning else { return }
        for id in throttled { unthrottle(id, generation: generation) }
        for index in pacing { relaunchPaced(index, generation: generation) }
        fillConnections()
    }

    // MARK: - Lifecycle

    private func stop(status: DownloadStatus, message: String? = nil, notify: Bool = true) {
        if isRunning {
            isRunning = false
            generation += 1
            verification?.cancel()
            verification = nil
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
        detail = nil
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
        if isRunning, ticker == nil { startTicker() } // finalize stops it before checking
        launch(index: -1)
    }

    private func restartAfterInconsistency(_ reason: String) {
        restarts += 1
        Log.engine.notice("Restarting \(self.id, privacy: .public): \(reason, privacy: .public)")
        if restarts > options.maxRestarts {
            fail(reason)
        } else {
            detail = "Started over: \(reason.prefix(1).lowercased() + reason.dropFirst())"
            restartFresh()
            emit()
        }
    }

    // MARK: - Connections

    private func launch(index: Int) {
        guard let session, let source = pickSource(probing: index < 0) else { return }
        var request = URLRequest(url: sources[source].resolved ?? sources[source].url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let referer = record.referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        let chunk = pacedChunkSize
        var requestEnd = Int64.max
        if index < 0 {
            if let chunk { requestEnd = chunk - 1 }
            request.setValue("bytes=0-\(requestEnd == .max ? "" : String(requestEnd))", forHTTPHeaderField: "Range")
        } else {
            let seg = record.segments[index]
            if !seg.isOpenEnded { requestEnd = chunk.map { min(seg.end, seg.offset + $0 - 1) } ?? seg.end }
            request.setValue("bytes=\(seg.offset)-\(requestEnd == .max ? "" : String(requestEnd))", forHTTPHeaderField: "Range")
            // If the file changed, If-Range makes the server answer 200 with the whole new
            // file rather than a 206 slice that would mix two versions. Validators belong
            // to the main link's server; mirrors are checked by size instead.
            if source == 0, sendIfRange {
                if let etag = record.etag, Self.isStrongETag(etag) {
                    request.setValue(etag, forHTTPHeaderField: "If-Range")
                } else if let lastModified = record.lastModified {
                    request.setValue(lastModified, forHTTPHeaderField: "If-Range")
                }
            }
        }
        let task = session.dataTask(with: request)
        tasks[task.taskIdentifier] = ActiveTask(task: task, index: index, source: source, requestEnd: requestEnd)
        task.resume()
    }

    /// Under a speed limit, ranged requests ask for about half a second of data at a time.
    /// URLSession keeps reading a paused connection into memory, so pausing can't hold a
    /// limit; a server can't send more than was asked for, so pacing requests can.
    private var pacedChunkSize: Int64? {
        guard let limit = limiters.tightestLimit else { return nil }
        return min(8 << 20, max(64 << 10, limit / 2))
    }

    /// The first usable link for the probe; otherwise the usable link with the fewest
    /// connections, so connections spread evenly across mirrors.
    private func pickSource(probing: Bool) -> Int? {
        let usable = sources.indices.filter { sources[$0].isUsable }
        if probing { return usable.first }
        var load = [Int: Int]()
        for active in tasks.values { load[active.source, default: 0] += 1 }
        return usable.min { (load[$0] ?? 0, $0) < (load[$1] ?? 0, $1) }
    }

    /// Takes a link out of use. Returns false when no usable link is left.
    private func drop(source: Int, reason: String) -> Bool {
        guard sources.indices.contains(source), sources[source].isUsable else {
            return sources.contains(where: \.isUsable)
        }
        sources[source].dropped = reason
        let left = sources.filter(\.isUsable).count
        Log.engine.notice("Download \(self.id, privacy: .public): dropped source \(source): \(reason, privacy: .public)")
        if left > 0, sources.count > 1 {
            detail = source == 0 ? "Main link failed, using mirrors" : "\(left) of \(sources.count) links working"
        }
        return left > 0
    }

    /// Fewer connections under a tight speed limit; see `Options.bytesPerSecondPerConnection`.
    private var effectiveConnectionLimit: Int {
        guard let limit = limiters.tightestLimit else { return connectionLimit }
        let allowed = Int(limit / max(1, options.bytesPerSecondPerConnection))
        return max(1, min(connectionLimit, allowed))
    }

    private var limiters: [SpeedLimiter] {
        [ownLimiter] + (options.sharedLimiter.map { [$0] } ?? [])
    }

    /// Keeps `connectionLimit` connections busy: resume idle segments first, then split.
    private func fillConnections() {
        guard isRunning, record.supportsRanges else { return }
        var busy = Set(tasks.values.map(\.index)).union(pacing)
        while tasks.count + pacing.count < effectiveConnectionLimit {
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
        throttled.removeAll()
        pacing.removeAll()
        for active in all { active.task.cancel() }
    }

    // MARK: - Speed limits

    /// Pauses one connection until the speed limits allow more data. A paused
    /// URLSession task stops reading from its socket, so the server slows down too.
    private func throttle(_ task: URLSessionDataTask) {
        let id = task.taskIdentifier
        guard throttled.insert(id).inserted else { return }
        task.suspend()
        scheduleUnthrottle(id, after: limiters.delay())
    }

    private func scheduleUnthrottle(_ id: Int, after wait: TimeInterval) {
        let gen = generation
        // Re-check at least every second so a raised limit takes effect quickly.
        let nap = min(max(wait, 0.01), 1)
        Task {
            try? await Task.sleep(for: .seconds(nap))
            self.unthrottle(id, generation: gen)
        }
    }

    /// A paced request delivered its chunk: ask for the next one once the limit allows.
    private func paceNext(_ index: Int) {
        pacing.insert(index)
        let wait = limiters.delay()
        if wait <= 0.005 {
            relaunchPaced(index, generation: generation)
            return
        }
        let gen = generation
        Task {
            try? await Task.sleep(for: .seconds(min(wait, 1)))
            self.relaunchPaced(index, generation: gen)
        }
    }

    private func relaunchPaced(_ index: Int, generation gen: Int) {
        guard generation == gen, isRunning, pacing.contains(index) else { return }
        guard record.segments.indices.contains(index), !record.segments[index].isComplete else {
            pacing.remove(index)
            segmentFinished()
            return
        }
        if limiters.delay() > 0.005 {
            pacing.remove(index)
            paceNext(index)
            return
        }
        pacing.remove(index)
        launch(index: index)
    }

    private func unthrottle(_ id: Int, generation gen: Int) {
        guard generation == gen, throttled.contains(id) else { return }
        guard let active = tasks[id] else {
            throttled.remove(id)
            return
        }
        let wait = limiters.delay()
        if wait > 0.02 {
            scheduleUnthrottle(id, after: wait)
            return
        }
        throttled.remove(id)
        active.task.resume()
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
        let source = active.source
        if let url = http.url, sources.indices.contains(source) { sources[source].resolved = url }

        if active.index < 0 {
            let isEmptyFile = status == 416 && ContentRange.isEmptyResource(http.value(forHTTPHeaderField: "Content-Range"))
            guard (200..<300).contains(status) || isEmptyFile else {
                tasks[task.taskIdentifier] = nil
                completion(.cancel)
                sourceFailed(source, message: Self.describe(status: status), retryable: Self.isRetryable(status: status), probing: true)
                return
            }
            if options.detectWebPages, !isEmptyFile, http.mimeType?.lowercased() == "text/html" {
                tasks[task.taskIdentifier] = nil
                completion(.cancel)
                landedOnWebPage = true
                fail("This link opens a web page, not a file.")
                return
            }
            referenceSource = source
            adoptFirstResponse(http, contentRange: contentRange, fromMainLink: source == 0)
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
            // A server that ignored the range sends everything; it can't be paced.
            if !record.supportsRanges { tasks[task.taskIdentifier]?.requestEnd = .max }
            record.status = .downloading
            completion(.allow)
            fillConnections()
            emit(checkpoint: true)
            return
        }

        let seg = record.segments[active.index]
        let isReference = source == referenceSource
        switch status {
        case 206:
            guard let cr = contentRange, cr.start == seg.offset else {
                completion(.cancel)
                if isReference {
                    restartAfterInconsistency("The server returned an unexpected byte range")
                } else {
                    rejectMirror(task, source: source, reason: "sent the wrong part of the file")
                }
                return
            }
            if let total = cr.total, let expected = record.totalBytes, total != expected {
                completion(.cancel)
                if isReference {
                    restartAfterInconsistency("The file size changed on the server")
                } else {
                    rejectMirror(task, source: source, reason: "has a different file (\(total) bytes, expected \(expected))")
                }
                return
            }
            sources[source].consecutiveFailures = 0
            record.status = .downloading
            completion(.allow)
        case 200:
            completion(.cancel)
            let askedIfRange = task.originalRequest?.value(forHTTPHeaderField: "If-Range") != nil
            if isReference, askedIfRange, Self.describesSameFile(http, as: record) {
                // Same file, but the server didn't honor If-Range (some CDNs only accept
                // one kind of validator). Carry on without it; sizes are still checked.
                Log.engine.notice("Download \(self.id, privacy: .public): server ignores If-Range; continuing without it")
                sendIfRange = false
                tasks[task.taskIdentifier] = nil
                launch(index: active.index)
            } else if isReference {
                restartAfterInconsistency("The file changed on the server")
            } else {
                rejectMirror(task, source: source, reason: "can't send parts of the file")
            }
        default:
            tasks[task.taskIdentifier] = nil
            completion(.cancel)
            sourceFailed(source, message: Self.describe(status: status), retryable: Self.isRetryable(status: status), probing: false)
        }
    }

    /// A mirror answered with something unusable: stop using it, keep the download going.
    private func rejectMirror(_ task: URLSessionDataTask, source: Int, reason: String) {
        tasks[task.taskIdentifier] = nil
        let host = sources[source].url.host() ?? "A mirror"
        if drop(source: source, reason: "\(host) \(reason)") {
            fillConnections()
            emit()
        } else {
            fail("No working link left: \(host) \(reason).")
        }
    }

    /// A link returned an error. Permanent errors (404, 403, …) take that link out of use
    /// when another link can carry on; otherwise the usual retry with backoff applies.
    private func sourceFailed(_ source: Int, message: String, retryable: Bool, probing: Bool) {
        let hasOthers = sources.indices.contains { $0 != source && sources[$0].isUsable }
        if sources.indices.contains(source) { sources[source].consecutiveFailures += 1 }
        let failures = sources.indices.contains(source) ? sources[source].consecutiveFailures : 0
        if hasOthers, !retryable || failures >= 3 {
            _ = drop(source: source, reason: message)
            if probing { restartFresh() } else { fillConnections() }
            emit()
            return
        }
        handleError(message, retryable: retryable)
    }

    fileprivate func didReceive(data: Data, task: URLSessionDataTask, session: URLSession) {
        guard session === self.session,
              let active = tasks[task.taskIdentifier],
              active.index >= 0, active.index < record.segments.count
        else { return }
        let index = active.index
        // Never write past the segment end or past what was asked for, whatever the server sends.
        let asked = active.requestEnd == .max ? Int64.max : max(0, active.requestEnd - record.segments[index].offset + 1)
        let count = Int(min(Int64(data.count), record.segments[index].remaining, asked))
        if count > 0 {
            guard write(data, count: count, at: record.segments[index].offset) else {
                fail("Couldn't write to disk: \(String(cString: strerror(errno)))")
                return
            }
            record.segments[index].received += Int64(count)
            meter.add(Int64(count))
            consecutiveFailures = 0
            let wait = limiters.consume(Int64(count))
            if wait > 0.02, active.requestEnd == .max, !record.segments[index].isComplete {
                throttle(task)
            }
        }
        if record.segments[index].isComplete {
            // The segment may have been shortened by a split; stop reading past its end.
            tasks[task.taskIdentifier] = nil
            task.cancel()
            segmentFinished()
        } else if active.requestEnd != .max, record.segments[index].offset > active.requestEnd {
            // This paced request is done; the response ends here, so the connection is reused.
            tasks[task.taskIdentifier] = nil
            paceNext(index)
        }
    }

    fileprivate func didComplete(task: URLSessionTask, error: Error?, session: URLSession) {
        guard session === self.session, let active = tasks.removeValue(forKey: task.taskIdentifier) else { return }
        throttled.remove(task.taskIdentifier)
        if active.index < 0 {
            sourceFailed(active.source, message: error?.localizedDescription ?? "No response from the server",
                         retryable: Self.isRetryable(error), probing: true)
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
        sourceFailed(active.source, message: error?.localizedDescription ?? "The connection closed before the data was complete",
                     retryable: Self.isRetryable(error), probing: false)
    }

    /// RFC 9110 entity tags are quoted; some servers send them bare, and then won't match
    /// them in If-Range either. Weak tags (`W/"…"`) aren't allowed in If-Range.
    static func isStrongETag(_ etag: String) -> Bool {
        etag.count >= 2 && etag.hasPrefix("\"") && etag.hasSuffix("\"")
    }

    /// A full (200) response that still has the same size and validators as before.
    static func describesSameFile(_ http: HTTPURLResponse, as record: DownloadRecord) -> Bool {
        guard let total = record.totalBytes, http.expectedContentLength == total else { return false }
        let etag = http.value(forHTTPHeaderField: "ETag")
        let lastModified = http.value(forHTTPHeaderField: "Last-Modified")
        var matched = false
        if let known = record.etag {
            guard etag == known else { return false }
            matched = true
        }
        if let known = record.lastModified {
            guard lastModified == known else { return false }
            matched = true
        }
        return matched
    }

    private static func describe(status: Int) -> String {
        let reason = HTTPURLResponse.localizedString(forStatusCode: status)
        switch status {
        case 401, 403: return "Access denied (HTTP \(status)). The link may have expired: use Update Link to continue with a new one."
        case 404, 410: return "File not found on the server (HTTP \(status))."
        default: return "Server error: HTTP \(status) \(reason)"
        }
    }

    // MARK: - First response

    private func adoptFirstResponse(_ http: HTTPURLResponse, contentRange: ContentRange?, fromMainLink: Bool) {
        // Validators are sent back only to the main link (see `launch`).
        record.etag = fromMainLink ? http.value(forHTTPHeaderField: "ETag") : nil
        record.lastModified = fromMainLink ? http.value(forHTTPHeaderField: "Last-Modified") : nil

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
        serverStatedSize = record.totalBytes != nil
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
        record.sizeVerified = serverStatedSize

        if let checksum = record.checksum {
            verify(part, against: checksum)
        } else {
            moveIntoPlace(part)
        }
    }

    /// Hashes the finished part file off the actor, then places it or fails. A file that
    /// doesn't match never appears under its real name, and Retry downloads it afresh.
    private func verify(_ part: URL, against checksum: Checksum) {
        detail = "Verifying \(checksum.algorithm.title)…"
        currentRate = 0
        emit()
        let gen = generation
        verification = Task {
            let result: Result<Bool, Error>
            do { result = .success(try await checksum.matches(part)) } catch { result = .failure(error) }
            self.finishVerification(result, part: part, checksum: checksum, generation: gen)
        }
    }

    private func finishVerification(_ result: Result<Bool, Error>, part: URL, checksum: Checksum, generation gen: Int) {
        guard generation == gen, isRunning else { return }
        verification = nil
        switch result {
        case .success(true):
            record.checksumVerified = true
            moveIntoPlace(part)
        case .success(false):
            record.checksumVerified = false
            discardPartialData()
            fail("The downloaded file doesn't match the expected \(checksum.algorithm.title) checksum, so it was discarded. Retry to download it again.")
        case .failure(let error):
            fail("Couldn't verify the checksum: \(error.localizedDescription)")
        }
    }

    private func moveIntoPlace(_ part: URL) {
        let total = record.totalBytes ?? 0
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
        detail = nil
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
            isCheckpoint: checkpoint,
            detail: isRunning ? detail : nil,
            landedOnWebPage: landedOnWebPage
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
