import JournalCore
import SwiftUI

/// Present the selected evidence for review without exposing prompt serialization in the UI.
struct ContextPreviewView: View {
    private struct Entry: Decodable, Identifiable {
        let citation: String
        let text: String
        let date: Date?
        var id: String { citation }
    }

    private let entries: [Entry]

    init(context: JournalContext) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([Entry].self, from: Data(context.text.utf8))) ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if entries.isEmpty {
                    Text("No journal evidence was included.").foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.text)
                        Text(
                            entry.date?.formatted(date: .abbreviated, time: .omitted)
                                ?? "Undated entry"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .textSelection(.enabled)
                    Divider()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(minHeight: 100, idealHeight: 150, maxHeight: 200)
    }
}
