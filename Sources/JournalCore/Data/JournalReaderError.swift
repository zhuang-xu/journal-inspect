import Foundation

public struct JournalReaderError: LocalizedError {
    public let message: String

    public let code: String

    public init(message: String, code: String = "scan_failed") {
        self.message = message
        self.code = code
    }

    public var errorDescription: String? { message }
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw JournalReaderError(message: message) }
}
