import Foundation

struct Migration: Sendable {
    let version: Int
    let name: String
    let sql: String
}

/// Ordered schema migrations keyed by `PRAGMA user_version`. Append only: never edit a
/// migration that has shipped; add a new one instead.
enum Schema {
    static let migrations: [Migration] = [
        Migration(version: 1, name: "downloads and settings", sql: """
            CREATE TABLE downloads (
                id              TEXT PRIMARY KEY NOT NULL,
                url             TEXT NOT NULL,
                file_name       TEXT NOT NULL,
                user_named_file INTEGER NOT NULL DEFAULT 0,
                directory       TEXT NOT NULL,
                total_bytes     INTEGER,
                received_bytes  INTEGER NOT NULL DEFAULT 0,
                supports_ranges INTEGER NOT NULL DEFAULT 0,
                etag            TEXT,
                last_modified   TEXT,
                segments        TEXT NOT NULL DEFAULT '[]',
                status          TEXT NOT NULL,
                error_message   TEXT,
                priority        INTEGER NOT NULL DEFAULT 0,
                max_connections INTEGER NOT NULL DEFAULT 8,
                part_file_name  TEXT,
                final_path      TEXT,
                created_at      REAL NOT NULL,
                completed_at    REAL
            );
            CREATE INDEX downloads_status ON downloads(status);
            CREATE INDEX downloads_created_at ON downloads(created_at);

            CREATE TABLE settings (
                key   TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            );
            """),
        Migration(version: 2, name: "media downloads", sql: """
            ALTER TABLE downloads ADD COLUMN kind TEXT NOT NULL DEFAULT 'file';
            ALTER TABLE downloads ADD COLUMN media_format TEXT;
            ALTER TABLE downloads ADD COLUMN title TEXT;
            """),
    ]

    static var latestVersion: Int { migrations.last?.version ?? 0 }

    static func migrate(_ db: SQLiteConnection, migrations: [Migration] = Schema.migrations) throws {
        let current = try db.userVersion()
        let latest = migrations.last?.version ?? 0
        guard current <= latest else {
            throw FluxError.databaseFromNewerVersion(found: current, supported: latest)
        }
        for migration in migrations where migration.version > current {
            try db.transaction {
                try db.execute(migration.sql)
                try db.setUserVersion(migration.version)
            }
            Log.persistence.info("Applied migration \(migration.version): \(migration.name, privacy: .public)")
        }
    }
}
