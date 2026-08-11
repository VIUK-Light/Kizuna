import Foundation

struct StoryGemma31BPart: Codable {
    let text: String?
    let thought: Bool?

    init(text: String?, thought: Bool? = nil) {
        self.text = text
        self.thought = thought
    }
}

struct StoryGemma31BContent: Codable {
    let role: String?
    let parts: [StoryGemma31BPart]

    init(role: String? = nil, parts: [StoryGemma31BPart]) {
        self.role = role
        self.parts = parts
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case parts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        // A blocked or truncated candidate can omit parts entirely. Treat it
        // as an empty candidate so diagnostics can still inspect finishReason
        // and promptFeedback instead of failing the whole response decode.
        parts = try container.decodeIfPresent([StoryGemma31BPart].self, forKey: .parts) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encode(parts, forKey: .parts)
    }
}

struct StoryGemma31BThinkingConfig: Encodable {
    let thinkingLevel: String
}

struct StoryGemma31BGenerationConfig: Encodable {
    let temperature: Double
    let topP: Double
    let maxOutputTokens: Int
    let thinkingConfig: StoryGemma31BThinkingConfig
}

struct StoryGemma31BGenerateContentRequest: Encodable {
    let contents: [StoryGemma31BContent]
    let systemInstruction: StoryGemma31BContent?
    let generationConfig: StoryGemma31BGenerationConfig

    init(
        systemPrompt: String?,
        userPrompt: String,
        temperature: Double,
        topP: Double = 0.92,
        maxOutputTokens: Int,
        thinkingLevel: String
    ) {
        let normalizedSystemPrompt = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        systemInstruction = normalizedSystemPrompt.map {
            StoryGemma31BContent(parts: [StoryGemma31BPart(text: $0)])
        }
        contents = [
            StoryGemma31BContent(
                role: "user",
                parts: [StoryGemma31BPart(text: userPrompt)]
            )
        ]
        generationConfig = StoryGemma31BGenerationConfig(
            temperature: temperature,
            topP: topP,
            maxOutputTokens: maxOutputTokens,
            thinkingConfig: StoryGemma31BThinkingConfig(thinkingLevel: thinkingLevel)
        )
    }
}

struct StoryGemma31BGenerateContentResponse: Decodable {
    let candidates: [StoryGemma31BCandidate]?
    let promptFeedback: StoryGemma31BPromptFeedback?
    let usageMetadata: StoryGemma31BUsageMetadata?
}

struct StoryGemma31BCandidate: Decodable {
    let index: Int?
    let content: StoryGemma31BContent?
    let finishReason: String?
}

struct StoryGemma31BPromptFeedback: Decodable {
    let blockReason: String?
}

struct StoryGemma31BUsageMetadata: Decodable {
    let promptTokenCount: Int?
    let candidatesTokenCount: Int?
    let thoughtsTokenCount: Int?
}

enum StoryGemma31BResponseParser {
    /// Returns only candidate parts intended for the user-visible answer.
    /// Gemma 4 can return reasoning parts with `thought: true`; those parts
    /// must not be persisted as story text or used as the next-turn history.
    static func visibleText(from response: StoryGemma31BGenerateContentResponse) -> String? {
        let text = (response.candidates ?? [])
            .flatMap { $0.content?.parts ?? [] }
            .filter { $0.thought != true }
            .compactMap(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
