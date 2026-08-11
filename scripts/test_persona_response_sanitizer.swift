import Foundation

@main
struct PersonaResponseSanitizerTests {
    static func main() {
        let cases: [(name: String, input: String, expected: String)] = [
            (
                "ordinary Japanese prose and identifiers survive",
                "「考えるのも大切」と思うよ。変数は user_id です。",
                "「考えるのも大切」と思うよ。変数は user_id です。"
            ),
            (
                "numbered advice survives",
                "1. まず深呼吸して、次に友達へ相談してね",
                "1. まず深呼吸して、次に友達へ相談してね"
            ),
            (
                "Markdown and code notation survive",
                "**大事**: `foo_bar` と C_* を確認してね。",
                "**大事**: `foo_bar` と C_* を確認してね。"
            ),
            (
                "Gemma thought channel is removed only at the leading protocol boundary",
                "<|channel>thought\ninternal reasoning<channel|>Visible answer",
                "Visible answer"
            ),
            (
                "paired leading thought tag is removed",
                "<think>internal reasoning</think>Visible answer",
                "Visible answer"
            ),
            (
                "protocol line before a thought tag does not expose reasoning",
                "<start_of_turn>model\n<think>internal reasoning</think>Visible answer",
                "Visible answer"
            ),
            (
                "unclosed Gemma thought channel is not exposed",
                "<|channel>thought\ninternal reasoning",
                ""
            ),
            (
                "unclosed leading thought tag is not exposed",
                "<think>internal reasoning",
                ""
            ),
            (
                "inline markup example remains visible",
                "Use <think> as an XML-like literal in this example.",
                "Use <think> as an XML-like literal in this example."
            ),
            (
                "Markdown code indentation remains visible",
                "    let user_id = 42\n    print(user_id)",
                "    let user_id = 42\n    print(user_id)"
            ),
            (
                "standalone protocol lines are removed",
                "<end_of_turn>\nVisible answer\n<|channel|>",
                "Visible answer"
            )
        ]

        for testCase in cases {
            let actual = PersonaResponseSanitizer.sanitize(testCase.input)
            precondition(
                actual == testCase.expected,
                "\(testCase.name): expected `\(testCase.expected)`, got `\(actual)`"
            )
        }

        print("Persona response sanitizer tests passed")
    }
}
