import Foundation

/// Extracts a model-reported context limit from LiteRT-LM's native error text.
///
/// `EngineConfig.maxNumTokens` is an application request, not a query for the
/// compiled model's limit. The native runtime may therefore report a smaller
/// limit when the downloaded `.litertlm` artifact rejects a prefill. Keeping
/// this parser separate makes that distinction testable without loading a
/// model or starting an iOS runtime.
enum LocalAssistantLiteRTLMContextLimit {
    static func reportedMaximumTokenCount(from message: String) -> Int? {
        let patterns = [
            #"maximum number of tokens allowed:\s*\d+\s*>=\s*(\d+)"#,
            #"maximum number of tokens allowed[^0-9]*(\d+)"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else {
                continue
            }
            let range = NSRange(message.startIndex..<message.endIndex, in: message)
            guard let match = regex.firstMatch(in: message, options: [], range: range),
                  match.numberOfRanges > 1,
                  let limitRange = Range(match.range(at: 1), in: message),
                  let limit = Int(message[limitRange]) else {
                continue
            }
            return limit
        }
        return nil
    }
}
