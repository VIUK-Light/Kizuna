import XCTest
@testable import KizunaAI

final class KizunaAITests: XCTestCase {
    func testPersonaResponseSanitizerPreservesVisibleText() {
        let input = "<think>private reasoning</think>Visible response"

        XCTAssertEqual(
            PersonaResponseSanitizer.sanitize(input),
            "Visible response"
        )
    }

    func testPersonaResponseSanitizerPreservesMarkdownCode() {
        let input = "```text\n<think>example</think>\n```"

        XCTAssertEqual(
            PersonaResponseSanitizer.sanitize(input),
            input
        )
    }

    func testStoryOutputSafetyRejectsEmptySofteningRewrite() {
        let decision = SafetyDecision(
            action: .soften,
            rewrittenText: " \n"
        )

        XCTAssertEqual(
            StoryOutputSafetyResolution.resolve(decision: decision),
            .rejectGeneratedText
        )
    }

    func testStoryOutputSafetyRejectsRequireEditEvenWithRewrite() {
        let decision = SafetyDecision(
            action: .requireEdit,
            rewrittenText: "安全な別の返答"
        )

        XCTAssertEqual(
            StoryOutputSafetyResolution.resolve(decision: decision),
            .rejectGeneratedText
        )
    }

    func testStoryOutputSafetyUsesTrimmedSofteningRewrite() {
        let decision = SafetyDecision(
            action: .soften,
            rewrittenText: "  安全な書き換え  "
        )

        XCTAssertEqual(
            StoryOutputSafetyResolution.resolve(decision: decision),
            .useRewrittenText("安全な書き換え")
        )
    }
}
