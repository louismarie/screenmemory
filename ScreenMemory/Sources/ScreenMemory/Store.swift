import Foundation
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct Hit { let ts: Double; let text: String; let score: Float; let app: String; let title: String; let memId: Int }
struct Row { let id: Int; let ts: Double; let text: String }

/// One decrypted retrieval unit (layout-aware block of a captured screen).
struct Chunk {
    let id: Int
    let memId: Int
    let ts: Double
    let app: String
    let title: String
    let text: String
    let vec: [Float]
}

/// SQLite-backed embedding store. Vectors are stored as raw Float32 BLOBs;
/// search is brute-force cosine top-k (fine for a single machine's screen history).
final class Store {
    private var db: OpaquePointer?
    private let crypto = Crypto()

    init(path: String) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw Err.open }
        // WAL + busy_timeout: the always-on capture daemon writes while `query` reads.
        // Without this, the writer blocks readers and concurrent access deadlocks.
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA busy_timeout=5000;")
        exec("""
            CREATE TABLE IF NOT EXISTS memories(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts REAL NOT NULL,
                enc BLOB NOT NULL,
                vec BLOB NOT NULL
            );
        """)
        // Retrieval units: several per screen. enc = AES-GCM(JSON{t,a,w}) so text AND
        // app/window metadata stay encrypted at rest; ts stays plain for SQL time filters.
        exec("""
            CREATE TABLE IF NOT EXISTS chunks(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                mem_id INTEGER NOT NULL,
                ts REAL NOT NULL,
                enc BLOB NOT NULL,
                vec BLOB NOT NULL
            );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_chunks_ts ON chunks(ts);")
        exec("CREATE INDEX IF NOT EXISTS idx_chunks_mem ON chunks(mem_id);")
    }
    deinit { sqlite3_close(db) }

    func insert(ts: Double, text: String, vec: [Float]) {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO memories(ts,enc,vec) VALUES(?,?,?)", -1, &stmt, nil)
        sqlite3_bind_double(stmt, 1, ts)
        let enc = crypto.encrypt(text)                       // AES-GCM ciphertext at rest
        enc.withUnsafeBytes { raw in
            _ = sqlite3_bind_blob(stmt, 2, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
        }
        vec.withUnsafeBytes { raw in
            _ = sqlite3_bind_blob(stmt, 3, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
        }
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func count() -> Int {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM memories", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    func insertChunk(memId: Int, ts: Double, app: String, title: String, text: String, vec: [Float]) {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO chunks(mem_id,ts,enc,vec) VALUES(?,?,?,?)", -1, &stmt, nil)
        sqlite3_bind_int64(stmt, 1, Int64(memId))
        sqlite3_bind_double(stmt, 2, ts)
        let payload = (try? JSONEncoder().encode(["t": text, "a": app, "w": title])) ?? Data()
        let enc = crypto.encrypt(String(data: payload, encoding: .utf8) ?? "")
        enc.withUnsafeBytes { raw in
            _ = sqlite3_bind_blob(stmt, 3, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
        }
        vec.withUnsafeBytes { raw in
            _ = sqlite3_bind_blob(stmt, 4, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
        }
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    var lastInsertedId: Int { Int(sqlite3_last_insert_rowid(db)) }

    func chunkCount() -> Int {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM chunks", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    /// All chunks decrypted, optionally restricted to a time range (SQL-side).
    /// Brute-force is fine at current volume; sqlite-vec is the planned escape hatch.
    func allChunks(from: Double? = nil, to: Double? = nil) -> [Chunk] {
        var sql = "SELECT id,mem_id,ts,enc,vec FROM chunks"
        if from != nil || to != nil { sql += " WHERE ts >= ? AND ts <= ?" }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if from != nil || to != nil {
            sqlite3_bind_double(stmt, 1, from ?? 0)
            sqlite3_bind_double(stmt, 2, to ?? Date().timeIntervalSince1970 + 86400)
        }
        defer { sqlite3_finalize(stmt) }
        var out = [Chunk]()
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Int(sqlite3_column_int64(stmt, 0))
            let memId = Int(sqlite3_column_int64(stmt, 1))
            let ts = sqlite3_column_double(stmt, 2)
            let encBytes = sqlite3_column_blob(stmt, 3)
            let encN = Int(sqlite3_column_bytes(stmt, 3))
            let enc = encBytes != nil ? Data(bytes: encBytes!, count: encN) : Data()
            let json = crypto.decrypt(enc)
            var text = json, app = "", title = ""
            if let data = json.data(using: .utf8),
               let dict = try? JSONDecoder().decode([String: String].self, from: data) {
                text = dict["t"] ?? ""
                app = dict["a"] ?? ""
                title = dict["w"] ?? ""
            }
            let bytes = sqlite3_column_blob(stmt, 4)
            let n = Int(sqlite3_column_bytes(stmt, 4)) / MemoryLayout<Float>.size
            var vec = [Float](repeating: 0, count: n)
            if let bytes { memcpy(&vec, bytes, n * MemoryLayout<Float>.size) }
            out.append(Chunk(id: id, memId: memId, ts: ts, app: app, title: title, text: text, vec: vec))
        }
        return out
    }

    /// Local-calendar days that have captured chunks, newest first, with counts.
    /// Lets the dashboard default to the most recent day that actually has data.
    func dayCounts() -> [(day: String, count: Int)] {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT date(ts,'unixepoch','localtime') d, COUNT(*) FROM chunks GROUP BY d ORDER BY d DESC", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        var out = [(String, Int)]()
        while sqlite3_step(stmt) == SQLITE_ROW {
            let day = String(cString: sqlite3_column_text(stmt, 0))
            out.append((day, Int(sqlite3_column_int(stmt, 1))))
        }
        return out
    }

    /// Memory ids that have no chunks yet (reindex backlog).
    func unchunkedMemoryIds() -> [Int] {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT id FROM memories WHERE id NOT IN (SELECT DISTINCT mem_id FROM chunks) ORDER BY id", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        var ids = [Int]()
        while sqlite3_step(stmt) == SQLITE_ROW { ids.append(Int(sqlite3_column_int64(stmt, 0))) }
        return ids
    }

    /// One memory row decrypted (nil if missing).
    func memory(id: Int) -> Row? {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT id,ts,enc FROM memories WHERE id = ?", -1, &stmt, nil)
        sqlite3_bind_int64(stmt, 1, Int64(id))
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let ts = sqlite3_column_double(stmt, 1)
        let encBytes = sqlite3_column_blob(stmt, 2)
        let encN = Int(sqlite3_column_bytes(stmt, 2))
        let enc = encBytes != nil ? Data(bytes: encBytes!, count: encN) : Data()
        return Row(id: id, ts: ts, text: crypto.decrypt(enc))
    }

    /// Most recent memories, decrypted (for the browse UI).
    func list(limit: Int, offset: Int) -> [Row] {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT id,ts,enc FROM memories ORDER BY id DESC LIMIT ? OFFSET ?", -1, &stmt, nil)
        sqlite3_bind_int(stmt, 1, Int32(limit))
        sqlite3_bind_int(stmt, 2, Int32(offset))
        defer { sqlite3_finalize(stmt) }
        var rows = [Row]()
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Int(sqlite3_column_int64(stmt, 0))
            let ts = sqlite3_column_double(stmt, 1)
            let encBytes = sqlite3_column_blob(stmt, 2)
            let encN = Int(sqlite3_column_bytes(stmt, 2))
            let enc = encBytes != nil ? Data(bytes: encBytes!, count: encN) : Data()
            rows.append(Row(id: id, ts: ts, text: crypto.decrypt(enc)))
        }
        return rows
    }

    /// Retention support: counts/deletes raw rows older than a cutoff.
    /// Recap markdowns act as the permanent summary layer (RAPTOR-lite).
    func countOlderThan(ts: Double) -> (memories: Int, chunks: Int) {
        func count(_ sql: String) -> Int {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            sqlite3_bind_double(stmt, 1, ts)
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
        }
        return (count("SELECT COUNT(*) FROM memories WHERE ts < ?"),
                count("SELECT COUNT(*) FROM chunks WHERE ts < ?"))
    }

    func deleteOlderThan(ts: Double) {
        for sql in ["DELETE FROM chunks WHERE ts < ?", "DELETE FROM memories WHERE ts < ?"] {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            sqlite3_bind_double(stmt, 1, ts)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        exec("VACUUM;")
    }

    @discardableResult private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }
    enum Err: Error { case open }
}
