import Foundation
import SQLite3

/// Per-vault SQLite sidecar at `<vault>/.nexus/index.sqlite`.
/// Stores note metadata, FTS5 body index, and graph node positions for fast cold start / search.
final class VaultIndexStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.ghost64.nexus.vault-index", qos: .userInitiated)
    private(set) var vaultRoot: URL?

    deinit { close() }

    // MARK: - Lifecycle

    func open(vaultRoot: URL) throws {
        close()
        self.vaultRoot = vaultRoot
        let dir = vaultRoot.appendingPathComponent(".nexus", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("index.sqlite").path
        var handle: OpaquePointer?
        if sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            throw IndexError.openFailed(String(cString: sqlite3_errmsg(handle)))
        }
        db = handle
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=NORMAL;")
        try migrate()
    }

    func close() {
        queue.sync {
            if let db {
                sqlite3_close(db)
            }
            self.db = nil
            self.vaultRoot = nil
        }
    }

    // MARK: - Notes / FTS

    struct NoteRow: Sendable {
        var path: String
        var title: String
        var folder: String
        var tags: String
        var modified: Double
        var content: String
    }

    func upsertNote(path: String, title: String, folder: String, tags: [String], modified: Date, content: String) {
        let tagsCSV = tags.joined(separator: ",")
        let mod = modified.timeIntervalSince1970
        queue.sync {
            guard let db else { return }
            let sql = """
            INSERT INTO notes(path, title, folder, tags, modified, content)
            VALUES(?,?,?,?,?,?)
            ON CONFLICT(path) DO UPDATE SET
              title=excluded.title,
              folder=excluded.folder,
              tags=excluded.tags,
              modified=excluded.modified,
              content=excluded.content;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, path)
            bindText(stmt, 2, title)
            bindText(stmt, 3, folder)
            bindText(stmt, 4, tagsCSV)
            sqlite3_bind_double(stmt, 5, mod)
            bindText(stmt, 6, content)
            _ = sqlite3_step(stmt)

            // Rebuild FTS row (delete + insert keeps content in sync)
            execLocked("DELETE FROM notes_fts WHERE path = \(sqlLiteral(path));")
            let ftsSQL = "INSERT INTO notes_fts(path, title, tags, body) VALUES(?,?,?,?);"
            var fts: OpaquePointer?
            guard sqlite3_prepare_v2(db, ftsSQL, -1, &fts, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(fts) }
            bindText(fts, 1, path)
            bindText(fts, 2, title)
            bindText(fts, 3, tagsCSV)
            bindText(fts, 4, content)
            _ = sqlite3_step(fts)
        }
    }

    func removeNote(path: String) {
        queue.sync {
            guard db != nil else { return }
            execLocked("DELETE FROM notes WHERE path = \(sqlLiteral(path));")
            execLocked("DELETE FROM notes_fts WHERE path = \(sqlLiteral(path));")
        }
    }

    func removeNotes(notIn paths: Set<String>) {
        queue.sync {
            guard let db else { return }
            var existing: [String] = []
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT path FROM notes;", -1, &stmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(stmt) }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let c = sqlite3_column_text(stmt, 0) {
                        existing.append(String(cString: c))
                    }
                }
            }
            for path in existing where !paths.contains(path) {
                execLocked("DELETE FROM notes WHERE path = \(sqlLiteral(path));")
                execLocked("DELETE FROM notes_fts WHERE path = \(sqlLiteral(path));")
            }
        }
    }

    func modifiedTimes() -> [String: Date] {
        queue.sync {
            guard let db else { return [:] }
            var result: [String: Date] = [:]
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT path, modified FROM notes;", -1, &stmt, nil) == SQLITE_OK else {
                return [:]
            }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let c = sqlite3_column_text(stmt, 0) else { continue }
                let path = String(cString: c)
                let mod = sqlite3_column_double(stmt, 1)
                result[path] = Date(timeIntervalSince1970: mod)
            }
            return result
        }
    }

    struct FTSHit: Sendable {
        var path: String
        var title: String
        var snippet: String
        var rank: Double
    }

    /// Full-text search with FTS5 BM25 ranking. Falls back to empty if index unavailable.
    func searchFTS(query: String, limit: Int = 200) -> [FTSHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        return queue.sync {
            guard let db else { return [] }
            // Convert free text into FTS5 query: quote multi-word tokens, OR for terms
            let ftsQuery = Self.buildFTSQuery(trimmed)
            guard !ftsQuery.isEmpty else { return [] }

            let sql = """
            SELECT n.path, n.title,
                   snippet(notes_fts, 3, '«', '»', '…', 12) AS snip,
                   bm25(notes_fts) AS rank
            FROM notes_fts
            JOIN notes n ON n.path = notes_fts.path
            WHERE notes_fts MATCH ?
            ORDER BY rank
            LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return []
            }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, ftsQuery)
            sqlite3_bind_int(stmt, 2, Int32(limit))

            var hits: [FTSHit] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let path = String(cString: sqlite3_column_text(stmt, 0))
                let title = String(cString: sqlite3_column_text(stmt, 1))
                let snip = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                let rank = sqlite3_column_double(stmt, 3)
                hits.append(FTSHit(path: path, title: title, snippet: snip, rank: -rank))
            }
            return hits
        }
    }

    // MARK: - Graph positions

    func loadGraphPositions() -> [String: SIMD2<Double>] {
        queue.sync {
            guard let db else { return [:] }
            var result: [String: SIMD2<Double>] = [:]
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT id, x, y FROM graph_positions;", -1, &stmt, nil) == SQLITE_OK else {
                return [:]
            }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let x = sqlite3_column_double(stmt, 1)
                let y = sqlite3_column_double(stmt, 2)
                result[id] = SIMD2(x, y)
            }
            return result
        }
    }

    func saveGraphPositions(_ positions: [String: SIMD2<Double>]) {
        queue.sync {
            guard let db else { return }
            execLocked("BEGIN;")
            execLocked("DELETE FROM graph_positions;")
            let sql = "INSERT INTO graph_positions(id, x, y) VALUES(?,?,?);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                execLocked("ROLLBACK;")
                return
            }
            defer { sqlite3_finalize(stmt) }
            for (id, p) in positions {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bindText(stmt, 1, id)
                sqlite3_bind_double(stmt, 2, p.x)
                sqlite3_bind_double(stmt, 3, p.y)
                _ = sqlite3_step(stmt)
            }
            execLocked("COMMIT;")
        }
    }

    // MARK: - Schema

    private func migrate() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS notes (
            path TEXT PRIMARY KEY NOT NULL,
            title TEXT NOT NULL,
            folder TEXT NOT NULL DEFAULT '',
            tags TEXT NOT NULL DEFAULT '',
            modified REAL NOT NULL DEFAULT 0,
            content TEXT NOT NULL DEFAULT ''
        );
        """)
        try exec("""
        CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(
            path UNINDEXED,
            title,
            tags,
            body,
            tokenize = 'porter unicode61'
        );
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS graph_positions (
            id TEXT PRIMARY KEY NOT NULL,
            x REAL NOT NULL,
            y REAL NOT NULL
        );
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        """)
    }

    // MARK: - Helpers

    enum IndexError: LocalizedError {
        case openFailed(String)
        case execFailed(String)

        var errorDescription: String? {
            switch self {
            case .openFailed(let m): return "SQLite open failed: \(m)"
            case .execFailed(let m): return "SQLite exec failed: \(m)"
            }
        }
    }

    private func exec(_ sql: String) throws {
        try queue.sync {
            try execThrowing(sql)
        }
    }

    private func execLocked(_ sql: String) {
        guard let db else { return }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            if let err { sqlite3_free(err) }
        }
    }

    private func execThrowing(_ sql: String) throws {
        guard let db else { throw IndexError.execFailed("no database") }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown"
            if let err { sqlite3_free(err) }
            throw IndexError.execFailed(message)
        }
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        _ = value.withCString { sqlite3_bind_text(stmt, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }

    private func sqlLiteral(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// Build a tolerant FTS5 MATCH string from free-form user input.
    nonisolated static func buildFTSQuery(_ raw: String) -> String {
        // Extract path:/tag:/file: elsewhere; here assume pure content terms.
        var terms: [String] = []
        var current = ""
        var inQuotes = false
        for ch in raw {
            if ch == "\"" {
                inQuotes.toggle()
                continue
            }
            if ch == " " && !inQuotes {
                if !current.isEmpty {
                    terms.append(current)
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { terms.append(current) }

        let cleaned = terms.compactMap { term -> String? in
            let lower = term.lowercased()
            if lower.hasPrefix("path:") || lower.hasPrefix("tag:") || lower.hasPrefix("file:") {
                return nil
            }
            let t = term.replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "*", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 1 else { return nil }
            // Quote tokens that contain special FTS chars
            if t.contains(where: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_" && $0 != "/" }) {
                return "\"\(t)\""
            }
            return "\(t)*"
        }
        return cleaned.joined(separator: " ")
    }
}
