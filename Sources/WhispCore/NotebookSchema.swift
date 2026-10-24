/// Shared SQLite schema. The local Python connector reads this raw SQL literal.
public enum NotebookSchema {
    public static let sql = #"""
PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS notes (
 id TEXT PRIMARY KEY, title TEXT NOT NULL, body TEXT NOT NULL, transcript TEXT NOT NULL,
 created_at REAL NOT NULL, updated_at REAL NOT NULL, audio_filename TEXT,
 duration REAL NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS memories (
 id TEXT PRIMARY KEY, content TEXT NOT NULL, kind TEXT NOT NULL DEFAULT 'context',
 evidence TEXT NOT NULL DEFAULT '', source_note_id TEXT REFERENCES notes(id) ON DELETE CASCADE,
 created_at REAL NOT NULL, updated_at REAL NOT NULL, enabled INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX IF NOT EXISTS notes_created ON notes(created_at DESC);
CREATE INDEX IF NOT EXISTS memories_source ON memories(source_note_id);
CREATE TABLE IF NOT EXISTS notebook_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS memory_tombstones (fingerprint TEXT PRIMARY KEY, created_at REAL NOT NULL);
PRAGMA user_version = 1;
"""#
}
