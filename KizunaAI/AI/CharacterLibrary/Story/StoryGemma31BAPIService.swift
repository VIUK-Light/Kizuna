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
        maxOutputTokens: Int = 4096,
        responseMIMEType: String? = nil
    ) async throws -> String {
        guard let apiKey = secretStore.configuredGemmaWebReaderAPIKey() else {
            throw StoryGemma31BAPIError.missingAPIKey
        }
        let prompt = """
        \(systemPrompt)

        ---
        USER_INPUT:
        \(userPrompt)
        """

        let body = try encoder.encode(GenerateContentRequest(
            contents: [
                Content(role: "user", parts: [Part(text: prompt)])
            ],
            generationConfig: GenerationConfig(
                temperature: temperature,
                topP: 0.92,
                maxOutputTokens: maxOutputTokens,
                responseMimeType: responseMIMEType
            )
        ))

        let data = try await performRequestWithRetry(
            apiKey: apiKey,
            body: body,
            modelNames: [primaryModelName] + fallbackModelNames
        )

        let decoded = try decoder.decode(GenerateContentResponse.self, from: data)
        let text = decoded.candidates?
            .flatMap { $0.content?.parts ?? [] }
            .compactMap(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            throw StoryGemma31BAPIError.emptyText
        }
        return text
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
    }

    private struct GenerationConfig: Encodable {
        let temperature: Double
        let topP: Double
        let maxOutputTokens: Int
        let responseMimeType: String?

        enum CodingKeys: String, CodingKey {
            case temperature
            case topP
            case maxOutputTokens
            case responseMimeType
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(temperature, forKey: .temperature)
            try container.encode(topP, forKey: .topP)
            try container.encode(maxOutputTokens, forKey: .maxOutputTokens)
            try container.encodeIfPresent(responseMimeType, forKey: .responseMimeType)
        }
    }

    private struct GenerateContentResponse: Decodable {
        let candidates: [Candidate]?
    }

    private struct Candidate: Decodable {
        let content: Content?
    }
}
