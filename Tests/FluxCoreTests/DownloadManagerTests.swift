import Foundation
import Testing
@testable import FluxCore

/// Mirrors the manager's event stream, as the app does, and records history for assertions.
final class EventMirror: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [UUID: DownloadManager.Item] = [:]
    private var completionOrder: [UUID] = []
    private var maxActive = 0
    private var task: Task<Void, Never>?

    init(_ manager: DownloadManager) async {
        let events = await manager.events()
        task = Task { [weak self] in
            for await event in events { self?.apply(event) }
        }
    }

    deinit { task?.cancel() }

    private func apply(_ event: DownloadManager.Event) {
        lock.withLock {
            switch event {
            case .reset(let all, _):
                items = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
            case .updated(let item):
                if item.record.status == .completed, items[item.id]?.record.status != .completed {
                    completionOrder.append(item.id)
                }
                items[item.id] = item
            case .removed(let ids):
                for id in ids { items[id] = nil }
            case .settingsChanged:
                break
            }
            maxActive = max(maxActive, items.values.filter { $0.record.status.isActive }.count)
        }
    }

    func status(_ id: UUID) -> DownloadStatus? { lock.withLock { items[id]?.record.status } }
    func record(_ id: UUID) -> DownloadRecord? { lock.withLock { items[id]?.record } }
    var completed: [UUID] { lock.withLock { completionOrder } }
    var peakActive: Int { lock.withLock { maxActive } }
}

@Suite(.serialized)
struct DownloadManagerTests {
    private func makeManager(_ dbURL: URL, settings: FluxSettings? = nil) async throws -> DownloadManager {
        let db = try FluxDatabase(url: dbURL)
        if let settings { try await db.save(settings) }
        return try await DownloadManager(database: db, jobOptions: fastOptions)
    }

    @Test func rejectsNonHTTPLinks() async throws {
        let manager = try await makeManager(try tempDir().appendingPathComponent("db.sqlite"))
        await #expect(throws: FluxError.self) {
            try await manager.add([.init(url: URL(string: "file:///etc/passwd")!)])
        }
        #expect(await manager.allItems.isEmpty)
    }

    @Test func queueRespectsConcurrencyLimitAndPriority() async throws {
        let server = try TestServer(throttle: 0.005)
        for name in ["low", "high", "normal"] { try server.addFile(name, size: 400_000) }
        let out = try tempDir()
        let manager = try await makeManager(
            out.appendingPathComponent("db.sqlite"),
            settings: FluxSettings(downloadDirectory: out, maxConcurrentDownloads: 1, connectionsPerDownload: 2))
        let mirror = await EventMirror(manager)
        await manager.start()

        let ids = try await manager.add([
            .init(url: server.url("low"), priority: .low, startImmediately: false),
            .init(url: server.url("high"), priority: .high, startImmediately: false),
            .init(url: server.url("normal"), priority: .normal, startImmediately: false),
        ])
        try await manager.resume(ids)
        try await eventually("all complete", timeout: 60) { mirror.completed.count == 3 }

        #expect(mirror.completed == [ids[1], ids[2], ids[0]], "high, normal, low")
        #expect(mirror.peakActive == 1)
    }

    @Test func quitAndRelaunchResumesFromCheckpoint() async throws {
        let server = try TestServer(throttle: 0.02)
        let source = try server.addFile("movie.bin", size: 6_000_000)
        let out = try tempDir()
        let dbURL = out.appendingPathComponent("db.sqlite")
        let settings = FluxSettings(downloadDirectory: out, maxConcurrentDownloads: 2, connectionsPerDownload: 4)

        // First "launch": download part of the file, then quit normally.
        let first = try await makeManager(dbURL, settings: settings)
        let firstMirror = await EventMirror(first)
        await first.start()
        let id = try #require(try await first.add([.init(url: server.url("movie.bin"))]).first)
        try await eventually("progress") { (firstMirror.record(id)?.receivedBytes ?? 0) > 1_000_000 }
        await first.shutdown()
        let savedBytes = try #require(try await FluxDatabase(url: dbURL).loadDownloads().first).receivedBytes
        #expect(savedBytes > 0)

        // Second "launch": the interrupted download is recovered and finishes.
        let second = try await makeManager(dbURL)
        #expect(await second.item(id)?.record.status == .queued)
        let mirror = await EventMirror(second)
        await second.start()
        try await eventually("completion", timeout: 60) { mirror.status(id) == .completed }

        let record = try #require(mirror.record(id))
        #expect(try sha256(of: record.finalPath) == sha256(source))
        let persisted = try #require(try await FluxDatabase(url: dbURL).loadDownloads().first)
        #expect(persisted.status == .completed)
        #expect(persisted.finalPath == record.finalPath)
    }

    @Test func recoveryHonorsResumeOnLaunchSetting() async throws {
        let dbURL = try tempDir().appendingPathComponent("db.sqlite")
        let db = try FluxDatabase(url: dbURL)
        var interrupted = DownloadRecord(url: URL(string: "https://example.com/a")!, directory: URL(fileURLWithPath: "/tmp"))
        interrupted.status = .downloading
        try await db.save(interrupted)
        try await db.save(FluxSettings(resumeOnLaunch: false))

        let manager = try await DownloadManager(database: try FluxDatabase(url: dbURL))
        #expect(await manager.item(interrupted.id)?.record.status == .paused)
    }

    @Test func pauseResumeCancelAndRemove() async throws {
        let server = try TestServer(throttle: 0.02)
        let source = try server.addFile("f.bin", size: 3_000_000)
        let out = try tempDir()
        let dbURL = out.appendingPathComponent("db.sqlite")
        let manager = try await makeManager(dbURL, settings: FluxSettings(downloadDirectory: out, connectionsPerDownload: 2))
        let mirror = await EventMirror(manager)
        await manager.start()
        let id = try #require(try await manager.add([.init(url: server.url("f.bin"))]).first)

        try await eventually("progress") { (mirror.record(id)?.receivedBytes ?? 0) > 100_000 }
        try await manager.pause([id])
        try await eventually("paused") { mirror.status(id) == .paused }

        try await manager.cancel([id])
        try await eventually("cancelled") { mirror.status(id) == .cancelled }
        #expect(mirror.record(id)?.receivedBytes == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).allSatisfy { !$0.hasSuffix(".fluxpart") })

        try await manager.resume([id]) // retry after cancel starts over
        try await eventually("completion", timeout: 60) { mirror.status(id) == .completed }
        let final = try #require(mirror.record(id)?.finalPath)
        #expect(try sha256(of: final) == sha256(source))

        try await manager.remove([id], trashFiles: false)
        #expect(await manager.item(id) == nil)
        #expect(try await FluxDatabase(url: dbURL).loadDownloads().isEmpty)
        #expect(FileManager.default.fileExists(atPath: final.path), "remove without trash keeps the file")
    }
}
