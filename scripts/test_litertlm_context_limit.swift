import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main
struct LiteRTLMContextLimitTests {
    static func main() {
        let cases: [(message: String, expected: Int?, context: Int?, shouldRetry: Bool?)] = [
            ("INVALID_ARGUMENT: Input token ids are too long. Exceeding the maximum number of tokens allowed: 1937 >= 1280", 1280, 2048, true),
            ("INVALID_ARGUMENT: Input token ids are too long. Exceeding the maximum number of tokens allowed: 1937 > 1280", 1280, 2048, true),
            ("maximum number of tokens allowed is 2048", 2048, 2048, false),
            ("native model failed before token validation", nil, 2048, false)
        ]

        var failures: [String] = []
        for testCase in cases {
            let message = testCase.message
            let actual = LocalAssistantLiteRTLMContextLimit.reportedMaximumTokenCount(from: message)
            if actual != testCase.expected {
                failures.append("Unexpected limit: expected=\(String(describing: testCase.expected)), actual=\(String(describing: actual)), message=\(message)")
            }
            if let context = testCase.context, let shouldRetry = testCase.shouldRetry {
                let actualShouldRetry = actual.map { $0 >= 256 && $0 < context } ?? false
                if actualShouldRetry != shouldRetry {
                    failures.append("Unexpected retry decision: expected=\(shouldRetry), actual=\(actualShouldRetry), message=\(message)")
                }
            }
        }

        guard failures.isEmpty else {
            let output = failures.joined(separator: "\n") + "\n"
            FileHandle.standardError.write(Data(output.utf8))
            exit(1)
        }
        print("LiteRT-LM context-limit parser tests passed")
    }
}
