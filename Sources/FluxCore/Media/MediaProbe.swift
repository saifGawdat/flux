import Foundation

/// What each format choice would produce for one link, before downloading.
public struct MediaPreview: Sendable, Equatable {
    public struct Option: Sendable, Equatable {
        /// Video height in pixels; nil for audio-only results.
        public var height: Int?
        public var fileExtension: String
        public var bytes: Int64?
        /// Size is an estimate (merged streams, or audio that will be converted).
        public var isEstimate: Bool
    }

    public var title: String
    public var duration: Double?
    public var options: [MediaFormat: Option]
}

public enum MediaProbeError: LocalizedError {
    case toolMissing
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .toolMissing: "yt-dlp isn't installed."
        case .failed(let message): message
        }
    }
}

/// Asks yt-dlp about a link without downloading it. The page is fetched once (`-J`);
/// each format choice is then resolved offline from that JSON (`--load-info-json`) with
/// the exact selector the download will use, so sizes match what you'll get.
public enum MediaProbe {
    static let printTemplate = "%(resolution)s|%(ext)s|%(filesize)s|%(filesize_approx)s|%(height)s"

    public static func preview(of url: URL, tools: MediaTools) async throws -> MediaPreview {
        guard let ytdlp = tools.ytdlp else { throw MediaProbeError.toolMissing }
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("flux-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let infoFile = workDir.appendingPathComponent("info.json")
        let env = tools.processEnvironment()
        let fetch = try await ProcessRunner.run(
            ytdlp, ["-J", "--no-playlist", "--no-warnings", "--", url.absoluteString],
            environment: env, stdoutFile: infoFile)
        guard fetch.status == 0 else {
            let message = fetch.stderrLines.last { $0.hasPrefix("ERROR: ") }.map { String($0.dropFirst(7)) }
            throw MediaProbeError.failed(MediaJob.friendly(message) ?? "Couldn't read this page.")
        }
        let (title, duration) = try summary(of: infoFile)

        let options = await withTaskGroup(of: (MediaFormat, MediaPreview.Option?).self) { group in
            for format in MediaFormat.allCases {
                group.addTask {
                    let option = try? await resolve(format, ytdlp: ytdlp, infoFile: infoFile, tools: tools,
                                                     environment: env, duration: duration)
                    return (format, option)
                }
            }
            var result: [MediaFormat: MediaPreview.Option] = [:]
            for await (format, option) in group {
                if let option { result[format] = option }
            }
            return result
        }
        try Task.checkCancellation()
        return MediaPreview(title: title, duration: duration, options: options)
    }

    static func summary(of infoFile: URL) throws -> (String, Double?) {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: infoFile)) as? [String: Any]
        guard let object else { throw MediaProbeError.failed("yt-dlp returned unreadable data.") }
        let title = object["title"] as? String ?? "Untitled"
        let duration = (object["duration"] as? NSNumber)?.doubleValue
        return (title, duration)
    }

    private static func resolve(
        _ format: MediaFormat, ytdlp: URL, infoFile: URL, tools: MediaTools,
        environment: [String: String], duration: Double?
    ) async throws -> MediaPreview.Option? {
        var args = ["--load-info-json", infoFile.path, "--simulate", "--no-warnings", "--print", printTemplate]
        args += format.ytdlpArguments(hasFFmpeg: tools.ffmpeg != nil)
        if let ffmpeg = tools.ffmpeg { args += ["--ffmpeg-location", ffmpeg.path] }
        let result = try await ProcessRunner.run(ytdlp, args, environment: environment)
        guard result.status == 0, let line = result.stdoutLines.first else { return nil }
        return parseOption(line, format: format, hasFFmpeg: tools.ffmpeg != nil, duration: duration)
    }

    /// Parses one `printTemplate` line. Audio that will be converted gets its output
    /// format and a bitrate-based size estimate.
    static func parseOption(_ line: String, format: MediaFormat, hasFFmpeg: Bool, duration: Double?) -> MediaPreview.Option? {
        let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 5 else { return nil }
        let isAudio = f[0] == "audio only"
        let exact = Double(f[2]).map { Int64($0) }
        let approx = Double(f[3]).map { Int64($0) }
        var option = MediaPreview.Option(
            height: isAudio ? nil : Int(f[4]),
            fileExtension: f[1],
            bytes: exact ?? approx,
            isEstimate: exact == nil)
        if hasFFmpeg && format == .mp3 {
            option.fileExtension = "mp3"
            // LAME V0 averages ~245 kbit/s.
            if let duration { option.bytes = Int64(duration * 245_000 / 8) }
            option.isEstimate = true
        } else if hasFFmpeg && format == .m4a {
            option.fileExtension = "m4a"
        }
        return option
    }
}

/// Runs a short-lived command, capturing output in temp files (no pipe-buffer deadlocks).
/// Cancelling the calling task terminates the process.
enum ProcessRunner {
    struct Result: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: Data
        var stdoutLines: [String] { lines(stdout) }
        var stderrLines: [String] { lines(stderr) }
        private func lines(_ data: Data) -> [String] {
            String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        }
    }

    static func run(_ executable: URL, _ arguments: [String], environment: [String: String], stdoutFile: URL? = nil) async throws -> Result {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("flux-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let outURL = stdoutFile ?? scratch.appendingPathComponent("out")
        let errURL = scratch.appendingPathComponent("err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outHandle
        process.standardError = errHandle

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try? outHandle.close()
        try? errHandle.close()
        try Task.checkCancellation()
        return Result(
            status: process.terminationStatus,
            stdout: (try? Data(contentsOf: outURL)) ?? Data(),
            stderr: (try? Data(contentsOf: errURL)) ?? Data())
    }
}
