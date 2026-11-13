import CryptoKit
import Foundation
import SQLite3

/// Preserves fingerprint v1 framing so refactoring does not invalidate the local index.
struct EntryFingerprint {
    private var hash: HMAC<SHA256>

    init(key: SymmetricKey) {
        hash = HMAC<SHA256>(key: key)
        hash.update(data: Data("journal-fingerprint-v1".utf8))
    }

    mutating func append(_ row: Statement) {
        Self.appendRow(row, into: &hash)
    }

    func finish() -> String {
        hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func appendRow(_ row: Statement, into hash: inout HMAC<SHA256>) {
        // Framing includes column names/types/lengths. Blob buffers are hashed in chunks.
        hash.update(data: Data("row:\(sqlite3_column_count(row.handle)):".utf8))
        for i in 0..<sqlite3_column_count(row.handle) {
            let name = String(cString: sqlite3_column_name(row.handle, i))
            let kind = sqlite3_column_type(row.handle, i)
            if kind == SQLITE_INTEGER || kind == SQLITE_FLOAT {
                let bits =
                    kind == SQLITE_INTEGER
                    ? UInt64(bitPattern: sqlite3_column_int64(row.handle, i))
                    : sqlite3_column_double(row.handle, i).bitPattern
                hash.update(data: Data("\(name.count):\(name):\(kind):\(bits):".utf8))
                continue
            }
            let pointer = sqlite3_column_blob(row.handle, i)
            let count = Int(sqlite3_column_bytes(row.handle, i))
            hash.update(data: Data("\(name.count):\(name):\(kind):\(count):".utf8))
            if let pointer {
                var offset = 0
                while offset < count {
                    let size = min(64 * 1024, count - offset)
                    hash.update(data: Data(bytes: pointer.advanced(by: offset), count: size))
                    offset += size
                }
            }
        }
    }
}
