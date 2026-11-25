import Foundation
import Testing
@testable import FluxCore

@Suite(.serialized)
struct DownloadJobTests {
    @Test func multiConnectionDownloadIsByteIdentical() async throws {
        let server = try TestServer()
        let source = try server.addFile("big.bin", size: 6_000_000)
        let out = try tempDir()
        let (job, log) = makeJob(DownloadRecord(url: server.url("big.bin"), directory: out, maxConnections: 8))
        await job.start()
        let record = try await finish(job, log)

        #expect(record.status == .completed, "\(record.errorMessage ?? "")")
        #expect(record.supportsRanges)
        #expect(record.segments.count >= 8)
        #expect(log.all.map(\.activeConnections).max() ?? 0 > 1, "used parallel connections")
        #expect(try sha256(of: record.finalPath) == sha256(source))
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == ["big.bin"], "no temp files left")
    }

    @Test func serverWithoutRangesFallsBackToSingleConnection() async throws {
        let server = try TestServer(noRange: true)
        let source = try server.addFile("plain.bin", size: 1_500_000)
        let (job, log) = makeJob(DownloadRecord(url: server.url("plain.bin"), directory: try tempDir()))
        await job.start()
        let record = try await finish(job, log)

        #expect(record.status == .completed)
        #expect(!record.supportsRanges)
        #expect(record.segments.count == 1)
        #expect(log.all.map(\.activeConnections).max() == 1)
        #expect(try sha256(of: record.finalPath) == sha256(source))
    }

    @Test func emptyFileCompletes() async throws {
        let server = try TestServer()
        try server.addFile("empty.txt", size: 0)
        let (job, log) = makeJob(DownloadRecord(url: server.url("empty.txt"), directory: try tempDir()))
        await job.start()
        let record = try await finish(job, log)
        #expect(record.status == .completed, "\(record.errorMessage ?? "")")
        #expect(try Data(contentsOf: try #require(record.finalPath)).isEmpty)
    }

    @Test func usesContentDispositionNameFollowsRedirectsNeverOverwrites() async throws {
        let server = try TestServer()
        let source = try server.addFile("blob", size: 300_000)
        let out = try tempDir()
        let existing = out.appendingPathComponent("Report.pdf")
        try Data("keep me".utf8).write(to: existing)
        let (job, log) = makeJob(DownloadRecord(url: server.url("redirect/blob?cd=Report.pdf"), directory: out))
        await job.start()
        let record = try await finish(job, log)

        #expect(record.status == .completed)
        #expect(record.fileName == "Report (1).pdf")
        #expect(try sha256(of: record.finalPath) == sha256(source))
        #expect(try String(contentsOf: existing, encoding: .utf8) == "keep me")
    }

    @Test func maliciousContentDispositionStaysInsideFolder() async throws {
        let server = try TestServer()
        try server.addFile("evil", size: 1000)
        let out = try tempDir()
        let (job, log) = makeJob(DownloadRecord(url: server.url("evil?cd=../../escape.sh"), directory: out))
        await job.start()
        let record = try await finish(job, log)
        let final = try #require(record.finalPath)
        #expect(final.deletingLastPathComponent().standardizedFileURL == out.standardizedFileURL)
        #expect(!final.lastPathComponent.contains("/"))
    }

    @Test func finishedFileIsQuarantined() async throws {
        let server = try TestServer()
        try server.addFile("app.zip", size: 10_000)
        let (job, log) = makeJob(DownloadRecord(url: server.url("app.zip"), directory: try tempDir()))
        await job.start()
        let record = try await finish(job, log)
        let path = try #require(record.finalPath).path
        #expect(getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) > 0)
        #expect(getxattr(path, "com.apple.metadata:kMDItemWhereFroms", nil, 0, 0, 0) > 0)
    }

    @Test func pauseThenResumeInFreshJobAfterRelaunch() async throws {
        let server = try TestServer(throttle: 0.02)
        let source = try server.addFile("slow.bin", size: 8_000_000)
        let (job, log) = makeJob(DownloadRecord(url: server.url("slow.bin"), directory: try tempDir(), maxConnections: 4))
        await job.start()
        try await eventually("progress") { (log.last?.record.receivedBytes ?? 0) > 1_000_000 }
        let paused = await job.pause().record

        #expect(paused.status == .paused)
        #expect(paused.receivedBytes > 0 && paused.receivedBytes < 8_000_000)
        #expect(FileManager.default.fileExists(atPath: try #require(paused.partFileURL).path))

        // A brand-new job from the persisted record, as after an app restart.
        let (resumed, resumedLog) = makeJob(paused)
        await resumed.start()
        let record = try await finish(resumed, resumedLog, timeout: 60)
        #expect(record.status == .completed, "\(record.errorMessage ?? "")")
        #expect(try sha256(of: record.finalPath) == sha256(source))
        let firstReceived = try #require(resumedLog.all.first { $0.record.status == .downloading }).record.receivedBytes
        #expect(firstReceived >= paused.receivedBytes, "resumed instead of restarting")
    }

    @Test func restartsWhenFileChangesWhilePaused() async throws {
        let server = try TestServer(throttle: 0.02)
        try server.addFile("changing.bin", size: 4_000_000)
        let (job, log) = makeJob(DownloadRecord(url: server.url("changing.bin"), directory: try tempDir(), maxConnections: 2))
        await job.start()
        try await eventually("progress") { (log.last?.record.receivedBytes ?? 0) > 300_000 }
        let paused = await job.pause().record
        try await Task.sleep(for: .milliseconds(20)) // ensure a different mtime → new ETag
        let replacement = try server.addFile("changing.bin", size: 1_000_000)

        let (resumed, resumedLog) = makeJob(paused)
        await resumed.start()
        let record = try await finish(resumed, resumedLog, timeout: 60)
        #expect(record.status == .completed, "\(record.errorMessage ?? "")")
        #expect(record.totalBytes == 1_000_000)
        #expect(try sha256(of: record.finalPath) == sha256(replacement))
    }

    @Test func cancelDeletesPartialData() async throws {
        let server = try TestServer(throttle: 0.02)
        try server.addFile("big.bin", size: 4_000_000)
        let out = try tempDir()
        let (job, log) = makeJob(DownloadRecord(url: server.url("big.bin"), directory: out, maxConnections: 2))
        await job.start()
        try await eventually("progress") { (log.last?.record.receivedBytes ?? 0) > 200_000 }
        let record = await job.cancel().record
        #expect(record.status == .cancelled)
        #expect(record.segments.isEmpty && record.partFileName == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
    }

    @Test func missingFileFailsFastWithReadableError() async throws {
        let server = try TestServer()
        let (job, log) = makeJob(DownloadRecord(url: server.url("nope.bin"), directory: try tempDir()))
        await job.start()
        let record = try await finish(job, log, timeout: 5)
        #expect(record.status == .failed)
        #expect(record.errorMessage?.contains("404") == true)
    }

    @Test func connectionRefusedRetriesThenFails() async throws {
        // Nothing listens on this port: every attempt fails, retries back off, then give up.
        var options = fastOptions
        options.maxRetries = 2
        let (job, log) = makeJob(DownloadRecord(url: URL(string: "http://127.0.0.1:9/x")!, directory: try tempDir()), options: options)
        await job.start()
        let record = try await finish(job, log, timeout: 10)
        #expect(record.status == .failed)
    }
}
