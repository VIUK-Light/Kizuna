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
}
