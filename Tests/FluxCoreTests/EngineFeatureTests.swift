import Foundation
import Testing
@testable import FluxCore

/// Fake clock for deterministic token-bucket tests.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    var now: TimeInterval { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

struct SpeedLimiterTests {
    @Test func unlimitedNeverWaits() {
        let limiter = SpeedLimiter()
        #expect(limiter.consume(100_000_000) == 0)
        #expect(limiter.delay() == 0)
    }

    @Test func debtTurnsIntoWaitAndDrainsOverTime() {
        let clock = ManualClock()
        let limiter = SpeedLimiter(bytesPerSecond: 100_000, clock: { clock.now })
        #expect(abs(limiter.consume(200_000) - 2) < 0.001)
        clock.advance(0.5)
        #expect(abs(limiter.delay() - 1.5) < 0.001)
        clock.advance(1.5)
        #expect(limiter.delay() == 0)
    }

    @Test func sharedBucketMakesEveryReaderWait() {
        let clock = ManualClock()
        let limiter = SpeedLimiter(bytesPerSecond: 100_000, clock: { clock.now })
        let first = limiter.consume(100_000)
        let second = limiter.consume(100_000)
        #expect(second > first, "the second reader waits behind the first")
        #expect(abs(second - 2) < 0.001)
    }

    @Test func idleTimeBuildsOnlyASmallBurst() {
        let clock = ManualClock()
        let limiter = SpeedLimiter(bytesPerSecond: 1_000_000, clock: { clock.now })
        _ = limiter.consume(0)
        clock.advance(60) // a minute idle must not allow a 60 MB burst
        #expect(limiter.consume(1_000_000) > 0.7)
    }

    @Test func removingTheLimitClearsDebt() {
        let limiter = SpeedLimiter(bytesPerSecond: 10_000)
        _ = limiter.consume(1_000_000)
        limiter.setLimit(nil)
        #expect(limiter.delay() == 0)
        #expect(limiter.bytesPerSecond == nil)
    }
}

struct ChecksumParsingTests {
    let sha = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"

    @Test func acceptsCommonSpellings() {
        let expected = Checksum(algorithm: .sha256, hex: sha)
        #expect(Checksum.parse(sha) == expected)
        #expect(Checksum.parse(sha.uppercased()) == expected)
        #expect(Checksum.parse("sha256:\(sha)") == expected)
        #expect(Checksum.parse("SHA-256: \(sha)") == expected)
        #expect(Checksum.parse("SHA256 (Flux.dmg) = \(sha)") == expected)
        #expect(Checksum.parse("\(sha)  Flux-1.0.dmg\n") == expected)
    }

    @Test func recognizesAlgorithmByLength() {
        #expect(Checksum.parse("d41d8cd98f00b204e9800998ecf8427e")?.algorithm == .md5)
        #expect(Checksum.parse("da39a3ee5e6b4b0d3255bfef95601890afd80709")?.algorithm == .sha1)
        #expect(Checksum.parse(String(repeating: "ab", count: 64))?.algorithm == .sha512)
    }

    @Test func rejectsNonsense() {
        #expect(Checksum.parse("") == nil)
        #expect(Checksum.parse("not a hash") == nil)
        #expect(Checksum.parse(String(sha.dropLast())) == nil, "wrong length")
        #expect(Checksum.parse("md5:\(sha)") == nil, "named algorithm doesn't fit the length")
    }

    @Test func storedFormRoundTrips() {
        let checksum = Checksum(algorithm: .sha1, hex: "DA39A3EE5E6B4B0D3255BFEF95601890AFD80709")
        #expect(Checksum.parse(checksum.description) == checksum)
    }
}

@Suite(.serialized)
struct EngineFeatureTests {
    // MARK: Speed limits

    // Unlimited, each of these downloads takes well under 0.1 s. Under a limit, ranged
    // requests are paced in half-second chunks, so the timing is close to exact.

    @Test func perDownloadLimitIsHonored() async throws {
        let server = try TestServer()
        let source = try server.addFile("limited.bin", size: 3_000_000)
        var record = DownloadRecord(url: server.url("limited.bin"), directory: try tempDir(), maxConnections: 8)
        record.speedLimit = 1_000_000
        let (job, log) = makeJob(record)
        let started = Date()
        await job.start()
        let done = try await finish(job, log, timeout: 20)
        let elapsed = Date().timeIntervalSince(started)

        #expect(done.status == .completed, "\(done.errorMessage ?? "")")
        #expect(try sha256(of: done.finalPath) == sha256(source))
        #expect(elapsed > 2.5, "3 MB at 1 MB/s takes about 3 s, took \(elapsed)")
        #expect(elapsed < 10)
        #expect(log.all.map(\.activeConnections).max() == 1, "one connection per 1 MB/s of limit")
    }

    @Test func globalLimitIsSharedByAllDownloads() async throws {
        let server = try TestServer()
        let a = try server.addFile("a.bin", size: 2_000_000)
        let b = try server.addFile("b.bin", size: 2_000_000)
        var options = fastOptions
        options.sharedLimiter = SpeedLimiter(bytesPerSecond: 1_000_000)
        let out = try tempDir()
        let (jobA, logA) = makeJob(DownloadRecord(url: server.url("a.bin"), directory: out), options: options)
        let (jobB, logB) = makeJob(DownloadRecord(url: server.url("b.bin"), directory: out), options: options)
        let started = Date()
        await jobA.start()
        await jobB.start()
        let doneA = try await finish(jobA, logA, timeout: 20)
        let doneB = try await finish(jobB, logB, timeout: 20)
        let elapsed = Date().timeIntervalSince(started)

        #expect(try sha256(of: doneA.finalPath) == sha256(a))
        #expect(try sha256(of: doneB.finalPath) == sha256(b))
        // Each download may run up to one half-second chunk ahead, so ~3 s rather than 4.
        #expect(elapsed > 2.7, "4 MB in total at 1 MB/s takes about 3–4 s, took \(elapsed)")
    }

    @Test func raisingTheLimitSpeedsUpARunningDownload() async throws {
        let server = try TestServer()
        let source = try server.addFile("big.bin", size: 4_000_000)
        var record = DownloadRecord(url: server.url("big.bin"), directory: try tempDir(), maxConnections: 4)
        record.speedLimit = 200_000
        let (job, log) = makeJob(record)
        let started = Date()
        await job.start()
        try await eventually("some progress") { (log.last?.record.receivedBytes ?? 0) > 100_000 }
        await job.setSpeedLimit(nil)
        let done = try await finish(job, log, timeout: 20)

        #expect(done.status == .completed)
        #expect(done.speedLimit == nil)
        #expect(try sha256(of: done.finalPath) == sha256(source))
        #expect(Date().timeIntervalSince(started) < 8, "4 MB at 200 KB/s would take 20 s")
    }

    @Test func mediaDownloadsAreHeldToTheLimit() async throws {
        let tools = MediaTools(ytdlp: try makeFakeYTDLP(), ffmpeg: nil)
        let out = try tempDir()
        var record = DownloadRecord(url: URL(string: "https://www.youtube.com/watch?v=fast")!, directory: out, kind: .media, mediaFormat: .best)
        record.speedLimit = 1_000_000
        let log = SnapshotLog()
        let job = MediaJob(record: record, tools: tools) { log.append($0) }
        let started = Date()
        await job.start()
        let done = try await finish(job, log, timeout: 20)
        let elapsed = Date().timeIntervalSince(started)

        #expect(done.status == .completed, "\(done.errorMessage ?? "")")
        #expect(elapsed > 1.4, "2 MB at 1 MB/s takes about 2 s, took \(elapsed)")
    }

    // MARK: Checksums

    @Test func matchingChecksumIsVerified() async throws {
        let server = try TestServer()
        let source = try server.addFile("app.dmg", size: 700_000)
        var record = DownloadRecord(url: server.url("app.dmg"), directory: try tempDir())
        record.checksum = Checksum(algorithm: .sha256, hex: sha256(source))
        let (job, log) = makeJob(record)
        await job.start()
        let done = try await finish(job, log)

        #expect(done.status == .completed, "\(done.errorMessage ?? "")")
        #expect(done.checksumVerified)
        #expect(done.checksumState == .verified)
        #expect(log.all.contains { $0.detail == "Verifying SHA-256…" })
    }

    @Test func wrongChecksumFailsAndLeavesNoFile() async throws {
        let server = try TestServer()
        try server.addFile("app.dmg", size: 300_000)
        let out = try tempDir()
        var record = DownloadRecord(url: server.url("app.dmg"), directory: out)
        record.checksum = Checksum(algorithm: .sha256, hex: String(repeating: "0", count: 64))
        let (job, log) = makeJob(record)
        await job.start()
        let done = try await finish(job, log)

        #expect(done.status == .failed)
        #expect(done.errorMessage?.contains("SHA-256") == true)
        #expect(!done.checksumVerified)
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty, "bad data is discarded")
    }

    @Test func finishedDownloadCanBeCheckedLater() async throws {
        let server = try TestServer()
        let source = try server.addFile("doc.pdf", size: 50_000)
        let manager = try await makeManager()
        let id = try #require(try await manager.add([.init(url: server.url("doc.pdf"), directory: try tempDir())]).first)
        await manager.start()
        try await eventually("completion") { await manager.item(id)?.record.status == .completed }

        let right = Checksum(algorithm: .sha256, hex: sha256(source))
        #expect(try await manager.setChecksum(right, for: id) == true)
        #expect(await manager.item(id)?.record.checksumState == .verified)
        let wrong = Checksum(algorithm: .md5, hex: String(repeating: "a", count: 32))
        #expect(try await manager.setChecksum(wrong, for: id) == false)
        #expect(await manager.item(id)?.record.checksumState == .mismatch)
    }

    // MARK: Mirrors

    @Test func mirrorsShareTheWork() async throws {
        let main = try TestServer(throttle: 0.005)
        let mirror = try TestServer(throttle: 0.005)
        let source = try main.addFile("iso.bin", size: 3_000_000)
        try source.write(to: mirror.root.appendingPathComponent("iso.bin"))
        var record = DownloadRecord(url: main.url("iso.bin"), directory: try tempDir(), maxConnections: 4)
        record.mirrors = [mirror.url("iso.bin")]
        let (job, log) = makeJob(record)
        await job.start()
        let done = try await finish(job, log)

        #expect(done.status == .completed, "\(done.errorMessage ?? "")")
        #expect(try sha256(of: done.finalPath) == sha256(source))
        #expect(!main.requests.isEmpty)
        #expect(!mirror.requests.isEmpty, "the mirror served part of the file")
    }

    @Test func deadMainLinkFallsBackToMirror() async throws {
        let server = try TestServer()
        let source = try server.addFile("real.bin", size: 400_000)
        var record = DownloadRecord(url: server.url("gone.bin"), directory: try tempDir(), fileName: "real.bin")
        record.mirrors = [server.url("real.bin")]
        let (job, log) = makeJob(record)
        await job.start()
        let done = try await finish(job, log)

        #expect(done.status == .completed, "\(done.errorMessage ?? "")")
        #expect(try sha256(of: done.finalPath) == sha256(source))
    }

    @Test func mirrorWithADifferentFileIsIgnored() async throws {
        let server = try TestServer(throttle: 0.005)
        let source = try server.addFile("right.bin", size: 2_000_000)
        try server.addFile("wrong.bin", size: 1_999_000)
        var record = DownloadRecord(url: server.url("right.bin"), directory: try tempDir(), maxConnections: 4)
        record.mirrors = [server.url("wrong.bin")]
        let (job, log) = makeJob(record)
        await job.start()
        let done = try await finish(job, log)

        #expect(done.status == .completed, "\(done.errorMessage ?? "")")
        #expect(try sha256(of: done.finalPath) == sha256(source))
    }

    @Test func allLinksDeadFails() async throws {
        let server = try TestServer()
        var record = DownloadRecord(url: server.url("a.bin"), directory: try tempDir())
        record.mirrors = [server.url("b.bin")]
        let (job, log) = makeJob(record)
        await job.start()
        let done = try await finish(job, log, timeout: 10)
        #expect(done.status == .failed)
        #expect(done.errorMessage?.contains("404") == true)
    }

    // MARK: Size validation

    @Test func statedSizeIsMarkedVerified() async throws {
        let server = try TestServer()
        try server.addFile("sized.bin", size: 200_000)
        let (job, log) = makeJob(DownloadRecord(url: server.url("sized.bin"), directory: try tempDir()))
        await job.start()
        let done = try await finish(job, log)
        #expect(done.status == .completed)
        #expect(done.sizeVerified)
    }

    @Test func unstatedSizeIsNotMarkedVerified() async throws {
        let server = try TestServer()
        let source = try server.addFile("stream.bin", size: 200_000)
        let (job, log) = makeJob(DownloadRecord(url: server.url("nolength/stream.bin"), directory: try tempDir()))
        await job.start()
        let done = try await finish(job, log)
        #expect(done.status == .completed, "\(done.errorMessage ?? "")")
        #expect(done.totalBytes == 200_000)
        #expect(!done.sizeVerified)
        #expect(try sha256(of: done.finalPath) == sha256(source))
    }

    // MARK: Picky servers

    @Test(arguments: ["bareetag", "noifrange"])
    func serversThatMishandleIfRangeStillWork(mode: String) async throws {
        let server = try TestServer(throttle: 0.005)
        let source = try server.addFile("big.bin", size: 4_000_000)
        let (job, log) = makeJob(DownloadRecord(url: server.url("\(mode)/big.bin"), directory: try tempDir(), maxConnections: 4))
        await job.start()
        let done = try await finish(job, log)

        #expect(done.status == .completed, "\(done.errorMessage ?? "")")
        #expect(try sha256(of: done.finalPath) == sha256(source))
        #expect(!log.all.contains { $0.detail?.hasPrefix("Started over") == true }, "no restart from scratch")
        #expect(log.all.map(\.activeConnections).max() ?? 0 > 1)
    }

    @Test func strongETagsOnly() {
        #expect(DownloadJob.isStrongETag("\"abc\""))
        #expect(!DownloadJob.isStrongETag("abc"))
        #expect(!DownloadJob.isStrongETag("W/\"abc\""))
    }

    // MARK: Expired links

    @Test func expiredLinkContinuesWithANewOne() async throws {
        let server = try TestServer(throttle: 0.02)
        let source = try server.addFile("movie.bin", size: 4_000_000)
        let manager = try await makeManager()
        let id = try #require(try await manager.add([
            .init(url: server.url("expiring/movie.bin"), directory: try tempDir(), connections: 2),
        ]).first)
        await manager.start()
        try await eventually("progress") { (await manager.item(id)?.record.receivedBytes ?? 0) > 500_000 }
        try await manager.pause([id])
        try server.expireLinks()
        try await manager.resume([id])
        try await eventually("the link to fail", timeout: 15) { await manager.item(id)?.record.status == .failed }
        let failed = try #require(await manager.item(id)?.record)
        #expect(failed.errorMessage?.contains("403") == true)
        #expect(failed.receivedBytes > 500_000)

        let info = try await RemoteFileProbe.probe(server.url("movie.bin"))
        #expect(info.canContinue(expectedBytes: failed.totalBytes))

        try await manager.updateLink(id, to: server.url("movie.bin"))
        try await eventually("completion", timeout: 60) { await manager.item(id)?.record.status == .completed }
        let done = try #require(await manager.item(id)?.record)
        #expect(done.url == server.url("movie.bin"))
        #expect(try sha256(of: done.finalPath) == sha256(source))
        // Requests to the new link started where the old one stopped, not at byte 0.
        let fresh = server.requests.filter { $0 == "/movie.bin" }
        #expect(!fresh.isEmpty)
        let ranges = try String(contentsOf: server.root.appendingPathComponent(".requests"), encoding: .utf8)
            .split(separator: "\n").filter { $0.hasPrefix("/movie.bin ") }
        #expect(!ranges.contains { $0.hasSuffix("bytes=0-") }, "kept the downloaded data: \(ranges)")
    }

    @Test func probeReportsDifferentFiles() async throws {
        let server = try TestServer()
        try server.addFile("one.bin", size: 1000)
        let info = try await RemoteFileProbe.probe(server.url("one.bin"))
        #expect(info.totalBytes == 1000)
        #expect(info.supportsRanges)
        #expect(!info.canContinue(expectedBytes: 999))
        await #expect(throws: RemoteFileProbe.ProbeError.http(404)) {
            try await RemoteFileProbe.probe(server.url("missing.bin"))
        }
    }

    // MARK: Manager

    @Test func editingMirrorsOfARunningDownloadKeepsItGoing() async throws {
        let server = try TestServer(throttle: 0.03)
        let source = try server.addFile("f.bin", size: 4_000_000)
        try source.write(to: server.root.appendingPathComponent("copy.bin"))
        let manager = try await makeManager()
        let id = try #require(try await manager.add([.init(url: server.url("f.bin"), directory: try tempDir(), connections: 2)]).first)
        await manager.start()
        try await eventually("progress") { (await manager.item(id)?.record.receivedBytes ?? 0) > 100_000 }
        try await manager.setMirrors([server.url("copy.bin"), server.url("f.bin")], for: id)
        #expect(await manager.item(id)?.record.mirrors == [server.url("copy.bin")], "the main link isn't its own mirror")
        try await eventually("completion", timeout: 60) { await manager.item(id)?.record.status == .completed }
        #expect(try sha256(of: await manager.item(id)?.record.finalPath) == sha256(source))
    }

    @Test func speedLimitsPersistAndApply() async throws {
        let dbURL = try tempDir().appendingPathComponent("flux.sqlite")
        let manager = try await DownloadManager(database: try FluxDatabase(url: dbURL), jobOptions: fastOptions, mediaTools: .none)
        let id = try #require(try await manager.add([
            .init(url: URL(string: "https://example.com/x.zip")!, startImmediately: false, speedLimit: 300_000),
        ]).first)
        #expect(await manager.item(id)?.record.speedLimit == 300_000)
        await manager.setSpeedLimit(1, for: [id])
        #expect(await manager.item(id)?.record.speedLimit == FluxSettings.minimumSpeedLimit, "clamped to the minimum")
        await manager.setSpeedLimit(nil, for: [id])
        #expect(await manager.item(id)?.record.speedLimit == nil)

        var settings = await manager.settings
        settings.speedLimitEnabled = true
        settings.speedLimit = 2_000_000
        try await manager.updateSettings(settings)
        let reopened = try await DownloadManager(database: try FluxDatabase(url: dbURL), jobOptions: fastOptions, mediaTools: .none)
        #expect(await reopened.settings.effectiveSpeedLimit == 2_000_000)
    }

    private func makeManager() async throws -> DownloadManager {
        let db = try FluxDatabase(url: try tempDir().appendingPathComponent("flux.sqlite"))
        return try await DownloadManager(database: db, jobOptions: fastOptions, mediaTools: .none)
    }
}
