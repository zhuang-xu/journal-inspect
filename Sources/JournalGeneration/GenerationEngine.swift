import Foundation
import JournalLlama
import llama

/// All access stays on LocalAnswerModel's executor. Native allocations never escape this owner.
final class GenerationEngine {
    private static let contextSize = 8192
    private static let batchSize = 512
    private static let maximumInputBytes = 64 * 1024

    enum OutputBudget: Int {
        case journalAnswer = 1536
        case memoryExtraction = 768
    }

    private let model: OpaquePointer
    private let context: OpaquePointer

    init(url: URL, onPreparingContext: () -> Void = {}) throws {
        LlamaRuntime.initialize()
        var parameters = llama_model_default_params()
        parameters.n_gpu_layers = 99
        guard let model = llama_model_load_from_file(url.path, parameters) else {
            throw GenerationError.modelUnavailable
        }
        onPreparingContext()
        var contextParameters = llama_context_default_params()
        contextParameters.n_ctx = UInt32(Self.contextSize)
        contextParameters.n_batch = UInt32(Self.batchSize)
        contextParameters.n_ubatch = UInt32(Self.batchSize)
        contextParameters.n_seq_max = 1
        guard let context = llama_init_from_model(model, contextParameters) else {
            llama_model_free(model)
            throw GenerationError.contextUnavailable
        }
        self.model = model
        self.context = context
    }

    deinit {
        llama_free(context)
        llama_model_free(model)
    }

    func generate(
        _ prompt: String, budget: OutputBudget, onUpdate: (String) -> Void = { _ in }
    ) throws -> String {
        let tokens = try tokenize(prompt, budget: budget)
        llama_memory_clear(llama_get_memory(context), true)
        defer { llama_memory_clear(llama_get_memory(context), true) }

        for offset in stride(from: 0, to: tokens.count, by: Self.batchSize) {
            try decode(Array(tokens[offset..<min(offset + Self.batchSize, tokens.count)]))
        }
        guard let sampler = llama_sampler_init_greedy() else {
            throw GenerationError.inferenceFailed
        }
        defer { llama_sampler_free(sampler) }

        var text = AnswerTextBuffer()
        let vocabulary = llama_model_get_vocab(model)
        for _ in 0..<budget.rawValue {
            try Task.checkCancellation()
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocabulary, token) {
                let answer = text.completedText
                guard !answer.isEmpty else { throw GenerationError.emptyAnswer }
                return answer
            }
            if let snapshot = text.append(try piece(for: token)) {
                onUpdate(snapshot)
            }
            try decode([token])
        }
        // The stream retains partial text; its terminal error marks the answer as incomplete.
        throw GenerationError.outputLimitReached
    }

    func tokenize(_ text: String, budget: OutputBudget) throws -> [llama_token] {
        guard text.utf8.count <= Self.maximumInputBytes else { throw GenerationError.inputTooLong }
        let capacity = Int(llama_n_ctx(context)) - budget.rawValue
        var tokens = [llama_token](repeating: 0, count: capacity)
        let count = text.withCString {
            llama_tokenize(
                llama_model_get_vocab(model), $0, Int32(text.utf8.count),
                &tokens, Int32(capacity), true, true)
        }
        guard count > 0, count <= capacity else { throw GenerationError.inputTooLong }
        return Array(tokens.prefix(Int(count)))
    }

    private func decode(_ tokens: [llama_token]) throws {
        try Task.checkCancellation()
        var tokens = tokens
        let result = tokens.withUnsafeMutableBufferPointer {
            llama_decode(context, llama_batch_get_one($0.baseAddress, Int32($0.count)))
        }
        try Task.checkCancellation()
        guard result == 0 else { throw GenerationError.inferenceFailed }
    }

    private func piece(for token: llama_token) throws -> [UInt8] {
        let vocabulary = llama_model_get_vocab(model)
        var buffer = [CChar](repeating: 0, count: 256)
        var count = llama_token_to_piece(vocabulary, token, &buffer, Int32(buffer.count), 0, false)
        if count < 0 {
            buffer = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(vocabulary, token, &buffer, Int32(buffer.count), 0, false)
        }
        guard count >= 0 else { throw GenerationError.inferenceFailed }
        return buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }
    }
}
