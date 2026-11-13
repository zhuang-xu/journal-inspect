import JournalCore
import SwiftUI

@MainActor
struct PromptView: View {
    @ObservedObject var model: PromptViewModel
    let blocked: Bool
    let openSettings: () -> Void
    @FocusState private var editingQuestion: Bool
    @State private var reviewingSources = false

    private let starters = [
        (
            "Recurring themes", "What themes keep coming up in my journal?",
            "arrow.triangle.2.circlepath"
        ),
        ("What helps", "What seems to help when I’m having a difficult day?", "sun.max"),
        (
            "How I’ve changed", "What changes can you see in how I write about my priorities?",
            "chart.line.uptrend.xyaxis"
        ),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            if model.preview == nil && model.answer == nil && !model.busy {
                suggestions
            }
            composer
            if let activity = model.activity, let startedAt = model.activityStartedAt {
                PromptProgressView(activity: activity, startedAt: startedAt)
            }
            if let status = model.status {
                Text(status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if model.answer != nil || model.preview != nil {
                response
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $reviewingSources) {
            if let preview = model.preview {
                sourceReview(preview)
            }
        }
        .onChange(of: model.preview == nil) { _, empty in
            if empty { reviewingSources = false }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("PRIVATE ON THIS MAC", systemImage: "lock")
                .font(.caption2.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            Text("Reflect on your journal")
                .font(.system(.largeTitle, design: .serif).weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Explore patterns in your entries or ask about something on your mind.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ideas to explore").font(.headline)
            HStack(spacing: 10) {
                ForEach(starters, id: \.0) { title, question, icon in
                    Button {
                        model.input = question
                        editingQuestion = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: icon).foregroundStyle(Color.accentColor)
                            Text(title)
                        }
                        .font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .help(question)
                }
            }
        }
        .disabled(blocked)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your question").font(.headline)
            TextField("What would you like to understand?", text: $model.input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...3)
                .focused($editingQuestion)
                .disabled(blocked || model.busy)
                .accessibilityLabel("Your journal question")
            Divider()
            HStack {
                if model.busy {
                    Button("Stop", action: model.cancel)
                        .disabled(blocked)
                } else if model.modelURL == nil {
                    Button("Set up answers", action: openSettings)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Ask Journal", action: model.ask)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(blocked || !model.canAsk)
                }
                Spacer()
                if !model.input.isEmpty && !model.busy {
                    Button("New question") {
                        model.clear()
                        editingQuestion = true
                    }
                    .disabled(blocked)
                }
                Menu {
                    Button("Find excerpts before answering", action: model.prepare)
                        .disabled(!model.canAsk)
                } label: {
                    Label("Question options", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .fixedSize()
                .disabled(blocked || model.busy)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var response: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.answer == nil ? "Journal excerpts" : "Your reflection")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let preview = model.preview {
                    Button {
                        reviewingSources = true
                    } label: {
                        Label("Sources (\(preview.context.citationIDs.count))", systemImage: "book")
                    }
                    .disabled(model.busy)
                }
            }
            if let answer = model.answer {
                EntryTextView(text: answer, format: .markdown, followsOutput: true)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Text("Check important details against your entries.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !model.busy {
                Text("Review the excerpts or ask Journal to write your reflection.")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    private func sourceReview(_ preview: AugmentedPrompt) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Journal excerpts").font(.title2.weight(.semibold))
            Text("These are the passages selected for your question.")
                .foregroundStyle(.secondary)
            ContextPreviewView(context: preview.context)
            MemoryProfilePreviewView(profile: preview.memory)
            HStack {
                Spacer()
                Button("Done") { reviewingSources = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 580)
    }
}

private struct MemoryProfilePreviewView: View {
    let profile: PersonalMemoryProfile
    private struct Fact: Decodable, Identifiable {
        let id: UUID
        let statement: String
        let asOf: String?
        let review: String?
    }
    var body: some View {
        let facts = (try? JSONDecoder().decode([Fact].self, from: Data(profile.text.utf8))) ?? []
        DisclosureGroup(
            "Saved background · \(facts.count) facts · \(profile.omittedCount) omitted or unavailable"
        ) {
            if facts.isEmpty {
                Text("No saved background was used.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(facts) { fact in
                            VStack(alignment: .leading) {
                                Text(fact.statement)
                                Text(
                                    (fact.asOf ?? "Undated")
                                        + (fact.review == "automatic_unconfirmed"
                                            ? " · Automatically extracted" : "")
                                ).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.vertical, 8)
                }
                .frame(height: 120)
            }
        }.font(.callout)
    }
}
