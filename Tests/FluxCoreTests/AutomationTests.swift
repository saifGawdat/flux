import Foundation
import Testing
@testable import FluxCore

private func finished(_ name: String, url: String = "https://www.example.com/files/x", size: Int64 = 1_000,
                      status: DownloadStatus = .completed, at date: Date = Date()) -> DownloadRecord {
    var r = DownloadRecord(url: URL(string: url)!, directory: URL(fileURLWithPath: "/tmp"), fileName: name)
    r.status = status
    r.totalBytes = size
    r.segments = [Segment(start: 0, end: size - 1, received: status == .completed ? size : 0)]
    r.completedAt = status == .completed ? date : nil
    r.createdAt = date
    return r
}

struct NamePatternTests {
    let date = today(14, 5)

    @Test func fillsTokensAndKeepsTheExtension() {
        var record = finished("Statement.pdf", url: "https://www.bank.example/statement")
        record.group = DownloadGroup(title: "Course", kind: .playlist)
        record.groupIndex = 2
        let ymd = date.formatted(.iso8601.year().month().day())
        #expect(NamePattern.apply("{date} {name}", to: "Statement.pdf", record: record, date: date) == "\(ymd) Statement.pdf")
        #expect(NamePattern.apply("{site}-{index} {playlist}", to: "a.pdf", record: record, date: date) == "bank.example-03 Course.pdf")
        #expect(NamePattern.apply("{time} {kind}", to: "a.pdf", record: record, date: date) == "14-05 Documents.pdf")
    }

    @Test func unknownTokensStayAndEmptyOnesCollapse() {
        let record = finished("a.zip")
        #expect(NamePattern.apply("{nope} {name}", to: "a.zip", record: record, date: date) == "{nope} a.zip")
        #expect(NamePattern.apply("{playlist} - {name} v2", to: "a.zip", record: record, date: date) == "a v2.zip")
    }

    @Test func nothingUsableOrNoChangeMeansNoRename() {
        let record = finished("a.zip")
        #expect(NamePattern.apply("{playlist}", to: "a.zip", record: record, date: date) == nil)
        #expect(NamePattern.apply("{name}", to: "a.zip", record: record, date: date) == nil)
        #expect(NamePattern.apply("../../{name}", to: "a.zip", record: record, date: date) == "-..-a.zip", "no path separators")
    }
}

struct RuleActionTests {
    @Test func olderRulesDecodeWithoutActionsAndStillMove() throws {
        let json = #"{"id":"6C2F7E1C-2C11-4D5D-9C8E-1F2A3B4C5D6E","name":"PDFs","isEnabled":true,"conditions":[{"fileExtension":{"_0":["pdf"]}}],"folder":"file:///tmp/PDFs/"}"#
        let rule = try JSONDecoder().decode(DownloadRule.self, from: Data(json.utf8))
        #expect(rule.movesFile)
        #expect(rule.actions == .none)
        #expect(rule.actions.isEmpty)
    }

    @Test func aRuleCanActWithoutMoving() {
        let rule = DownloadRule(name: "Notify", conditions: [.fileExtension(["pdf"])], folder: URL(fileURLWithPath: "/tmp/x"),
                                movesFile: false, actions: RuleActions(notify: true))
        var settings = FluxSettings(downloadDirectory: URL(fileURLWithPath: "/tmp"), sortIntoCategoryFolders: true)
        settings.rules = [rule]
        let record = finished("paper.pdf")
        #expect(Filing.rule(for: record, settings: settings)?.id == rule.id)
        #expect(Filing.destination(for: record, settings: settings) == nil, "first match wins, and it stays")
        #expect(rule.actions.summary { _ in nil } == ["notify"])
        #expect(!rule.actions.isEmpty)
    }
}

struct CommandTests {
    @Test func approvalCoversExactlyTheApprovedText() {
        var command = AutomationCommand(name: "Copy", script: "cp \"$1\" /tmp/")
        #expect(!command.isApproved)
        command.approve()
        #expect(command.isApproved)
        command.script += " # changed"
        #expect(!command.isApproved)
    }

    @Test func theFileIsAnArgumentNotScriptText() async throws {
        let folder = try tempDir()
        let file = folder.appendingPathComponent("a \"quoted\" $(touch pwned) name.txt")
        try Data("hello".utf8).write(to: file)
        var command = AutomationCommand(name: "Show", script: #"printf '%s|%s|%s\n' "$1" "$FLUX_NAME" "$(cat "$1")""#)
        command.approve()
        let output = try await CommandRunner.run(command, file: file, record: finished(file.lastPathComponent))
        #expect(output == "\(file.path)|\(file.lastPathComponent)|hello")
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("pwned").path))
        #expect(!FileManager.default.fileExists(atPath: FileManager.default.currentDirectoryPath + "/pwned"))
    }

    @Test func failuresAndUnapprovedCommandsAreReported() async throws {
        let file = try tempDir().appendingPathComponent("f.txt")
        try Data().write(to: file)
        var failing = AutomationCommand(name: "Fail", script: "echo nope >&2; exit 3")
        failing.approve()
        await #expect(throws: CommandRunner.Failure.failed("Fail", status: 3, output: "nope")) {
            try await CommandRunner.run(failing, file: file, record: finished("f.txt"))
        }
        let marker = file.deletingLastPathComponent().appendingPathComponent("ran")
        let unapproved = AutomationCommand(name: "Sneaky", script: "touch \"\(marker.path)\"")
        await #expect(throws: CommandRunner.Failure.notApproved("Sneaky")) {
            try await CommandRunner.run(unapproved, file: file, record: finished("f.txt"))
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func slowCommandsAreStopped() async throws {
        let file = try tempDir().appendingPathComponent("f.txt")
        try Data().write(to: file)
        var slow = AutomationCommand(name: "Slow", script: "sleep 30")
        slow.approve()
        let started = Date()
        await #expect(throws: CommandRunner.Failure.timedOut("Slow")) {
            try await CommandRunner.run(slow, file: file, record: finished("f.txt"), timeout: .milliseconds(300))
        }
        #expect(Date().timeIntervalSince(started) < 10)
    }
}

struct TrafficTests {
    @Test func countsOnlyBytesReceivedWhileWatching() {
        var meter = TrafficMeter()
        var a = finished("a.iso", url: "https://www.mirror.example/a.iso", size: 1_000, status: .downloading)
        a.segments = [Segment(start: 0, end: 999, received: 400)]
        let t = today(10, 0, second: 5)
        meter.observe(a, at: t) // baseline: 400 bytes from before
        a.segments[0].received = 700
        meter.observe(a, at: t.addingTimeInterval(10))
        a.segments[0].received = 1_000
        meter.observe(a, at: t.addingTimeInterval(60)) // next minute
        #expect(meter.drain() == [
            TrafficSample(date: t, host: "mirror.example", bytes: 300),
            TrafficSample(date: t.addingTimeInterval(60), host: "mirror.example", bytes: 300),
        ])
        #expect(meter.drain().isEmpty)

        a.segments[0].received = 100 // started over: new baseline, nothing counted
        meter.observe(a, at: t.addingTimeInterval(70))
        a.segments[0].received = 150
        meter.observe(a, at: t.addingTimeInterval(80))
        #expect(meter.drain().map(\.bytes) == [50])
    }

    @Test func pagesCountForTheSiteTheyCameFrom() {
        var r = finished("img.jpg", url: "https://cdn.example.net/img.jpg")
        r.referer = URL(string: "https://www.gallery.example/page")
        #expect(TrafficMeter.site(of: r) == "gallery.example")
    }
}

struct StatisticsTests {
    @Test func barsTotalsSitesAndKinds() {
        let now = today(15, 30)
        let traffic = [
            TrafficSample(date: today(9, 0), host: "a.example", bytes: 6_000),
            TrafficSample(date: today(9, 1), host: "a.example", bytes: 1_200),
            TrafficSample(date: today(14, 0), host: "b.example", bytes: 600),
            TrafficSample(date: today(12, 0, dayOffset: -3), host: "a.example", bytes: 5_000), // outside a day
        ]
        let records = [
            finished("a.pdf", url: "https://a.example/a.pdf", size: 7_000, at: today(9, 2)),
            finished("b.mp4", url: "https://b.example/b.mp4", size: 600, at: today(14, 1)),
            finished("c.zip", url: "https://b.example/c.zip", status: .failed, at: today(13, 0)),
            finished("old.zip", url: "https://a.example/old.zip", at: today(12, 0, dayOffset: -3)),
        ]
        let day = Statistics(period: .day, records: records, traffic: traffic, now: now)
        #expect(day.bars.count == 24)
        #expect(day.bars.last?.start == today(15))
        #expect(day.bars.first { $0.start == today(9) }?.bytes == 7_200)
        #expect(day.totalBytes == 7_800)
        #expect(day.peakSpeed == 100) // 6,000 bytes in one minute
        #expect(day.finished == 2)
        #expect(day.failed == 1)
        #expect(day.successRate == 2.0 / 3.0)
        #expect(day.sites.map(\.host) == ["a.example", "b.example"])
        #expect(day.sites.last?.failed == 1)
        #expect(day.kinds.map(\.category) == [.documents, .videos])

        let week = Statistics(period: .week, records: records, traffic: traffic, now: now)
        #expect(week.bars.count == 7)
        #expect(week.totalBytes == 12_800)
        #expect(week.finished == 3)
    }

    @Test func emptyMeansZeroesNotNothing() {
        let stats = Statistics(period: .month, records: [], traffic: [])
        #expect(stats.bars.count == 30)
        #expect(stats.bars.allSatisfy { $0.bytes == 0 })
        #expect(stats.successRate == nil)
        #expect(stats.sites.isEmpty)
    }
}

struct TrafficPersistenceTests {
    @Test func samplesAddUpAndOldOnesArePruned() async throws {
        let db = try FluxDatabase(url: try tempDir().appendingPathComponent("flux.sqlite"))
        #expect(try await db.schemaVersion() == 8)
        let t = today(10)
        try await db.addTraffic([TrafficSample(date: t, host: "a", bytes: 10)])
        try await db.addTraffic([TrafficSample(date: t, host: "a", bytes: 5), TrafficSample(date: t, host: "b", bytes: 1),
                                 TrafficSample(date: t.addingTimeInterval(-86_400 * 100), host: "a", bytes: 99)])
        #expect(try await db.traffic(since: t.addingTimeInterval(-60)).map(\.bytes) == [15, 1])
        try await db.pruneTraffic(before: t.addingTimeInterval(-86_400 * 90))
        #expect(try await db.traffic(since: .distantPast).count == 2)
    }

    @Test func automationNotesAreSaved() async throws {
        let db = try FluxDatabase(url: try tempDir().appendingPathComponent("flux.sqlite"))
        var record = finished("a.zip")
        record.automationNote = "Ran “Upload”: done"
        try await db.save(record)
        #expect(try await db.loadDownloads().first?.automationNote == "Ran “Upload”: done")
    }
}

struct AutomationManagerTests {
    @Test func aRuleRenamesRunsItsCommandAndAsksTheApp() async throws {
        let server = try TestServer()
        try server.addFile("scan.pdf", size: 20_000)
        let downloads = try tempDir()
        let db = try FluxDatabase(url: try tempDir().appendingPathComponent("flux.sqlite"))
        let log = try tempDir().appendingPathComponent("ran.txt")
        var command = AutomationCommand(name: "Log", script: "printf '%s' \"$FLUX_NAME\" > \"\(log.path)\"; echo logged")
        command.approve()
        var settings = FluxSettings(downloadDirectory: downloads)
        settings.commands = [command]
        settings.rules = [DownloadRule(
            name: "Scans", conditions: [.fileExtension(["pdf"])], folder: downloads, movesFile: false,
            actions: RuleActions(rename: "Scan {name}", computeChecksum: true, command: command.id, notify: true, reveal: true))]
        try await db.save(settings)
        let manager = try await DownloadManager(database: db, jobOptions: fastOptions, mediaTools: .none)
        let events = await manager.events()
        let requests = Task { () -> [DownloadManager.AutomationRequest] in
            var seen: [DownloadManager.AutomationRequest] = []
            for await event in events {
                if case .automation(_, let request) = event { seen.append(request) }
                if seen.count == 2 { break }
            }
            return seen
        }
        await manager.start()
        let id = try #require(try await manager.add([.init(url: server.url("scan.pdf"))]).first)
        try await eventually("rule to finish", timeout: 30) {
            let finishing = await manager.isFinishing(id)
            return await manager.item(id)?.record.automationNote != nil && !finishing
        }
        let done = try #require(await manager.item(id)?.record)
        #expect(done.fileName == "Scan scan.pdf")
        #expect(done.finalPath == downloads.appendingPathComponent("Scan scan.pdf"))
        #expect(done.contentHash == (try sha256(of: done.finalPath)))
        #expect(done.automationNote == "Ran “Log”: logged")
        #expect(try String(contentsOf: log, encoding: .utf8) == "Scan scan.pdf")
        #expect(await requests.value == [.notify(rule: "Scans"), .reveal])

        let stats = await manager.statistics(.day)
        #expect(stats.finished == 1)
        #expect(stats.sites.first?.host == "127.0.0.1")
        #expect(stats.totalBytes == 20_000)
        await manager.shutdown()
    }
}
