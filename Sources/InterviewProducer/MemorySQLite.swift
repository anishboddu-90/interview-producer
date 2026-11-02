import Foundation
import CSQLite

enum SQLiteValue {
    case text(String), data(Data), number(Double), integer(Int64), null
    var string: String { if case .text(let s) = self { return s }; return "" }
    var int: Int { switch self { case .integer(let i): return Int(i); case .number(let d): return Int(d); default:return 0 } }
    var double: Double? { switch self { case .number(let d):return d; case .integer(let i):return Double(i); default:return nil } }
    var blob: Data { if case .data(let d) = self { return d }; return Data() }
    static func optional(_ value: Double?) -> Self { value.map { .number($0) } ?? .null }
    static func optional(_ value: String?) -> Self { value.map { .text($0) } ?? .null }
}
typealias SQLiteRow = [String:SQLiteValue]

/// Private to ConversationMemory's actor. FULLMUTEX also protects actor thread hops.
final class MemorySQLite {
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1,to:sqlite3_destructor_type.self)
    init(url: URL) throws {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let status = sqlite3_open_v2(url.path,&handle,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_FULLMUTEX,nil)
        guard status == SQLITE_OK else { if let handle { sqlite3_close(handle) }; handle = nil; throw ProducerError.message("Cannot open local conversation memory (SQLite \(status)).") }
        sqlite3_busy_timeout(handle,3000)
        try exec("PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA secure_delete=ON; PRAGMA synchronous=NORMAL;")
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        try exec("""
        CREATE TABLE IF NOT EXISTS conversations(
          id TEXT PRIMARY KEY, original_id TEXT NOT NULL, title TEXT NOT NULL,
          created REAL, updated REAL, current_node TEXT, raw_json BLOB NOT NULL,
          sha256 TEXT NOT NULL, source_name TEXT NOT NULL, imported REAL NOT NULL,
          excluded INTEGER NOT NULL DEFAULT 0, alternatives INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS nodes(
          conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
          node_id TEXT NOT NULL, parent_id TEXT, children_json TEXT NOT NULL,
          ordinal INTEGER NOT NULL, active INTEGER NOT NULL, canonical_branch TEXT,
          message_id TEXT, role TEXT NOT NULL, text_exact TEXT NOT NULL,
          created REAL, updated REAL, hidden INTEGER NOT NULL, raw_node BLOB NOT NULL,
          kind TEXT NOT NULL, note TEXT NOT NULL DEFAULT '', source_url TEXT NOT NULL DEFAULT '',
          thread_status TEXT NOT NULL DEFAULT '', pinned INTEGER NOT NULL DEFAULT 0, excluded INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY(conversation_id,node_id));
        CREATE TABLE IF NOT EXISTS branches(
          conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
          leaf_id TEXT NOT NULL, active INTEGER NOT NULL, path_json TEXT NOT NULL,
          PRIMARY KEY(conversation_id,leaf_id));
        CREATE TABLE IF NOT EXISTS branch_nodes(
          conversation_id TEXT NOT NULL, leaf_id TEXT NOT NULL, node_id TEXT NOT NULL, position INTEGER NOT NULL,
          PRIMARY KEY(conversation_id,leaf_id,node_id),
          FOREIGN KEY(conversation_id,node_id) REFERENCES nodes(conversation_id,node_id) ON DELETE CASCADE);
        CREATE INDEX IF NOT EXISTS branch_node_lookup ON branch_nodes(conversation_id,node_id);
        CREATE TABLE IF NOT EXISTS relations(
          conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
          source_node TEXT NOT NULL, target_node TEXT NOT NULL, kind TEXT NOT NULL,
          PRIMARY KEY(conversation_id,source_node,target_node,kind));
        CREATE INDEX IF NOT EXISTS relation_targets ON relations(conversation_id,target_node);
        CREATE TABLE IF NOT EXISTS passages(
          id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, node_id TEXT NOT NULL,
          start_offset INTEGER NOT NULL, end_offset INTEGER NOT NULL, text_exact TEXT NOT NULL,
          FOREIGN KEY(conversation_id,node_id) REFERENCES nodes(conversation_id,node_id) ON DELETE CASCADE);
        CREATE INDEX IF NOT EXISTS passage_nodes ON passages(conversation_id,node_id);
        CREATE VIRTUAL TABLE IF NOT EXISTS passages_fts USING fts5(
          passage_id UNINDEXED, title, text_exact, annotation, tokenize='unicode61 remove_diacritics 2');
        CREATE TRIGGER IF NOT EXISTS delete_passage_fts AFTER DELETE ON passages BEGIN
          DELETE FROM passages_fts WHERE passage_id=old.id;
        END;
        CREATE TABLE IF NOT EXISTS dossier_versions(id INTEGER PRIMARY KEY AUTOINCREMENT,text_exact TEXT NOT NULL,created REAL NOT NULL);
        PRAGMA user_version=1;
        """)
    }
    deinit { if let handle { sqlite3_close(handle) } }
    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle,sql,nil,nil,&error) == SQLITE_OK else {
            let message = error.map { String(cString:$0) } ?? "SQLite operation failed"
            if let error { sqlite3_free(error) }
            throw ProducerError.message(message)
        }
    }
    func rows(_ sql: String,_ values: [SQLiteValue] = []) throws -> [SQLiteRow] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle,sql,-1,&statement,nil) == SQLITE_OK, let statement else { throw ProducerError.message("Local memory query failed: \(String(cString:sqlite3_errmsg(handle)))") }
        defer { sqlite3_finalize(statement) }
        for (i,value) in values.enumerated() {
            let index = Int32(i+1); let status: Int32
            switch value {
            case .text(let text): status = text.withCString { sqlite3_bind_text(statement,index,$0,Int32(text.utf8.count),transient) }
            case .data(let data): status = data.withUnsafeBytes { sqlite3_bind_blob(statement,index,$0.baseAddress,Int32(data.count),transient) }
            case .number(let n):status = sqlite3_bind_double(statement,index,n)
            case .integer(let n):status = sqlite3_bind_int64(statement,index,n)
            case .null:status = sqlite3_bind_null(statement,index)
            }
            guard status == SQLITE_OK else { throw ProducerError.message("Cannot bind local memory query (\(status)).") }
        }
        var result = [SQLiteRow]()
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw ProducerError.message("Local memory query failed: \(String(cString:sqlite3_errmsg(handle)))") }
            var row = SQLiteRow()
            for i in 0..<sqlite3_column_count(statement) {
                let key = String(cString:sqlite3_column_name(statement,i))
                switch sqlite3_column_type(statement,i) {
                case SQLITE_TEXT:
                    let count = Int(sqlite3_column_bytes(statement,i))
                    if let p = sqlite3_column_text(statement,i) { row[key] = .text(String(decoding:UnsafeBufferPointer(start:p,count:count),as:UTF8.self)) } else { row[key] = .text("") }
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement,i)); row[key] = .data(sqlite3_column_blob(statement,i).map { Data(bytes:$0,count:count) } ?? Data())
                case SQLITE_INTEGER:row[key] = .integer(sqlite3_column_int64(statement,i))
                case SQLITE_FLOAT:row[key] = .number(sqlite3_column_double(statement,i))
                default:row[key] = .null
                }
            }
            result.append(row)
        }
        return result
    }
    func write(_ sql: String,_ values: [SQLiteValue] = []) throws { _ = try rows(sql,values) }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do { let result = try body(); try exec("COMMIT"); return result }
        catch { try? exec("ROLLBACK"); throw error }
    }
}
