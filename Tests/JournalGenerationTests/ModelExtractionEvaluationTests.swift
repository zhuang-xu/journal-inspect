import Foundation
import JournalCore
import XCTest

@testable import JournalGeneration

/// A small labeled comparison, using model inference only and synthetic text.
final class ModelExtractionEvaluationTests: XCTestCase {
    struct Fixture {
        let text: String
        let category: MemoryCategory?
        let anchor: String
    }
    let fixtures: [Fixture] = [
        Fixture(
            text: "I am preparing for backend engineering interviews.", category: .goal,
            anchor: "interview"),
        Fixture(text: "今年的目标是拿到后端开发岗位的录用通知。最近每晚都在复习数据库和算法。", category: .goal, anchor: "后端"),
        Fixture(
            text: "I prefer written feedback because it gives me time to reflect.",
            category: .preference, anchor: "written"),
        Fixture(text: "相比打电话，更喜欢用文字沟通，这样有时间组织想法。", category: .preference, anchor: "文字"),
        Fixture(
            text: "My partner is named Alex. We live together in Shanghai.",
            category: .relationship, anchor: "Alex"),
        Fixture(text: "小林是我的伴侣，我们一起住在上海。", category: .relationship, anchor: "小林"),
        Fixture(
            text: "I work as a backend engineer at a small software company.",
            category: .circumstance, anchor: "engineer"),
        Fixture(text: "现在住在杭州，在一家小公司做后端开发。", category: .circumstance, anchor: "杭州"),
        Fixture(
            text: "I used to like coffee, but now I prefer tea and avoid coffee.",
            category: .preference, anchor: "tea"),
        Fixture(text: "今年打算考研究生，每天晚上都为这个目标复习。", category: .goal, anchor: "研究生"),
        Fixture(
            text: "It rained this afternoon. I saw a red umbrella on the bus.", category: nil,
            anchor: ""),
        Fixture(text: "今天有点紧张，吃了一碗面，然后散步回家。", category: nil, anchor: ""),
    ]
    func testCompareRawModelExtraction() async throws {
        guard ProcessInfo.processInfo.environment["JOURNAL_MODEL_EVALUATION"] == "1" else {
            throw XCTSkip("Set JOURNAL_MODEL_EVALUATION=1 for the local-model comparison.")
        }
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        var results: [String: [String: Double]] = [:]
        var details: [[String: Any]] = []
        for configuration in [GenerationModel.qwenSmall, .qwen4BInstruct] {
            let model = LocalAnswerModel()
            let start = Date()
            try await model.load(
                from: checkout.appendingPathComponent("Models/" + configuration.filename))
            let loaded = Date()
            let extractor = LocalMemoryExtractor(model: model, configuration: configuration)
            var hits = 0
            var valid = 0
            var emptyNegatives = 0
            var candidatesTotal = 0
            for (index, fixture) in fixtures.enumerated() {
                do {
                    let candidates = try await extractor.extract(from: fixture.text)
                    candidatesTotal += candidates.count
                    details.append([
                        "model": configuration.rawValue, "fixture": index,
                        "input": fixture.text,
                        "candidates": candidates.map {
                            [
                                "statement": $0.statement, "category": $0.category.rawValue,
                                "quote": $0.quote,
                            ]
                        },
                    ])
                    if candidates.allSatisfy({
                        !$0.quote.isEmpty
                            && fixture.text.range(of: $0.quote, options: .literal) != nil
                    }) {
                        valid += 1
                    }
                    if let category = fixture.category {
                        if candidates.contains(where: {
                            $0.category == category
                                && ($0.statement.localizedCaseInsensitiveContains(fixture.anchor)
                                    || $0.quote.localizedCaseInsensitiveContains(fixture.anchor))
                        }) {
                            hits += 1
                        }
                    } else if candidates.isEmpty {
                        emptyNegatives += 1
                    }
                } catch is CancellationError {
                    await model.unload()
                    throw CancellationError()
                } catch {
                    // Synthetic fixtures only: retain details for manual grounding review.
                    let raw = try? await model.answer(
                        LocalMemoryExtractor.extractionPrompt(fixture.text),
                        budget: .memoryExtraction)
                    details.append([
                        "model": configuration.rawValue, "fixture": index,
                        "input": fixture.text, "error": String(describing: error),
                        "synthetic_raw_response": raw ?? "",
                    ])
                }
            }
            let elapsed = Date().timeIntervalSince(loaded)
            await model.unload()
            results[configuration.rawValue] = [
                "positive_hits": Double(hits), "positive_total": 10,
                "valid_cases": Double(valid), "negative_empty": Double(emptyNegatives),
                "negative_total": 2, "candidates": Double(candidatesTotal),
                "load_seconds": loaded.timeIntervalSince(start), "inference_seconds": elapsed,
            ]
        }
        let data = try JSONSerialization.data(
            withJSONObject: results, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: URL(fileURLWithPath: "/tmp/journal-model-evaluation.json"))
        let detailData = try JSONSerialization.data(
            withJSONObject: details, options: [.sortedKeys, .prettyPrinted])
        try detailData.write(to: URL(fileURLWithPath: "/tmp/journal-model-evaluation-details.json"))
        print("Synthetic model evaluation: " + String(decoding: data, as: UTF8.self))
        let baseline = try XCTUnwrap(results[GenerationModel.qwenSmall.rawValue])
        let larger = try XCTUnwrap(results[GenerationModel.qwen4BInstruct.rawValue])
        XCTAssertGreaterThan(larger["positive_hits"]!, baseline["positive_hits"]!)
        XCTAssertGreaterThanOrEqual(larger["positive_hits"]!, 8)
        XCTAssertEqual(larger["valid_cases"], 12)
        XCTAssertEqual(larger["negative_empty"], 2)
    }
}
