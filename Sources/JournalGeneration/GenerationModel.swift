import Foundation

/// Explicitly supported, checksum-pinned local weights. No arbitrary GGUF is trusted by name.
public enum GenerationModel: String, CaseIterable, Sendable {
    case qwen4BInstruct = "qwen3-4b-instruct-2507-q5-k-m"
    case qwenSmall = "qwen3-0.6b-q8-0"

    public static let preferred = GenerationModel.qwen4BInstruct
    public var filename: String {
        switch self {
        case .qwen4BInstruct: return "Qwen_Qwen3-4B-Instruct-2507-Q5_K_M.gguf"
        case .qwenSmall: return "Qwen3-0.6B-Q8_0.gguf"
        }
    }
    public var sha256: String {
        switch self {
        case .qwen4BInstruct:
            return "66713ce35a58a82fe87642d4ec13425bf9b9a46800fff5c49a665ef5701439dc"
        case .qwenSmall: return "9465e63a22add5354d9bb4b99e90117043c7124007664907259bd16d043bb031"
        }
    }
    public var displayName: String {
        switch self {
        case .qwen4BInstruct: return "Qwen3 4B Instruct · Q5_K_M"
        case .qwenSmall: return "Qwen3 0.6B · Q8_0"
        }
    }
    var usesEmptyThinkingPrefix: Bool { self == .qwenSmall }
    public static func named(_ url: URL?) -> GenerationModel? {
        allCases.first { $0.filename == url?.lastPathComponent }
    }
}
