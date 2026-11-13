import Combine
import Foundation
import JournalCore

@MainActor
final class ReaderViewModel: ObservableObject {
    @Published private(set) var status = "Ready to index entries from Apple Journal."
    @Published private(set) var processed = 0
    @Published private(set) var entries: [JournalEntry] = []
    @Published private(set) var total = 0
    @Published private(set) var offset = 0
    @Published private(set) var nextOffset: Int?
    @Published var dateFilter = false
    @Published var start = Calendar.current.startOfDay(for: Date())
    @Published var end = Calendar.current.startOfDay(for: Date())
    @Published var showDeleted = false
    @Published var selection: String?
    @Published var uuidInput = ""
    @Published private(set) var loadedText: String?
    @Published private(set) var entryStatus = "Select an entry to load its current text."
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var lastRun = "No sync recorded."
    @Published private(set) var browsing = false

    @Published private(set) var isSyncing = false

    let memory: MemoryViewModel
    let prompt: PromptViewModel
    private var observations = Set<AnyCancellable>()

    init(memory: MemoryViewModel, prompt: PromptViewModel) {
        self.memory = memory
        self.prompt = prompt
        memory.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(
            in: &observations)
        prompt.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(
            in: &observations)
    }

    private static let pageSize = 50

    private var job: Task<Void, Never>?
    private var worker: Task<SyncResult, Error>?
    private var textWorker: Task<LoadedJournalEntry, Error>?
    private var pageRequest = UUID()
    private var entryRequest = UUID()
    private var syncRequest = UUID()
    private var pageJob: Task<Void, Never>?
    private var pageWorker: Task<(EntryPage, JournalSyncStatus), Error>?

    func clearEntry() {
        entryRequest = UUID()
        textWorker?.cancel()
        textWorker = nil
        loadedText = nil
        entryStatus = "Select an entry to load its current text."
    }

    func openEntry(_ uuid: String, sourceID: String? = nil) {
        guard !isSyncing else { return }
        clearEntry()
        let request = entryRequest
        entryStatus = "Loading current text from Apple Journal…"
        let task = Task.detached { try JournalReader().openEntry(uuid: uuid, sourceID: sourceID) }
        textWorker = task
        Task { @MainActor in
            do {
                let entry = try await task.value
                guard request == entryRequest else { return }
                loadedText = entry.text
                entryStatus = "\(entry.uuid) • Loaded from Apple Journal"
            } catch {
                guard request == entryRequest else { return }
                entryStatus =
                    (error as? JournalReaderError)?.message ?? "Entry load cancelled or failed."
            }
            if request == entryRequest { textWorker = nil }
        }
    }

    func reloadPage() {
        guard !isSyncing else { return }
        pageJob?.cancel()
        pageWorker?.cancel()
        pageRequest = UUID()
        let request = pageRequest
        let pageOffset = offset
        let lower = dateFilter ? Calendar.current.startOfDay(for: start) : nil
        let upper =
            dateFilter
            ? Calendar.current.date(
                byAdding: .day, value: 1,
                to: Calendar.current.startOfDay(for: end)) : nil
        let deleted = showDeleted
        browsing = true
        selection = nil
        clearEntry()
        let task = Task.detached {
            try Task.checkCancellation()
            let store = try JournalMetadataStore(directory: JournalMetadataStore.defaultDirectory)
            let result = await (
                try store.browse(
                    start: lower, end: upper, limit: Self.pageSize, offset: pageOffset,
                    includeDeleted: deleted), try store.syncStatus()
            )
            try Task.checkCancellation()
            return result
        }
        pageWorker = task
        pageJob = Task { @MainActor in
            defer {
                if request == pageRequest {
                    browsing = false
                    pageWorker = nil
                    pageJob = nil
                }
            }
            do {
                let (page, history) = try await task.value
                guard request == pageRequest else { return }
                entries = page.entries
                total = page.total
                nextOffset = page.nextOffset
                lastSuccess = history.lastSuccessfulSync
                lastRun = "No sync recorded."
                if history.state == "succeeded" {
                    lastRun = "Last sync: \(history.changed) changed, \(history.removed) removed."
                } else if history.errorCode == "cancelled" {
                    lastRun = "Last sync cancelled; previous index preserved."
                } else if history.errorCode == "permission_denied" {
                    lastRun = "Last sync failed: Journal access denied."
                } else if history.state != nil {
                    lastRun = "Last sync failed; previous index preserved."
                }
            } catch {
                guard request == pageRequest else { return }
                entries = []
                total = 0
                nextOffset = nil
                status = (error as? JournalReaderError)?.message ?? "Cannot read metadata index."
            }
        }
    }

    func synchronize() {
        guard !isSyncing, !memory.busy, !prompt.busy else { return }
        prompt.clear()
        isSyncing = true
        syncRequest = UUID()
        let request = syncRequest
        pageRequest = UUID()
        pageJob?.cancel()
        pageWorker?.cancel()
        browsing = false
        selection = nil
        processed = 0
        clearEntry()
        status = "Reading Apple Journal and updating the local metadata index…"
        let task = Task.detached {
            try JournalReader().synchronize { count in
                Task { @MainActor in
                    guard request == self.syncRequest, self.isSyncing else { return }
                    self.processed = count
                }
            }
        }
        worker = task
        job = Task { @MainActor in
            defer {
                if request == syncRequest {
                    isSyncing = false
                    job = nil
                    worker = nil
                    offset = 0
                    reloadPage()
                }
            }
            do {
                let result = try await task.value
                guard request == syncRequest else { return }
                status =
                    "Indexed \(result.seen) entries. \(result.changed) changed, \(result.removed) removed."
                do {
                    try await prompt.updateCacheAfterSync()
                } catch {
                    guard request == syncRequest else { return }
                    status +=
                        Task.isCancelled
                        ? " Follow-up refresh cancelled."
                        : " Retrieval cache update failed. Ask a question to retry."
                }
                guard !Task.isCancelled, request == syncRequest else { return }
                memory.update(modelURL: prompt.modelURL, fullBuild: false)
            } catch is CancellationError {
                guard request == syncRequest else { return }
                status = "Sync cancelled. Previous index preserved."
            } catch {
                guard request == syncRequest else { return }
                status =
                    (error as? JournalReaderError)?.message
                    ?? "Sync failed; private diagnostics suppressed."
            }
        }
    }

    func selectEntry(_ id: String?) {
        guard let entry = entries.first(where: { $0.id == id }) else {
            clearEntry()
            return
        }
        uuidInput = entry.uuid
        openEntry(entry.uuid, sourceID: entry.sourceID)
    }

    func applyFilters() {
        guard !browsing, !isSyncing else { return }
        offset = 0
        reloadPage()
    }

    func previousPage() {
        guard offset > 0, !browsing, !isSyncing else { return }
        offset = max(0, offset - Self.pageSize)
        reloadPage()
    }

    func nextPage() {
        guard let nextOffset, !browsing, !isSyncing else { return }
        offset = nextOffset
        reloadPage()
    }

    func cancelSync() {
        worker?.cancel()
        job?.cancel()
    }

    func stop() {
        memory.cancel()
        prompt.clear()
        syncRequest = UUID()
        pageRequest = UUID()
        worker?.cancel()
        job?.cancel()
        pageWorker?.cancel()
        pageJob?.cancel()
        worker = nil
        job = nil
        pageWorker = nil
        pageJob = nil
        isSyncing = false
        browsing = false
        clearEntry()
    }
}
