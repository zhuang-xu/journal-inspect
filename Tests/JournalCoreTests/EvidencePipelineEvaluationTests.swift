import Foundation
import JournalEmbeddings
import XCTest

@testable import JournalCore
@testable import JournalGeneration

final class EvidencePipelineEvaluationTests: XCTestCase {
    func testNativeEvidencePipelineDevelopmentV1() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let embeddingPath = environment["JOURNAL_EMBEDDING_MODEL"],
            let answerPath = environment["JOURNAL_GENERATION_MODEL"]
        else {
            throw XCTSkip("Set both JOURNAL_EMBEDDING_MODEL and JOURNAL_GENERATION_MODEL.")
        }

        let fixture = try JournalTestFixture()
        try EvidenceDevelopmentV1.populate(fixture)
        let cases = EvidenceDevelopmentV1.cases
        let embeddings = LocalEmbeddingModel()
        let prepared: [PreparedCase]
        try await embeddings.load(from: URL(fileURLWithPath: embeddingPath))
        do {
            prepared = try await prepare(cases, fixture: fixture, embeddings: embeddings)
            await embeddings.unload()
        } catch {
            await embeddings.unload()
            throw error
        }

        let model = LocalAnswerModel()
        try await model.load(from: URL(fileURLWithPath: answerPath))
        do {
            let loadedConfiguration = await model.loadedConfiguration
            let configuration = try XCTUnwrap(loadedConfiguration)
            for item in prepared {
                try await evaluate(item, model: model, configuration: configuration)
            }
            await model.unload()
        } catch {
            await model.unload()
            throw error
        }
    }

    private struct PreparedCase {
        let probe: EvidenceDevelopmentV1.Probe
        let candidates: [JournalEvidence]
        let draft: AugmentedPrompt
        let prepareMilliseconds: Int
    }

    private func prepare(
        _ cases: [EvidenceDevelopmentV1.Probe], fixture: JournalTestFixture,
        embeddings: LocalEmbeddingModel
    ) async throws -> [PreparedCase] {
        let cache = JournalEmbeddingCache(
            directory: fixture.directory.appendingPathComponent("cache"))
        let source = OnDemandJournalSource(
            sourceURL: fixture.sourceURL, indexDirectory: fixture.indexDirectory)
        let recording = RecordingEvidenceRetriever(
            CachedJournalRetriever(cache: cache, embeddings: embeddings, source: source))
        let augmenter = JournalPromptAugmenter(retriever: recording)
        let clock = ContinuousClock()
        var prepared: [PreparedCase] = []
        for probe in cases {
            let start = clock.now
            let draft = try await augmenter.augment(probe.question)
            let elapsed = milliseconds(start.duration(to: clock.now))
            let candidates = await recording.candidates
            XCTAssertEqual(candidates.count, 25, probe.id)
            let references = candidates.compactMap(\.reference)
            XCTAssertEqual(references.count, candidates.count, probe.id)
            let valid = try await cache.validate(references, sourceURL: fixture.sourceURL)
            XCTAssertTrue(valid, probe.id)
            prepared.append(
                PreparedCase(
                    probe: probe, candidates: candidates, draft: draft, prepareMilliseconds: elapsed
                ))
        }
        return prepared
    }

    private func evaluate(
        _ item: PreparedCase, model: LocalAnswerModel, configuration: GenerationModel
    ) async throws {
        let probe = item.probe
        let answerProbe = AugmentedPrompt(
            instructions: item.draft.instructions,
            userPrompt: item.draft.userPrompt
                + "\nReply with just one word in English: Yes, No, or Unknown. Do not explain.",
            context: item.draft.context, memory: item.draft.memory)
        let fitted = try await model.budgetedPrompt(answerProbe)
        let tokens = try await model.tokenCount(
            QwenPromptFormatter.format(fitted, configuration: configuration))
        let draftIDs = Set(item.draft.context.citationIDs)
        let fittedIDs = Set(fitted.context.citationIDs)
        let drafts = item.candidates.filter { draftIDs.contains($0.id) }
        let final = item.candidates.filter { fittedIDs.contains($0.id) }
        let supportingDates = Set(probe.anchors.map { EvidenceDevelopmentV1.date($0.entry) })
        let candidateEntries = supportingDates.intersection(item.candidates.compactMap(\.date))
            .count
        struct FittedExcerpt: Decodable {
            let citation: String
            let text: String
        }
        let records = try JSONDecoder().decode(
            [FittedExcerpt].self, from: Data(fitted.context.text.utf8))
        XCTAssertEqual(records.map(\.citation), fitted.context.citationIDs, probe.id)
        for record in records {
            let excerpt = try XCTUnwrap(final.first { $0.id == record.citation }, probe.id)
            XCTAssertTrue(record.text.utf8.elementsEqual(excerpt.text.utf8), probe.id)
        }
        func hits(_ excerpts: [JournalEvidence]) -> Int {
            probe.anchors.count { anchor in
                excerpts.contains {
                    $0.date == EvidenceDevelopmentV1.date(anchor.entry)
                        && Data($0.text.utf8).range(of: Data(anchor.exactText.utf8)) != nil
                }
            }
        }
        let candidateHits = hits(item.candidates)
        let draftHits = hits(drafts)
        let finalHits = hits(final)
        let expected = probe.anchors.count
        XCTAssertTrue(fittedIDs.isSubset(of: draftIDs), probe.id)
        XCTAssertLessThanOrEqual(finalHits, draftHits, probe.id)
        XCTAssertLessThanOrEqual(draftHits, candidateHits, probe.id)

        let start = ContinuousClock.now
        let answer = try await model.answer(fitted)
        let generateMilliseconds = milliseconds(start.duration(to: .now))
        let normalized = answer.lowercased().trimmingCharacters(
            in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let observed = EvidenceDevelopmentV1.Verdict(rawValue: normalized)
        let outcome: String
        switch observed {
        case .none:
            outcome = "ungraded-format"
        case .unknown:
            outcome = probe.expected == .unknown ? "correct-abstention" : "abstained"
        case .yes, .no:
            if observed != probe.expected {
                outcome = "unsupported-verdict"
            } else {
                outcome = finalHits == expected ? "grounded-verdict" : "missing-anchor-verdict"
            }
        }
        // This is a measurement run. Keep outcomes separate from structural test assertions.
        print(
            "Evidence development-v1 \(probe.id) entry=\(candidateEntries)/\(supportingDates.count)"
                + " candidate=\(candidateHits)/\(expected) draft=\(draftHits)/\(expected)"
                + " final=\(finalHits)/\(expected) excerpts=\(final.count) tokens=\(tokens)"
                + " prepare_ms=\(item.prepareMilliseconds) generate_ms=\(generateMilliseconds)"
                + " outcome=\(outcome)")
    }

    private func milliseconds(_ duration: Duration) -> Int {
        Int(
            duration.components.seconds * 1000 + duration.components.attoseconds
                / 1_000_000_000_000_000)
    }

}

private actor RecordingEvidenceRetriever: JournalRetrieving {
    let retriever: CachedJournalRetriever
    private(set) var candidates: [JournalEvidence] = []

    init(_ retriever: CachedJournalRetriever) { self.retriever = retriever }

    func retrieve(_ request: RetrievalRequest) async throws -> [JournalEvidence] {
        let result = try await retriever.retrieve(request)
        candidates = result
        return result
    }
}

private enum EvidenceDevelopmentV1 {
    enum Verdict: String {
        case yes, no, unknown
    }

    struct Anchor {
        let entry: Int
        let exactText: String

        init(_ entry: Int, _ exactText: String) {
            self.entry = entry
            self.exactText = exactText
        }
    }

    struct Probe {
        let id: String
        let question: String
        let expected: Verdict
        let anchors: [Anchor]

        init(_ id: String, _ question: String, _ expected: Verdict, _ anchors: [Anchor] = []) {
            self.id = id
            self.question = question
            self.expected = expected
            self.anchors = anchors
        }
    }

    static let cases: [Probe] = [
        Probe(
            "lookup-en", "Did I bake a lemon tart for the picnic?", .yes,
            [
                Anchor(1, "I baked a lemon tart for the picnic.")
            ]),
        Probe(
            "lookup-zh", "周二晚饭我吃的是番茄鸡蛋面吗？", .yes,
            [
                Anchor(2, "周二晚饭我吃了番茄鸡蛋面。")
            ]),
        Probe(
            "negation-en", "Was I worried about the second interview?", .no,
            [
                Anchor(4, "I was not worried about the second interview.")
            ]),
        Probe(
            "negation-zh", "我在牙医预约前感到紧张吗？", .no,
            [
                Anchor(5, "去看牙医之前我一点也不紧张。")
            ]),
        Probe("related-en", "Did I get the job after my second interview?", .unknown),
        Probe("related-zh", "我买的跑鞋是蓝色的吗？", .unknown),
        Probe(
            "attribution-en", "Did I describe myself as anxious before the school concert?", .no,
            [
                Anchor(7, "Mina said she was anxious before the school concert."),
                Anchor(7, "I told her I felt relaxed."),
            ]),
        Probe(
            "attribution-zh", "是我说自己害怕第一次坐船吗？", .no,
            [
                Anchor(8, "小林说她第一次坐船很害怕。"),
                Anchor(8, "我说我一点也不怕。"),
            ]),
        Probe(
            "comparison-en", "Did my worry decrease from the first job interview to the second?",
            .yes,
            [
                Anchor(3, "I was worried before the first job interview."),
                Anchor(4, "I was not worried about the second interview."),
            ]),
        Probe(
            "comparison-zh", "和十月上旬比，十月下旬我入睡更早了吗？", .yes,
            [
                Anchor(9, "十月上旬，我通常凌晨一点才睡着。"),
                Anchor(23, "十月下旬，我通常晚上十一点就睡着了。"),
            ]),
        Probe("missing-side-en", "Was my commute shorter in November than in October?", .unknown),
        Probe(
            "split-en", "Did I find my missing passport in the attic?", .yes,
            [
                Anchor(12, "I went to the attic to look for my missing passport."),
                Anchor(12, "It turned up there inside an old map case."),
            ]),
        Probe(
            "split-zh", "绿色笔记本是在旧书店的窗台上找到的吗？", .yes,
            [
                Anchor(13, "我去旧书店找丢失的绿色笔记本。"),
                Anchor(13, "最后我在那儿的窗台上找到了它。"),
            ]),
        Probe(
            "conflict-en", "Do both accounts agree that I took the train on October 14?", .no,
            [
                Anchor(14, "I took the train to the lake on October 14."),
                Anchor(15, "I drove to the lake on October 14 and did not take the train."),
            ]),
    ]

    private static let entries: [Int: String] = [
        1: "I baked a lemon tart for the picnic.",
        2: "周二晚饭我吃了番茄鸡蛋面。",
        3: "I was worried before the first job interview.",
        4:
            "I was not worried about the second interview. I bought clothes for the interview and sent a thank-you note.",
        5: "去看牙医之前我一点也不紧张。",
        6: "我比较了店里的蓝色跑鞋和白色跑鞋，后来在网上买了一双跑鞋。",
        7: "Mina said she was anxious before the school concert. I told her I felt relaxed.",
        8: "小林说她第一次坐船很害怕。我说我一点也不怕。",
        9: "十月上旬，我通常凌晨一点才睡着。",
        10: "In October my commute took forty minutes each way.",
        11: "I bought a rail pass for November.",
        12: "I went to the attic to look for my missing passport. "
            + String(repeating: "The boxes were dusty. ", count: 37)
            + "It turned up there inside an old map case.",
        13: "我去旧书店找丢失的绿色笔记本。"
            + String(repeating: "雨打在玻璃上，店里很安静。", count: 23)
            + "最后我在那儿的窗台上找到了它。",
        14: "I took the train to the lake on October 14.",
        15: "Looking back, I drove to the lake on October 14 and did not take the train.",
        23: "十月下旬，我通常晚上十一点就睡着了。",
    ]

    private static let distractors = [
        "I washed the picnic blanket and made a list of picnic supplies.",
        "我的跑鞋放在门边，我擦掉了鞋底的泥。",
        "The mock interview practice covered a question about changing jobs.",
        "我整理了餐桌，打算周二试做一道新菜。",
        "The passport application website lists the documents needed for renewal.",
        "我给新买的绿色钢笔配了墨水。",
        "I checked train schedules and looked up parking by the lake.",
        "十月晚上我关了窗户，因为街道上有噪音。",
    ]

    static func date(_ entry: Int) -> Date {
        // October 1, 2026 at noon UTC is entry 1.
        Date(timeIntervalSince1970: 1_790_856_000 + Double(entry - 1) * 86_400)
    }

    static func populate(_ fixture: JournalTestFixture) throws {
        try fixture.populateEntries(count: 40)
        let update = try Statement(
            fixture.source,
            "UPDATE ZJOURNALENTRYMO SET ZID=CAST(printf('%016d', Z_PK) AS BLOB), ZTEXT=?, ZENTRYDATE=? WHERE Z_PK=?"
        )
        for entry in 1...40 {
            let text = entries[entry] ?? distractors[(entry - 1) % distractors.count]
            try update.execute([
                text, String(date(entry).timeIntervalSinceReferenceDate), String(entry),
            ])
        }
    }
}
