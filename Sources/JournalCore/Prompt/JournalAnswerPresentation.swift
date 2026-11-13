import Foundation

/// Presentation guard for legacy/internal reference dumps; ordinary prose stays intact.
public enum JournalAnswerPresentation {
    public static func readable(_ text: String, internalIDs: [String]) -> String {
        var result = text
        // Suppress a metadata appendix as soon as its marker arrives in a streamed snapshot.
        if let marker = result.range(
            of: #"\[\s*citation\s+ids?\s*:"#,
            options: [.regularExpression, .caseInsensitive])
        {
            result = String(result[..<marker.lowerBound])
        }
        if let brackets = try? NSRegularExpression(pattern: #"\[[^\]]*\]"#) {
            let matches = brackets.matches(
                in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                var content = String(result[range].dropFirst().dropLast())
                var found = false
                for id in internalIDs where content.range(of: id, options: .caseInsensitive) != nil
                {
                    found = true
                    content = content.replacingOccurrences(
                        of: id, with: "", options: .caseInsensitive)
                }
                if found
                    && content.trimmingCharacters(
                        in: CharacterSet.whitespacesAndNewlines.union(
                            CharacterSet(charactersIn: ",;"))
                    ).isEmpty
                {
                    var start = range.lowerBound
                    if start > result.startIndex, result[result.index(before: start)] == " " {
                        start = result.index(before: start)
                    }
                    result.removeSubrange(start..<range.upperBound)
                }
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
