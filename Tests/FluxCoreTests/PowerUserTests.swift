import Foundation
import Testing
@testable import FluxCore

/// A clock tests can move.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date) { current = date }
    var now: Date { lock.withLock { current } }
    func set(_ date: Date) { lock.withLock { current = date } }
}

/// Today (in the current calendar) at hh:mm.
func today(_ hour: Int, _ minute: Int = 0, second: Int = 0, dayOffset: Int = 0) -> Date {
    let calendar = Calendar.current
    let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: Date()))!
    return calendar.date(bySettingHour: hour, minute: minute, second: second, of: day)!
}

struct ScheduleTests {
    @Test func findsStartsAndStopsInAnInterval() {
        let schedule = QueueSchedule(start: 2 * 60, stop: 6 * 60)
        let changes = schedule.changes(from: today(0), to: today(12))
        #expect(changes.map(\.change) == [.start, .stop])
        #expect(changes.map(\.date) == [today(2), today(6)])
        #expect(schedule.isInsideWindow(at: today(3)))
        #expect(!schedule.isInsideWindow(at: today(7)))
        #expect(!schedule.isInsideWindow(at: today(1, 59)))
    }

    @Test func overnightWindowStopsTheNextDay() {
        let schedule = QueueSchedule(start: 23 * 60, stop: 60)
        #expect(schedule.isInsideWindow(at: today(23, 30)))
        #expect(schedule.isInsideWindow(at: today(0, 30, dayOffset: 1)))
        #expect(!schedule.isInsideWindow(at: today(1, 30, dayOffset: 1)))
        #expect(schedule.next(after: today(12))?.date == today(23))
        #expect(schedule.next(after: today(23, 30))?.date == today(1, dayOffset: 1))
        #expect(schedule.next(after: today(23, 30))?.change == .stop)
    }

    @Test func onlyRunsOnChosenDays() {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: today(12))
        let tomorrow = weekday % 7 + 1
        let schedule = QueueSchedule(days: [tomorrow], start: 9 * 60, stop: 10 * 60)
        #expect(schedule.changes(from: today(0), to: today(23)).isEmpty)
        #expect(schedule.changes(from: today(0), to: today(23, dayOffset: 1)).count == 2)
    }

    @Test func withoutStopTimeOnlyStarts() {
        let schedule = QueueSchedule(start: 2 * 60)
        #expect(schedule.changes(from: today(0), to: today(12)).map(\.change) == [.start])
        #expect(!schedule.isInsideWindow(at: today(3)))
        #expect(schedule.summary == "Every day at \(QueueSchedule.time(120))")
        #expect(QueueSchedule(days: [2, 3, 4, 5, 6], start: 90, stop: 6 * 60).summary
            == "Weekdays \(QueueSchedule.time(90))–\(QueueSchedule.time(360))")
    }

    @Test func settingsKeepQueuesAndTolerateJunk() throws {
        let queue = DownloadQueue(name: "  Night ", maxConcurrent: 0, schedule: QueueSchedule(start: 60, stop: 120))
        var settings = FluxSettings(queues: [queue, queue])
        settings = settings.normalized()
        #expect(settings.queues.count == 1)
        #expect(settings.queues[0].name == "Night")
        #expect(settings.queues[0].maxConcurrent == 1)
        let decoded = try JSONDecoder().decode(FluxSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.queues == settings.queues)
        let junk = try JSONDecoder().decode(FluxSettings.self, from: Data(#"{"queues": 5, "watchClipboard": true}"#.utf8))
        #expect(junk.queues.isEmpty)
        #expect(junk.watchClipboard)
    }
}

@Suite(.serialized)
struct QueueManagerTests {
    private func makeManager(
        queues: [DownloadQueue], maxConcurrent: Int = 3, clock: TestClock = TestClock(Date()), start: Bool = true
    ) async throws -> DownloadManager {
        let db = try FluxDatabase(url: try tempDir().appendingPathComponent("flux.sqlite"))
        try await db.save(FluxSettings(downloadDirectory: try tempDir(), maxConcurrentDownloads: maxConcurrent, queues: queues))
        let manager = try await DownloadManager(database: db, jobOptions: fastOptions, mediaTools: .none, clock: { clock.now })
        if start { await manager.start() }
        return manager
    }

    @Test func stoppedQueueWaitsUntilStarted() async throws {
        let server = try TestServer()
        try server.addFile("a.bin", size: 200_000)
        try server.addFile("b.bin", size: 200_000)
        let night = DownloadQueue(name: "Night")
        let manager = try await makeManager(queues: [night])
        let ids = try await manager.add([
            .init(url: server.url("a.bin"), queue: night.id),
            .init(url: server.url("b.bin")),
        ])
        try await eventually("main queue download") { await manager.item(ids[1])?.record.status == .completed }
        #expect(await manager.item(ids[0])?.record.status == .queued)
        #expect(await manager.item(ids[0])?.record.queueID == night.id)

        await manager.startQueue(night.id)
        #expect(await manager.queue(night.id)?.isRunning == true)
        try await eventually("queued download") { await manager.item(ids[0])?.record.status == .completed }
    }

    @Test func stoppingAQueueStopsItsDownloadsAndKeepsThemWaiting() async throws {
        let server = try TestServer(throttle: 0.01)
        try server.addFile("slow.bin", size: 2_000_000)
        let queue = DownloadQueue(name: "Later", isRunning: true)
        let manager = try await makeManager(queues: [queue])
        let id = try #require(try await manager.add([.init(url: server.url("slow.bin"), connections: 2, queue: queue.id)]).first)
        try await eventually("download to start") {
            (await manager.item(id)?.record.receivedBytes ?? 0) > 50_000
        }
        await manager.stopQueue(queue.id)
        #expect(await manager.item(id)?.record.status == .queued)
        let received = await manager.item(id)?.record.receivedBytes ?? 0
        try await Task.sleep(for: .milliseconds(400))
        #expect(await manager.item(id)?.record.status == .queued)
        #expect(await manager.item(id)?.record.receivedBytes == received)

        await manager.startQueue(queue.id)
        try await eventually("download to finish", timeout: 60) { await manager.item(id)?.record.status == .completed }
    }

    @Test func scheduleStartsAndStopsTheQueue() async throws {
        let server = try TestServer()
        try server.addFile("night.bin", size: 100_000)
        let clock = TestClock(today(1, 59))
        let queue = DownloadQueue(name: "Night", schedule: QueueSchedule(start: 2 * 60, stop: 3 * 60))
        let manager = try await makeManager(queues: [queue], clock: clock)
        let id = try #require(try await manager.add([.init(url: server.url("night.bin"), queue: queue.id)]).first)

        clock.set(today(1, 59, second: 30))
        await manager.checkSchedules()
        #expect(await manager.queue(queue.id)?.isRunning == false)
        #expect(await manager.item(id)?.record.status == .queued)

        clock.set(today(2, 0, second: 5))
        await manager.checkSchedules()
        #expect(await manager.queue(queue.id)?.isRunning == true)
        try await eventually("scheduled download") { await manager.item(id)?.record.status == .completed }

        clock.set(today(3, 0, second: 5))
        await manager.checkSchedules()
        #expect(await manager.queue(queue.id)?.isRunning == false)
    }

    @Test func scheduleWithoutStopTimeStopsWhenEmpty() async throws {
        let server = try TestServer()
        try server.addFile("once.bin", size: 80_000)
        let clock = TestClock(today(4, 59))
        let queue = DownloadQueue(name: "Dawn", schedule: QueueSchedule(start: 5 * 60))
        let manager = try await makeManager(queues: [queue], clock: clock)
        let id = try #require(try await manager.add([.init(url: server.url("once.bin"), queue: queue.id)]).first)
        clock.set(today(5, 0, second: 1))
        await manager.checkSchedules()
        try await eventually("download") { await manager.item(id)?.record.status == .completed }
        try await eventually("queue to stop by itself") { await manager.queue(queue.id)?.isRunning == false }
        // Added later: waits for tomorrow's start.
        let later = try #require(try await manager.add([.init(url: server.url("once.bin"), queue: queue.id)]).first)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await manager.item(later)?.record.status == .queued)
    }

    @Test func launchingInsideAWindowStartsTheQueue() async throws {
        let clock = TestClock(today(2, 30))
        let queue = DownloadQueue(name: "Night", schedule: QueueSchedule(start: 2 * 60, stop: 3 * 60))
        let manager = try await makeManager(queues: [queue], clock: clock)
        #expect(await manager.queue(queue.id)?.isRunning == true)
    }

    @Test func queueLimitCapsItsOwnDownloads() async throws {
        let server = try TestServer(throttle: 0.002)
        for n in 0..<3 { try server.addFile("q\(n).bin", size: 300_000) }
        let queue = DownloadQueue(name: "One at a time", maxConcurrent: 1, isRunning: true)
        let manager = try await makeManager(queues: [queue], maxConcurrent: 3)
        let mirror = await EventMirror(manager)
        let ids = try await manager.add((0..<3).map { .init(url: server.url("q\($0).bin"), connections: 1, queue: queue.id) })
        try await eventually("all three", timeout: 60) {
            await ids.asyncCompactMap { await manager.item($0)?.record.status }.allSatisfy { $0 == .completed }
        }
        #expect(mirror.peakActive == 1)
    }

    @Test func editingSettingsKeepsRunStateAndDeletingAQueueFreesItsDownloads() async throws {
        let server = try TestServer()
        try server.addFile("x.bin", size: 100_000)
        let queue = DownloadQueue(name: "Held")
        let manager = try await makeManager(queues: [queue])
        await manager.startQueue(queue.id)
        await manager.stopQueue(queue.id)
        let id = try #require(try await manager.add([.init(url: server.url("x.bin"), queue: queue.id)]).first)

        // A stale copy of the settings (as the UI might hold) says "running": ignored.
        var stale = await manager.settings
        stale.queues[0].isRunning = true
        stale.queues[0].name = "Held renamed"
        try await manager.updateSettings(stale)
        #expect(await manager.queue(queue.id)?.isRunning == false)
        #expect(await manager.queue(queue.id)?.name == "Held renamed")
        #expect(await manager.item(id)?.record.status == .queued)

        var without = await manager.settings
        without.queues = []
        try await manager.updateSettings(without)
        #expect(await manager.item(id)?.record.queueID == nil)
        try await eventually("download in main queue") { await manager.item(id)?.record.status == .completed }
    }

    @Test func movingADownloadIntoAStoppedQueueStopsIt() async throws {
        let server = try TestServer(throttle: 0.01)
        try server.addFile("m.bin", size: 2_000_000)
        let queue = DownloadQueue(name: "Parked")
        let manager = try await makeManager(queues: [queue])
        let id = try #require(try await manager.add([.init(url: server.url("m.bin"), connections: 2)]).first)
        try await eventually("download to start") { await manager.item(id)?.record.status == .downloading }
        await manager.move([id], toQueue: queue.id)
        #expect(await manager.item(id)?.record.status == .queued)
        #expect(await manager.item(id)?.record.queueID == queue.id)
        await manager.move([id], toQueue: nil)
        try await eventually("download to finish", timeout: 60) { await manager.item(id)?.record.status == .completed }
    }
}

struct LinkListTests {
    @Test func readsTextWithCommentsAndAria2Options() throws {
        let text = """
        # my links
        https://example.com/a.zip
        see https://example.com/b.pdf and https://example.com/c.iso
        https://example.com/d.dmg
          out=Disk Image.dmg
          dir=/tmp/flux-imports
          checksum=sha-256=\(String(repeating: "ab", count: 32))
        https://one.example/e.tar\thttps://two.example/e.tar
        https://example.com/a.zip
        not a link
        """
        let entries = try LinkList.parse(Data(text.utf8), format: .text)
        #expect(entries.map(\.url.absoluteString) == [
            "https://example.com/a.zip", "https://example.com/b.pdf", "https://example.com/c.iso",
            "https://example.com/d.dmg", "https://one.example/e.tar",
        ])
        #expect(entries[3].fileName == "Disk Image.dmg")
        #expect(entries[3].directory?.path == "/tmp/flux-imports")
        #expect(entries[3].checksum?.algorithm == .sha256)
        #expect(entries[4].mirrors == [URL(string: "https://two.example/e.tar")!])
    }

    @Test func readsCSVWithHeadersQuotesAndOtherSeparators() throws {
        let csv = """
        Name,URL,Folder,SHA256,Notes
        "Report, final.pdf",https://example.com/r.pdf,~/Documents,,"says ""hi""
        over two lines"
        ,https://example.com/x.bin,relative/folder,\(String(repeating: "cd", count: 32)),
        bad,ftp://example.com/nope,,,
        """
        let entries = try LinkList.parse(Data(csv.utf8))
        #expect(entries.count == 2)
        #expect(entries[0].fileName == "Report, final.pdf")
        #expect(entries[0].directory?.path == NSHomeDirectory() + "/Documents")
        #expect(entries[1].fileName == nil)
        #expect(entries[1].directory == nil, "relative folders are ignored")
        #expect(entries[1].checksum?.hex == String(repeating: "cd", count: 32))

        let semicolons = try LinkList.parse(Data("link;name\nhttps://example.com/1.zip;One.zip\n".utf8), format: .csv)
        #expect(semicolons.first?.fileName == "One.zip")
        let headerless = try LinkList.parse(Data("https://example.com/1.zip,whatever\nhttps://example.com/2.zip\n".utf8), format: .csv)
        #expect(headerless.count == 2)
    }

    @Test func jsonRoundTripKeepsDetails() throws {
        var record = DownloadRecord(url: URL(string: "https://example.com/tool.dmg")!, directory: URL(fileURLWithPath: "/tmp/apps"))
        record.fileName = "Tool.dmg"
        record.mirrors = [URL(string: "https://mirror.example/tool.dmg")!]
        record.checksum = Checksum.parse(String(repeating: "ef", count: 32))
        record.referer = URL(string: "https://example.com/download")
        let data = LinkList.export([record], format: .json)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"format\" : \"flux-downloads\""))
        let entries = try LinkList.parse(data)
        #expect(entries.count == 1)
        #expect(entries[0].url == record.url)
        #expect(entries[0].fileName == "Tool.dmg")
        #expect(entries[0].directory?.path == "/tmp/apps")
        #expect(entries[0].mirrors == record.mirrors)
        #expect(entries[0].checksum == record.checksum)
        #expect(entries[0].referer == record.referer)
    }

    @Test func jsonArraysOfStringsOrObjectsSkipBadEntries() throws {
        let json = #"["https://example.com/a.zip", {"url": "https://example.com/b.zip", "name": "B.zip"}, {"url": "javascript:alert(1)"}, 42]"#
        let entries = try LinkList.parse(Data(json.utf8), format: .text) // wrong format: content wins
        #expect(entries.map(\.url.lastPathComponent) == ["a.zip", "b.zip"])
        #expect(entries[1].fileName == "B.zip")
    }

    @Test func emptyOrBrokenFilesExplainThemselves() {
        #expect(throws: LinkListError.noLinks) { try LinkList.parse(Data("nothing here\n".utf8)) }
        #expect(throws: LinkListError.self) { try LinkList.parse(Data("{ not json".utf8), format: .json) }
    }

    @Test func csvExportIsSafeForSpreadsheets() throws {
        var record = DownloadRecord(url: URL(string: "https://example.com/a.csv")!, directory: URL(fileURLWithPath: "/tmp"))
        record.fileName = "=HYPERLINK(\"x\"), more.csv"
        let text = String(decoding: LinkList.export([record], format: .csv), as: UTF8.self)
        let lines = text.split(separator: "\n")
        #expect(lines.first?.hasPrefix("url,name,folder,status") == true)
        #expect(text.contains(#""'=HYPERLINK(""x""), more.csv""#))
        let back = try LinkList.parse(Data(text.utf8))
        #expect(back.first?.url == record.url)
    }
}

struct ClipboardLinkTests {
    @Test func offersFilesAndMediaButNotOrdinaryPages() {
        let text = """
        https://example.com/app.dmg https://example.com/about https://www.youtube.com/watch?v=dQw4w9WgXcQ
        https://www.youtube.com/ https://api.example.com/data.json https://example.com/index.html
        https://cdn.example.com/files/archive.tar.gz?token=1 https://example.com/font.woff2
        """
        let offered = ClipboardLinks.downloadCandidates(in: text).map(\.absoluteString)
        #expect(offered == [
            "https://example.com/app.dmg", "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://cdn.example.com/files/archive.tar.gz?token=1", "https://example.com/font.woff2",
        ])
    }

    @Test func ignoresLongText() {
        let long = String(repeating: "word ", count: 5_000) + "https://example.com/app.dmg"
        #expect(ClipboardLinks.downloadCandidates(in: long).isEmpty)
    }
}

@Suite(.serialized)
struct ControlTests {
    private func socketURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("fx-\(UUID().uuidString.prefix(8)).sock")
    }

    @Test func socketIsPrivateAndAnswers() throws {
        let url = socketURL()
        let server = ControlServer(socketURL: url)
        try server.start { request in ControlResponse(message: "pong \(request.command.rawValue)") }
        defer { server.stop() }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try ControlClient.send(ControlRequest(.ping), socketURL: url).message == "pong ping")
        #expect(try ControlClient.send(ControlRequest(.list), socketURL: url).message == "pong list")

        // A second app instance can't take over the live socket.
        #expect(throws: ControlError.alreadyRunning) { try ControlServer(socketURL: url).start { _ in ControlResponse() } }
    }

    @Test func staleSocketsAreReplacedButOtherFilesAreNot() throws {
        let url = socketURL()
        let first = ControlServer(socketURL: url)
        try first.start { _ in ControlResponse() }
        // Simulate a crash: the listener goes away but the file stays.
        let crashed = ControlServer(socketURL: url)
        first.stop()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(throws: ControlError.notRunning) { try ControlClient.send(ControlRequest(.ping), socketURL: url) }

        try crashed.start { _ in ControlResponse(message: "back") }
        crashed.stop()

        try Data("keep me".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: ControlError.pathInUse(url.path)) { try ControlServer(socketURL: url).start { _ in ControlResponse() } }
        #expect(try String(contentsOf: url, encoding: .utf8) == "keep me")
    }

    @Test func garbageGetsAnErrorNotACrash() throws {
        let url = socketURL()
        let server = ControlServer(socketURL: url)
        try server.start { _ in ControlResponse(message: "ok") }
        defer { server.stop() }
        let fd = try ControlClient.connect(url.path)
        defer { close(fd) }
        ControlClient.configure(fd, timeout: 5)
        _ = "not json\n".withCString { write(fd, $0, strlen($0)) }
        var buffer = Data()
        let reply = try JSONDecoder().decode(ControlResponse.self, from: ControlClient.readLine(fd, buffer: &buffer))
        #expect(!reply.ok)
        // The connection stays usable.
        try ControlClient.writeLine(fd, ControlRequest(.ping))
        #expect(try JSONDecoder().decode(ControlResponse.self, from: ControlClient.readLine(fd, buffer: &buffer)).message == "ok")
    }

    @Test func commandsDriveTheManager() async throws {
        let server = try TestServer(throttle: 0.01)
        try server.addFile("big.bin", size: 3_000_000)
        try server.addFile("small.bin", size: 50_000)
        let downloads = try tempDir()
        let db = try FluxDatabase(url: try tempDir().appendingPathComponent("flux.sqlite"))
        let night = DownloadQueue(name: "Night")
        try await db.save(FluxSettings(downloadDirectory: downloads, queues: [night]))
        let manager = try await DownloadManager(database: db, jobOptions: fastOptions, mediaTools: .none)
        await manager.start()
        let handler = ControlHandler(manager: manager)

        let custom = try tempDir()
        let added = await handler.handle(ControlRequest(.add, entries: [
            LinkListEntry(url: server.url("small.bin"), fileName: "renamed.bin", directory: custom),
            LinkListEntry(url: server.url("big.bin")),
        ]))
        #expect(added.ok)
        #expect(added.message == "Added 2 downloads.")
        let ids = try #require(added.ids)
        let smallID = try #require(UUID(uuidString: ids[0]))
        try await eventually("small download") { await manager.item(smallID)?.record.status == .completed }
        #expect(await manager.item(smallID)?.record.finalPath?.path == custom.appendingPathComponent("renamed.bin").path)

        // IDs by prefix, as flux list shows them.
        let bigPrefix = String(ids[1].prefix(8))
        let paused = await handler.handle(ControlRequest(.pause, targets: [bigPrefix]))
        #expect(paused.ok, "\(paused.error ?? "")")
        try await eventually("pause") { await manager.item(UUID(uuidString: ids[1])!)?.record.status == .paused }
        let status = await handler.handle(ControlRequest(.status, targets: [bigPrefix]))
        #expect(status.downloads?.first?.status == "paused")
        #expect(status.downloads?.first?.shortID == bigPrefix)

        let unknown = await handler.handle(ControlRequest(.resume, targets: ["zzzz"]))
        #expect(!unknown.ok)
        #expect(unknown.error?.contains("No download with ID zzzz") == true)
        #expect(await !handler.handle(ControlRequest(.add, entries: [LinkListEntry(url: server.url("x"))], queue: "Nope")).ok)

        let list = await handler.handle(ControlRequest(.list))
        #expect(list.downloads?.count == 2)

        let limited = await handler.handle(ControlRequest(.limit, speedLimit: 2_000_000))
        #expect(limited.speedLimit == 2_000_000)
        #expect(await manager.settings.effectiveSpeedLimit == 2_000_000)
        #expect(await handler.handle(ControlRequest(.limit, speedLimit: 0)).speedLimit == nil)

        let queued = await handler.handle(ControlRequest(.add, entries: [LinkListEntry(url: server.url("small.bin"))], queue: "night"))
        #expect(queued.message == "Added 1 download to “night”.")
        let queues = await handler.handle(ControlRequest(.queues))
        #expect(queues.queues?.map(\.name) == ["Main", "Night"])
        #expect(queues.queues?.last?.waiting == 1)
        let started = await handler.handle(ControlRequest(.startQueue, targets: ["Night"]))
        #expect(started.message == "Started “Night”.")
        let queuedID = try #require(queued.ids?.first.flatMap(UUID.init(uuidString:)))
        try await eventually("queued download") { await manager.item(queuedID)?.record.status == .completed }

        let export = await handler.handle(ControlRequest(.export, format: .text))
        #expect(export.text?.split(separator: "\n").count == 3)

        let removed = await handler.handle(ControlRequest(.remove, targets: ["all"]))
        #expect(removed.ok)
        #expect(await manager.allItems.isEmpty)
    }

    @Test func endToEndOverTheSocket() async throws {
        let server = try TestServer()
        try server.addFile("e2e.bin", size: 120_000)
        let db = try FluxDatabase(url: try tempDir().appendingPathComponent("flux.sqlite"))
        try await db.save(FluxSettings(downloadDirectory: try tempDir()))
        let manager = try await DownloadManager(database: db, jobOptions: fastOptions, mediaTools: .none)
        await manager.start()
        let url = socketURL()
        let control = ControlServer(socketURL: url)
        let handler = ControlHandler(manager: manager)
        try control.start { await handler.handle($0) }
        defer { control.stop() }

        let request = ControlRequest(.add, entries: [LinkListEntry(url: server.url("e2e.bin"))])
        let response = try await Task.detached { try ControlClient.send(request, socketURL: url) }.value
        let id = try #require(response.ids?.first)
        try await eventually("download over the socket") {
            let status = try await Task.detached { try ControlClient.send(ControlRequest(.status, targets: [id]), socketURL: url) }.value
            return status.downloads?.first?.status == "completed"
        }
    }
}

extension PersistenceTests {
    @Test func queueMembershipIsSaved() async throws {
        let url = try tempDir().appendingPathComponent("flux.sqlite")
        let queue = UUID()
        var record = DownloadRecord(url: URL(string: "https://example.com/q.zip")!, directory: URL(fileURLWithPath: "/tmp"))
        record.queueID = queue
        do {
            let db = try FluxDatabase(url: url)
            try await db.save(record)
            #expect(try await db.schemaVersion() == 7)
        }
        let loaded = try await FluxDatabase(url: url).loadDownloads()
        #expect(loaded.first?.queueID == queue)
    }
}
