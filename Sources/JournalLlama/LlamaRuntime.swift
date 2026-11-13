import llama

/// Shared initialization for embedding and generation engines in the same process.
public enum LlamaRuntime {
    private static let initialization: Void = {
        llama_log_set({ _, _, _ in }, nil)
        ggml_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()

    public static func initialize() {
        _ = initialization
    }
}
