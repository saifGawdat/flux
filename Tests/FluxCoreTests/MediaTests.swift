import Foundation
import Testing
@testable import FluxCore

/// Writes an executable stand-in for yt-dlp that speaks the same output protocol Flux
/// requests (`--print`/`--progress-template`), keeps `.part` files on Ctrl-C like the real
/// tool, and resumes them on the next run. The URL controls its behavior:
/// a final `fail` → "Video unavailable", `slow` → throttled, `nofile` → exits 0 without a file.
func makeFakeYTDLP() throws -> URL {
    let dir = try tempDir()
    let script = dir.appendingPathComponent("yt-dlp")
    try #"""
    #!/usr/bin/env python3
    import os, sys, time, signal
    args = sys.argv[1:]
    open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "last-args.txt"), "w").write("\n".join(args))
    url = args[-1]
    key = url.rsplit("=", 1)[-1].rsplit("/", 1)[-1]
    if "-J" in args:
        if key == "fail":
            print("ERROR: [youtube] abc123: Private video. Sign in if you've been granted access", file=sys.stderr)
            sys.exit(1)
        print('{"title": "Fake Video: Part 1", "duration": 120, "formats": ['
              '{"format_id": "v2160", "protocol": "m3u8_native", "tbr": 8000},'
              '{"format_id": "v1080", "protocol": "https", "filesize": 30000000, "filesize_approx": 29000000},'
              '{"format_id": "v360", "protocol": "https", "filesize_approx": 9000000},'
              '{"format_id": "a", "protocol": "https", "filesize": 3000000, "tbr": 150}]}')
        sys.exit(0)
    if "--load-info-json" in args:
        sel = args[args.index("-f") + 1]
        if "height<=1080" in sel: print("v1080+a|1920x1080|mp4|1080")
        elif "height<=720" in sel: print("v360+a|640x360|mp4|360")
        elif sel.startswith("ba"): print("a|audio only|webm|NA")
        else: print("v2160+a|3840x2160|webm|2160")
        sys.exit(0)
    workdir = args[args.index("-P") + 1]
    print("FLUXTITLE|Fake Video: Part 1", flush=True)
    if key == "fail":
        print("ERROR: [youtube] abc123: Video unavailable", file=sys.stderr, flush=True)
        sys.exit(1)
    if key == "nofile":
        sys.exit(0)
    interrupted = False
    def on_int(signum, frame):
        global interrupted
        interrupted = True
    signal.signal(signal.SIGINT, on_int)
    total = 2_000_000
    part = os.path.join(workdir, "Fake Video- Part 1.mp4.part")
    have = os.path.getsize(part) if os.path.exists(part) else 0
    delay = 0.03 if key == "slow" else 0
    with open(part, "ab") as f:
        while have < total:
            if interrupted:
                print("ERROR: Interrupted by user", file=sys.stderr, flush=True)
                sys.exit(1)
            n = min(50_000, total - have)
            f.write(bytes([have % 251]) * n)
            f.flush()
            have += n
            print(f"FLUXPROG|downloading|{have}|{total}|NA|1500000.0|137", flush=True)
            time.sleep(delay)
    print(f"FLUXPROG|finished|{total}|{total}|NA|NA|137", flush=True)
    final = os.path.join(workdir, "Fake Video- Part 1.mp4")
    os.rename(part, final)
    print("[Merger] Merging formats into \"" + final + "\"", flush=True)
    print("FLUXFILE|" + final, flush=True)
    """#.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
}

func makeMediaJob(_ record: DownloadRecord, tools: MediaTools) -> (MediaJob, SnapshotLog) {
    let log = SnapshotLog()
    return (MediaJob(record: record, tools: tools) { log.append($0) }, log)
}

func mediaRecord(_ path: String, in dir: URL, format: MediaFormat = .best) -> DownloadRecord {
    DownloadRecord(url: URL(string: "https://www.youtube.com/watch?v=\(path)")!, directory: dir,
                   kind: .media, mediaFormat: format)
}

struct MediaParsingTests {
    @Test func parsesProgressLines() {
        #expect(MediaOutput.parse("FLUXPROG|downloading|1024|4096|NA|512.5|137") == .progress(.init(
            status: "downloading", downloaded: 1024, total: 4096, estimate: nil, speed: 512.5, formatID: "137")))
        #expect(MediaOutput.parse("FLUXPROG|downloading|10|NA|5000.0|NA|NA") == .progress(.init(
            status: "downloading", downloaded: 10, total: nil, estimate: 5000, speed: nil, formatID: nil)))
    }

    @Test func parsesMarkersAndErrors() {
        #expect(MediaOutput.parse("FLUXTITLE|A | B") == .title("A | B"))
        #expect(MediaOutput.parse("FLUXFILE|/tmp/x.mp4") == .finalFile("/tmp/x.mp4"))
        #expect(MediaOutput.parse("ERROR: boom") == .error("boom"))
        #expect(MediaOutput.parse(#"[Merger] Merging formats into "x.mp4""#) == .postProcessing("Merging video and audio…"))
        #expect(MediaOutput.parse("[youtube] abc: Downloading webpage") == .other)
    }

    @Test func lineBufferHandlesSplitsAndCarriageReturns() {
        var buffer = LineBuffer()
        #expect(buffer.append(Data("ab".utf8)).isEmpty)
        #expect(buffer.append(Data("c\r\nde\rf".utf8)) == ["abc", "de"])
        #expect(buffer.flush() == ["f"])
    }

    @Test func friendlyErrors() {
        #expect(MediaJob.friendly("[youtube] abc: Private video. Sign in if you've been granted access") == "This video is private.")
        #expect(MediaJob.friendly("Unsupported URL: https://example.com") == "No downloadable media found on this page.")
        #expect(MediaJob.friendly("[generic] xyz: Something odd") == "Something odd")
    }

    @Test func formatArgumentsDependOnFFmpeg() {
        #expect(MediaFormat.best.ytdlpArguments(hasFFmpeg: true) == ["-f", "bv*+ba/b"])
        #expect(MediaFormat.best.ytdlpArguments(hasFFmpeg: false) == ["-f", "b"])
        #expect(MediaFormat.mp3.ytdlpArguments(hasFFmpeg: true).contains("--audio-format"))
        #expect(!MediaFormat.mp3.ytdlpArguments(hasFFmpeg: false).contains("-x"), "can't convert without ffmpeg")
        #expect(MediaFormat.mp4_720.ytdlpArguments(hasFFmpeg: true).contains("--merge-output-format"))
    }
}

struct MediaRoutingTests {
    @Test(arguments: [
        ("https://www.youtube.com/watch?v=dQw4w9WgXcQ", true),
        ("https://youtu.be/dQw4w9WgXcQ", true),
        ("https://music.youtube.com/watch?v=x", true),
        ("https://vimeo.com/123", true),
        ("https://x.com/user/status/1", true),
        ("https://www.reddit.com/r/videos/comments/abc", true),
        ("https://example.com/file.zip", false),
        ("https://github.com/org/repo/releases/download/v1/app.dmg", false),
        ("https://notyoutube.com/watch", false),
        ("https://vimeo.com/files/clip.mp4", false),
    ])
    func routesKnownMediaSites(_ link: String, _ expected: Bool) {
        #expect(MediaRouting.prefersMedia(URL(string: link)!) == expected)
    }

    @Test func discoveryFindsToolsOnSearchPath() throws {
        let fake = try makeFakeYTDLP()
        let tools = MediaTools.discover(environment: ["PATH": fake.deletingLastPathComponent().path])
        #expect(tools.ytdlp != nil)
        let env = MediaTools(ytdlp: fake).processEnvironment(base: ["PATH": "/usr/bin"])
        #expect(env["PATH"]?.hasPrefix(fake.deletingLastPathComponent().path) == true)
    }
}

struct MediaProbeTests {
    @Test func previewListsEveryFormatWithSizes() async throws {
        let tools = MediaTools(ytdlp: try makeFakeYTDLP(), ffmpeg: URL(fileURLWithPath: "/opt/fake/ffmpeg"))
        let preview = try await MediaProbe.preview(of: URL(string: "https://youtu.be/ok")!, tools: tools)

        #expect(preview.title == "Fake Video: Part 1")
        #expect(preview.duration == 120)
        #expect(Set(preview.options.keys) == Set(MediaFormat.allCases))
        // Streamed 4K: 8000 kbit/s peak × 120 s × 0.6 average, plus 3 MB exact audio.
        #expect(preview.options[.best] == .init(height: 2160, fileExtension: "webm", bytes: 75_000_000, isEstimate: true))
        #expect(preview.options[.mp4_1080] == .init(height: 1080, fileExtension: "mp4", bytes: 33_000_000, isEstimate: false),
                "exact sizes add up exactly")
        #expect(preview.options[.mp4_720] == .init(height: 360, fileExtension: "mp4", bytes: 12_000_000, isEstimate: true))
        #expect(preview.options[.m4a] == .init(height: nil, fileExtension: "m4a", bytes: 3_000_000, isEstimate: false))
        let mp3 = try #require(preview.options[.mp3])
        #expect(mp3.fileExtension == "mp3" && mp3.isEstimate && mp3.height == nil)
        #expect(mp3.bytes == Int64(3_150_000), "120 s × (150 kbit/s source × 1.4), not the source size")
    }

    @Test func previewErrorsAreFriendly() async throws {
        let tools = MediaTools(ytdlp: try makeFakeYTDLP())
        await #expect(throws: MediaProbeError.self) {
            try await MediaProbe.preview(of: URL(string: "https://youtu.be/fail")!, tools: tools)
        }
        do {
            _ = try await MediaProbe.preview(of: URL(string: "https://youtu.be/fail")!, tools: tools)
        } catch {
            #expect(error.localizedDescription == "This video is private.")
        }
    }

    @Test func previewNeedsYTDLP() async {
        await #expect(throws: MediaProbeError.self) {
            try await MediaProbe.preview(of: URL(string: "https://youtu.be/ok")!, tools: .none)
        }
    }

    @Test func parsesOptionLines() {
        let page = MediaProbe.PageInfo(title: "t", duration: 60, formats: [
            "a": .init(filesize: 3_000_000, filesizeApprox: nil, tbr: nil, isStreamed: false),
            "v": .init(filesize: nil, filesizeApprox: nil, tbr: nil, isStreamed: false),
        ])
        let audio = MediaProbe.parseOption("a|audio only|webm|2160", format: .m4a, hasFFmpeg: false, page: page)
        #expect(audio == .init(height: nil, fileExtension: "webm", bytes: 3_000_000, isEstimate: false),
                "audio-only ignores stray height; no conversion without ffmpeg")
        #expect(MediaProbe.parseOption("v+a|1280x720|mp4|720", format: .mp4_720, hasFFmpeg: true, page: page)?.bytes == nil,
                "unknown size stays unknown instead of showing only the audio part")
        #expect(MediaProbe.parseOption("zzz|1280x720|mp4|720", format: .mp4_720, hasFFmpeg: true, page: page)?.bytes == nil)
        #expect(MediaProbe.parseOption("garbage", format: .best, hasFFmpeg: true, page: page) == nil)
    }

    @Test func mp4PresetsPreferH264() {
        let selector = MediaFormat.mp4_1080.ytdlpArguments(hasFFmpeg: true)[1]
        #expect(selector.hasPrefix("bv*[height<=1080][vcodec^=avc1]+ba[ext=m4a]/"))
    }
}

@Suite(.serialized)
struct MediaJobTests {
    @Test func downloadsAndPlacesFile() async throws {
        let tools = MediaTools(ytdlp: try makeFakeYTDLP())
        let out = try tempDir()
        let (job, log) = makeMediaJob(mediaRecord("ok", in: out), tools: tools)
        await job.start()
        let record = try await finish(job, log)

        #expect(record.status == .completed, "\(record.errorMessage ?? "")")
        #expect(record.title == "Fake Video: Part 1")
        #expect(record.totalBytes == 2_000_000)
        let final = try #require(record.finalPath)
        #expect(final.deletingLastPathComponent().standardizedFileURL == out.standardizedFileURL)
        #expect(try Data(contentsOf: final).count == 2_000_000)
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == [final.lastPathComponent], "work folder removed")
        #expect(log.all.contains { $0.detail == "Merging video and audio…" })
        #expect(getxattr(final.path, "com.apple.quarantine", nil, 0, 0, 0) > 0)
    }

    @Test func passesFormatAndFFmpegToYTDLP() async throws {
        let fake = try makeFakeYTDLP()
        let ffmpeg = URL(fileURLWithPath: "/opt/fake/ffmpeg")
        let (job, log) = makeMediaJob(mediaRecord("ok", in: try tempDir(), format: .mp3), tools: MediaTools(ytdlp: fake, ffmpeg: ffmpeg))
        await job.start()
        _ = try await finish(job, log)
        let args = try String(contentsOf: fake.deletingLastPathComponent().appendingPathComponent("last-args.txt"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(args.contains("--audio-format") && args.contains("mp3"))
        #expect(args.contains("--ffmpeg-location") && args.contains("/opt/fake/ffmpeg"))
        #expect(args.contains("--no-playlist"))
        #expect(args.contains("--no-quiet"), "keeps post-processing stage lines visible")
        #expect(args.suffix(2) == ["--", "https://www.youtube.com/watch?v=ok"], "URL passed after -- so it can't be read as an option")
    }

    @Test func neverOverwritesExistingFile() async throws {
        let out = try tempDir()
        try Data("mine".utf8).write(to: out.appendingPathComponent("Fake Video- Part 1.mp4"))
        let (job, log) = makeMediaJob(mediaRecord("ok", in: out), tools: MediaTools(ytdlp: try makeFakeYTDLP()))
        await job.start()
        let record = try await finish(job, log)
        #expect(record.fileName == "Fake Video- Part 1 (1).mp4")
        #expect(try String(contentsOf: out.appendingPathComponent("Fake Video- Part 1.mp4"), encoding: .utf8) == "mine")
    }

    @Test func reportsFriendlyError() async throws {
        let (job, log) = makeMediaJob(mediaRecord("fail", in: try tempDir()), tools: MediaTools(ytdlp: try makeFakeYTDLP()))
        await job.start()
        let record = try await finish(job, log)
        #expect(record.status == .failed)
        #expect(record.errorMessage == "This video is unavailable.")
    }

    @Test func failsClearlyWhenNoFileProduced() async throws {
        let (job, log) = makeMediaJob(mediaRecord("nofile", in: try tempDir()), tools: MediaTools(ytdlp: try makeFakeYTDLP()))
        await job.start()
        let record = try await finish(job, log)
        #expect(record.status == .failed)
        #expect(record.errorMessage == "yt-dlp finished without producing a file.")
    }

    @Test func failsWithInstallHintWhenYTDLPMissing() async throws {
        let (job, log) = makeMediaJob(mediaRecord("ok", in: try tempDir()), tools: .none)
        await job.start()
        let record = try await finish(job, log, timeout: 2)
        #expect(record.status == .failed)
        #expect(record.errorMessage?.contains("brew install yt-dlp") == true)
    }

    @Test func pauseKeepsPartialDataAndResumeContinues() async throws {
        let tools = MediaTools(ytdlp: try makeFakeYTDLP())
        let (job, log) = makeMediaJob(mediaRecord("slow", in: try tempDir()), tools: tools)
        await job.start()
        try await eventually("progress") { (log.last?.record.receivedBytes ?? 0) >= 300_000 }
        let paused = await job.pause().record
        #expect(paused.status == .paused)
        let pausedBytes = paused.receivedBytes

        // Resume in a new job, as after an app restart.
        let (resumed, resumedLog) = makeMediaJob(paused, tools: tools)
        await resumed.start()
        let record = try await finish(resumed, resumedLog, timeout: 60)
        #expect(record.status == .completed, "\(record.errorMessage ?? "")")
        let firstProgress = try #require(resumedLog.all.first { $0.record.status == .downloading })
        #expect(firstProgress.record.receivedBytes >= pausedBytes, "continued from the .part file")
        let data = try Data(contentsOf: try #require(record.finalPath))
        #expect(data.count == 2_000_000)
        #expect(data.enumerated().allSatisfy { $0.element == UInt8(($0.offset / 50_000 * 50_000) % 251) }, "no duplicated or missing chunks")
    }

    @Test func cancelRemovesWorkFolder() async throws {
        let out = try tempDir()
        let (job, log) = makeMediaJob(mediaRecord("slow", in: out), tools: MediaTools(ytdlp: try makeFakeYTDLP()))
        await job.start()
        try await eventually("progress") { (log.last?.record.receivedBytes ?? 0) > 100_000 }
        let record = await job.cancel().record
        #expect(record.status == .cancelled)
        #expect(record.receivedBytes == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
    }
}

@Suite(.serialized)
struct MediaManagerTests {
    @Test func mediaSiteLinksUseExtractorWithDefaultFormat() async throws {
        let out = try tempDir()
        let db = try FluxDatabase(url: out.appendingPathComponent("db.sqlite"))
        try await db.save(FluxSettings(downloadDirectory: out, defaultMediaFormat: .m4a))
        let manager = try await DownloadManager(database: db, jobOptions: fastOptions,
                                                mediaTools: MediaTools(ytdlp: try makeFakeYTDLP()))
        let mirror = await EventMirror(manager)
        await manager.start()
        let id = try #require(try await manager.add([.init(url: URL(string: "https://youtu.be/ok")!)]).first)
        try await eventually("completion") { mirror.status(id) == .completed }
        let record = try #require(mirror.record(id))
        #expect(record.kind == .media)
        #expect(record.mediaFormat == .m4a)
        let saved = try #require(try await db.loadDownloads().first)
        #expect(saved.kind == .media && saved.mediaFormat == .m4a && saved.title == "Fake Video: Part 1")
    }

    @Test func webPageLinkFallsBackToExtractor() async throws {
        let server = try TestServer()
        try "<html><body>video page</body></html>".write(
            to: server.root.appendingPathComponent("watch.html"), atomically: true, encoding: .utf8)
        let out = try tempDir()
        let db = try FluxDatabase(url: out.appendingPathComponent("db.sqlite"))
        try await db.save(FluxSettings(downloadDirectory: out))
        let manager = try await DownloadManager(database: db, jobOptions: fastOptions,
                                                mediaTools: MediaTools(ytdlp: try makeFakeYTDLP()))
        let mirror = await EventMirror(manager)
        await manager.start()
        let id = try #require(try await manager.add([.init(url: server.url("watch.html"))]).first)
        try await eventually("completion") { mirror.status(id) == .completed }
        #expect(mirror.record(id)?.kind == .media)
    }

    @Test func webPageWithoutYTDLPExplainsWhatToInstall() async throws {
        let server = try TestServer()
        try "<html></html>".write(to: server.root.appendingPathComponent("page.html"), atomically: true, encoding: .utf8)
        let out = try tempDir()
        let db = try FluxDatabase(url: out.appendingPathComponent("db.sqlite"))
        try await db.save(FluxSettings(downloadDirectory: out))
        let manager = try await DownloadManager(database: db, jobOptions: fastOptions, mediaTools: .none)
        let mirror = await EventMirror(manager)
        await manager.start()
        let id = try #require(try await manager.add([.init(url: server.url("page.html"))]).first)
        try await eventually("failure") { mirror.status(id) == .failed }
        #expect(mirror.record(id)?.errorMessage?.contains("yt-dlp") == true)
    }
}

struct MigrationUpgradeTests {
    @Test func version1DatabaseUpgradesWithExistingRows() async throws {
        let url = try tempDir().appendingPathComponent("old.sqlite")
        do {
            let conn = try SQLiteConnection(path: url.path)
            try Schema.migrate(conn, migrations: Array(Schema.migrations.prefix(1)))
            try conn.run("""
                INSERT INTO downloads (id, url, file_name, directory, status, max_connections, created_at)
                VALUES ('\(UUID().uuidString)', 'https://e.com/a.zip', 'a.zip', '/tmp', 'completed', 8, 0)
                """)
        }
        let db = try FluxDatabase(url: url)
        #expect(try await db.schemaVersion() == 2)
        let record = try #require(try await db.loadDownloads().first)
        #expect(record.kind == .file && record.mediaFormat == nil)
    }
}

/// Opt-in checks against the real yt-dlp and network: `FLUX_LIVE_TESTS=1 ./scripts/test.sh`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["FLUX_LIVE_TESTS"] == "1"))
struct LiveMediaTests {
    static let shortVideo = URL(string: "https://www.youtube.com/watch?v=jNQXAC9IVRw")! // 19 s, "Me at the zoo"

    @Test(arguments: [MediaFormat.mp4_720, .mp3])
    func realYouTubeDownload(_ format: MediaFormat) async throws {
        let tools = MediaTools.discover()
        try #require(tools.ytdlp != nil && tools.ffmpeg != nil, "install yt-dlp and ffmpeg")
        let out = try tempDir()
        let record = DownloadRecord(url: Self.shortVideo, directory: out, kind: .media, mediaFormat: format)
        let (job, log) = makeMediaJob(record, tools: tools)
        await job.start()
        let done = try await finish(job, log, timeout: 120)

        #expect(done.status == .completed, "\(done.errorMessage ?? "")")
        #expect(done.title == "Me at the zoo")
        let file = try #require(done.finalPath)
        #expect(file.pathExtension == (format == .mp3 ? "mp3" : "mp4"))
        #expect((done.totalBytes ?? 0) > 100_000)
        #expect(log.all.contains { $0.record.status == .downloading && $0.bytesPerSecond > 0 }, "live progress reported")
        if format == .mp3 {
            #expect(log.all.contains { $0.detail == "Converting audio…" })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == [file.lastPathComponent])
    }

    @Test func realPreviewReportsSizes() async throws {
        let tools = MediaTools.discover()
        try #require(tools.ytdlp != nil && tools.ffmpeg != nil, "install yt-dlp and ffmpeg")
        let preview = try await MediaProbe.preview(of: Self.shortVideo, tools: tools)
        #expect(preview.title == "Me at the zoo")
        #expect(Set(preview.options.keys) == Set(MediaFormat.allCases))
        for (format, option) in preview.options {
            #expect((option.bytes ?? 0) > 10_000, "\(format) has a size")
        }
        #expect(preview.options[.mp3]?.fileExtension == "mp3")
    }

    /// The number shown in the add sheet must match what actually lands on disk.
    @Test(arguments: [MediaFormat.mp4_720, .mp3, .m4a])
    func shownSizeMatchesDownloadedSize(_ format: MediaFormat) async throws {
        let tools = MediaTools.discover()
        try #require(tools.ytdlp != nil && tools.ffmpeg != nil, "install yt-dlp and ffmpeg")
        let preview = try await MediaProbe.preview(of: Self.shortVideo, tools: tools)
        let shown = try #require(preview.options[format]?.bytes)

        let record = DownloadRecord(url: Self.shortVideo, directory: try tempDir(), kind: .media, mediaFormat: format)
        let (job, log) = makeMediaJob(record, tools: tools)
        await job.start()
        let done = try await finish(job, log, timeout: 120)
        let actual = try #require(done.totalBytes)
        let error = abs(Double(shown - actual)) / Double(actual)
        #expect(error < 0.15, "\(format): shown \(shown) vs downloaded \(actual) (\(Int(error * 100))% off)")
    }

    @Test func realUnsupportedPageFailsClearly() async throws {
        let tools = MediaTools.discover()
        try #require(tools.ytdlp != nil)
        let record = DownloadRecord(url: URL(string: "https://example.com/")!, directory: try tempDir(), kind: .media)
        let (job, log) = makeMediaJob(record, tools: tools)
        await job.start()
        let done = try await finish(job, log, timeout: 60)
        #expect(done.status == .failed)
        #expect(done.errorMessage == "No downloadable media found on this page.")
    }
}
