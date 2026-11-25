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
        let mirrors = String(decoding: try encoder.encode(record.mirrors.map(\.absoluteString)), as: UTF8.self)
        try connection.run("""
            INSERT INTO downloads (
                id, url, file_name, user_named_file, directory, total_bytes, received_bytes,
                supports_ranges, etag, last_modified, segments, status, error_message, priority,
                max_connections, part_file_name, final_path, created_at, completed_at,
                kind, media_format, title, thumbnail_url,
                group_id, group_title, group_kind, group_index, referer,
                mirrors, speed_limit, checksum, checksum_verified, size_verified,
                auto_file, filed_by, content_hash, duplicate_of, extracted_path, extraction_error, archived
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                      ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                url = excluded.url, file_name = excluded.file_name,
                user_named_file = excluded.user_named_file, directory = excluded.directory,
                total_bytes = excluded.total_bytes, received_bytes = excluded.received_bytes,
                supports_ranges = excluded.supports_ranges, etag = excluded.etag,
                last_modified = excluded.last_modified, segments = excluded.segments,
                status = excluded.status, error_message = excluded.error_message,
                priority = excluded.priority, max_connections = excluded.max_connections,
                part_file_name = excluded.part_file_name, final_path = excluded.final_path,
                completed_at = excluded.completed_at, kind = excluded.kind,
                media_format = excluded.media_format, title = excluded.title,
                thumbnail_url = excluded.thumbnail_url,
                group_id = excluded.group_id, group_title = excluded.group_title,
                group_kind = excluded.group_kind, group_index = excluded.group_index,
                referer = excluded.referer,
                mirrors = excluded.mirrors, speed_limit = excluded.speed_limit,
                checksum = excluded.checksum, checksum_verified = excluded.checksum_verified,
                size_verified = excluded.size_verified,
                auto_file = excluded.auto_file, filed_by = excluded.filed_by,
                content_hash = excluded.content_hash, duplicate_of = excluded.duplicate_of,
                extracted_path = excluded.extracted_path, extraction_error = excluded.extraction_error,
                archived = excluded.archived
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
                .text(record.kind.rawValue),
                .text(record.mediaFormat?.rawValue),
                .text(record.title),
                .text(record.thumbnailURL?.absoluteString),
                .text(record.group?.id.uuidString),
                .text(record.group?.title),
                .text(record.group?.kind.rawValue),
                .integer(Int64(record.groupIndex)),
                .text(record.referer?.absoluteString),
                .text(mirrors),
                .integer(record.speedLimit),
                .text(record.checksum?.description),
                .bool(record.checksumVerified),
                .bool(record.sizeVerified),
                .bool(record.autoFile),
                .text(record.filedBy),
                .text(record.contentHash),
                .text(record.duplicateOf?.path),
                .text(record.extractedPath?.path),
                .text(record.extractionError),
                .bool(record.isArchived),
            ])
    }

    /// Saves many records in one transaction (adding a whole playlist).
    public func save(_ records: [DownloadRecord]) throws {
        try connection.transaction {
            for record in records { try save(record) }
        }
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
        record.kind = row.string("kind").flatMap(DownloadKind.init(rawValue:)) ?? .file
        record.mediaFormat = row.string("media_format").flatMap(MediaFormat.init(rawValue:))
        record.title = row.string("title")
        record.thumbnailURL = row.string("thumbnail_url").flatMap(Thumbnails.remote)
        if let groupID = row.string("group_id").flatMap(UUID.init(uuidString:)) {
            record.group = DownloadGroup(
                id: groupID,
                title: row.string("group_title") ?? "",
                kind: row.string("group_kind").flatMap(DownloadGroup.Kind.init(rawValue:)) ?? .playlist)
        }
        record.groupIndex = Int(row.int64("group_index") ?? 0)
        record.referer = row.string("referer").flatMap(Thumbnails.remote)
        let mirrors = (try? decoder.decode([String].self, from: Data((row.string("mirrors") ?? "[]").utf8))) ?? []
        record.mirrors = mirrors.compactMap(Thumbnails.remote)
        record.speedLimit = row.int64("speed_limit").flatMap { $0 > 0 ? $0 : nil }
        record.checksum = row.string("checksum").flatMap(Checksum.parse)
        record.checksumVerified = row.bool("checksum_verified")
        record.sizeVerified = row.bool("size_verified")
        record.autoFile = row.bool("auto_file")
        record.filedBy = row.string("filed_by")
        record.contentHash = row.string("content_hash")
        record.duplicateOf = row.string("duplicate_of").map { URL(fileURLWithPath: $0) }
        record.extractedPath = row.string("extracted_path").map { URL(fileURLWithPath: $0) }
        record.extractionError = row.string("extraction_error")
        record.isArchived = row.bool("archived")
        return record
    }
}
