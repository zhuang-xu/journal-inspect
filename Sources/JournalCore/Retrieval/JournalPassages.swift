import Foundation
import NaturalLanguage

/// A conservative UTF-8 bound stays below the native 2048-token context for byte-based
/// tokenization. Prefer whitespace boundaries; never drop text or break a Unicode scalar.
/// Passage selection is explicit: returned evidence may be an excerpt of an entry.
enum JournalPassages {
    static let maximumBytes = 768
    static let maximumExcerptBytes = 1280

    struct Located: Sendable {
        let text: String
        let offset: Int
        var length: Int { text.utf8.count }
    }

    /// Expand only the displayed excerpt. Indexed passage boundaries and offsets stay fixed.
    static func expanded(_ passage: Located, in original: String) -> Located {
        let bytes = original.utf8
        let count = bytes.count
        if count <= maximumExcerptBytes { return Located(text: original, offset: 0) }

        let padding = (maximumExcerptBytes - passage.length) / 2
        let startOffset = max(0, min(passage.offset - padding, count - maximumExcerptBytes))
        var start = bytes.index(bytes.startIndex, offsetBy: startOffset)
        var end = bytes.index(start, offsetBy: maximumExcerptBytes)
        // Move inward to scalar boundaries. The winning passage is already scalar-aligned.
        while bytes[start] & 0xC0 == 0x80 { bytes.formIndex(after: &start) }
        while end < bytes.endIndex, bytes[end] & 0xC0 == 0x80 { bytes.formIndex(before: &end) }
        let offset = bytes.distance(from: bytes.startIndex, to: start)
        let window = String(decoding: bytes[start..<end], as: UTF8.self)

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = window
        let sentences = tokenizer.tokens(for: window.startIndex..<window.endIndex)
        let anchorStart = passage.offset - offset
        let anchorEnd = anchorStart + passage.length
        let windowBytes = window.utf8
        var lower = windowBytes.startIndex
        var upper = windowBytes.endIndex

        // Prefer complete outer sentences if trimming preserves the entire winning passage.
        // With punctuation-free text, the scalar-aligned window remains usable.
        if start != bytes.startIndex, sentences.count > 1 {
            let boundary = sentences[1].lowerBound
            if windowBytes.distance(from: windowBytes.startIndex, to: boundary) <= anchorStart {
                lower = boundary
            }
        }
        if end != bytes.endIndex, sentences.count > 1 {
            let boundary = sentences[sentences.count - 2].upperBound
            if windowBytes.distance(from: windowBytes.startIndex, to: boundary) >= anchorEnd {
                upper = boundary
            }
        }
        return Located(
            text: String(decoding: windowBytes[lower..<upper], as: UTF8.self),
            offset: offset + windowBytes.distance(from: windowBytes.startIndex, to: lower))
    }

    static func located(_ text: String) -> [Located] {
        let scalars = text.unicodeScalars
        var start = scalars.startIndex
        var passages = [Located]()
        var offset = 0
        while start < scalars.endIndex {
            var end = start
            var bytes = 0
            var boundary: String.UnicodeScalarView.Index?
            while end < scalars.endIndex {
                let scalar = scalars[end]
                let size = scalar.utf8.count
                guard bytes + size <= maximumBytes else { break }
                bytes += size
                end = scalars.index(after: end)
                if CharacterSet.whitespacesAndNewlines.contains(scalar), bytes >= maximumBytes / 2 {
                    boundary = end
                }
            }
            if end < scalars.endIndex, let boundary { end = boundary }
            let passage = String(scalars[start..<end])
            if !passage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                passages.append(Located(text: passage, offset: offset))
            }
            offset += passage.utf8.count
            start = end
        }
        return passages
    }
}
