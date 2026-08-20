import Foundation

@main
struct StoryGemma31BResponseParserTests {
    static func main() throws {
        let responseData = Data(
            """
            {
              "candidates": [
                {
                  "index": 0,
                  "content": {
                    "role": "model",
                    "parts": [
                      {"text": "internal reasoning", "thought": true},
                      {"text": "visible story text", "thought": false}
                    ]
                  },
                  "finishReason": "STOP"
                }
              ],
              "usageMetadata": {"promptTokenCount": 20, "candidatesTokenCount": 12, "thoughtsTokenCount": 7}
            }
            """.utf8
        )
        let response = try JSONDecoder().decode(
            StoryGemma31BGenerateContentResponse.self,
            from: responseData
        )
        precondition(
            StoryGemma31BResponseParser.visibleText(from: response) == "visible story text",
            "Thought parts must not become visible story text"
        )

        let thoughtOnlyResponse = try JSONDecoder().decode(
            StoryGemma31BGenerateContentResponse.self,
            from: Data(
                "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"only reasoning\",\"thought\":true}]}}]}".utf8
            )
        )
        precondition(
            StoryGemma31BResponseParser.visibleText(from: thoughtOnlyResponse) == nil,
            "A thought-only candidate must be treated as empty visible text"
        )

        let missingPartsResponse = try JSONDecoder().decode(
            StoryGemma31BGenerateContentResponse.self,
            from: Data("{\"candidates\":[{\"content\":{\"role\":\"model\"},\"finishReason\":\"MAX_TOKENS\"}]}".utf8)
        )
        precondition(
            StoryGemma31BResponseParser.visibleText(from: missingPartsResponse) == nil,
            "A candidate without parts must remain decodable and empty"
        )
        precondition(
            StoryGemma31BResponseParser.truncationReason(from: missingPartsResponse) == "MAX_TOKENS",
            "MAX_TOKENS must be surfaced as a truncation reason"
        )

        let completedResponse = try JSONDecoder().decode(
            StoryGemma31BGenerateContentResponse.self,
            from: Data("{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"complete\"}]},\"finishReason\":\"STOP\"}]}".utf8)
        )
        precondition(
            StoryGemma31BResponseParser.truncationReason(from: completedResponse) == nil,
            "STOP must not be treated as truncation"
        )

        let request = StoryGemma31BGenerateContentRequest(
            systemPrompt: "You are a story narrator.",
            userPrompt: "Continue the scene.",
            temperature: 0.72,
            maxOutputTokens: 1536,
            thinkingLevel: "high"
        )
        let requestObject = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(request)
        ) as? [String: Any]
        let systemInstruction = requestObject?["systemInstruction"] as? [String: Any]
        let systemParts = systemInstruction?["parts"] as? [[String: Any]]
        let systemText = systemParts?.first?["text"] as? String
        precondition(systemText == "You are a story narrator.", "System prompt must use systemInstruction")

        let contents = requestObject?["contents"] as? [[String: Any]]
        let userParts = contents?.first?["parts"] as? [[String: Any]]
        let userText = userParts?.first?["text"] as? String
        precondition(userText == "Continue the scene.", "User prompt must remain user content")
        precondition(!((userText ?? "").contains("<Thinking>")), "Prompt must not inject a Thinking marker")

        print("Story Gemma response parser and request tests passed")
    }
}
