import Foundation

@main
struct LiteRTLMContextLimitTests {
    static func main() {
        let cases: [(String, Int?)] = [
            ("INVALID_ARGUMENT: Input token ids are too long. Exceeding the maximum number of tokens allowed: 1937 >= 1280", 1280),
            ("maximum number of tokens allowed is 2048", 2048),
            ("native model failed before token validation", nil)
        ]

        for (message, expected) in cases {
            let actual = LocalAssistantLiteRTLMContextLimit.reportedMaximumTokenCount(from: message)
            precondition(actual == expected, "Unexpected limit for: \(message)")
        }
        print("LiteRT-LM context-limit parser tests passed")
    }
}
