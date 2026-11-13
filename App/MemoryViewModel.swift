import Combine
import Foundation
import JournalCore
import JournalGeneration

@MainActor
final class MemoryViewModel: ObservableObject {
    let store: PersonalMemoryStore

    init(store: PersonalMemoryStore) { self.store = store }
    @Published private(set) var enabled = false
    @Published private(set) var records: [PersonalMemory] = []
    @Published private(set) var busy = false
    @Published private(set) var building = false
    @Published private(set) var processedEntryCount = 0
    @Published private(set) var lastBuild: MemoryBuildReport?
    @Published private(set) var status =
        "Memory is stored privately on this Mac. Enable it to use it in answers."
    @Published private(set) var revision = UUID()
    @Published var sourceText: String?
    private var requestID = UUID()
    private var job: Task<Void, Never>?

    func reload() async throws {
        let snapshot = try await store.snapshot()
        let changed = enabled != snapshot.enabled || records != snapshot.records
        enabled = snapshot.enabled
        records = snapshot.records
        processedEntryCount = snapshot.processedEntryCount
        lastBuild = snapshot.lastBuild
        if changed { revision = UUID() }
    }
    var activeCount: Int { records.filter { $0.state == .active }.count }
    var suggestionCount: Int {
        records.filter { $0.state == .unreviewed || $0.state == .awaitingClarification }.count
    }
    var outdatedCount: Int { records.filter { $0.state == .outdated }.count }

    var emptyMessage: String {
        if building { return "Completed suggestions will appear here as the build progresses." }
        if let lastBuild, lastBuild.status != .completed {
            return
                "The last build did not finish. No memories are currently saved. Build suggestions will read all entries again."
        }
        if processedEntryCount > 0 {
            return
                "\(processedEntryCount) entry revisions have processing checkpoints, but no memories are saved. The local model can return no facts even when an entry contains useful information."
        }
        return
            "Build suggestions from synced entries, or add a memory yourself. Saved facts and suggestions will appear here."
    }

    private var completionMessage: String {
        guard let report = lastBuild else {
            return records.isEmpty
                ? "No saved memories. \(processedEntryCount) entries have processing checkpoints."
                : "\(records.count) saved memories loaded."
        }
        guard report.status == .completed else {
            return
                "Last build \(report.status == .running ? "interrupted" : report.status.rawValue): \(report.completedEntries) of \(report.totalEntries) entries checked; \(report.failedEntries ?? 0) extraction failures. Saved memories are shown below."
        }
        if report.totalEntries == 0 {
            return "No synced entries were available. Sync Apple Journal, then build suggestions."
        }
        if report.extractedEntries == 0, report.unchangedEntries > 0 {
            return
                "No changed entries to extract; \(report.unchangedEntries) skipped as unchanged, \(report.unavailableEntries) unavailable. \(records.count) saved memories. Build suggestions reads all entries again."
        }
        return
            "Build finished: \(report.extractedEntries) entries extracted, \(report.candidateCount) candidates returned, \(report.unavailableEntries) entries unavailable. \(records.count) saved memories; \(suggestionCount) automatically extracted."
    }

    func load() {
        run {
            try await self.reload()
            self.status = self.completionMessage
        }
    }
    func toggle(_ value: Bool) {
        run {
            try await self.store.setEnabled(value)
            try await self.reload()
            self.status =
                value
                ? "Memory enabled. Build suggestions to process synced entries."
                : "Memory disabled. Excluded from answers; automatic updates stopped."
        }
    }
    func save(id: UUID?, statement: String, category: MemoryCategory, date: Date) {
        run {
            try await self.store.save(id: id, statement: statement, category: category, asOf: date)
            try await self.reload()
            self.status = "Saved your memory. Your edits take precedence over extraction."
        }
    }
    func approve(_ id: UUID) { mutate { try await self.store.approve(id) } }
    func markOutdated(_ id: UUID) { mutate { try await self.store.markOutdated(id) } }
    func forget(_ id: UUID) { mutate { try await self.store.forget(id) } }
    func deleteAll() {
        mutate {
            try await self.store.deleteAll()
            self.status =
                "Deleted all memory and forget decisions; memory disabled. Reenable and build to recreate suggestions."
        }
    }
    func restore() { mutate { try await self.store.restoreSuggestions() } }
    private func mutate(_ operation: @escaping () async throws -> Void) {
        run {
            try await operation()
            try await self.reload()
        }
    }
    func update(modelURL: URL?, fullBuild: Bool = true) {
        guard enabled, !busy else { return }
        run {
            self.building = true
            defer { self.building = false }
            let request = self.requestID
            guard let modelURL else { throw GenerationError.modelUnavailable }
            let model = LocalAnswerModel()
            do {
                self.status =
                    "Loading \(GenerationModel.named(modelURL)?.displayName ?? modelURL.lastPathComponent) for memory extraction…"
                try await model.load(from: modelURL)
                try await PersonalMemoryUpdater(
                    store: self.store,
                    extractor: LocalMemoryExtractor(
                        model: model, configuration: await model.loadedConfiguration ?? .preferred)
                )
                .update(forceExtraction: fullBuild) { done, total in
                    Task { @MainActor in
                        guard self.requestID == request, self.busy else { return }
                        self.status = "Checked \(done) of \(total) entries…"
                        if done % 10 == 0 || done == total { try? await self.reload() }
                    }
                }
                await model.unload()
                try await self.reload()
                self.status = self.completionMessage
            } catch {
                await model.unload()
                throw error
            }
        }
    }
    func open(_ source: MemorySource) {
        run {
            let text = try await journalWorker {
                try JournalReader().openEntry(uuid: source.uuid, sourceID: source.sourceID).text
            }
            self.sourceText = text
        }
    }
    func cancel() { job?.cancel() }
    private func run(_ operation: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        requestID = UUID()
        job = Task {
            defer {
                busy = false
                requestID = UUID()
                job = nil
            }
            do { try await operation() } catch {
                try? await reload()
                status =
                    error is CancellationError
                    ? "Cancelled. Completed suggestions were saved. Build suggestions will read all entries again."
                    : "Memory operation failed. Check model, source access, and available storage. Completed entries remain saved."
            }
        }
    }
}
