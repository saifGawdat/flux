import Foundation
import Testing
@testable import FluxCore

struct PersistenceTests {
    @Test func freshDatabaseIsMigratedToLatest() async throws {
        let db = try FluxDatabase(url: try tempDir().appendingPathComponent("flux.sqlite"))
        #expect(try await db.schemaVersion() == Schema.latestVersion)
        #expect(try await db.loadDownloads().isEmpty)
    }

    @Test func reopeningDoesNotReapplyMigrations() async throws {
        let url = try tempDir().appendingPathComponent("flux.sqlite")
        let record = DownloadRecord(url: URL(string: "https://example.com/a.zip")!, directory: URL(fileURLWithPath: "/tmp"))
        try await FluxDatabase(url: url).save(record)
        let reopened = try FluxDatabase(url: url)
        #expect(try await reopened.loadDownloads().map(\.id) == [record.id])
    }

    @Test func recordRoundTripsEveryField() async throws {
        let db = try FluxDatabase(url: try tempDir().appendingPathComponent("flux.sqlite"))
        var record = DownloadRecord(
            url: URL(string: "https://example.com/files/a%20b.zip?token=1")!,
            directory: URL(fileURLWithPath: "/tmp/dl", isDirectory: true),
            fileName: "custom.zip",
            maxConnections: 16,
            priority: .high,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000.5))
        record.totalBytes = 1000
        record.supportsRanges = true
        record.etag = "\"abc\""
        record.lastModified = "Wed, 21 Oct 2015 07:28:00 GMT"
        record.segments = [Segment(start: 0, end: 499, received: 120), Segment(start: 500, end: 999, received: 7)]
        record.status = .paused
        record.errorMessage = "oops"
        record.partFileName = "custom.zip.1234.fluxpart"
        record.finalPath = URL(fileURLWithPath: "/tmp/dl/custom.zip")
        record.completedAt = Date(timeIntervalSince1970: 1_700_000_100)
        record.thumbnailURL = URL(string: "https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg")

        try await db.save(record)
        try await db.save(record) // upsert, not duplicate
        let loaded = try await db.loadDownloads()
        #expect(loaded.count == 1)
        #expect(loaded.first == record)
    }

    @Test func deleteRemovesRows() async throws {
        let db = try FluxDatabase(url: try tempDir().appendingPathComponent("flux.sqlite"))
        let a = DownloadRecord(url: URL(string: "https://e.com/a")!, directory: URL(fileURLWithPath: "/tmp"))
        let b = DownloadRecord(url: URL(string: "https://e.com/b")!, directory: URL(fileURLWithPath: "/tmp"))
        try await db.save(a)
        try await db.save(b)
        try await db.deleteDownloads([a.id])
        #expect(try await db.loadDownloads().map(\.id) == [b.id])
    }

    @Test func settingsDefaultThenRoundTrip() async throws {
        let db = try FluxDatabase(url: try tempDir().appendingPathComponent("flux.sqlite"))
        #expect(try await db.loadSettings() == FluxSettings())
        let custom = FluxSettings(downloadDirectory: URL(fileURLWithPath: "/tmp/x"), maxConcurrentDownloads: 5,
                                  connectionsPerDownload: 4, resumeOnLaunch: false)
        try await db.save(custom)
        #expect(try await db.loadSettings() == custom)
    }

    @Test func settingsToleratesMissingKeysAndClampsValues() throws {
        let decoded = try JSONDecoder().decode(FluxSettings.self, from: Data(#"{"maxConcurrentDownloads": 99}"#.utf8))
        #expect(decoded.connectionsPerDownload == FluxSettings().connectionsPerDownload)
        #expect(decoded.normalized().maxConcurrentDownloads == FluxSettings.concurrentRange.upperBound)
    }

    @Test func migrationsApplyInOrderAndRefuseNewerSchemas() throws {
        let path = try tempDir().appendingPathComponent("m.sqlite").path
        let conn = try SQLiteConnection(path: path)
        let v1 = Migration(version: 1, name: "a", sql: "CREATE TABLE t (x INTEGER)")
        let v2 = Migration(version: 2, name: "b", sql: "ALTER TABLE t ADD COLUMN y TEXT")
        try Schema.migrate(conn, migrations: [v1])
        try conn.run("INSERT INTO t (x) VALUES (1)")
        try Schema.migrate(conn, migrations: [v1, v2])
        #expect(try conn.userVersion() == 2)
        #expect(try conn.query("SELECT x, y FROM t").first?.int64("x") == 1)

        #expect(throws: FluxError.databaseFromNewerVersion(found: 2, supported: 1)) {
            try Schema.migrate(conn, migrations: [v1])
        }
    }

    @Test func failedMigrationRollsBack() throws {
        let conn = try SQLiteConnection(path: try tempDir().appendingPathComponent("r.sqlite").path)
        let bad = Migration(version: 1, name: "bad", sql: "CREATE TABLE ok (x); THIS IS NOT SQL;")
        #expect(throws: SQLiteError.self) { try Schema.migrate(conn, migrations: [bad]) }
        #expect(try conn.userVersion() == 0)
        #expect(try conn.query("SELECT name FROM sqlite_master WHERE name = 'ok'").isEmpty)
    }
}
