import Foundation
import XCTest

@testable import JournalEmbeddings

final class EmbeddingLifecycleTests: XCTestCase {
    func testUnloadedModelRejectsInference() async throws {
        let model = LocalEmbeddingModel()
        do {
            _ = try await model.embedDocument("Synthetic text")
            XCTFail("Expected unloaded model error")
        } catch EmbeddingError.modelUnavailable {}
        await model.unload()
    }
}
