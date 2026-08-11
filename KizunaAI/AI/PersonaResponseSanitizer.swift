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
    nonisolated private static let leadingGemmaThoughtPattern =
        #"(?is)^\s*<\|?channel\|?>\s*thought\b[\s\S]*?<\|?channel\|?>\s*"#
    nonisolated private static let leadingUnclosedGemmaThoughtPattern =
        #"(?is)^\s*<\|?channel\|?>\s*thought\b[\s\S]*$"#

    nonisolated private static let reasoningTagNames = ["think", "reasoning", "reflect", "thought"]

    /// These tokens are emitted by model templates and have no visible-text
    /// meaning when they occupy a complete line. Do not strip them from an
    /// inline code example or a normal sentence.
    nonisolated private static let standaloneProtocolTokens: Set<String> = [
        "<|channel|>", "<channel|>", "<|channel>", "<channel>",
        "<|message|>", "<message|>", "<|message>", "<message>",
        "<|start_of_turn|>", "<start_of_turn|>", "<|start|>",
        "<start_of_turn>", "<start_of_turn>model", "<start_of_turn>assistant",
        "<start_of_turn>user", "<end_of_turn>"
    ]

    nonisolated static func sanitize(_ text: String) -> String {
        // A template token can precede a leading thought payload. Remove such
        // complete-line tokens first, otherwise the thought tag no longer
        // begins at the protocol boundary and its contents would leak.
        let withoutStandaloneProtocolTokens = removingStandaloneProtocolLines(from: text)
        // An indented or fenced Markdown code block can legitimately begin
        // with a protocol-looking literal. It is user-visible code, not model
        // reasoning, so preserve it before applying leading-payload patterns.
        guard !startsWithMarkdownCodeBlock(withoutStandaloneProtocolTokens) else {
            return withoutStandaloneProtocolTokens
        }
        let withoutLeadingReasoning = removingLeadingReasoningPayloads(
            from: withoutStandaloneProtocolTokens
        )
        return removingStandaloneProtocolLines(from: withoutLeadingReasoning)
    }

    nonisolated private static func removingStandaloneProtocolLines(from text: String) -> String {
        var activeFence: (marker: Character, length: Int)?
        var retainedLines: [String] = []

        for line in text.components(separatedBy: .newlines) {
            if let fence = activeFence {
                retainedLines.append(line)
                if let candidate = fencedCodeDelimiter(in: line),
                   candidate.marker == fence.marker,
                   candidate.length >= fence.length {
                    activeFence = nil
                }
                continue
            }

            if let openingFence = fencedCodeDelimiter(in: line) {
                retainedLines.append(line)
                activeFence = openingFence
                continue
            }

            if isIndentedMarkdownCodeLine(line) || !isStandaloneProtocolToken(line) {
                retainedLines.append(line)
            }
        }

        return retainedLines.joined(separator: "\n")
    }

    nonisolated private static func removingLeadingReasoningPayloads(from text: String) -> String {
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

    nonisolated private static func startsWithMarkdownCodeBlock(_ text: String) -> Bool {
        for line in text.components(separatedBy: .newlines) {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            return isIndentedMarkdownCodeLine(line) || fencedCodeDelimiter(in: line) != nil
        }
        return false
    }

    nonisolated private static func isIndentedMarkdownCodeLine(_ line: String) -> Bool {
        line.hasPrefix("    ") || line.hasPrefix("\t")
    }

    nonisolated private static func fencedCodeDelimiter(
        in line: String
    ) -> (marker: Character, length: Int)? {
        let content = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let marker = content.first, marker == "`" || marker == "~" else { return nil }
        let length = content.prefix(while: { $0 == marker }).count
        guard length >= 3 else { return nil }
        return (marker, length)
    }

    nonisolated private static func isStandaloneProtocolToken(_ line: String) -> Bool {
        let normalized = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return standaloneProtocolTokens.contains(normalized)
    }
}
