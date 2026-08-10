/*
仕様:
- 役割: Story モードで NAGI / Gemma4 31B をローカル GGUF ではなく Generative Language API 経由で呼ぶ。
- 編集ポイント: modelName、タイムアウト、JSON 応答パース。
*/

import Foundation

enum StoryGemma31BAPIError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case httpStatus(Int, String)
    case emptyResponse
    case emptyText

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Gemma4 APIキーが未設定です。"
        case .invalidURL:
            return "Gemma4 31B API のURLを作れませんでした。"
        case let .httpStatus(status, body):
            let preview = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Gemma4 31B API に失敗しました。HTTP \(status)\(preview.isEmpty ? "" : ": \(String(preview.prefix(160)))")"
        case .emptyResponse:
            return "Gemma4 31B API が空レスポンスを返しました。"
        case .emptyText:
            return "Gemma4 31B API の出力本文が空でした。"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .emptyResponse, .emptyText:
            return true
        case let .httpStatus(status, _):
            return status == -1 || [408, 409, 425, 429, 500, 502, 503, 504].contains(status)
        case .missingAPIKey, .invalidURL:
            return false
        }
    }
}

final class StoryGemma31BAPIService {
    static let shared = StoryGemma31BAPIService()

    private let primaryModelName = "gemma-4-31b-it"
    private let fallbackModelNames = ["gemma-4-26b-a4b-it"]
    private let secretStore = AISecretStore.shared
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private init() {}

    var hasAPIKey: Bool {
        secretStore.configuredGemmaWebReaderAPIKey() != nil
    }

    func generate(
        systemPrompt: String,
        userPrompt: String,
        temperature: Double = 0.72,
        maxOutputTokens: Int = 4096
    ) async throws -> String {
        guard let apiKey = secretStore.configuredGemmaWebReaderAPIKey() else {
            throw StoryGemma31BAPIError.missingAPIKey
        }
        let prompt = """
        <Thinking>
        \(systemPrompt)

        ---
        USER_INPUT:
        \(userPrompt)
        """

        let body = try makeRequestBody(
            prompt: prompt,
            temperature: temperature,
            maxOutputTokens: maxOutputTokens,
            thinkingLevel: "high"
        )

        let data = try await performRequestWithRetry(
            apiKey: apiKey,
            body: body,
            modelNames: [primaryModelName] + fallbackModelNames
        )

        let decoded = try decoder.decode(GenerateContentResponse.self, from: data)
        if let text = visibleText(from: decoded), !text.isEmpty {
            return text
        }

        logEmptyResponse(decoded)

        // Gemma 4 APIのThinkingは high / minimal の切り替えだけを受け付ける。
        // highで思考トークンが候補を使い切って本文が空になった場合は、
        // 未対応の medium を送らず、minimalで本文の余白を確保する。
        // 空本文の時だけ一度実行するため、通常ターンの待ち時間やAPI使用量は増やさない。
        let fallbackBody = try makeRequestBody(
            prompt: prompt,
            temperature: temperature,
            maxOutputTokens: max(maxOutputTokens, 1_536),
            thinkingLevel: "minimal"
        )
        let fallbackData = try await performRequestWithRetry(
            apiKey: apiKey,
            body: fallbackBody,
            modelNames: [primaryModelName] + fallbackModelNames
        )
        let fallbackResponse = try decoder.decode(GenerateContentResponse.self, from: fallbackData)
        if let text = visibleText(from: fallbackResponse), !text.isEmpty {
            return text
        }
        logEmptyResponse(fallbackResponse)
        throw StoryGemma31BAPIError.emptyText
    }

    private func makeRequestBody(
        prompt: String,
        temperature: Double,
        maxOutputTokens: Int,
        thinkingLevel: String
    ) throws -> Data {
        try encoder.encode(GenerateContentRequest(
            contents: [
                Content(role: "user", parts: [Part(text: prompt)])
            ],
            generationConfig: GenerationConfig(
                temperature: temperature,
                topP: 0.92,
                maxOutputTokens: maxOutputTokens,
                // Gemma 4 APIではThinkingを常に有効化する。medium は空本文時だけの復旧用。
                thinkingConfig: ThinkingConfig(thinkingLevel: thinkingLevel)
            )
        ))
    }

    private func visibleText(from response: GenerateContentResponse) -> String? {
        response.candidates?
            .flatMap { $0.content?.parts ?? [] }
            // 思考過程は会話本文・次ターンの履歴へ保存しない。
            .filter { $0.thought != true }
            .compactMap(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func logEmptyResponse(_ response: GenerateContentResponse) {
        let candidates = response.candidates ?? []
        let parts = candidates.flatMap { $0.content?.parts ?? [] }
        let thoughtParts = parts.filter { $0.thought == true }.count
        let textParts = parts.filter { !($0.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }.count
        let finishReasons = candidates.compactMap(\.finishReason).joined(separator: ",")
        let blockReason = response.promptFeedback?.blockReason ?? "none"
        let promptTokens = response.usageMetadata?.promptTokenCount ?? -1
        let outputTokens = response.usageMetadata?.candidatesTokenCount ?? -1
        NSLog(
            "[StoryGemma31B] empty visible text candidates=%d parts=%d textParts=%d thoughtParts=%d finish=%@ block=%@ promptTokens=%d outputTokens=%d",
            candidates.count,
            parts.count,
            textParts,
            thoughtParts,
            finishReasons.isEmpty ? "none" : finishReasons,
            blockReason,
            promptTokens,
            outputTokens
        )
    }

    private func performRequestWithRetry(
        apiKey: String,
        body: Data,
        modelNames: [String]
    ) async throws -> Data {
        var lastFailure: StoryGemma31BAPIError?
        let maxAttemptsPerModel = 5
        for modelName in modelNames {
            guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):generateContent") else {
                throw StoryGemma31BAPIError.invalidURL
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 90
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            request.httpBody = body

            for attempt in 0..<maxAttemptsPerModel {
                do {
                    let data = try await performSingleRequest(request)
                    return data
                } catch let error as StoryGemma31BAPIError {
                    lastFailure = error
                    if !error.isRetryable || attempt == maxAttemptsPerModel - 1 {
                        break
                    }
                    let delay = UInt64(min(7.5, 0.75 * pow(1.7, Double(attempt))) * 1_000_000_000)
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    lastFailure = .httpStatus(-1, error.localizedDescription)
                    if attempt == maxAttemptsPerModel - 1 {
                        break
                    }
                    let delay = UInt64(min(7.5, 0.75 * pow(1.7, Double(attempt))) * 1_000_000_000)
                    try await Task.sleep(nanoseconds: delay)
                }
            }
        }
        throw lastFailure ?? StoryGemma31BAPIError.emptyResponse
    }

    private func performSingleRequest(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        if (200...299).contains(statusCode) {
            guard !data.isEmpty else {
                throw StoryGemma31BAPIError.emptyResponse
            }
            return data
        }
        throw StoryGemma31BAPIError.httpStatus(statusCode, String(data: data, encoding: .utf8) ?? "")
    }

    private struct GenerateContentRequest: Encodable {
        let contents: [Content]
        let generationConfig: GenerationConfig
    }

    private struct Content: Codable {
        let role: String?
        let parts: [Part]
    }

    private struct Part: Codable {
        let text: String?
        let thought: Bool?

        init(text: String?, thought: Bool? = nil) {
            self.text = text
            self.thought = thought
        }
    }

    private struct GenerationConfig: Encodable {
        let temperature: Double
        let topP: Double
        let maxOutputTokens: Int
        let thinkingConfig: ThinkingConfig
    }

    private struct ThinkingConfig: Encodable {
        let thinkingLevel: String
    }

    private struct GenerateContentResponse: Decodable {
        let candidates: [Candidate]?
        let promptFeedback: PromptFeedback?
        let usageMetadata: UsageMetadata?
    }

    private struct Candidate: Decodable {
        let index: Int?
        let content: Content?
        let finishReason: String?
    }

    private struct PromptFeedback: Decodable {
        let blockReason: String?
    }

    private struct UsageMetadata: Decodable {
        let promptTokenCount: Int?
        let candidatesTokenCount: Int?
        let thoughtsTokenCount: Int?
    }
}
