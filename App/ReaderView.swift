import AppKit
import JournalCore
import SwiftUI

@MainActor
struct ReaderView: View {
    @StateObject private var model = JournalAppComposition.makeReader()

    private enum Destination: Hashable {
        case reflect
        case entries
    }

    @State private var settingsTab = JournalSettingsView.Tab.journalAccess
    @State private var destination: Destination? = .reflect
    @State private var showingSettings = false

    var body: some View {
        NavigationSplitView {
            List(selection: $destination) {
                Label("Reflect", systemImage: "sparkles").tag(Destination.reflect)
                Label("Entries", systemImage: "book.closed").tag(Destination.entries)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
            .navigationTitle("Journal")
        } detail: {
            switch destination ?? .reflect {
            case .reflect:
                PromptView(
                    model: model.prompt, blocked: model.isSyncing || model.memory.busy,
                    openSettings: {
                        settingsTab = .answerSetup
                        showingSettings = true
                    })
            case .entries:
                EntriesView(model: model)
                    .task { model.reloadPage() }
            }
        }
        .toolbar {
            Button {
                showingSettings = true
            } label: {
                Label("Journal Settings", systemImage: "gearshape")
            }
            .help("Journal Settings")
        }
        .sheet(isPresented: $showingSettings) {
            JournalSettingsView(model: model, tab: $settingsTab)
        }
        .task {
            model.reloadPage()
            model.memory.load()
        }
        .onChange(of: model.selection) { _, value in model.selectEntry(value) }
        .onDisappear { model.stop() }
        .onChange(of: model.memory.revision) { _, _ in model.prompt.resetResponse() }
    }

}

@MainActor
private struct JournalSettingsView: View {
    enum Tab: Hashable {
        case journalAccess
        case answerSetup
        case personalization
    }

    @ObservedObject var model: ReaderViewModel
    @Binding var tab: Tab
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Journal Settings").font(.title2.weight(.semibold))
            TabView(selection: $tab) {
                Form {
                    Section("Journal access") {
                        syncControls
                        Text(model.status).textSelection(.enabled)
                        syncHistory
                    }
                }
                .formStyle(.grouped)
                .tabItem { Text("Journal Access") }
                .tag(Tab.journalAccess)

                Form {
                    Section("Local answer model") {
                        LabeledContent("Model", value: model.prompt.modelDisplayName)
                        Button("Choose model…", action: chooseModel)
                    }
                    .disabled(model.isSyncing || model.memory.busy || model.prompt.busy)
                    Section("Retrieval cache") {
                        Toggle(
                            "Reuse passage embeddings",
                            isOn: Binding(
                                get: { model.prompt.cacheEnabled },
                                set: { model.prompt.cacheEnabled = $0 }
                            )
                        )
                        .disabled(model.prompt.busy)
                        Text(
                            "Stored vectors contain sensitive information derived from your entries. Turning off reuse keeps existing vectors on disk."
                        )
                        Text(model.prompt.cacheSummary).textSelection(.enabled)
                        if model.prompt.activity == .maintaining {
                            HStack {
                                ProgressView().controlSize(.small)
                                Button("Cancel", action: model.prompt.cancel)
                            }
                        } else {
                            HStack {
                                Button("Update") { model.prompt.updateCache() }
                                    .disabled(!model.prompt.cacheEnabled)
                                Button("Rebuild") { model.prompt.updateCache(rebuild: true) }
                                    .disabled(!model.prompt.cacheEnabled)
                                Button("Clear cache", action: model.prompt.clearCache)
                            }
                            .disabled(model.prompt.busy)
                        }
                    }
                    .disabled(model.isSyncing || model.memory.busy)
                }
                .formStyle(.grouped)
                .tabItem { Text("Answer Setup") }
                .tag(Tab.answerSetup)

                MemoryView(model: model.memory, modelURL: model.prompt.modelURL)
                    .padding(12)
                    .disabled(model.isSyncing || model.prompt.busy)
                    .tabItem { Text("Personalization") }
                    .tag(Tab.personalization)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 740, height: 550)
    }

    private func chooseModel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the supported local Qwen3 4B or 0.6B model file."
        if panel.runModal() == .OK, let url = panel.url { model.prompt.selectModel(url) }
    }

    private var syncControls: some View {
        HStack {
            Button("Sync Apple Journal", action: model.synchronize).disabled(
                model.isSyncing || model.memory.busy || model.prompt.busy)
            Button("Cancel", action: model.cancelSync).disabled(!model.isSyncing)
            Button("Open Index Folder") {
                NSWorkspace.shared.open(JournalMetadataStore.defaultDirectory)
            }
            if model.isSyncing {
                ProgressView().controlSize(.small)
                Text("Scanned \(model.processed) entries…")
            }
        }
    }

    private var syncHistory: some View {
        HStack {
            if let lastSuccess = model.lastSuccess {
                Text(
                    "Last successful sync: \(lastSuccess.formatted(date: .abbreviated, time: .standard))"
                )
            } else {
                Text("Last successful sync: Never")
            }
            Text(model.lastRun)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

}

@MainActor
private struct EntriesView: View {
    @ObservedObject var model: ReaderViewModel
    @State private var showingEntryOptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Journal entries")
                    .font(.system(.largeTitle, design: .serif).weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if model.isSyncing {
                    ProgressView().controlSize(.small).accessibilityLabel("Refreshing entries")
                    Button("Stop", action: model.cancelSync)
                } else {
                    Button {
                        model.synchronize()
                    } label: {
                        Label("Refresh entries", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.memory.busy || model.prompt.busy)
                }
            }
            filters
            HSplitView {
                entryBrowser
                entryDetail
            }
        }
        .padding(24)
    }

    private var filters: some View {
        HStack {
            Toggle("Filter by date", isOn: $model.dateFilter)
            if model.dateFilter {
                DatePicker("From", selection: $model.start, displayedComponents: .date)
                DatePicker("Through", selection: $model.end, displayedComponents: .date)
            }
            Toggle("Include deleted", isOn: $model.showDeleted)
            Button("Apply filters", action: model.applyFilters)
                .disabled(model.browsing || model.isSyncing)
        }
        .font(.callout)
    }

    private var entryBrowser: some View {
        VStack(alignment: .leading, spacing: 8) {
            List(model.entries, selection: $model.selection) { entry in
                EntryRow(entry: entry).tag(entry.id)
            }
            .disabled(model.isSyncing || model.browsing)
            pagination
        }.frame(minWidth: 300, idealWidth: 360)
    }

    private var pagination: some View {
        HStack {
            Button("Previous", action: model.previousPage).disabled(
                model.offset == 0 || model.browsing || model.isSyncing)
            Text(
                model.total == 0
                    ? "No entries"
                    : "\(model.offset + 1)–\(model.offset + model.entries.count) of \(model.total)")
            Button("Next", action: model.nextPage).disabled(
                model.nextOffset == nil || model.browsing || model.isSyncing)
            if model.browsing { ProgressView().controlSize(.small) }
        }
    }

    private var entryDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    showingEntryOptions = true
                } label: {
                    Label("Entry options", systemImage: "ellipsis.circle")
                }
                .disabled(model.isSyncing)
                .popover(isPresented: $showingEntryOptions, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Entry UUID", text: $model.uuidInput)
                            .onSubmit(openEntryByID)
                        HStack {
                            Button("Close entry") {
                                model.clearEntry()
                                showingEntryOptions = false
                            }
                            Spacer()
                            Button("Open entry", action: openEntryByID)
                                .disabled(model.uuidInput.isEmpty)
                        }
                    }
                    .padding(16)
                    .frame(width: 320)
                }
                Spacer()
            }
            if let loadedText = model.loadedText {
                EntryTextView(text: loadedText)
            } else {
                ContentUnavailableView {
                    Label("Journal entry", systemImage: "book")
                } description: {
                    Text(model.entryStatus).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.leading, 12)
        .frame(minWidth: 300)
    }

    private func openEntryByID() {
        guard !model.uuidInput.isEmpty else { return }
        model.openEntry(model.uuidInput)
        showingEntryOptions = false
    }

}

private struct EntryRow: View {
    let entry: JournalEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(dateLabel).font(.headline)
            if entry.deleted { Text("Deleted").foregroundStyle(.secondary) }
        }
        .padding(.vertical, 5)
        .help(entry.uuid)
    }

    private var dateLabel: String {
        (entry.entryDate ?? entry.created).map {
            Date(timeIntervalSinceReferenceDate: $0).formatted(date: .abbreviated, time: .shortened)
        } ?? "Undated entry"
    }
}
