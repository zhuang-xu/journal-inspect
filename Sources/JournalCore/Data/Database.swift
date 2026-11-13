import Darwin
import Foundation
import SQLite3

final class Database {
    let handle: OpaquePointer
    var checkInterruption: (() throws -> Void)?

    init(_ path: String, readOnly: Bool) throws {
        var h: OpaquePointer?
        let url = URL(fileURLWithPath: path)

        guard let parent = realpath(url.deletingLastPathComponent().path, nil) else {
            throw JournalReaderError(
                message: "Database parent directory is unavailable; check access permissions.",
                code: errno == EACCES || errno == EPERM ? "permission_denied" : "source_unavailable"
            )
        }
        defer { free(parent) }

        let canonical = String(cString: parent) + "/" + url.lastPathComponent
        let result = sqlite3_open_v2(
            canonical, &h,
            (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
                | SQLITE_OPEN_NOFOLLOW, nil)

        guard result == SQLITE_OK, let opened = h else {
            let systemError = h.map { sqlite3_system_errno($0) } ?? errno
            if let h { sqlite3_close(h) }
            let denied =
                systemError == EACCES || systemError == EPERM || result == SQLITE_PERM
                || result == SQLITE_AUTH
            throw JournalReaderError(
                message: denied
                    ? "Permission denied. Enable Full Disk Access for the launching app in System Settings → Privacy & Security."
                    : "Cannot open database; check that Apple Journal is available and access is permitted.",
                code: denied ? "permission_denied" : "source_unavailable")
        }

        handle = opened
        sqlite3_busy_timeout(handle, 5000)
        try execute("PRAGMA trusted_schema=OFF; PRAGMA cache_size=-8192; PRAGMA temp_store=FILE")
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String) throws {
        try require(
            sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK,
            "Database operation failed; private diagnostics suppressed.")
    }

    var changedRowCount: Int { Int(sqlite3_changes(handle)) }

    /// Serializes writers and guarantees rollback if the operation or commit fails.
    func transaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try operation()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func scalar(_ sql: String) throws -> String {
        let stmt = try Statement(self, sql)
        try require(try stmt.next(), "Database validation failed.")
        return stmt.text(0) ?? ""
    }
}

final class Statement {
    private let database: Database
    let handle: OpaquePointer

    init(_ db: Database, _ sql: String) throws {
        database = db
        var h: OpaquePointer?
        let rc = sqlite3_prepare_v2(db.handle, sql, -1, &h, nil)

        guard rc == SQLITE_OK, let h else {
            if let h { sqlite3_finalize(h) }
            throw JournalReaderError(message: "Unsupported database schema.")
        }

        handle = h
    }

    deinit { sqlite3_finalize(handle) }

    func bind(_ values: [String?]) throws {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        for (i, value) in values.enumerated() {
            let rc =
                value.map { v in
                    v.withCString {
                        sqlite3_bind_text(handle, Int32(i + 1), $0, -1, transient)
                    }
                } ?? sqlite3_bind_null(handle, Int32(i + 1))
            try require(rc == SQLITE_OK, "Cannot bind metadata.")
        }
    }

    enum Value {
        case text(String)
        case integer(Int64)
        case real(Double)
        case blob(Data)
        case null
    }

    func bindValues(_ values: [Value]) throws {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in values.enumerated() {
            let position = Int32(i + 1)
            let rc: Int32
            switch value {
            case .text(let text):
                rc = text.withCString { sqlite3_bind_text(handle, position, $0, -1, transient) }
            case .integer(let number): rc = sqlite3_bind_int64(handle, position, number)
            case .real(let number): rc = sqlite3_bind_double(handle, position, number)
            case .blob(let data):
                rc =
                    data.isEmpty
                    ? sqlite3_bind_zeroblob(handle, position, 0)
                    : data.withUnsafeBytes {
                        sqlite3_bind_blob(
                            handle, position, $0.baseAddress, Int32($0.count), transient)
                    }
            case .null: rc = sqlite3_bind_null(handle, position)
            }
            try require(rc == SQLITE_OK, "Cannot bind database value.")
        }
    }

    func executeValues(_ values: [Value]) throws {
        try bindValues(values)
        try require(try !next(), "Expected a database write statement.")
    }

    func execute(_ values: [String?]) throws {
        try bind(values)
        try require(try !next(), "Expected a metadata write statement.")
    }

    func next() throws -> Bool {
        try database.checkInterruption?()
        let rc = sqlite3_step(handle)
        try require(rc == SQLITE_ROW || rc == SQLITE_DONE, "Database read/write failed.")
        return rc == SQLITE_ROW
    }

    func text(_ index: Int32) -> String? {
        guard let p = sqlite3_column_text(handle, index) else { return nil }
        return String(cString: p)
    }

    func data(_ index: Int32) -> Data? {
        guard sqlite3_column_type(handle, index) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(handle, index))
        guard count > 0, let pointer = sqlite3_column_blob(handle, index) else { return Data() }
        return Data(bytes: pointer, count: count)
    }

    func columnIndex(named name: String) throws -> Int32 {
        for index in 0..<sqlite3_column_count(handle) {
            if String(cString: sqlite3_column_name(handle, index)) == name {
                return index
            }
        }
        throw JournalReaderError(message: "Required database column is missing.")
    }

    func integer(_ index: Int32) -> Int64 {
        sqlite3_column_int64(handle, index)
    }

    func uuid(_ index: Int32) -> UUID? {
        if sqlite3_column_type(handle, index) == SQLITE_BLOB {
            guard sqlite3_column_bytes(handle, index) == 16,
                let bytes = sqlite3_column_blob(handle, index)
            else { return nil }
            return UUID(uuid: bytes.loadUnaligned(as: uuid_t.self))
        }
        return text(index).flatMap(UUID.init(uuidString:))
    }

    func number(_ index: Int32) -> Double? {
        sqlite3_column_type(handle, index) == SQLITE_NULL
            ? nil : sqlite3_column_double(handle, index)
    }
}
