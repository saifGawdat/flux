import Darwin
import Foundation

/// Downloads media from a web page (YouTube, Vimeo, …) by running yt-dlp.
///
/// yt-dlp works entirely inside a private temp folder next to the destination
/// (`.flux-<id>`), so pause/resume (`--continue`) and cancel (delete the folder) never
/// touch other files. When yt-dlp reports the finished file, Flux moves it into place
/// itself with the same never-overwrite rule as file downloads.
public actor MediaJob: TransferJob {
    private enum ProcessEvent: Sendable {
        case stdout(Data)
        case stderr(Data)
        case exit(Int32)
    }

    public nonisolated let id: UUID
    private let tools: MediaTools
    private let onUpdate: @Sendable (TransferSnapshot) -> Void

    private var record: DownloadRecord
    private var process: Process?
    private var runID = 0
    private var stopIntent: DownloadStatus?
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    private var stdoutBuffer = LineBuffer()
    private var stderrBuffer = LineBuffer()
    private var openStreams = 0
    private var exitCode: Int32?
    private var lastError: String?
    private var finalFile: String?
    private var detail: String?
    private var speed: Double = 0
    private var formatID: String?
    private var streamCount = 0
    private var sequence: UInt64 = 0
    private var lastEmit: TimeInterval = 0

    public init(record: DownloadRecord, tools: MediaTools, onUpdate: @escaping @Sendable (TransferSnapshot) -> Void) {
        self.id = record.id
        self.record = record
        self.tools = tools
        self.onUpdate = onUpdate
    }

    public var currentRecord: DownloadRecord { record }

    var workDirectory: URL {
        record.directory.appendingPathComponent(".flux-\(id.uuidString.prefix(8))", isDirectory: true)
    }

    // MARK: - Controls

    public func start() {
        guard process == nil, record.status != .completed else { return }
        guard let ytdlp = tools.ytdlp else {
            record.status = .failed
            record.errorMessage = "Video downloads need yt-dlp. Install it with: brew install yt-dlp ffmpeg"
            emit(checkpoint: true)
            return
        }
        do {
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        } catch {
            fail("Can't create the download folder: \(error.localizedDescription)")
            return
        }

        stopIntent = nil
        lastError = nil
        finalFile = nil
        speed = 0
        formatID = nil
        streamCount = 0
        stdoutBuffer = LineBuffer()
        stderrBuffer = LineBuffer()
        openStreams = 2
        exitCode = nil
        record.status = .connecting
        record.errorMessage = nil
        detail = "Fetching media info…"

        let process = Process()
        process.executableURL = ytdlp
        process.arguments = arguments()
        process.environment = tools.processEnvironment()
        process.currentDirectoryURL = workDirectory
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let (events, continuation) = AsyncStream.makeStream(of: ProcessEvent.self)
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            continuation.yield(.stdout(data))
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            continuation.yield(.stderr(data))
        }
        process.terminationHandler = { finished in
            continuation.yield(.exit(finished.terminationStatus))
        }

        do {
            try process.run()
        } catch {
            fail("Couldn't start yt-dlp: \(error.localizedDescription)")
            return
        }
        self.process = process
        runID += 1
        let run = runID
        Log.engine.info("Media download \(self.id, privacy: .public) started")
        Task {
            for await event in events {
                if self.handle(event, run: run) { break }
            }
            continuation.finish()
        }
        emit(checkpoint: true)
    }

    public func pause() async -> TransferSnapshot {
        await stopProcess(intent: .paused)
        if record.status != .completed {
            record.status = .paused
            detail = nil
        }
        emit(checkpoint: true)
        return makeSnapshot(checkpoint: true)
    }

    public func cancel() async -> TransferSnapshot {
        await stopProcess(intent: .cancelled)
        try? FileManager.default.removeItem(at: workDirectory)
        if record.status != .completed {
            record.status = .cancelled
            record.totalBytes = nil
            record.segments = []
            detail = nil
        }
        emit(checkpoint: true)
        return makeSnapshot(checkpoint: true)
    }

    public func suspendForShutdown() async -> DownloadRecord {
        await stopProcess(intent: record.status)
        return record
    }

    // MARK: - Process

    private func arguments() -> [String] {
        let outputName = record.userNamedFile
            ? (record.fileName as NSString).deletingPathExtension.replacingOccurrences(of: "%", with: "%%") + ".%(ext)s"
            : "%(title).180B.%(ext)s"
        var args = [
            // --print implies --quiet; --no-quiet keeps stage lines like [Merger] visible.
            "--no-quiet", "--newline", "--progress", "--no-simulate", "--no-playlist", "--continue", "--no-mtime",
            "--retries", "10", "--fragment-retries", "10",
            "-P", workDirectory.path,
            "-o", outputName,
            "--progress-template", MediaOutput.progressTemplate,
            "--print", MediaOutput.titleTemplate,
            "--print", MediaOutput.fileTemplate,
        ]
        args += (record.mediaFormat ?? .best).ytdlpArguments(hasFFmpeg: tools.ffmpeg != nil)
        if let ffmpeg = tools.ffmpeg { args += ["--ffmpeg-location", ffmpeg.path] }
        args += ["--", record.url.absoluteString]
        return args
    }

    /// Interrupts yt-dlp (it keeps partial data on SIGINT) and waits for it to exit,
    /// escalating to SIGTERM and SIGKILL if it hangs.
    private func stopProcess(intent: DownloadStatus) async {
        guard let process else { return }
        stopIntent = intent
        if process.isRunning { process.interrupt() }
        let run = runID
        let pid = process.processIdentifier
        Task {
            try? await Task.sleep(for: .seconds(5))
            guard self.runID == run, self.process != nil else { return }
            kill(pid, SIGTERM)
            try? await Task.sleep(for: .seconds(3))
            guard self.runID == run, self.process != nil else { return }
            kill(pid, SIGKILL)
        }
        await withCheckedContinuation { exitWaiters.append($0) }
    }

    /// Returns true once the run is fully finished.
    private func handle(_ event: ProcessEvent, run: Int) -> Bool {
        guard run == runID else { return true }
        switch event {
        case .stdout(let data):
            if data.isEmpty {
                openStreams -= 1
                stdoutBuffer.flush().forEach(handleLine)
            } else {
                stdoutBuffer.append(data).forEach(handleLine)
            }
        case .stderr(let data):
            if data.isEmpty {
                openStreams -= 1
                stderrBuffer.flush().forEach(handleLine)
            } else {
                stderrBuffer.append(data).forEach(handleLine)
            }
        case .exit(let code):
            exitCode = code
            // A child (ffmpeg) can keep the pipes open briefly; don't wait on it forever.
            Task {
                try? await Task.sleep(for: .seconds(2))
                if self.runID == run, self.process != nil, let code = self.exitCode {
                    self.finish(code: code)
                }
            }
        }
        if openStreams <= 0, let code = exitCode, process != nil {
            finish(code: code)
            return true
        }
        return process == nil
    }

    private func handleLine(_ line: String) {
        switch MediaOutput.parse(line) {
        case .title(let title):
            record.title = title
            if !record.userNamedFile, record.finalPath == nil {
                record.fileName = FileNaming.sanitize(title)
            }
        case .progress(let p):
            if p.formatID != formatID {
                formatID = p.formatID
                streamCount += 1
            }
            let downloaded = p.downloaded ?? 0
            let total = p.total ?? p.estimate
            record.totalBytes = total
            record.segments = [Segment(start: 0, end: total.map { max($0, downloaded) - 1 } ?? .max, received: downloaded)]
            record.status = .downloading
            speed = p.status == "finished" ? 0 : (p.speed ?? 0)
            detail = streamCount > 1 ? "Downloading stream \(streamCount)" : nil
            emitThrottled()
        case .postProcessing(let text):
            detail = text
            speed = 0
            emit()
        case .finalFile(let path):
            finalFile = path
        case .error(let message):
            lastError = message
        case .other:
            break
        }
    }

    private func finish(code: Int32) {
        guard process != nil else { return }
        process = nil
        let waiters = exitWaiters
        exitWaiters.removeAll()
        defer { waiters.forEach { $0.resume() } }

        if stopIntent != nil { return } // pause/cancel/shutdown set the status themselves
        if code == 0, let finalFile {
            complete(URL(fileURLWithPath: finalFile))
        } else if code == 0 {
            fail("yt-dlp finished without producing a file.")
        } else {
            fail(Self.friendly(lastError) ?? "yt-dlp stopped with exit code \(code).")
        }
    }

    private func complete(_ produced: URL) {
        var destination: URL?
        for _ in 0..<5 {
            let candidate = FileNaming.uniqueURL(for: FileNaming.sanitize(produced.lastPathComponent), in: record.directory)
            if renamex_np(produced.path, candidate.path, UInt32(RENAME_EXCL)) == 0 {
                destination = candidate
                break
            }
            if errno != EEXIST { break }
        }
        guard let destination else {
            fail("Couldn't move the finished file into place: \(String(cString: strerror(errno)))")
            return
        }
        try? FileManager.default.removeItem(at: workDirectory)
        DownloadMetadata.apply(to: destination, source: record.url)

        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        record.finalPath = destination
        record.fileName = destination.lastPathComponent
        record.totalBytes = size
        record.segments = [Segment(start: 0, end: size - 1, received: size)]
        record.status = .completed
        record.completedAt = Date()
        record.errorMessage = nil
        detail = nil
        speed = 0
        Log.engine.info("Media download \(self.id, privacy: .public) completed: \(size) bytes")
        emit(checkpoint: true)
    }

    private func fail(_ message: String) {
        Log.engine.error("Media download \(self.id, privacy: .public) failed: \(message, privacy: .public)")
        record.status = .failed
        record.errorMessage = message
        detail = nil
        speed = 0
        emit(checkpoint: true)
    }

    /// Turns common yt-dlp errors into plain language.
    static func friendly(_ message: String?) -> String? {
        guard let message else { return nil }
        let lower = message.lowercased()
        if lower.contains("unsupported url") { return "No downloadable media found on this page." }
        if lower.contains("private video") { return "This video is private." }
        if lower.contains("sign in to confirm your age") { return "This video is age-restricted and needs a signed-in account." }
        if lower.contains("video unavailable") { return "This video is unavailable." }
        if lower.contains("ffmpeg") && lower.contains("not found") {
            return "This format needs ffmpeg. Install it with: brew install ffmpeg"
        }
        // Drop yt-dlp's "[extractor] id: " prefix.
        if let range = message.range(of: #"^\[[^\]]+\] [^:]+: "#, options: .regularExpression) {
            return String(message[range.upperBound...])
        }
        return message
    }

    // MARK: - Snapshots

    private func makeSnapshot(checkpoint: Bool) -> TransferSnapshot {
        sequence += 1
        return TransferSnapshot(
            record: record,
            bytesPerSecond: process != nil ? speed : 0,
            activeConnections: process != nil ? 1 : 0,
            sequence: sequence,
            isCheckpoint: checkpoint,
            detail: detail)
    }

    private func emit(checkpoint: Bool = false) {
        lastEmit = ProcessInfo.processInfo.systemUptime
        onUpdate(makeSnapshot(checkpoint: checkpoint))
    }

    private func emitThrottled() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastEmit >= 0.25 { emit(checkpoint: true) }
    }
}
