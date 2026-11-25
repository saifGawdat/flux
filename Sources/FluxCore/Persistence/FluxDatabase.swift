import Foundation

/// Local SQLite store for downloads and settings.
public actor FluxDatabase {
    private let connection: SQLiteConnection
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Opens (creating if needed) and migrates the database at `url`.
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        connection = try SQLiteConnection(path: url.path)
        try Schema.migrate(connection)
    }

    /// The default location: `~/Library/Application Support/Flux/flux.sqlite`.
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flux", isDirectory: true)
            .appendingPathComponent("flux.sqlite")
    }

    public func schemaVersion() throws -> Int { try connection.userVersion() }

    // MARK: Downloads

    public func loadDownloads() throws -> [DownloadRecord] {
        try connection.query("SELECT * FROM downloads ORDER BY created_at").compactMap { row in
            do {
                return try record(from: row)
            } catch {
                Log.persistence.error("Skipping unreadable download row: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
    }

    public func save(_ record: DownloadRecord) throws {
        let segments = String(decoding: try encoder.encode(record.segments), as: UTF8.self)
        try connection.run("""
            INSERT INTO downloads (
                id, url, file_name, user_named_file, directory, total_bytes, received_bytes,
                supports_ranges, etag, last_modified, segments, status, error_message, priority,
                max_connections, part_file_name, final_path, created_at, completed_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                url = excluded.url, file_name = excluded.file_name,
                user_named_file = excluded.user_named_file, directory = excluded.directory,
                total_bytes = excluded.total_bytes, received_bytes = excluded.received_bytes,
                supports_ranges = excluded.supports_ranges, etag = excluded.etag,
                last_modified = excluded.last_modified, segments = excluded.segments,
                status = excluded.status, error_message = excluded.error_message,
                priority = excluded.priority, max_connections = excluded.max_connections,
                part_file_name = excluded.part_file_name, final_path = excluded.final_path,
                completed_at = excluded.completed_at
            """, [
                .text(record.id.uuidString),
                .text(record.url.absoluteString),
                .text(record.fileName),
                .bool(record.userNamedFile),
                .text(record.directory.path),
                .integer(record.totalBytes),
                .integer(record.receivedBytes),
                .bool(record.supportsRanges),
                .text(record.etag),
                .text(record.lastModified),
                .text(segments),
                .text(record.status.rawValue),
                .text(record.errorMessage),
                .integer(Int64(record.priority.rawValue)),
                .integer(Int64(record.maxConnections)),
                .text(record.partFileName),
                .text(record.finalPath?.path),
                .real(record.createdAt.timeIntervalSince1970),
                .real(record.completedAt?.timeIntervalSince1970),
            ])
    }

    public func deleteDownloads(_ ids: [UUID]) throws {
        try connection.transaction {
            for id in ids {
                try connection.run("DELETE FROM downloads WHERE id = ?", [.text(id.uuidString)])
            }
        }
    }

    // MARK: Settings

    private static let settingsKey = "app"

    public func loadSettings() throws -> FluxSettings {
        guard let json = try connection.query("SELECT value FROM settings WHERE key = ?", [.text(Self.settingsKey)])
            .first?.string("value")
        else { return FluxSettings() }
        do {
            return try decoder.decode(FluxSettings.self, from: Data(json.utf8)).normalized()
        } catch {
            Log.persistence.error("Settings unreadable, using defaults: \(String(describing: error), privacy: .public)")
            return FluxSettings()
        }
    }

    public func save(_ settings: FluxSettings) throws {
        let json = String(decoding: try encoder.encode(settings), as: UTF8.self)
        try connection.run(
            "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [.text(Self.settingsKey), .text(json)])
    }

    // MARK: Mapping

    private struct CorruptRow: Error, CustomStringConvertible {
        let description: String
    }

    private func record(from row: SQLiteRow) throws -> DownloadRecord {
        guard let idText = row.string("id"), let id = UUID(uuidString: idText),
              let urlText = row.string("url"), let url = URL(string: urlText),
              let fileName = row.string("file_name"),
              let directory = row.string("directory"),
              let statusText = row.string("status"), let status = DownloadStatus(rawValue: statusText),
              let created = row.double("created_at")
        else { throw CorruptRow(description: "missing required column in \(row.string("id") ?? "?")") }

        var record = DownloadRecord(
            id: id,
            url: url,
            directory: URL(fileURLWithPath: directory, isDirectory: true),
            maxConnections: Int(row.int64("max_connections") ?? 8),
            priority: DownloadPriority(rawValue: Int(row.int64("priority") ?? 0)) ?? .normal,
            createdAt: Date(timeIntervalSince1970: created))
        record.fileName = fileName
        record.userNamedFile = row.bool("user_named_file")
        record.totalBytes = row.int64("total_bytes")
        record.supportsRanges = row.bool("supports_ranges")
        record.etag = row.string("etag")
        record.lastModified = row.string("last_modified")
        record.segments = try decoder.decode([Segment].self, from: Data((row.string("segments") ?? "[]").utf8))
        record.status = status
        record.errorMessage = row.string("error_message")
        record.partFileName = row.string("part_file_name")
        record.finalPath = row.string("final_path").map { URL(fileURLWithPath: $0) }
        record.completedAt = row.double("completed_at").map { Date(timeIntervalSince1970: $0) }
        return record
    }
}
