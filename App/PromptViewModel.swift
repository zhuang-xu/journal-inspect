import Combine
import Foundation
import JournalCore
import JournalEmbeddings
import JournalGeneration

@MainActor
final class PromptViewModel: ObservableObject {
    @Published var input = "" {
        didSet {
            guard input != oldValue else { return }
            selectedSources = nil
            answer = nil
            status = nil
        }
    }
    private enum Preview {
        case draft(AugmentedPrompt)
        case fitted(AugmentedPrompt)
    }

    @Published private var selectedSources: Preview?
    var preview: AugmentedPrompt? {
        switch selectedSources {
        case .draft(let prompt), .fitted(let prompt): return prompt
        case nil: return nil
        }
    }
    @Published private(set) var answer: String?
    @Published private(set) var status: String?
    @Published private(set) var activity: PromptActivity?
    @Published private(set) var activityStartedAt: Date?

    @Published private(set) var modelURL = LocalAnswerModel.defaultModelURL

    var modelDisplayName: String {
        GenerationModel.named(modelURL)?.displayName ?? modelURL?.lastPathComponent
            ?? "Choose model"
    }

    @Published var cacheEnabled =
        UserDefaults.standard.object(forKey: "retrievalCacheEnabled") as? Bool ?? true
    {
        didSet {
            UserDefaults.standard.set(cacheEnabled, forKey: "retrievalCacheEnabled")
            selectedSources = nil
            answer = nil
            status = nil
        }
    }
    @Published private(set) var cacheSummary =
        "Passage vectors are private, sensitive derived data stored on this Mac."
    private let service: JournalPromptService

    init(service: JournalPromptService) { self.service = service }

    private var job: Task<Void, Never>?
    private var drainingJob: Task<Void, Never>?
    private var requestID = UUID()

    var busy: Bool { activity != nil }
    var canAsk: Bool { !busy && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func selectModel(_ url: URL) {
        resetResponse()
        modelURL = url
    }

    func clear() {
        resetResponse()
        input = ""
    }

    func cancel() {
        let maintaining = activity == .maintaining
        resetResponse()
        if maintaining {
            cacheSummary = "Cache operation cancelled."
        } else {
            status = "Cancelled."
        }
    }

    func resetResponse() {
        requestID = UUID()
        drainingJob = job ?? drainingJob
        job?.cancel()
        job = nil
        selectedSources = nil
        answer = nil
        activity = nil
        activityStartedAt = nil
        status = nil
    }

    func prepare() {
        guard canAsk else { return }
        let question = input
        run(activity: .retrieving) { [self] request in
            selectedSources = nil
            let draft = try await preparePrompt(question, request: request)
            selectedSources = .draft(draft)
        }
    }

    func ask() {
        guard canAsk, let modelURL else { return }
        let question = input
        let sources = selectedSources
        run(activity: .retrieving) { [self] request in
            selectedSources = nil
            let memoryRevision = try await service.memoryStore.selectionRevision()
            let prompt: AugmentedPrompt
            if case .draft(let draft) = sources,
                try await service.validateEvidence(in: draft.context)
            {
                let memory = try await service.refreshMemory(
                    for: question, cacheEnabled: cacheEnabled)
                prompt = AugmentedPrompt(
                    instructions: draft.instructions, userPrompt: question,
                    context: draft.context, memory: memory)
            } else {
                prompt = try await preparePrompt(question, request: request)
            }
            try Task.checkCancellation()
            guard request == requestID else { throw CancellationError() }
            try await generate(
                prompt, modelURL: modelURL, memoryRevision: memoryRevision,
                request: request)
        }
    }

    private func generate(
        _ prompt: AugmentedPrompt, modelURL: URL, memoryRevision: String, request: UUID
    ) async throws {
        activity = .verifyingModel
        let model = LocalAnswerModel()
        do {
            try await model.load(from: modelURL) { [weak self] stage in
                Task { @MainActor in
                    self?.updateLoadingStage(stage, request: request)
                }
            }
            guard request == requestID else { throw CancellationError() }
            guard
                try await service.memoryStore.validateProfile(
                    prompt.memory, revision: memoryRevision, sourceURL: service.source.sourceURL)
            else {
                throw PersonalMemoryError.staleUpdate
            }
            try Task.checkCancellation()
            guard request == requestID else { throw CancellationError() }
            activity = .processingPrompt
            let fitted = try await model.budgetedPrompt(prompt)
            guard try await service.validateEvidence(in: fitted.context) else {
                throw JournalCacheError.sourceChanged
            }
            try Task.checkCancellation()
            guard request == requestID else { throw CancellationError() }
            selectedSources = .fitted(fitted)
            for try await snapshot in model.streamAnswer(fitted) {
                try Task.checkCancellation()
                guard request == requestID else { throw CancellationError() }
                activity = .generating
                answer = JournalAnswerPresentation.readable(
                    snapshot, internalIDs: fitted.context.citationIDs)
            }
            await model.unload()
        } catch {
            await model.unload()
            throw error
        }
    }

    private func preparePrompt(_ question: String, request: UUID) async throws -> AugmentedPrompt {
        let prompt = try await service.prepare(
            question, cacheEnabled: cacheEnabled, progress: cacheProgress(request))
        guard request == requestID else { throw CancellationError() }
        await refreshCacheSummary(request: request)
        try Task.checkCancellation()
        guard request == requestID else { throw CancellationError() }
        return prompt
    }

    private func cacheProgress(_ request: UUID) -> @Sendable (JournalCacheProgress) -> Void {
        { [weak self] progress in
            Task { @MainActor in
                guard let self, request == self.requestID else { return }
                switch progress {
                case .checkingSource: self.cacheSummary = "Checking Apple Journal for changes…"
                case .updating(let completed, let total):
                    self.cacheSummary = "Updating retrieval cache: \(completed)/\(total) entries…"
                case .searching: self.cacheSummary = "Searching cached passages…"
                case .validating: self.cacheSummary = "Checking selected excerpts…"
                }
            }
        }
    }

    private func refreshCacheSummary(request: UUID) async {
        guard let value = await service.cache.status(), request == requestID else { return }
        cacheSummary =
            "\(value.ready)/\(value.total) entries · \(value.passages) passages · "
            + ByteCountFormatter.string(fromByteCount: value.bytes, countStyle: .file)
            + " · \(value.reused) reused, \(value.rebuilt) rebuilt · checked "
            + (value.checkedAt?.formatted(date: .omitted, time: .shortened) ?? "—")
    }

    func updateCache(rebuild: Bool = false) {
        guard !busy else { return }
        run(activity: .maintaining) { [self] request in
            try await updateCacheNow(rebuild: rebuild, request: request)
        }
    }

    // Explicit Sync uses the same reconciliation pipeline before optional memory work.
    func updateCacheAfterSync() async throws {
        guard cacheEnabled else { return }
        try await updateCacheNow(rebuild: false, request: requestID)
    }

    private func updateCacheNow(rebuild: Bool, request: UUID) async throws {
        selectedSources = nil
        try await service.updateCache(rebuild: rebuild, progress: cacheProgress(request))
        guard request == requestID else { throw CancellationError() }
        await refreshCacheSummary(request: request)
        try Task.checkCancellation()
        guard request == requestID else { throw CancellationError() }
    }

    func clearCache() {
        guard !busy else { return }
        run(activity: .maintaining) { [self] request in
            try await service.cache.clear()
            guard request == requestID else { throw CancellationError() }
            selectedSources = nil
            cacheSummary = "Retrieval cache cleared."
        }
    }

    private func updateLoadingStage(_ stage: ModelLoadStage, request: UUID) {
        guard request == requestID, let current = activity else { return }
        let next: PromptActivity
        switch stage {
        case .verifyingFile: next = .verifyingModel
        case .loadingWeights: next = .loadingModel
        case .preparingContext: next = .preparingModel
        }
        guard next.rawValue >= current.rawValue else { return }
        activity = next
    }

    private func run(
        activity: PromptActivity,
        _ operation: @escaping @MainActor (UUID) async throws -> Void
    ) {
        requestID = UUID()
        let request = requestID
        answer = nil
        self.activity = activity
        activityStartedAt = Date()
        status = nil
        let previous = drainingJob
        drainingJob = nil
        job = Task {
            if let previous { await previous.value }
            defer {
                if request == requestID {
                    self.activity = nil
                    activityStartedAt = nil
                    job = nil
                }
            }
            do {
                try Task.checkCancellation()
                guard request == requestID else { return }
                try await operation(request)
            } catch {
                guard request == requestID else { return }
                let message = Self.message(for: error)
                if activity == .maintaining {
                    cacheSummary = message
                } else {
                    status = answer == nil ? message : "Incomplete answer. " + message
                }
            }
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case is CancellationError:
            return "Cancelled."
        case EmbeddingError.modelUnavailable:
            return
                "Cannot find or load the local embedding model. Install Qwen3-Embedding-0.6B-Q8_0.gguf in the Models folder."
        case SemanticRetrievalError.emptyQuery:
            return "Enter a question to search your journal."
        case is EmbeddingError, is SemanticRetrievalError:
            return "Semantic search failed. Check the embedding model and available memory."
        case JournalCacheError.storageUnavailable, JournalCacheError.invalidCache:
            return
                "Retrieval cache unavailable. In Journal Settings, rebuild or turn off the retrieval cache and try again."
        case JournalCacheError.busy:
            return
                "Journal maintenance is finishing. Try again shortly."
        case JournalCacheError.sourceChanged, JournalCacheError.incompleteIndex:
            return
                "Journal changed during preparation or the index is incomplete. Try asking again."
        case PersonalMemoryError.staleUpdate:
            return "Your saved background changed while we were working. Try asking again."
        case JournalCacheError.staleUpdate:
            return "Journal information changed while we were working. Try asking again."
        case let error as JournalReaderError:
            return error.message
        case GenerationError.modelUnavailable:
            return
                "Cannot load the model. Select the supported Qwen3 4B Instruct or 0.6B baseline weights."
        case GenerationError.inputTooLong:
            return "Try a shorter question."
        case GenerationError.outputLimitReached:
            return "The answer exceeded its length limit. Try a more focused question."
        case is GenerationError:
            return "Local generation failed. Check the model file and available memory."
        default:
            return
                "Couldn’t answer this question. Check Journal access in Journal Settings and try again."
        }
    }
}
