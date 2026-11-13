import JournalCore
import SwiftUI

struct MemoryView: View {
    @ObservedObject var model: MemoryViewModel
    let modelURL: URL?
    @State private var editing: PersonalMemory?
    @State private var showingEditor = false
    @State private var statement = ""
    @State private var category = MemoryCategory.circumstance
    @State private var date = Date()
    @State private var deleting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Use personal memory", isOn: Binding(get: { model.enabled }, set: model.toggle))
                .disabled(model.busy)
            Text(
                "Built memories provide dated background when enabled. Automatic memories can be wrong; confirm, edit, or forget them. Current sources are checked before use."
            )
            .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Add memory") { edit(nil) }
                Button("Build suggestions") { model.update(modelURL: modelURL) }
                    .disabled(!model.enabled || modelURL == nil)
                    .help(
                        "Read every synced journal entry and build a source-linked memory list. Existing edits and forget decisions are preserved."
                    )
                Menu("More") {
                    Button("Restore forgotten suggestions", action: model.restore)
                    Button("Delete all memory…", role: .destructive) { deleting = true }
                }
                if model.busy { ProgressView().controlSize(.small) }
            }.disabled(model.busy)
            if model.busy { Button("Cancel", action: model.cancel) }
            Text(model.status).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Saved memories · \(model.records.count)").font(.headline)
                Spacer()
                Text(
                    "\(model.activeCount) confirmed · \(model.suggestionCount) automatic · \(model.outdatedCount) outdated"
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            buildHistory
            if model.records.isEmpty {
                ContentUnavailableView {
                    Label(
                        model.building ? "Building suggestions" : "No saved memories",
                        systemImage: "brain")
                } description: {
                    Text(model.emptyMessage)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.records) { memory in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(memory.statement).textSelection(.enabled)
                        Text(
                            "\(memory.category.rawValue) · \(memory.state.displayName) · \(memory.origin.rawValue) · \(memory.asOf?.formatted(date: .abbreviated, time: .omitted) ?? "Undated")"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            if memory.state == .unreviewed || memory.state == .awaitingClarification
                            {
                                Button(
                                    memory.state == .unreviewed ? "Confirm" : "Include in answers"
                                ) { model.approve(memory.id) }
                            }
                            Button("Edit") { edit(memory) }
                            if memory.state == .active || memory.state == .unreviewed {
                                Button("Mark outdated") { model.markOutdated(memory.id) }
                            }
                            Button("Forget") { model.forget(memory.id) }
                            if !memory.sources.isEmpty {
                                Menu("Sources · \(memory.sources.count)") {
                                    ForEach(Array(memory.sources.enumerated()), id: \.offset) {
                                        i, source in
                                        Button(
                                            "Source \(i + 1) · \(source.date?.formatted(date: .abbreviated, time: .omitted) ?? "Undated")"
                                        ) { model.open(source) }
                                    }
                                }
                            }
                        }.font(.caption)
                    }.padding(.vertical, 6)
                }.disabled(model.busy)
            }
            Text(
                "Background is selected for each question from confirmed and automatic memories. Outdated, unsupported, and clarification items are excluded. Your edits survive rebuilds."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 12)
        .task { model.load() }
        .sheet(isPresented: $showingEditor) {
            VStack(alignment: .leading, spacing: 16) {
                Text(editing == nil ? "Add memory" : "Edit memory").font(.headline)
                TextEditor(text: $statement).frame(width: 480, height: 100)
                Picker("Category", selection: $category) {
                    ForEach(MemoryCategory.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                DatePicker("As of", selection: $date, displayedComponents: .date)
                Text("Use the date this was true. Up to 600 UTF-8 bytes.").font(.caption)
                HStack {
                    Button("Cancel") { showingEditor = false }
                    Button("Save") {
                        model.save(
                            id: editing?.id, statement: statement, category: category, date: date)
                        showingEditor = false
                    }.disabled(
                        statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || statement.utf8.count > 600)
                }
            }.padding(24)
        }
        .sheet(
            isPresented: Binding(
                get: { model.sourceText != nil }, set: { if !$0 { model.sourceText = nil } })
        ) {
            VStack {
                Text("Current original entry · may have changed since extraction").font(.headline)
                EntryTextView(text: model.sourceText ?? "").frame(minWidth: 600, minHeight: 400)
                Button("Close") { model.sourceText = nil }
            }.padding(24)
        }
        .confirmationDialog(
            "Delete all memory and forget decisions, and disable memory? Original Journal entries remain intact. Reenabling and rebuilding can recreate suggestions.",
            isPresented: $deleting
        ) {
            Button("Delete all memory", role: .destructive, action: model.deleteAll)
        }
    }
    @ViewBuilder
    private var buildHistory: some View {
        if let report = model.lastBuild {
            DisclosureGroup(
                "Last build · \(report.status == .running && !model.busy ? "interrupted" : report.status.rawValue) · \(report.completedEntries)/\(report.totalEntries) entries"
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        "Started: \(report.startedAt.formatted(date: .abbreviated, time: .shortened))"
                    )
                    if let finished = report.finishedAt {
                        Text(
                            "Finished: \(finished.formatted(date: .abbreviated, time: .shortened))")
                    }
                    Text(
                        "\(report.extractedEntries) extracted · \(report.unchangedEntries) unchanged · \(report.unavailableEntries) unavailable"
                    )
                    if let nonempty = report.nonemptyEntries, let bytes = report.decodedTextBytes {
                        Text(
                            "\(nonempty) entries with nonempty decoded text · \(bytes) total UTF-8 bytes read"
                        )
                    }
                    if let empty = report.zeroCandidateEntries {
                        Text("\(empty) extracted entries returned no candidates.")
                    }
                    Text(
                        "\(report.candidateCount) candidates returned before deduplication and saved-memory decisions."
                    )
                    if report.extractedEntries > 0 && report.candidateCount == 0 {
                        Text(
                            "The model returned no memory candidates. This does not mean your journal contains no useful facts."
                        )
                    }
                    Text(
                        "\(model.processedEntryCount) entry revisions have saved processing checkpoints. All saved memories are listed below, including suggestions and outdated facts."
                    )
                }.padding(.vertical, 6)
            }.font(.caption).foregroundStyle(.secondary)
        } else if model.processedEntryCount > 0 {
            Text(
                "Previous processing: \(model.processedEntryCount) entry revisions. Detailed build results were not recorded by the earlier app version."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func edit(_ memory: PersonalMemory?) {
        editing = memory
        statement = memory?.statement ?? ""
        category = memory?.category ?? .circumstance
        date = memory?.asOf ?? Date()
        showingEditor = true
    }
}
