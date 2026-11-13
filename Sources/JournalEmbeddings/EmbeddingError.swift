public enum EmbeddingError: Error {
    case modelUnavailable
    case contextUnavailable
    case emptyInput
    case inputTooLong
    case inferenceFailed
    case invalidVector
}
