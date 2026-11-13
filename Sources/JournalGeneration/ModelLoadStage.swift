/// Coarse native loading stages. These are real transitions, not percentage estimates.
public enum ModelLoadStage: Sendable, Equatable {
    case verifyingFile
    case loadingWeights
    case preparingContext
}
