import Foundation

/// Ordered schema migrations, tracked with `PRAGMA user_version`.
enum Migrations {
    static let all: [(version: Int, sql: String)] = [
        (1, """
        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS sessions (
            session_key TEXT PRIMARY KEY,
            provider TEXT NOT NULL,
            session_id TEXT NOT NULL,
            project_path TEXT,
            title TEXT,
            state TEXT NOT NULL,
            lifecycle TEXT NOT NULL,
            started_at REAL,
            first_seen_at REAL NOT NULL,
            last_event_at REAL NOT NULL,
            ended_at REAL,
            event_count INTEGER NOT NULL,
            snapshot TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS sessions_last_event ON sessions(last_event_at);
        CREATE INDEX IF NOT EXISTS sessions_project ON sessions(project_path);
        CREATE TABLE IF NOT EXISTS events (
            id TEXT PRIMARY KEY,
            session_key TEXT NOT NULL,
            provider TEXT NOT NULL,
            kind TEXT NOT NULL,
            occurred_at REAL NOT NULL,
            received_at REAL NOT NULL,
            order_wall INTEGER NOT NULL,
            order_mono INTEGER,
            boot TEXT,
            collection TEXT NOT NULL,
            confidence TEXT NOT NULL,
            project_path TEXT,
            payload TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS events_session_time ON events(session_key, occurred_at);
        CREATE INDEX IF NOT EXISTS events_time ON events(occurred_at);
        CREATE INDEX IF NOT EXISTS events_kind ON events(kind);
        """),
    ]

    static var latestVersion: Int { all.last?.version ?? 0 }

    static func migrate(_ database: SQLiteDatabase) throws {
        let current = database.userVersion
        for migration in all where migration.version > current {
            try database.transaction {
                try database.execute(migration.sql)
                try database.setUserVersion(migration.version)
            }
        }
    }
}
