import Foundation
import JournalCore

/// Actor-isolated native generation. No server, network transport, or prompt/answer persistence.
public actor LocalAnswerModel {
    private var engine: GenerationEngine?
    public private(set) var loadedConfiguration: GenerationModel?

    public init() {}

    public func load(
        from url: URL, onStage: @Sendable (ModelLoadStage) -> Void = { _ in }
    ) throws {
        try Task.checkCancellation()
        engine = nil
        loadedConfiguration = nil
        onStage(.verifyingFile)
        let configuration = try ModelVerification.verify(url)
        try Task.checkCancellation()
        onStage(.loadingWeights)
        let loaded = try GenerationEngine(url: url) { onStage(.preparingContext) }
        try Task.checkCancellation()
        engine = loaded
        loadedConfiguration = configuration
    }

    public func unload() {
        engine = nil
        loadedConfiguration = nil
    }

    public func answer(_ prompt: AugmentedPrompt) throws -> String {
        try answer(prompt, budget: .journalAnswer)
    }

    func answer(
        _ prompt: AugmentedPrompt, budget: GenerationEngine.OutputBudget,
        onUpdate: (String) -> Void = { _ in }
    ) throws -> String {
        try Task.checkCancellation()
        guard let engine else { throw GenerationError.modelUnavailable }
        return try engine.generate(
            QwenPromptFormatter.format(
                budgetedPrompt(prompt, budget: budget),
                configuration: loadedConfiguration ?? .preferred),
            budget: budget, onUpdate: onUpdate)
    }

    /// Measure with the pinned model tokenizer and reserve room for a journal answer.
    /// Cap memory at 900 tokens and trim it before original evidence when fitting the full request.
    public func budgetedPrompt(_ prompt: AugmentedPrompt) throws -> AugmentedPrompt {
        try budgetedPrompt(prompt, budget: .journalAnswer)
    }

    private func budgetedPrompt(
        _ prompt: AugmentedPrompt, budget: GenerationEngine.OutputBudget
    ) throws -> AugmentedPrompt {
        guard let engine else { throw GenerationError.modelUnavailable }
        var memories =
            try JSONSerialization.jsonObject(with: Data(prompt.memory.text.utf8))
            as? [[String: Any]] ?? []
        var evidence =
            try JSONSerialization.jsonObject(with: Data(prompt.context.text.utf8))
            as? [[String: Any]] ?? []
        var omittedMemory = prompt.memory.omittedCount
        var omittedEvidence = prompt.context.omittedCount
        func json(_ records: [[String: Any]]) throws -> String {
            String(
                decoding: try JSONSerialization.data(
                    withJSONObject: records, options: [.sortedKeys]), as: UTF8.self)
        }
        while !memories.isEmpty {
            let count = try? tokenCount(
                QwenPromptFormatter.modelData(json(memories)), budget: budget)
            if let count, count <= 900 { break }
            memories.removeLast()
            omittedMemory += 1
        }
        while true {
            try Task.checkCancellation()
            let fitted = AugmentedPrompt(
                instructions: prompt.instructions, userPrompt: prompt.userPrompt,
                context: JournalContext(
                    text: try json(evidence),
                    citationIDs: evidence.compactMap { $0["citation"] as? String },
                    omittedCount: omittedEvidence,
                    references: prompt.context.references.filter { ref in
                        evidence.contains {
                            ($0["citation"] as? String) == ref.sourceID + ":" + ref.uuid
                        }
                    }),
                memory: PersonalMemoryProfile(text: try json(memories), omittedCount: omittedMemory)
            )
            do {
                _ = try engine.tokenize(
                    QwenPromptFormatter.format(
                        fitted, configuration: loadedConfiguration ?? .preferred),
                    budget: budget)
                return fitted
            } catch GenerationError.inputTooLong {
                if !memories.isEmpty {
                    memories.removeLast()
                    omittedMemory += 1
                } else if !evidence.isEmpty {
                    evidence.removeLast()
                    omittedEvidence += 1
                } else {
                    throw GenerationError.inputTooLong
                }
            }
        }
    }

    /// Uses the already-loaded tokenizer without allocating a second native model/context.
    func tokenCount(
        _ text: String, budget: GenerationEngine.OutputBudget = .journalAnswer
    ) throws -> Int {
        guard let engine else { throw GenerationError.modelUnavailable }
        return try engine.tokenize(text, budget: budget).count
    }

    public nonisolated func streamAnswer(_ prompt: AugmentedPrompt) -> AsyncThrowingStream<
        String, Error
    > {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let worker = Task {
                do {
                    try await produceAnswer(prompt, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }

    /// No suspension while the native engine is active, preserving actor resource isolation.
    private func produceAnswer(
        _ prompt: AugmentedPrompt,
        into continuation: AsyncThrowingStream<String, Error>.Continuation
    ) throws {
        let answer = try answer(prompt, budget: .journalAnswer) {
            snapshot in
            continuation.yield(snapshot)
        }
        try Task.checkCancellation()
        continuation.yield(answer)
    }
}
