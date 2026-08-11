import Foundation

/// Removes only protocol payloads that are known to be internal reasoning.
///
/// Persona responses are already delivered as visible text by
/// `LocalAssistantRuntimeBridge`. This is deliberately a conservative last
/// line of defense for an occasional raw model-token leak, not a formatter for
/// user-visible prose. Markdown, identifiers, quotations, numbered
/// instructions, and ordinary language must remain lossless because the result
/// is persisted in the conversation history.
enum PersonaResponseSanitizer {
    private static let leadingGemmaThoughtPattern =
        #"(?is)^\s*<\|?channel\|?>\s*thought\b[\s\S]*?<\|?channel\|?>\s*"#
    private static let leadingUnclosedGemmaThoughtPattern =
        #"(?is)^\s*<\|?channel\|?>\s*thought\b[\s\S]*$"#

    private static let reasoningTagNames = ["think", "reasoning", "reflect", "thought"]

    /// These tokens are emitted by model templates and have no visible-text
    /// meaning when they occupy a complete line. Do not strip them from an
    /// inline code example or a normal sentence.
    private static let standaloneProtocolTokens: Set<String> = [
        "<|channel|>", "<channel|>", "<|channel>", "<channel>",
        "<|message|>", "<message|>", "<|message>", "<message>",
        "<|start_of_turn|>", "<start_of_turn|>", "<|start|>",
        "<start_of_turn>", "<start_of_turn>model", "<start_of_turn>assistant",
        "<start_of_turn>user", "<end_of_turn>"
    ]

    static func sanitize(_ text: String) -> String {
        // A template token can precede a leading thought payload. Remove such
        // complete-line tokens first, otherwise the thought tag no longer
        // begins at the protocol boundary and its contents would leak.
        let withoutStandaloneProtocolTokens = removingStandaloneProtocolLines(from: text)
        let withoutLeadingReasoning = removingLeadingReasoningPayloads(
            from: withoutStandaloneProtocolTokens
        )
        return removingStandaloneProtocolLines(from: withoutLeadingReasoning)
    }

    private static func removingStandaloneProtocolLines(from text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .filter { !isStandaloneProtocolToken($0) }
            .joined(separator: "\n")
    }

    private static func removingLeadingReasoningPayloads(from text: String) -> String {
        var value = text

        while true {
            let withoutGemmaThought = value.replacingOccurrences(
                of: leadingGemmaThoughtPattern,
                with: "",
                options: .regularExpression
            )
            if withoutGemmaThought != value {
                value = withoutGemmaThought
                continue
            }
            let withoutUnclosedGemmaThought = value.replacingOccurrences(
                of: leadingUnclosedGemmaThoughtPattern,
                with: "",
                options: .regularExpression
            )
            if withoutUnclosedGemmaThought != value {
                value = withoutUnclosedGemmaThought
                continue
            }

            var removedTaggedPayload = false
            for tag in reasoningTagNames {
                let pattern = #"(?is)^\s*<\#(tag)\b[^>]*>[\s\S]*?</\#(tag)\s*>\s*"#
                let withoutTaggedPayload = value.replacingOccurrences(
                    of: pattern,
                    with: "",
                    options: .regularExpression
                )
                if withoutTaggedPayload != value {
                    value = withoutTaggedPayload
                    removedTaggedPayload = true
                    break
                }

                let unclosedPattern = #"(?is)^\s*<\#(tag)\b[^>]*>[\s\S]*$"#
                let withoutUnclosedPayload = value.replacingOccurrences(
                    of: unclosedPattern,
                    with: "",
                    options: .regularExpression
                )
                if withoutUnclosedPayload != value {
                    value = withoutUnclosedPayload
                    removedTaggedPayload = true
                    break
                }
            }

            if !removedTaggedPayload {
                return value
            }
        }
    }

    private static func isStandaloneProtocolToken(_ line: String) -> Bool {
        let normalized = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return standaloneProtocolTokens.contains(normalized)
    }
}
