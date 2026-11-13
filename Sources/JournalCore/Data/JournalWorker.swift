import Foundation

/// Runs blocking Journal work off the caller's actor and forwards cancellation to the worker.
/// Database handles must be created and consumed inside the operation.
public func journalWorker<T: Sendable>(
    _ operation: @escaping @Sendable () throws -> T
) async throws -> T {
    try Task.checkCancellation()
    let worker = Task.detached {
        try Task.checkCancellation()
        let result = try operation()
        try Task.checkCancellation()
        return result
    }
    return try await withTaskCancellationHandler {
        let result = try await worker.value
        try Task.checkCancellation()
        return result
    } onCancel: {
        worker.cancel()
    }
}
