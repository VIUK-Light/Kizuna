/*
仕様:
- 役割: Story モードで NAGI / Gemma4 31B をローカル GGUF ではなく Generative Language API 経由で呼ぶ。
- 編集ポイント: modelName、タイムアウト、JSON 応答パース。
*/

import Foundation

enum StoryGemma31BAPIAvailability: Equatable, Sendable {
    case notConfigured
    case savedNotVerified
    case checking
    case available
    case authenticationError
    case modelUnavailable
    case rateLimited
    case unavailable

    var isUsable: Bool {
        self == .available
    }
}

enum StoryGemma31BAPIError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case httpStatus(Int, String)
    case emptyResponse
    case emptyText
    case truncated(String)

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
        case let .truncated(reason):
            return "Gemma4 31B API の出力が上限(" + reason + ")で途中終了しました。"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .emptyResponse, .emptyText:
            return true
        case .truncated:
            return false
        case let .httpStatus(status, _):
            return status == -1 || [408, 409, 425, 429, 500, 502, 503, 504].contains(status)
        case .missingAPIKey, .invalidURL:
            return false
        }
    }
}

struct StoryGemma31BGenerationResult {
    let text: String
    let modelName: String
    let finishReason: String?
    let usageMetadata: StoryGemma31BUsageMetadata?

    var identity: AIModelIdentity {
        AIModelIdentity(
            providerID: .googleGenerativeLanguage,
            modelID: modelName,
            displayName: modelName
        )
    }

    init(
        text: String,
        modelName: String,
        finishReason: String? = nil,
        usageMetadata: StoryGemma31BUsageMetadata? = nil
    ) {
        self.text = text
        self.modelName = modelName
        self.finishReason = finishReason
        self.usageMetadata = usageMetadata
    }
}

final class StoryGemma31BStreamAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""

    func append(_ delta: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        value += delta
        return value
    }
}

final class StoryGemma31BAPIService {
    static let shared = StoryGemma31BAPIService()

    private let primaryModelName = "gemma-4-31b-it"
    private let fallbackModelNames = ["gemma-4-26b-a4b-it"]
    private let secretStore = AISecretStore.shared
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let availabilityLock = NSLock()
    private var storedAvailability: StoryGemma31BAPIAvailability = .notConfigured

    private init() {}

    var hasAPIKey: Bool {
        if secretStore.configuredGemmaWebReaderAPIKey() != nil {
            return true
        }
        return AIModelRegistry.shared.configurations(for: .story).contains { configuration in
            configuration.identity.providerID != .localRuntime
                && secretStore.providerAPIKey(for: configuration.id) != nil
        }
    }

    var availability: StoryGemma31BAPIAvailability {
        availabilityLock.lock()
        defer { availabilityLock.unlock() }
        if storedAvailability == .notConfigured, hasAPIKey {
            return .savedNotVerified
        }
        return storedAvailability
    }

    /// Validate the credential and the selected primary model without
    /// consuming a generation. Google exposes model metadata through GET, so
    /// invalid keys/model access are surfaced before a user starts a Story.
    func validateConfiguration() async -> StoryGemma31BAPIAvailability {
        guard let apiKey = secretStore.configuredGemmaWebReaderAPIKey() else {
            updateAvailability(.notConfigured)
            return .notConfigured
        }
        updateAvailability(.checking)
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(primaryModelName)") else {
            updateAvailability(.unavailable)
            return .unavailable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let result: StoryGemma31BAPIAvailability
            switch status {
            case 200...299:
                result = .available
            case 401, 403:
                result = .authenticationError
            case 404:
                result = .modelUnavailable
            case 408, 409, 425, 429:
                result = .rateLimited
            case 500...599:
                result = .unavailable
            default:
                result = .unavailable
            }
            updateAvailability(result)
            return result
        } catch {
            updateAvailability(.unavailable)
            return .unavailable
        }
    }

    private func updateAvailability(_ value: StoryGemma31BAPIAvailability) {
        availabilityLock.lock()
        storedAvailability = value
        availabilityLock.unlock()
    }

    func generate(
        systemPrompt: String,
        userPrompt: String,
        temperature: Double = 0.72,
        maxOutputTokens: Int = 4096,
        seed: Int? = nil,
        apiKey overrideAPIKey: String? = nil
    ) async throws -> StoryGemma31BGenerationResult {
        guard let apiKey = resolvedAPIKey(overrideAPIKey) else {
            throw StoryGemma31BAPIError.missingAPIKey
        }
        let body = try makeRequestBody(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            temperature: temperature,
            maxOutputTokens: maxOutputTokens,
            thinkingLevel: "high",
            seed: seed
        )

        let generation = try await performRequestWithRetry(
            apiKey: apiKey,
            body: body,
            modelNames: [primaryModelName] + fallbackModelNames
        )

        let decoded = try decoder.decode(StoryGemma31BGenerateContentResponse.self, from: generation.data)
        if let text = visibleText(from: decoded), !text.isEmpty {
            if let reason = StoryGemma31BResponseParser.truncationReason(from: decoded) {
                AppLog.error("[StoryGemma31B] visible response truncated finishReason=%@", reason)
                throw StoryGemma31BAPIError.truncated(reason)
            }
            return StoryGemma31BGenerationResult(
                text: text,
                modelName: generation.modelName,
                finishReason: decoded.candidates?.compactMap(\.finishReason).first,
                usageMetadata: decoded.usageMetadata
            )
        }

        logEmptyResponse(decoded)

        // Gemma 4 APIのThinkingは high / minimal の切り替えだけを受け付ける。
        // highで思考トークンが候補を使い切って本文が空になった場合は、
        // 未対応の medium を送らず、minimalで本文の余白を確保する。
        // 空本文の時だけ一度実行するため、通常ターンの待ち時間やAPI使用量は増やさない。
        let fallbackBody = try makeRequestBody(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            temperature: temperature,
            maxOutputTokens: max(maxOutputTokens, 1_536),
            thinkingLevel: "minimal",
            seed: seed
        )
        let fallbackGeneration = try await performRequestWithRetry(
            apiKey: apiKey,
            body: fallbackBody,
            modelNames: [primaryModelName] + fallbackModelNames
        )
        let fallbackResponse = try decoder.decode(
            StoryGemma31BGenerateContentResponse.self,
            from: fallbackGeneration.data
        )
        if let text = visibleText(from: fallbackResponse), !text.isEmpty {
            if let reason = StoryGemma31BResponseParser.truncationReason(from: fallbackResponse) {
                AppLog.error("[StoryGemma31B] fallback visible response truncated finishReason=%@", reason)
                throw StoryGemma31BAPIError.truncated(reason)
            }
            return StoryGemma31BGenerationResult(
                text: text,
                modelName: fallbackGeneration.modelName,
                finishReason: fallbackResponse.candidates?.compactMap(\.finishReason).first,
                usageMetadata: fallbackResponse.usageMetadata
            )
        }
        if let reason = StoryGemma31BResponseParser.truncationReason(from: fallbackResponse) {
            throw StoryGemma31BAPIError.truncated(reason)
        }
        logEmptyResponse(fallbackResponse)
        throw StoryGemma31BAPIError.emptyText
    }

    /// Streams Google `streamGenerateContent` SSE chunks. The request body is
    /// identical to generateContent; only the endpoint and response transport
    /// differ. Each visible text part is delivered as a delta before the final
    /// result is returned, while thought parts stay out of the UI/history.
    func generateStreaming(
        systemPrompt: String,
        userPrompt: String,
        temperature: Double = 0.72,
        maxOutputTokens: Int = 4096,
        seed: Int? = nil,
        apiKey overrideAPIKey: String? = nil,
        onTextDelta: @escaping @Sendable (String) -> Void,
        onModelResolved: (@Sendable (String) -> Void)? = nil
    ) async throws -> StoryGemma31BGenerationResult {
        guard let apiKey = resolvedAPIKey(overrideAPIKey) else {
            throw StoryGemma31BAPIError.missingAPIKey
        }
        let body = try makeRequestBody(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            temperature: temperature,
            maxOutputTokens: maxOutputTokens,
            thinkingLevel: "high",
            seed: seed
        )

        var lastFailure: StoryGemma31BAPIError?
        for modelName in [primaryModelName] + fallbackModelNames {
            do {
                return try await streamSingleRequest(
                    apiKey: apiKey,
                    body: body,
                    modelName: modelName,
                    onTextDelta: onTextDelta,
                    onModelResolved: onModelResolved
                )
            } catch let error as StoryGemma31BAPIError {
                lastFailure = error
                guard error.isRetryable == false || ![400, 404, 405].contains(httpStatus(from: error)) else {
                    // A provider/model endpoint incompatibility is allowed to
                    // move to the configured model fallback immediately.
                    continue
                }
                if !error.isRetryable { break }
            } catch {
                lastFailure = .httpStatus(-1, error.localizedDescription)
            }
        }
        throw lastFailure ?? StoryGemma31BAPIError.emptyResponse
    }

    /// Registry configurations keep provider credentials under their own UUID.
    /// The legacy NAGI field remains a fallback so existing installations keep
    /// working during migration, while a newly added Google configuration can
    /// use its own Keychain entry without copying the key into the legacy slot.
    private func resolvedAPIKey(_ overrideAPIKey: String?) -> String? {
        let override = overrideAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !override.isEmpty {
            return override
        }
        return secretStore.configuredGemmaWebReaderAPIKey()
    }

    private func makeRequestBody(
        systemPrompt: String,
        userPrompt: String,
        temperature: Double,
        maxOutputTokens: Int,
        thinkingLevel: String,
        seed: Int?
    ) throws -> Data {
        // The API has a native systemInstruction field. Putting the system
        // prompt and a literal <Thinking> marker into user content makes the
        // request ambiguous and spends output/input budget on prompt plumbing.
        try encoder.encode(StoryGemma31BGenerateContentRequest(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            temperature: temperature,
            maxOutputTokens: maxOutputTokens,
            thinkingLevel: thinkingLevel,
            seed: seed
        ))
    }

    private func visibleText(from response: StoryGemma31BGenerateContentResponse) -> String? {
        StoryGemma31BResponseParser.visibleText(from: response)
    }

    private func logEmptyResponse(_ response: StoryGemma31BGenerateContentResponse) {
        let candidates = response.candidates ?? []
        let parts = candidates.flatMap { $0.content?.parts ?? [] }
        let thoughtParts = parts.filter { $0.thought == true }.count
        let textParts = parts.filter { !($0.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }.count
        let finishReasons = candidates.compactMap(\.finishReason).joined(separator: ",")
        let blockReason = response.promptFeedback?.blockReason ?? "none"
        let promptTokens = response.usageMetadata?.promptTokenCount ?? -1
        let outputTokens = response.usageMetadata?.candidatesTokenCount ?? -1
        AppLog.note(
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

    private func streamSingleRequest(
        apiKey: String,
        body: Data,
        modelName: String,
        onTextDelta: @escaping @Sendable (String) -> Void,
        onModelResolved: (@Sendable (String) -> Void)?
    ) async throws -> StoryGemma31BGenerationResult {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):streamGenerateContent?alt=sse") else {
            throw StoryGemma31BAPIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = body
        onModelResolved?(modelName)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        var streamedText = ""
        var finishReason: String?
        var usageMetadata: StoryGemma31BUsageMetadata?

        for try await line in bytes.lines {
            guard statusCode >= 200, statusCode <= 299 else { continue }
            let payload = line.hasPrefix("data:")
                ? String(line.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
                : line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty, payload != "[DONE]",
                  let data = payload.data(using: .utf8),
                  let chunk = try? decoder.decode(StoryGemma31BGenerateContentResponse.self, from: data) else {
                continue
            }
            if let reason = chunk.candidates?.compactMap(\.finishReason).first {
                finishReason = reason
            }
            if let usage = chunk.usageMetadata {
                usageMetadata = usage
            }
            guard let delta = self.visibleText(from: chunk), !delta.isEmpty else { continue }
            streamedText += delta
            onTextDelta(delta)
        }

        guard (200...299).contains(statusCode) else {
            throw StoryGemma31BAPIError.httpStatus(statusCode, "")
        }
        guard !streamedText.isEmpty else {
            if let finishReason,
               isTruncationReason(finishReason) {
                throw StoryGemma31BAPIError.truncated(finishReason)
            }
            throw StoryGemma31BAPIError.emptyText
        }
        if let finishReason, isTruncationReason(finishReason) {
            throw StoryGemma31BAPIError.truncated(finishReason)
        }
        return StoryGemma31BGenerationResult(
            text: streamedText,
            modelName: modelName,
            finishReason: finishReason,
            usageMetadata: usageMetadata
        )
    }

    private func isTruncationReason(_ reason: String) -> Bool {
        let normalized = reason
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .uppercased()
        return normalized == "MAX_TOKENS"
            || normalized == "MAX_OUTPUT_TOKENS"
            || normalized == "LENGTH"
    }

    private func httpStatus(from error: StoryGemma31BAPIError) -> Int {
        guard case let .httpStatus(status, _) = error else { return -1 }
        return status
    }

    private func performRequestWithRetry(
        apiKey: String,
        body: Data,
        modelNames: [String]
    ) async throws -> (data: Data, modelName: String) {
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
                    return (data: data, modelName: modelName)
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

}
