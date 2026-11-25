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

/// A list of videos (YouTube playlist or channel, SoundCloud set, Vimeo showcase, …).
public struct MediaPlaylist: Sendable, Equatable {
    public struct Entry: Sendable, Equatable, Identifiable {
        /// The entry's URL, which is unique within a playlist.
        public var id: String
        public var url: URL
        public var title: String
        public var duration: Double?
        public var thumbnailURL: URL?
        /// Private, deleted or not yet premiered.
        public var isAvailable: Bool
        /// A nested list (a channel's playlists); expanded before it reaches the UI.
        var isPlaylist: Bool = false
    }

    public var title: String
    public var uploader: String?
    public var entries: [Entry]
    /// Only the first `MediaProbe.playlistLimit` entries were read.
    public var isTruncated: Bool

    public var availableEntries: [Entry] { entries.filter(\.isAvailable) }
}

/// What yt-dlp found behind a link: a single video, a playlist, or (YouTube video opened
/// from a playlist) both.
public struct MediaInspection: Sendable, Equatable {
    public var video: MediaPreview?
    public var playlist: MediaPlaylist?
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
        try await withInfo(of: url, playlist: false, tools: tools) { infoFile, json in
            try await options(infoFile: infoFile, json: json, tools: tools)
        }
    }

    /// Looks at a link that may be a playlist (or channel). For a YouTube video opened
    /// from a playlist (`watch?v=…&list=…`) both the video and its playlist are returned.
    public static func inspect(_ url: URL, tools: MediaTools) async throws -> MediaInspection {
        let alsoSingle = Self.isVideoInPlaylist(url)
        async let single: MediaPreview? = alsoSingle ? try? await preview(of: url, tools: tools) : nil
        let first = try await withInfo(of: url, playlist: true, tools: tools) { infoFile, json -> MediaInspection in
            if let playlist = try playlistInfo(from: json) {
                return MediaInspection(video: nil, playlist: try await expandNested(playlist, tools: tools))
            }
            return MediaInspection(video: try await options(infoFile: infoFile, json: json, tools: tools), playlist: nil)
        }
        if first.playlist != nil, let video = await single {
            return MediaInspection(video: video, playlist: first.playlist)
        }
        return first
    }

    /// Most entries a playlist listing reads (huge channels would take minutes).
    static let playlistLimit = 1000

    /// YouTube `watch?v=ID&list=…`: one video that is also part of a playlist.
    static func isVideoInPlaylist(_ url: URL) -> Bool {
        guard Thumbnails.youTube(for: url) != nil else { return false }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .contains { $0.name == "list" && !($0.value ?? "").isEmpty } ?? false
    }

    /// Fetches the page JSON once into a temp file and hands it to `body`.
    private static func withInfo<T>(
        of url: URL, playlist: Bool, tools: MediaTools, _ body: (URL, Data) async throws -> T
    ) async throws -> T {
        guard let ytdlp = tools.ytdlp else { throw MediaProbeError.toolMissing }
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("flux-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let infoFile = workDir.appendingPathComponent("info.json")
        var args = ["-J", "--no-warnings"]
        args += playlist
            ? ["--yes-playlist", "--flat-playlist", "--playlist-items", "1:\(playlistLimit)"]
            : ["--no-playlist"]
        args += ["--", url.absoluteString]
        let fetch = try await ProcessRunner.run(ytdlp, args, environment: tools.processEnvironment(), stdoutFile: infoFile)
        guard fetch.status == 0 else {
            let message = fetch.stderrLines.last { $0.hasPrefix("ERROR: ") }.map { String($0.dropFirst(7)) }
            throw MediaProbeError.failed(MediaJob.friendly(message) ?? "Couldn't read this page.")
        }
        return try await body(infoFile, try Data(contentsOf: infoFile))
    }

    private static func options(infoFile: URL, json: Data, tools: MediaTools) async throws -> MediaPreview {
        guard let ytdlp = tools.ytdlp else { throw MediaProbeError.toolMissing }
        let page = try pageInfo(from: json)
        let env = tools.processEnvironment()
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

    /// Channel pages can list playlists (e.g. a "Playlists" tab); read those one level deep.
    private static func expandNested(_ playlist: MediaPlaylist, tools: MediaTools) async throws -> MediaPlaylist {
        let nested = playlist.entries.filter(\.isPlaylist)
        guard !nested.isEmpty else { return playlist }
        let lists = await withTaskGroup(of: (String, [MediaPlaylist.Entry]).self) { group in
            for entry in nested.prefix(25) {
                group.addTask {
                    let inner = try? await withInfo(of: entry.url, playlist: true, tools: tools) { _, json in
                        try playlistInfo(from: json)
                    }
                    return (entry.id, inner?.entries.filter { !$0.isPlaylist } ?? [])
                }
            }
            var result: [String: [MediaPlaylist.Entry]] = [:]
            for await (id, entries) in group { result[id] = entries }
            return result
        }
        var expanded = playlist
        expanded.entries = playlist.entries.flatMap { $0.isPlaylist ? lists[$0.id] ?? [] : [$0] }
        var seen = Set<URL>()
        expanded.entries = expanded.entries.filter { seen.insert($0.url).inserted }
        return expanded
    }

    /// nil when the JSON describes a single video rather than a list.
    static func playlistInfo(from data: Data) throws -> MediaPlaylist? {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MediaProbeError.failed("yt-dlp returned unreadable data.")
        }
        guard (object["_type"] as? String) == "playlist" || object["entries"] != nil else { return nil }
        let raw = object["entries"] as? [[String: Any]] ?? []
        var entries: [MediaPlaylist.Entry] = []
        var seen = Set<URL>()
        for (index, entry) in raw.enumerated() {
            // A playlist can hold the same video twice; download it once.
            guard let url = entryURL(entry), seen.insert(url).inserted else { continue }
            let knownTitle = (entry["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let ieKey = entry["ie_key"] as? String ?? ""
            let availability = (entry["availability"] as? String ?? "").lowercased()
            // YouTube lists private and deleted videos either by a bracketed title or with no
            // title and no duration at all; every watchable entry has a title.
            let hiddenOnYouTube = ieKey == "Youtube" && knownTitle == nil && !(entry["duration"] is NSNumber)
            let unavailable = hiddenOnYouTube
                || ["[private video]", "[deleted video]", "[unavailable video]"].contains(knownTitle?.lowercased() ?? "")
                || ["private", "needs_auth", "subscriber_only", "premium_only"].contains(availability)
                || (entry["live_status"] as? String) == "is_upcoming"
            let title = knownTitle ?? (hiddenOnYouTube ? "Private or deleted video" : "Item \(index + 1)")
            let isPlaylist = (entry["_type"] as? String) == "playlist" || ieKey.hasSuffix("Tab") || ieKey.hasSuffix("Playlist")
            entries.append(MediaPlaylist.Entry(
                id: url.absoluteString,
                url: url,
                title: title,
                duration: (entry["duration"] as? NSNumber)?.doubleValue,
                thumbnailURL: thumbnail(entry),
                isAvailable: !unavailable,
                isPlaylist: isPlaylist))
        }
        let count = (object["playlist_count"] as? NSNumber)?.intValue
        return MediaPlaylist(
            title: (object["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Playlist",
            uploader: object["uploader"] as? String ?? object["channel"] as? String,
            entries: entries,
            isTruncated: raw.count >= playlistLimit && (count ?? Int.max) > raw.count)
    }

    private static func entryURL(_ entry: [String: Any]) -> URL? {
        for key in ["url", "webpage_url", "original_url"] {
            if let text = entry[key] as? String, let url = URL(string: text), LinkExtractor.isDownloadable(url) {
                return url
            }
        }
        // Some extractors list bare video IDs.
        if (entry["ie_key"] as? String) == "Youtube", let id = entry["id"] as? String {
            return URL(string: "https://www.youtube.com/watch?v=\(id)")
        }
        return nil
    }

    /// The smallest listed thumbnail at least 320 px wide (else the largest).
    private static func thumbnail(_ entry: [String: Any]) -> URL? {
        let list = (entry["thumbnails"] as? [[String: Any]] ?? []).compactMap { t -> (URL, Int)? in
            guard let url = (t["url"] as? String).flatMap(Thumbnails.remote) else { return nil }
            return (url, (t["width"] as? NSNumber)?.intValue ?? 0)
        }
        if let good = list.filter({ $0.1 >= 320 }).min(by: { $0.1 < $1.1 }) { return good.0 }
        if let largest = list.max(by: { $0.1 < $1.1 }) { return largest.0 }
        return (entry["thumbnail"] as? String).flatMap(Thumbnails.remote)
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
