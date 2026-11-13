import Foundation
import XCTest

@testable import JournalGeneration

final class LocalModelLocationTests: XCTestCase {
    func testDiscoverySkipsMissingWeightsAndUsesDirectoryPriority() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("preferred")
        let second = root.appendingPathComponent("fallback")
        for directory in [first, second] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
        XCTAssertNil(LocalAnswerModel.findModel(in: [first, second]))

        // Discovery only locates files. Model loading separately verifies the pinned checksum.
        let fallback = second.appendingPathComponent(GenerationModel.preferred.filename)
        try Data("synthetic".utf8).write(to: fallback)
        XCTAssertEqual(LocalAnswerModel.findModel(in: [first, second]), fallback)

        let preferred = first.appendingPathComponent(GenerationModel.preferred.filename)
        try Data("synthetic".utf8).write(to: preferred)
        XCTAssertEqual(LocalAnswerModel.findModel(in: [first, second]), preferred)
    }

    func testLargerModelWinsOverBaselineInEarlierDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("private")
        let second = root.appendingPathComponent("checkout")
        for dir in [first, second] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let baseline = first.appendingPathComponent(GenerationModel.qwenSmall.filename)
        let larger = second.appendingPathComponent(GenerationModel.qwen4BInstruct.filename)
        try Data().write(to: baseline)
        XCTAssertEqual(LocalAnswerModel.findModel(in: [first, second]), baseline)
        try Data().write(to: larger)
        XCTAssertEqual(LocalAnswerModel.findModel(in: [first, second]), larger)
    }

    func testDiscoveryRejectsEmbeddingWeightsAndDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("Qwen3-Embedding-0.6B-Q8_0.gguf"))
        XCTAssertNil(LocalAnswerModel.findModel(in: [root]))

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(GenerationModel.preferred.filename),
            withIntermediateDirectories: false)
        XCTAssertNil(LocalAnswerModel.findModel(in: [root]))
    }
}
