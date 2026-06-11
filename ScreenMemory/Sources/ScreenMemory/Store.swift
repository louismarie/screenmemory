import Foundation
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct Hit { let ts: Double; let text: String; let score: Float }
struct Row { let id: Int; let ts: Double; let text: String }

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

    /// Top-k by cosine similarity (query vector assumed L2-normalized, as ours is).
    func search(_ q: [Float], k: Int) -> [Hit] {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT ts,enc,vec FROM memories", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        var hits = [Hit]()
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts = sqlite3_column_double(stmt, 0)
            let encBytes = sqlite3_column_blob(stmt, 1)
            let encN = Int(sqlite3_column_bytes(stmt, 1))
            let enc = encBytes != nil ? Data(bytes: encBytes!, count: encN) : Data()
            let text = crypto.decrypt(enc)
            let bytes = sqlite3_column_blob(stmt, 2)
            let n = Int(sqlite3_column_bytes(stmt, 2)) / MemoryLayout<Float>.size
            var vec = [Float](repeating: 0, count: n)
            if let bytes { memcpy(&vec, bytes, n * MemoryLayout<Float>.size) }
            hits.append(Hit(ts: ts, text: text, score: cosine(q, vec)))
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(k))
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return -1 }
        var dot: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i] }
        return dot   // both sides L2-normalized -> dot == cosine
    }

    @discardableResult private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }
    enum Err: Error { case open }
}
