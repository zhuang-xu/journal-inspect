import JournalCore
import XCTest

final class JournalAnswerPresentationTests: XCTestCase {
    func testCitationDumpIsSuppressedDuringStreamingAndAtCompletion() {
        let prose = "There were hopeful moments on October 27."
        XCTAssertEqual(
            JournalAnswerPresentation.readable(
                prose + "\n\n[Citation IDs: source:entry", internalIDs: ["source:entry"]), prose)
        XCTAssertEqual(
            JournalAnswerPresentation.readable(
                prose + "\n\n[Citation IDs: source:entry, another:entry]",
                internalIDs: ["source:entry"]), prose)
    }
    func testInternalCitationBracketsAreRemovedWithoutChangingOrdinaryReferences() {
        let text = "Hope improved [source:entry]. See [1] and [a useful note]."
        XCTAssertEqual(
            JournalAnswerPresentation.readable(text, internalIDs: ["source:entry"]),
            "Hope improved. See [1] and [a useful note].")
        XCTAssertEqual(
            JournalAnswerPresentation.readable(
                "情绪有所改善 [source:entry]。", internalIDs: ["source:entry"]), "情绪有所改善。")
    }
}
