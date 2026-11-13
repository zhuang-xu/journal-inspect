import Foundation

/// Token pieces can split a UTF-8 character. Publish only complete text snapshots.
struct AnswerTextBuffer {
    private var bytes = [UInt8]()

    mutating func append(_ piece: [UInt8]) -> String? {
        guard !piece.isEmpty else { return nil }
        bytes += piece
        return String(bytes: bytes, encoding: .utf8)
    }

    var completedText: String {
        String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
