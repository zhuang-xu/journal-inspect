public enum GenerationError: Error {
    case modelUnavailable
    case contextUnavailable
    case inputTooLong
    case inferenceFailed
    case emptyAnswer
    case outputLimitReached
}
