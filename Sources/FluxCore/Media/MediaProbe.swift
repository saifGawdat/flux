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
    /// Which formats a choice resolves to; sizes are then looked up in the page JSON.
    static let printTemplate = "%(format_id)s|%(resolution)s|%(ext)s|%(height)s"

    /// Streaming (HLS/DASH manifest) formats list only a *peak* bitrate. Measured on
    /// YouTube, the real average is about 60% of it.
    static let streamedAverageToPeak = 0.6

    struct FormatSize: Equatable {
        var filesize: Int64?
        var filesizeApprox: Int64?
        var tbr: Double? // kbit/s
        var isStreamed: Bool
    }

    struct PageInfo {
        var title: String
        var duration: Double?
        var formats: [String: FormatSize]
    }

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
        let page = try pageInfo(from: Data(contentsOf: infoFile))

        let options = await withTaskGroup(of: (MediaFormat, MediaPreview.Option?).self) { group in
            for format in MediaFormat.allCases {
                group.addTask {
                    let option = try? await resolve(format, ytdlp: ytdlp, infoFile: infoFile, tools: tools,
                                                     environment: env, page: page)
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
        return MediaPreview(title: page.title, duration: page.duration, options: options)
    }

    static func pageInfo(from data: Data) throws -> PageInfo {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MediaProbeError.failed("yt-dlp returned unreadable data.")
        }
        func int(_ value: Any?) -> Int64? { (value as? NSNumber).map { Int64($0.doubleValue) } }
        var formats: [String: FormatSize] = [:]
        for entry in object["formats"] as? [[String: Any]] ?? [] {
            guard let id = entry["format_id"] as? String else { continue }
            let proto = (entry["protocol"] as? String ?? "").lowercased()
            formats[id] = FormatSize(
                filesize: int(entry["filesize"]),
                filesizeApprox: int(entry["filesize_approx"]),
                tbr: (entry["tbr"] as? NSNumber)?.doubleValue,
                isStreamed: proto.contains("m3u8") || proto.contains("dash") || proto.contains("ism"))
        }
        return PageInfo(
            title: object["title"] as? String ?? "Untitled",
            duration: (object["duration"] as? NSNumber)?.doubleValue,
            formats: formats)
    }

    private static func resolve(
        _ format: MediaFormat, ytdlp: URL, infoFile: URL, tools: MediaTools,
        environment: [String: String], page: PageInfo
    ) async throws -> MediaPreview.Option? {
        var args = ["--load-info-json", infoFile.path, "--simulate", "--no-warnings", "--print", printTemplate]
        args += format.ytdlpArguments(hasFFmpeg: tools.ffmpeg != nil)
        if let ffmpeg = tools.ffmpeg { args += ["--ffmpeg-location", ffmpeg.path] }
        let result = try await ProcessRunner.run(ytdlp, args, environment: environment)
        guard result.status == 0, let line = result.stdoutLines.first else { return nil }
        return parseOption(line, format: format, hasFFmpeg: tools.ffmpeg != nil, page: page)
    }

    /// Sums the sizes of the formats a choice resolves to (e.g. `137+140`).
    static func parseOption(_ line: String, format: MediaFormat, hasFFmpeg: Bool, page: PageInfo) -> MediaPreview.Option? {
        let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 4, !f[0].isEmpty, f[0] != "NA" else { return nil }
        let isAudio = f[1] == "audio only"
        var option = MediaPreview.Option(height: isAudio ? nil : Int(f[3]), fileExtension: f[2], bytes: nil, isEstimate: false)

        var total: Int64 = 0
        var complete = true
        var sourceKbps: Double?
        for id in f[0].split(separator: "+").map(String.init) {
            guard let size = page.formats[id] else { complete = false; break }
            if let tbr = size.tbr { sourceKbps = (sourceKbps ?? 0) + tbr }
            if let exact = size.filesize {
                total += exact
            } else if let approx = size.filesizeApprox {
                total += approx
                option.isEstimate = true
            } else if let tbr = size.tbr, let duration = page.duration {
                let factor = size.isStreamed ? streamedAverageToPeak : 1
                total += Int64(tbr * 1000 / 8 * duration * factor)
                option.isEstimate = true
            } else {
                complete = false
                break
            }
        }
        if complete { option.bytes = total }

        if hasFFmpeg && format == .mp3 {
            option.fileExtension = "mp3"
            // LAME V0 is variable bitrate and follows the source: measured on YouTube,
            // 106 kbit/s Opus → 139 kbit/s MP3 and 152 → 226, so ~1.4× the source.
            if let duration = page.duration {
                let kbps = sourceKbps.map { min(max($0 * 1.4, 96), 245) } ?? 192
                option.bytes = Int64(duration * kbps * 1000 / 8)
            }
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
