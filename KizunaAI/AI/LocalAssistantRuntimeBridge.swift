/*
仕様:
- 役割: ローカルAIの実行可否判定と、埋め込み runtime を使った生成を担う。
- 主な型: `LocalAssistantRuntimeBridge`, `LocalAssistantRuntimeAvailability`.
- 編集ポイント: runtime の切替、self-check 条件、プロンプト整形を変えるときに触る。
*/
import Darwin
import Foundation
#if os(macOS)
import AppKit
#endif

#if os(macOS) || os(iOS)
// Objective-C runtimeの結果型をSwift Concurrency境界へ渡すために必要。
// iOSでも埋め込み llama.cpp runtime を使用する。
extension VIUKEmbeddedRuntimeResult: @unchecked Sendable {}
#endif

nonisolated private func makeRuntimeDefaultGemmaAdvancedSettings() -> GemmaAdvancedSettings {
    GemmaAdvancedSettings(
        safetyProfile: .auto,
        safetyThresholds: Dictionary(
            uniqueKeysWithValues: GemmaSafetyCategory.allCases.map { category in
                let threshold: GemmaSafetyThreshold = switch category {
                case .dangerousContent, .hate, .sexuallyExplicit:
                    .strict
                case .harassment:
                    .standard
                }
                return (category.rawValue, threshold)
            }
        ),
        useAutomaticTemperature: true,
        temperature: 0.45,
        allowToolUsage: true,
        strictJSONToolCalls: true,
        allowDirectAnswersWithoutTools: true,
        requireSearchForFactualQueries: true,
        requireExternalSourcesInDeepResearch: true,
        maxToolRounds: 8,
        maxSearchRounds: 10,
        enabledTools: [
            "conversation_search": true,
            "external_search": true,
            "python_exec": true,
            "table_builder": true,
            "current_time": true,
            "calculator": true
        ],
        speculativeDecodingMode: .auto
    )
}

enum LocalAssistantRuntimeAvailability: Equatable {
    case checking
    case executable
    case recentFailure
    case savedOnly
    case modelMissing
}

enum LocalAssistantRuntimeFailureKind: Equatable {
    case runnerUnavailable
    case runnerStartupFailed
    case modelLoadFailed
    case thinkingUnsupported
    case toolCallingUnsupported
    case timeout
    case emptyOutput
    case selfCheckFailed
    case generationFailed
    case supportBriefFailed
}

struct LocalAssistantToolName: RawRepresentable, Codable, Hashable, Equatable {
    let rawValue: String

    init?(rawValue: String) {
        guard AIToolCatalog.containsTool(named: rawValue) else {
            return nil
        }
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported local tool name: \(rawValue)")
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static let conversationSearch = LocalAssistantToolName(rawValue: "conversation_search")!
    static let externalSearch = LocalAssistantToolName(rawValue: "external_search")!
    static let pythonExec = LocalAssistantToolName(rawValue: "python_exec")!
    static let tableBuilder = LocalAssistantToolName(rawValue: "table_builder")!
    static let currentTime = LocalAssistantToolName(rawValue: "current_time")!
    static let calculator = LocalAssistantToolName(rawValue: "calculator")!
}

struct LocalAssistantToolCallArguments: Codable, Hashable {
    let query: String?
    let queries: [String]?
    let code: String?
    let source: String?
    let expression: String?
    let limit: Int?
    let stopCondition: String?

    init(
        query: String? = nil,
        queries: [String]? = nil,
        code: String? = nil,
        source: String? = nil,
        expression: String? = nil,
        limit: Int? = nil,
        stopCondition: String? = nil
    ) {
        self.query = query
        self.queries = queries
        self.code = code
        self.source = source
        self.expression = expression
        self.limit = limit
        self.stopCondition = stopCondition
    }
}

struct LocalAssistantToolCall: Codable, Hashable {
    let name: LocalAssistantToolName
    let arguments: LocalAssistantToolCallArguments?
    let reason: String?
}

private struct LocalFunctionCallPayload: Decodable {
    let functionCall: LocalFunctionInvocation?
    let functionCalls: [LocalFunctionInvocation]?
    let toolCalls: [LocalFunctionInvocation]?
    let name: String?
    let arguments: [String: JSONValue]?
    let reason: String?

    private enum CodingKeys: String, CodingKey {
        case functionCall
        case functionCalls
        case toolCalls
        case toolCallsSnake = "tool_calls"
        case name
        case arguments
        case reason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        functionCall = try container.decodeIfPresent(LocalFunctionInvocation.self, forKey: .functionCall)
        functionCalls = try container.decodeIfPresent([LocalFunctionInvocation].self, forKey: .functionCalls)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        arguments = try container.decodeIfPresent([String: JSONValue].self, forKey: .arguments)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)

        let openAIToolCalls: [LocalOpenAIToolCall]?
        if let snakeCalls = try container.decodeIfPresent([LocalOpenAIToolCall].self, forKey: .toolCallsSnake) {
            openAIToolCalls = snakeCalls
        } else {
            openAIToolCalls = try container.decodeIfPresent([LocalOpenAIToolCall].self, forKey: .toolCalls)
        }
        toolCalls = openAIToolCalls?.compactMap(\.invocation)
    }
}

private struct LocalFunctionInvocation: Decodable {
    let name: String
    let arguments: [String: JSONValue]?
    let reason: String?
}

private struct LocalOpenAIToolCall: Decodable {
    let function: LocalOpenAIFunctionCall?
    let name: String?
    let arguments: LocalToolArgumentsPayload?
    let reason: String?

    var invocation: LocalFunctionInvocation? {
        if let function {
            return LocalFunctionInvocation(
                name: function.name,
                arguments: function.arguments?.objectValue,
                reason: reason
            )
        }
        guard let name else { return nil }
        return LocalFunctionInvocation(
            name: name,
            arguments: arguments?.objectValue,
            reason: reason
        )
    }
}

private struct LocalOpenAIFunctionCall: Decodable {
    let name: String
    let arguments: LocalToolArgumentsPayload?
}

private enum LocalToolArgumentsPayload: Decodable {
    case object([String: JSONValue])
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported tool arguments")
        }
    }

    var objectValue: [String: JSONValue]? {
        switch self {
        case .object(let object):
            return object
        case .string(let string):
            guard let data = string.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode([String: JSONValue].self, from: data)
        }
    }
}

private enum JSONValue: Decodable {
    case string(String)
    case integer(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    var anyValue: Any {
        switch self {
        case .string(let value):
            return value
        case .integer(let value):
            return value
        case .double(let value):
            return value
        case .bool(let value):
            return value
        case .array(let value):
            return value.map(\.anyValue)
        case .object(let value):
            return value.mapValues(\.anyValue)
        case .null:
            return NSNull()
        }
    }
}

struct LocalAssistantToolResult: Codable, Hashable {
    let toolName: String
    let contextText: String
    let visibleSummary: String
}

enum LocalAssistantNormalizedEvent: Equatable {
    case thought(String)
    case toolCall(LocalAssistantToolCall)
    case finalText(String)
}

struct LocalAssistantStructuredTurn: Equatable {
    let finalText: String
    let visibleText: String
    let thinkingSegments: [String]
    let rawThinkingStream: String
    let toolCalls: [LocalAssistantToolCall]
    let normalizedEvents: [LocalAssistantNormalizedEvent]
    let finishReason: String?
}

enum LocalAssistantStructuredTurnUpdate: Equatable {
    case status(LocalExecutionStatusUpdate)
    case thinkingPreview(String)
    case visiblePreview(String)
    case toolCallPreview(String)
}

private struct BundledServerSession {
    let process: Process
    let port: Int
    let modelPath: String
    let runnerPath: String
    let apiKey: String
    let nativeThinkingEnabled: Bool
    /// 起動時に指定した `--spec-type` の値 (nil なら投機デコード無効)。
    /// セッション再利用時の判定に使う: ユーザーが設定変更したら値が変わるため再起動が必要。
    let activeSpecType: String?
}

private struct BundledServerChatResponse {
    let content: String
    let reasoningContent: String
    let toolCalls: [LocalAssistantToolCall]
    var finishReason: String?
    var promptTokens: Int?
    var completionTokens: Int?
}

// URLSessionDataDelegate でサーバー SSE チャンクを逐次受信するコレクター
private final class BundledSSECollector: NSObject, URLSessionDataDelegate {
    private(set) var accContent = ""
    private(set) var accReasoning = ""
    /// tool_calls デルタをインデックス別に累積し、最終的に完全な tool_calls 配列を再構成する。
    private var toolCallBuffers: [Int: [String: Any]] = [:]
    private(set) var accToolCalls: [[String: Any]] = []
    private(set) var statusCode = -1
    private(set) var finishReason: String?
    private(set) var promptTokens: Int?
    private(set) var completionTokens: Int?
    let semaphore = DispatchSemaphore(value: 0)
    var onDelta: ((String, String) -> Void)?
    private var lineBuffer = ""
    // UI バックログを防ぐため、onDelta の呼び出しを最低 16ms (~60fps) に絞る。
    // 旧: 50ms (20fps)。partialThinkingPreview の高速パスと
    // 下流コールバックの 16ms コアレスにより per-delta コストが十分下がったので、
    // 思考プレビュー / 本文プレビューの「出るのが遅い」体感を解消するためここを詰める。
    // 最後のデルタは didCompleteWithError / [DONE] で必ず flush する。
    private var lastNotifiedAt: Date?
    private var pendingFlush = false
    private let minNotifyInterval: TimeInterval = 0.016
    // [DONE] 受信で semaphore.signal() 済みかのフラグ。
    // llama-server は [DONE] 後も TCP 接続を数秒保持するため、
    // didCompleteWithError を待つと体感「生成終了後の無駄待ち」になる。
    private var didSignalOnDone = false

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        lineBuffer += text
        parseLines()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if pendingFlush {
            onDelta?(accContent, accReasoning)
            pendingFlush = false
        }
        if !didSignalOnDone {
            didSignalOnDone = true
            semaphore.signal()
        }
    }

    private func parseLines() {
        while let nlRange = lineBuffer.range(of: "\n") {
            let line = String(lineBuffer[..<nlRange.lowerBound])
            lineBuffer = String(lineBuffer[nlRange.upperBound...])
            processLine(line)
        }
    }

    private func processLine(_ line: String) {
        guard line.hasPrefix("data: ") else { return }
        let payload = String(line.dropFirst(6))
        if payload == "[DONE]" {
            // 生成完了: 未 flush のデルタを流し、接続クローズを待たず即 signal。
            if pendingFlush {
                onDelta?(accContent, accReasoning)
                pendingFlush = false
            }
            if !didSignalOnDone {
                didSignalOnDone = true
                semaphore.signal()
            }
            return
        }
        guard let raw = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return }
        // include_usage=true の最後のチャンクは choices:[] かつ usage を含む。
        if let usage = obj["usage"] as? [String: Any] {
            if let pt = usage["prompt_tokens"] as? Int { promptTokens = pt }
            if let ct = usage["completion_tokens"] as? Int { completionTokens = ct }
        }
        guard let choices = obj["choices"] as? [[String: Any]],
              let choice = choices.first else { return }
        if let fr = choice["finish_reason"] as? String, !fr.isEmpty, fr != "null" {
            finishReason = fr
        }
        guard let delta = choice["delta"] as? [String: Any] else { return }
        let cc = flattenedDeltaText(delta["content"])
        let rc = reasoningDeltaText(from: delta)
        // tool_calls デルタを index 別に累積する。
        // OpenAI 互換 SSE: 最初のデルタで {index, id, type, function:{name, arguments}} が来て、
        // 以降のデルタで function.arguments が断片で追加される。
        if let toolDeltas = delta["tool_calls"] as? [[String: Any]] {
            for d in toolDeltas {
                guard let idx = d["index"] as? Int else { continue }
                var buffer = toolCallBuffers[idx] ?? [
                    "id": "",
                    "type": "function",
                    "function": ["name": "", "arguments": ""]
                ]
                if let id = d["id"] as? String, !id.isEmpty {
                    buffer["id"] = id
                }
                if let type = d["type"] as? String {
                    buffer["type"] = type
                }
                if let fn = d["function"] as? [String: Any] {
                    var fnBuf = (buffer["function"] as? [String: Any]) ?? ["name": "", "arguments": ""]
                    if let name = fn["name"] as? String, !name.isEmpty {
                        fnBuf["name"] = name
                    }
                    if let args = fn["arguments"] as? String {
                        let prev = (fnBuf["arguments"] as? String) ?? ""
                        fnBuf["arguments"] = prev + args
                    }
                    buffer["function"] = fnBuf
                }
                toolCallBuffers[idx] = buffer
            }
            accToolCalls = toolCallBuffers
                .sorted { $0.key < $1.key }
                .map { $0.value }
        }
        guard !cc.isEmpty || !rc.isEmpty else { return }
        accContent += cc
        accReasoning += rc
        // 診断: 最初の non-empty デルタが content / reasoning_content のどちらに乗ってきたかを必ず記録。
        // Gemma 4 の `<|channel>thought\n...<channel|>` が content 側にこぼれていないか調べるため。
        if !cc.isEmpty && accContent.count - cc.count < 200 {
            NSLog("[BundledSSE] content delta(len=%d) prefix=%@", cc.count, String(cc.prefix(120)).replacingOccurrences(of: "\n", with: "\\n"))
        }
        if !rc.isEmpty && accReasoning.count - rc.count < 200 {
            NSLog("[BundledSSE] reasoning_content delta(len=%d) prefix=%@", rc.count, String(rc.prefix(120)).replacingOccurrences(of: "\n", with: "\\n"))
        }
        let now = Date()
        let hasThinkingDelta = !rc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            cc.localizedCaseInsensitiveContains("<|channel") ||
            cc.localizedCaseInsensitiveContains("<channel") ||
            cc.localizedCaseInsensitiveContains("<think")
        // Thinking は体感 TTFT が重要なので、最初の reasoning/channel 断片は 16ms
        // コアレスを待たず即 UI へ渡す。本文側は従来どおり 60fps 相当に抑える。
        if !hasThinkingDelta, let last = lastNotifiedAt, now.timeIntervalSince(last) < minNotifyInterval {
            pendingFlush = true
            return
        }
        lastNotifiedAt = now
        pendingFlush = false
        // 累積値を渡す（コンシューマーは accContent.dropFirst(prevContentLen) で
        // デルタを計算するため、デルタを渡してしまうと cleanVisibleAccum が更新されず
        // ストリーミング表示が完了時の一括描画になってしまう）。
        onDelta?(accContent, accReasoning)
    }

    private func reasoningDeltaText(from delta: [String: Any]) -> String {
        let keys = [
            "reasoning_content",
            "reasoningContent",
            "reasoning",
            "thinking",
            "thought",
            "thoughts"
        ]
        return keys
            .map { flattenedDeltaText(delta[$0]) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func flattenedDeltaText(_ rawValue: Any?) -> String {
        if let text = rawValue as? String {
            return text
        }
        if let items = rawValue as? [[String: Any]] {
            return items.compactMap { item -> String? in
                if let text = item["text"] as? String {
                    return text
                }
                if let text = item["content"] as? String {
                    return text
                }
                if let text = item["value"] as? String {
                    return text
                }
                return nil
            }.joined(separator: "\n")
        }
        if let item = rawValue as? [String: Any] {
            for key in ["text", "content", "value"] {
                let text = flattenedDeltaText(item[key])
                if !text.isEmpty {
                    return text
                }
            }
            return ""
        }
        return ""
    }
}

struct LocalAssistantRuntimeDiagnostic: Equatable {
    enum Stage: String, Equatable {
        case selfCheck = "self-check"
        case generation = "generation"
        case supportBrief = "support-brief"
    }

    let stage: Stage
    let kind: LocalAssistantRuntimeFailureKind
    let summary: String
    let detail: String?
    let terminationStatus: Int32?
    let runnerPath: String?
    let modelPath: String?

    var detailedMessage: String {
        var lines: [String] = [summary]
        if let terminationStatus {
            lines.append("終了コード: \(terminationStatus)")
        }
        if let runnerPath, runnerPath.isEmpty == false {
            lines.append("runner: \(runnerPath)")
        }
        if let modelPath, modelPath.isEmpty == false {
            lines.append("model: \(modelPath)")
        }
        if let detail, detail.isEmpty == false, detail != summary {
            lines.append(detail)
        }
        return lines.joined(separator: "\n")
    }
}

struct LocalAssistantRuntimeDebugSnapshot: Equatable {
    let stage: LocalAssistantRuntimeDiagnostic.Stage?
    let runnerLabel: String?
    let rawOutputPreview: String?
    let errorMessage: String?
    let diagnosticMessage: String?
}

private struct LocalAssistantModelCacheIdentity: Equatable {
    let path: String
    let size: Int64
    let modificationTime: TimeInterval
}

final class LocalAssistantRuntimeBridge {
    static let shared = LocalAssistantRuntimeBridge()

    private let queue = DispatchQueue(label: "viuk.local-runtime.embedded", qos: .userInitiated)
    private let queueSpecificKey = DispatchSpecificKey<Void>()
    private var cachedAvailability: LocalAssistantRuntimeAvailability = .modelMissing
    private var cachedModelPath: String?
    private var cachedModelIdentity: LocalAssistantModelCacheIdentity?
    private(set) var lastRuntimeError: String?
    private(set) var lastRuntimeDiagnostic: LocalAssistantRuntimeDiagnostic?
    private var lastRuntimeStage: LocalAssistantRuntimeDiagnostic.Stage?
    private var lastRuntimeRunnerLabel: String?
    private var lastRuntimeRawOutputPreview: String?
    private var validatedStructuredCapabilityModelPath: String?
    private var prewarmedModelPath: String?
    private var prewarmingModelPaths: Set<String> = []
    private var bundledServerSession: BundledServerSession?
    private var bundledServerLastUsedAt: Date?
    private let bundledServerIdleReuseWindow: TimeInterval = 10 * 60
    private var lastBundledServerLaunchErrorMessage: String?
    private let activeBundledRequestLock = NSLock()
    private var activeBundledRequestTask: URLSessionDataTask?

    /// 直近の bundled server レスポンスの usage。AICoachService が `ResponseDebugDetails`
    /// 構築時に読み取り、UI に「prompt N tok / completion M tok」を表示する。
    struct TokenUsage {
        let promptTokens: Int?
        let completionTokens: Int?
        let recordedAt: Date
    }
    private(set) var latestChatTokenUsage: TokenUsage?

    fileprivate func recordChatTokenUsage(_ response: BundledServerChatResponse) {
        if response.promptTokens != nil || response.completionTokens != nil {
            latestChatTokenUsage = TokenUsage(
                promptTokens: response.promptTokens,
                completionTokens: response.completionTokens,
                recordedAt: Date()
            )
        }
    }

    // MARK: - 投機デコード設定 (ユーザー選択 + バイナリ capability)

    /// ユーザーが設定 UI で選択した投機デコードモード。
    /// AICoachService が advancedSettings 更新時に updateSpeculativeDecodingMode 経由で反映する。
    private var userSpeculativeDecodingMode: SpeculativeDecodingMode = .auto

    /// llama-server バイナリの help 出力から抽出した capability キャッシュ (bundledServerCandidateURL ごと)。
    private var serverCapabilityCache: [String: ServerCapabilities] = [:]

    /// llama-server が `--mtp-load` で MTP ヘッドの非対応エラーを起こしたモデルを記録。
    /// 以降は自動フォールバックで MTP を要求しないようにする。
    private var mtpUnsupportedModelPaths: Set<String> = []

    /// バンドル llama-server が公開している投機デコードオプションを保持する。
    private struct ServerCapabilities {
        /// `--spec-type` で受け付けるオプション集合 (例: ["mtp", "ngram-cache", ...])。
        let availableSpecTypes: Set<String>
        /// `--draft-max` 等の draft 関連フラグが存在するか。
        let supportsDraftMax: Bool
    }
    // sendMessage 発行前に AICoachService がセットする会話履歴。
    // generateReply / performStructuredTurn が消費後 nil にリセットする。
    private var stagedChatHistory: [AICoachService.ChatMessage]?

    /// 次の generate 呼び出し用に会話履歴をステージングする（AICoachService から呼ぶ）。
    /// キュー外 (MainActor) から呼んでも安全なよう DispatchQueue.async で保護。
    func stageChatHistory(_ history: [AICoachService.ChatMessage]) {
        queue.async { self.stagedChatHistory = history }
    }

    private init() {
        queue.setSpecific(key: queueSpecificKey, value: ())
        registerLifecycleTerminationHooks()
    }

    /// アプリ終了時 / SIGTERM 受信時に llama-server の子プロセスを確実に止める。
    /// 怠るとポート占有・GPU メモリ占有のまま孤児プロセスが残り、再起動時の
    /// `ensureBundledServer` がポート競合で失敗する原因になる。
    private func registerLifecycleTerminationHooks() {
        #if os(macOS)
        let center = NotificationCenter.default
        center.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.terminateBundledServerBlockingForShutdown()
        }
        #endif
    }

    /// アプリ終了パスで使う同期版。queue を待たずに即時 terminate を呼ぶ。
    fileprivate func terminateBundledServerBlockingForShutdown() {
        queue.sync { [weak self] in
            self?.terminateBundledServer()
        }
    }

    func cancelActiveGeneration() {
        // LiteRT-LMはURLSession/bundled serverではないため、SDKのConversationへ
        // 明示的にcancelを届ける。これをしないとUIだけ停止して推論は続行する。
        LocalAssistantLiteRTLMRuntime.shared.cancelActiveGeneration()
        activeBundledRequestLock.lock()
        let task = activeBundledRequestTask
        activeBundledRequestTask = nil
        activeBundledRequestLock.unlock()
        task?.cancel()
        queue.async { [weak self] in
            self?.terminateBundledServer()
        }
    }

    private func setActiveBundledRequestTask(_ task: URLSessionDataTask?) {
        activeBundledRequestLock.lock()
        activeBundledRequestTask = task
        activeBundledRequestLock.unlock()
    }

    var runtimeLabel: String {
        switch preferredRuntimeEngine {
        case .embedded:
            return "埋め込み runtime"
        case .bundledServer:
            return "ローカル server"
        case .bundledCLI:
            return "ローカル runtime"
        case .liteRTLM:
            return "LiteRT-LM"
        case .unavailable:
            return "ローカル runtime"
        }
    }

    var isBundledRunnerAvailable: Bool {
        embeddedRuntimeSupported
            || bundledServerCandidateURLs.isEmpty == false
            || bundledCLICandidateURLs.isEmpty == false
            || LocalAssistantLiteRTLMRuntime.shared.isRuntimeLinked
    }

    var hasRecentRuntimeFailure: Bool {
        readState {
            cachedAvailability == .recentFailure
        }
    }

    func prewarmIfPossible() {
#if !os(macOS)
        // iOSはアプリ起動時にnative Engineを先回りで初期化しない。
        // ModelManagerがモデル検出後に一度だけ、UIへ状態を出しながら自動self-checkする。
        return
        #else
        guard let installedModelURL = LocalAssistantModelManager.shared.installedModelURL else {
            return
        }

        let modelPath = installedModelURL.path
        let preferredEngine = prewarmRuntimeEngine(forModelPath: modelPath)
        guard preferredEngine != .unavailable else {
            return
        }
        queue.async {
            guard self.prewarmedModelPath != modelPath else { return }
            guard self.prewarmingModelPaths.insert(modelPath).inserted else { return }
            defer { self.prewarmingModelPaths.remove(modelPath) }
            switch preferredEngine {
            case .embedded:
#if os(macOS)
                let result = VIUKEmbeddedRuntime.shared().performSelfCheck(withModelPath: modelPath, maxTokens: 12)
                if result.success {
                    self.prewarmedModelPath = modelPath
                    if self.cachedModelPath == nil {
                        self.cacheModelIdentity(forModelPath: modelPath)
                    }
                }
#endif
            case .bundledServer:
                self.warmModelFileCache(modelPath: modelPath, maxBytes: LocalAssistantModelProfile.prewarmReadAheadBytes)
                if self.ensureBundledServer(modelPath: modelPath, timeoutSeconds: LocalAssistantModelProfile.prewarmTimeoutSeconds) != nil {
                    self.prewarmedModelPath = modelPath
                    if self.cachedModelPath == nil {
                        self.cacheModelIdentity(forModelPath: modelPath)
                    }
                }
            case .bundledCLI:
                self.warmModelFileCache(modelPath: modelPath, maxBytes: LocalAssistantModelProfile.prewarmReadAheadBytes)
                if self.performBundledCLIPrewarm(modelPath: modelPath) {
                    self.prewarmedModelPath = modelPath
                    if self.cachedModelPath == nil {
                        self.cacheModelIdentity(forModelPath: modelPath)
                    }
                }
            case .liteRTLM:
                break
            case .unavailable:
                break
            }
        }
        #endif
    }

    private func hasAvailableRuntimeEngine(_ engine: RuntimeEngine) -> Bool {
        switch engine {
        case .embedded:
            return embeddedRuntimeSupported
        case .bundledServer:
            return bundledServerCandidateURLs.isEmpty == false
        case .bundledCLI:
            return bundledCLICandidateURLs.isEmpty == false
        case .liteRTLM:
            return LocalAssistantLiteRTLMRuntime.shared.isRuntimeLinked
        case .unavailable:
            return false
        }
    }

    private func usesBundledCLI(_ engine: RuntimeEngine) -> Bool {
        if case .bundledCLI = engine {
            return true
        }
        return false
    }

    private func usesBundledServer(_ engine: RuntimeEngine) -> Bool {
        if case .bundledServer = engine {
            return true
        }
        return false
    }

    private func usesSplitPromptTransport(_ engine: RuntimeEngine) -> Bool {
        // LiteRT-LM's ConversationConfig has a first-class systemMessage.
        // Passing a serialized `<start_of_turn>system` prompt as a user message
        // made the small on-device model treat the formatting instructions as
        // ordinary text and occasionally answer with only an ellipsis.
        switch engine {
        case .bundledCLI, .bundledServer, .liteRTLM:
            return true
        case .embedded, .unavailable:
            return false
        }
    }

    private func warmModelFileCache(modelPath: String, maxBytes: Int64) {
        guard maxBytes > 0 else { return }
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: modelPath)) else { return }
        defer {
            try? handle.close()
        }

        var remaining = maxBytes
        let chunkSize = 4 * 1024 * 1024
        while remaining > 0 {
            let nextCount = min(Int64(chunkSize), remaining)
            guard let data = try? handle.read(upToCount: Int(nextCount)), !data.isEmpty else {
                break
            }
            remaining -= Int64(data.count)
        }
    }

    private func performBundledCLIPrewarm(modelPath: String) -> Bool {
        guard let runnerURL = bundledCLICandidateURLs.first else { return false }

        let runtimePreset = LocalAssistantModelProfile.prewarmRuntimePreset
        let forceConservativeCPURuntime = shouldForceConservativeCPURuntime(forModelPath: modelPath)
        let flashAttentionEnabled = forceConservativeCPURuntime ? false : runtimePreset.flashAttentionEnabled
        let gpuLayers = forceConservativeCPURuntime ? 0 : runtimePreset.gpuLayers
        let disableKVOffload = forceConservativeCPURuntime ? true : runtimePreset.disableKVOffload
        var arguments = [
            "--simple-io",
            "--log-disable",
            "--no-display-prompt",
            "--single-turn",
            "--model", modelPath,
            "--predict", "1",
            "--ctx-size", String(runtimePreset.contextSize),
            "--batch-size", String(runtimePreset.batchSize),
            "--ubatch-size", String(runtimePreset.microBatchSize),
            "--threads", String(runtimePreset.threadCount),
            "--threads-batch", String(runtimePreset.batchThreadCount),
            "--flash-attn", flashAttentionEnabled ? "on" : "off",
            "--temp", "0",
            "--top-p", "0.7",
            "--top-k", "16",
            "--seed", "7",
            "--prompt", "ok"
        ]
        if forceConservativeCPURuntime {
            arguments.append(contentsOf: ["--device", "none"])
        } else if gpuLayers > 0 {
            arguments.append(contentsOf: ["--gpu-layers", String(gpuLayers)])
        }
        if disableKVOffload {
            arguments.append("--no-kv-offload")
        }

        let process = Process()
        process.executableURL = runnerURL
        process.arguments = arguments
        process.qualityOfService = .utility

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let terminationSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            terminationSemaphore.signal()
        }

        do {
            try process.run()
        } catch {
            return false
        }

        let timeout = DispatchTime.now() + .seconds(LocalAssistantModelProfile.prewarmTimeoutSeconds)
        let completed = terminationSemaphore.wait(timeout: timeout) == .success
        if !completed, process.isRunning {
            process.terminate()
        }

        _ = outputPipe.fileHandleForReading.readDataToEndOfFile()
        _ = errorPipe.fileHandleForReading.readDataToEndOfFile()

        return completed ? process.terminationStatus == 0 : true
    }

    private func terminateBundledServer() {
        guard let session = bundledServerSession else { return }
        bundledServerSession = nil
        bundledServerLastUsedAt = nil
        if session.process.isRunning {
            session.process.terminate()
            // SIGTERM 後にポートが解放される前に次のサーバーが起動すると EADDRINUSE になる。
            // waitUntilExit() でプロセスの完全終了を待ち、ポート競合を防ぐ。
            // シリアルキューで呼ばれるため一時ブロックは問題ない。
            session.process.waitUntilExit()
        }
    }

    private func bundledServerFailureMessage(_ fallback: String) -> String {
        let message = lastBundledServerLaunchErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (message?.isEmpty == false) ? message! : fallback
    }

    private func ensureBundledServer(
        modelPath: String,
        timeoutSeconds: Int = 60,
        reasoningMode: ReasoningMode = .thinking
    ) -> BundledServerSession? {
        lastBundledServerLaunchErrorMessage = nil
        let nativeThinkingEnabled = shouldEnableNativeThinking(forModelPath: modelPath, reasoningMode: reasoningMode)

        // 投機デコードの解決: 先に runner を取得して capability 検出 → ユーザー選択と突き合わせ
        guard let runnerURL = bundledServerCandidateURLs.first else {
            return nil
        }
        let capabilities = detectServerCapabilities(runnerURL: runnerURL)
        let resolvedSpecType = resolveSpecType(
            userMode: userSpeculativeDecodingMode,
            modelPath: modelPath,
            capabilities: capabilities
        )

        if let session = bundledServerSession,
           session.modelPath == modelPath,
           session.nativeThinkingEnabled == nativeThinkingEnabled,
           session.activeSpecType == resolvedSpecType,
           session.process.isRunning,
           (bundledServerLastUsedAt == nil || Date().timeIntervalSince(bundledServerLastUsedAt ?? .distantPast) <= bundledServerIdleReuseWindow),
           waitForBundledServerReady(port: session.port, apiKey: session.apiKey, timeoutSeconds: 2) {
            bundledServerLastUsedAt = Date()
            return session
        }

        terminateBundledServer()

        let runtimePreset = bundledServerRuntimePreset(forModelPath: modelPath, reasoningMode: reasoningMode)
        // localhost 上でも他プロセスから推論APIへ接続できるため、
        // 起動ごとに推測できない一時キーを発行して認証する。
        let apiKey = UUID().uuidString.replacingOccurrences(of: "-", with: "")

        for port in bundledServerPortCandidates() {
            guard isBundledServerPortAvailable(port) else {
                continue
            }

            let process = Process()
            process.executableURL = runnerURL
            process.qualityOfService = .userInitiated

            var arguments = [
                "--host", "127.0.0.1",
                "--port", String(port),
                "--api-key", apiKey,
                "--model", modelPath,
                "--alias", "viuk-local",
                "--ctx-size", String(runtimePreset.contextSize),
                "--batch-size", String(runtimePreset.batchSize),
                "--ubatch-size", String(runtimePreset.microBatchSize),
                "--threads", String(runtimePreset.threadCount),
                "--threads-batch", String(runtimePreset.batchThreadCount),
                "--flash-attn", runtimePreset.flashAttentionEnabled ? "on" : "off",
                "--parallel", "1",
                "--timeout", "120",
                "--no-webui",
                "--cache-prompt",
                // KV シフトで前回プロンプトとの共通 prefix を最大限再利用（チャット連続質問で大幅高速化）
                "--cache-reuse", "64",
                "--jinja"
            ]

            // 投機デコード (resolveSpecType で解決された --spec-type):
            // - mtp: Google 公式 MTP ヘッド経由 (最大 3x 高速化)
            // - ngram-*: ドラフトモデル不要の n-gram 推測 (10〜30% 高速化)
            // - nil: 投機デコード無効
            // ユーザーが設定 UI で auto/明示選択でき、binary 未対応の場合は自動でフォールバックする。
            if let specType = resolvedSpecType {
                arguments.append(contentsOf: ["--spec-type", specType])
                if capabilities.supportsDraftMax {
                    // mtp は draft-max 4 が公式推奨、n-gram は 8 が経験則的に良い
                    let draftMax = (specType == "mtp") ? "4" : "8"
                    arguments.append(contentsOf: ["--draft-max", draftMax])
                }
                // n-gram-* 系のみ ngram-min-hits を指定 (mtp では無関係)
                if specType.hasPrefix("ngram") {
                    arguments.append(contentsOf: ["--spec-ngram-min-hits", "1"])
                }
            }

            if !nativeThinkingEnabled {
                arguments.append(contentsOf: [
                    "--reasoning", "off",
                    "--chat-template-kwargs", #"{"enable_thinking":false}"#
                ])
            } else {
                // Gemma 4 はチャットテンプレートの `enable_thinking` kwarg で
                // `<|think|>` トリガーを先頭挿入する必要がある。サーバー起動時に
                // 明示しないと per-request の chat_template_kwargs が効かない
                // ビルドが存在するため、起動引数でも有効化する。
                // セッション起動時は -1 にしておき、各リクエストの
                // thinking_budget_tokens でモード別 budget を渡す。
                arguments.append(contentsOf: [
                    "--reasoning", "on",
                    "--reasoning-format", "auto",
                    "--reasoning-budget", "-1",
                    "--chat-template-kwargs", #"{"enable_thinking":true}"#
                ])
            }

            // bundled server は preset の gpuLayers を直接使用する（CLI の --device none は適用しない）
            if runtimePreset.gpuLayers > 0 {
                arguments.append(contentsOf: ["--gpu-layers", String(runtimePreset.gpuLayers)])
            }
            if runtimePreset.disableKVOffload {
                arguments.append("--no-kv-offload")
            }
            // RAM に余裕がある環境ではモデルを mlock で固定し、2回目以降のページアウト/再読込を防ぐ。
            // ディスク圧迫時やメモリ少量時は mlock しない。
            let physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory
            let hasPlentyRAM = physicalMemoryBytes >= 15 * 1024 * 1024 * 1024
            if hasPlentyRAM && !hasSevereDiskPressure(forModelPath: modelPath) {
                arguments.append("--mlock")
            }

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            process.arguments = arguments

            let stderrAggregator = BundledServerLogAggregator()
            attachBundledServerLogStream(pipe: errorPipe, aggregator: stderrAggregator)

            do {
                try process.run()
            } catch {
                errorPipe.fileHandleForReading.readabilityHandler = nil
                let diagnostic = classifyRuntimeFailure(
                    stage: .generation,
                    rawMessage: "ローカル server の起動に失敗しました: \(error.localizedDescription)",
                    terminationStatus: nil,
                    runnerPath: runnerURL.path,
                    modelPath: modelPath
                )
                lastRuntimeDiagnostic = diagnostic
                lastRuntimeError = diagnostic.detailedMessage
                lastBundledServerLaunchErrorMessage = diagnostic.detailedMessage
                continue
            }

            let session = BundledServerSession(
                process: process,
                port: port,
                modelPath: modelPath,
                runnerPath: runnerURL.path,
                apiKey: apiKey,
                nativeThinkingEnabled: nativeThinkingEnabled,
                activeSpecType: resolvedSpecType
            )
            bundledServerSession = session

            LocalAssistantModelManager.shared.updateModelLoadProgress(
                LocalAssistantLoadProgress(fraction: 0.04, message: "サーバーを起動中…", isDone: false)
            )
            if waitForBundledServerReady(
                port: port,
                apiKey: apiKey,
                timeoutSeconds: timeoutSeconds,
                reportProgress: true,
                logAggregator: stderrAggregator
            ) {
                errorPipe.fileHandleForReading.readabilityHandler = nil
                bundledServerLastUsedAt = Date()
                return session
            }

            errorPipe.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stderr = stderrAggregator.snapshot().trimmingCharacters(in: .whitespacesAndNewlines)
            let message = stderr.isEmpty ? stdout : stderr
            let diagnostic = classifyRuntimeFailure(
                stage: .generation,
                rawMessage: message.isEmpty ? "ローカル server の起動に失敗しました。" : message,
                terminationStatus: process.terminationStatus,
                runnerPath: runnerURL.path,
                modelPath: modelPath
            )
            lastBundledServerLaunchErrorMessage = diagnostic.detailedMessage
            bundledServerSession = nil
        }

        return nil
    }

    private func bundledServerPortCandidates() -> [Int] {
        var candidates = Set<Int>()
        while candidates.count < 16 {
            candidates.insert(Int.random(in: 49_152...65_535))
        }
        return Array(candidates)
    }

    private func isBundledServerPortAvailable(_ port: Int) -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(socketFD, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private func waitForBundledServerReady(
        port: Int,
        apiKey: String,
        timeoutSeconds: Int,
        reportProgress: Bool = false,
        logAggregator: BundledServerLogAggregator? = nil
    ) -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        let started = Date()
        // fallback 時間見積もり。実測で 5GB GGUF + Metal 初回コンパイルは 25-45 秒かかる。
        let expectedSeconds: Double = 35
        while Date() < deadline {
            if !isCurrentBundledServerProcessRunning() {
                if reportProgress {
                    LocalAssistantModelManager.shared.updateModelLoadProgress(nil)
                }
                return false
            }
            if bundledServerHealthStatus(port: port, apiKey: apiKey) == 200 {
                if reportProgress {
                    LocalAssistantModelManager.shared.updateModelLoadProgress(
                        LocalAssistantLoadProgress(fraction: 1.0, message: "準備完了", isDone: true)
                    )
                }
                return true
            }
            if reportProgress {
                let elapsed = Date().timeIntervalSince(started)
                let milestone = logAggregator?.currentMilestone() ?? .starting
                let timeFraction = min(0.92, 0.04 + (elapsed / expectedSeconds) * 0.88)
                // 実ログから拾ったマイルストーンと時間ベースの大きい方を採用（戻らない進捗）。
                let fraction = max(milestone.fraction, timeFraction)
                LocalAssistantModelManager.shared.updateModelLoadProgress(
                    LocalAssistantLoadProgress(fraction: fraction, message: milestone.message, isDone: false)
                )
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        if reportProgress {
            LocalAssistantModelManager.shared.updateModelLoadProgress(nil)
        }
        return false
    }

    fileprivate func attachBundledServerLogStream(
        pipe: Pipe,
        aggregator: BundledServerLogAggregator
    ) {
        var buffer = Data()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            buffer.append(chunk)
            let newline: UInt8 = 0x0A
            while let idx = buffer.firstIndex(of: newline) {
                let lineData = buffer.subdata(in: 0..<idx)
                buffer.removeSubrange(0...idx)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                aggregator.append(line: line)
            }
        }
    }

/// llama.cpp server の stderr をストリーム収集し、進捗マイルストーンを判定する。
final class BundledServerLogAggregator {
    enum Milestone: Int, Comparable {
        case starting = 0
        case parsingGGUF = 1
        case loadingTensors = 2
        case offloadingToGPU = 3
        case compilingMetal = 4
        case allocatingKV = 5
        case finalizing = 6
        case listening = 7

        static func < (lhs: Milestone, rhs: Milestone) -> Bool { lhs.rawValue < rhs.rawValue }

        var fraction: Double {
            switch self {
            case .starting: return 0.04
            case .parsingGGUF: return 0.12
            case .loadingTensors: return 0.30
            case .offloadingToGPU: return 0.55
            case .compilingMetal: return 0.72
            case .allocatingKV: return 0.84
            case .finalizing: return 0.92
            case .listening: return 0.98
            }
        }

        var message: String {
            switch self {
            case .starting: return "サーバーを起動中…"
            case .parsingGGUF: return "モデル情報を解析中…"
            case .loadingTensors: return "テンソルを読み込み中…"
            case .offloadingToGPU: return "GPUにレイヤーを転送中…"
            case .compilingMetal: return "Metalカーネルをコンパイル中…"
            case .allocatingKV: return "KVキャッシュを確保中…"
            case .finalizing: return "チャットテンプレートを準備中…"
            case .listening: return "最終確認中…"
            }
        }
    }

    private let lock = NSLock()
    private var aggregated = ""
    private var milestone: Milestone = .starting

    func append(line: String) {
        lock.lock()
        defer { lock.unlock() }
        aggregated += line + "\n"
        if aggregated.count > 64 * 1024 {
            aggregated = String(aggregated.suffix(48 * 1024))
        }
        updateMilestone(from: line)
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return aggregated
    }

    func currentMilestone() -> Milestone {
        lock.lock()
        defer { lock.unlock() }
        return milestone
    }

    private func advance(_ next: Milestone) {
        if next > milestone { milestone = next }
    }

    private func updateMilestone(from line: String) {
        let lower = line.lowercased()
        if lower.contains("listening") || lower.contains("server is listening") || lower.contains("starting the main loop") {
            advance(.listening)
            return
        }
        if lower.contains("model loaded") || lower.contains("chat template") || lower.contains("srv  log_server_r") {
            advance(.finalizing)
            return
        }
        if lower.contains("kv self") || lower.contains("kv cache") || lower.contains("llama_kv_cache") || lower.contains("llama_context:") {
            advance(.allocatingKV)
            return
        }
        if lower.contains("ggml_metal") || lower.contains("compiling metal") || lower.contains("using embedded metal library") {
            advance(.compilingMetal)
            return
        }
        if lower.contains("offloaded") && lower.contains("layer") {
            advance(.offloadingToGPU)
            return
        }
        if lower.contains("load_tensors") || lower.contains("loading model tensors") {
            advance(.loadingTensors)
            return
        }
        if lower.contains("llama_model_loader") || lower.contains("print_info:") || lower.contains("gguf") {
            advance(.parsingGGUF)
            return
        }
    }
}

    private func isCurrentBundledServerProcessRunning() -> Bool {
        bundledServerSession?.process.isRunning ?? false
    }

    private func bundledServerHealthStatus(port: Int, apiKey: String) -> Int {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return -1 }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let semaphore = DispatchSemaphore(value: 0)
        var statusCode = -1
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 3)
        return statusCode
    }

    func clearRuntimeError() {
        readState {
            lastRuntimeError = nil
            lastRuntimeDiagnostic = nil
            validatedStructuredCapabilityModelPath = nil
            if cachedAvailability == .recentFailure {
                cachedAvailability = cachedModelPath == nil ? .modelMissing : .savedOnly
            }
        }
#if os(macOS) || os(iOS)
        VIUKEmbeddedRuntime.shared().clearCachedModel()
#endif
        terminateBundledServer()
    }

    private func modelCacheIdentity(forModelPath modelPath: String) -> LocalAssistantModelCacheIdentity? {
        let url = URL(fileURLWithPath: modelPath)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let fileSize = values.fileSize.map(Int64.init),
              let modificationDate = values.contentModificationDate else {
            return nil
        }
        return LocalAssistantModelCacheIdentity(
            path: modelPath,
            size: fileSize,
            modificationTime: modificationDate.timeIntervalSinceReferenceDate
        )
    }

    private func cacheModelIdentity(forModelPath modelPath: String) {
        cachedModelPath = modelPath
        cachedModelIdentity = modelCacheIdentity(forModelPath: modelPath)
    }

    private func clearCachedModelIdentity() {
        cachedModelPath = nil
        cachedModelIdentity = nil
    }

    private func cachedModelIdentityMatches(modelPath: String) -> Bool {
        guard cachedModelPath == modelPath,
              let cachedModelIdentity,
              let currentIdentity = modelCacheIdentity(forModelPath: modelPath) else {
            return false
        }
        return cachedModelIdentity == currentIdentity
    }

    func availability(installedModelURL: URL?) -> LocalAssistantRuntimeAvailability {
        readState {
            guard let installedModelURL else {
                return .modelMissing
            }
            let preferredEngine = preferredRuntimeEngine(forModelPath: installedModelURL.path)
            guard hasAvailableRuntimeEngine(preferredEngine) else {
                if preferredEngine == .liteRTLM {
                    return markLiteRTLMUnavailable(
                        stage: .selfCheck,
                        modelPath: installedModelURL.path
                    )
                }
#if os(iOS)
                return markLocalRuntimeUnavailable(
                    stage: .selfCheck,
                    modelPath: installedModelURL.path,
                    summary: "このiOSビルドでは現在のモデル形式を実行できません。",
                    detail: "iOS実機では .gguf/.bin は埋め込みruntime、.litertlm はLiteRT-LM native runtimeで実行します。現在のファイル形式には対応する経路がありません。"
                )
#else
                return .savedOnly
#endif
            }
            if cachedModelIdentityMatches(modelPath: installedModelURL.path) {
                return cachedAvailability
            }
            return .savedOnly
        }
    }

    func performSelfCheck(installedModelURL: URL?) async -> LocalAssistantRuntimeAvailability {
        guard let installedModelURL else {
            return readState {
                clearCachedModelIdentity()
                cachedAvailability = .modelMissing
                lastRuntimeError = nil
                return .modelMissing
            }
        }

        let preferredEngine = preferredRuntimeEngine(forModelPath: installedModelURL.path)
        let selfCheckEngine = selfCheckRuntimeEngine(forModelPath: installedModelURL.path)

        guard hasAvailableRuntimeEngine(preferredEngine) else {
            return readState {
                cacheModelIdentity(forModelPath: installedModelURL.path)
                if preferredEngine == .liteRTLM {
                    return markLiteRTLMUnavailable(
                        stage: .selfCheck,
                        modelPath: installedModelURL.path
                    )
                }
#if os(iOS)
                return markLocalRuntimeUnavailable(
                    stage: .selfCheck,
                    modelPath: installedModelURL.path,
                    summary: "このiOSビルドでは現在のモデル形式を実行できません。",
                    detail: "iOS実機では .gguf/.bin は埋め込みruntime、.litertlm はLiteRT-LM native runtimeで実行します。現在のファイル形式には対応する経路がありません。"
                )
#else
                cachedAvailability = .savedOnly
                lastRuntimeError = nil
                return .savedOnly
#endif
            }
        }

        let modelPath = installedModelURL.path
        let alreadyExecutable = readState {
            cachedModelIdentityMatches(modelPath: modelPath) && cachedAvailability == .executable
        }
        if alreadyExecutable {
            return .executable
        }

        if selfCheckEngine == .liteRTLM {
            let result = await LocalAssistantLiteRTLMRuntime.shared.performSelfCheckAsync(modelPath: modelPath)
            return await withCheckedContinuation { continuation in
                queue.async {
                    self.cacheModelIdentity(forModelPath: modelPath)
                    if result.success {
                        self.cachedAvailability = .executable
                        self.lastRuntimeError = nil
                        self.lastRuntimeDiagnostic = nil
                    } else {
                        let diagnostic = self.classifyRuntimeFailure(
                            stage: .selfCheck,
                            rawMessage: result.errorMessage,
                            terminationStatus: nil
                        )
                        self.cachedAvailability = .recentFailure
                        self.lastRuntimeDiagnostic = diagnostic
                        self.lastRuntimeError = diagnostic.detailedMessage
                    }
                    continuation.resume(returning: self.cachedAvailability)
                }
            }
        }

        return await withCheckedContinuation { continuation in
            queue.async {
                let result = self.performRuntimeSelfCheck(modelPath: modelPath)
                self.cacheModelIdentity(forModelPath: modelPath)
                if result.success {
                    self.cachedAvailability = .executable
                    self.lastRuntimeError = nil
                    self.lastRuntimeDiagnostic = nil
                } else {
                    let rawMessage = result.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let canFallbackToCLI = self.usesBundledCLI(preferredEngine) && !self.usesBundledCLI(selfCheckEngine)
                    let embeddedLoadMismatch = canFallbackToCLI && (
                        rawMessage.contains("モデルファイルの読み込みに失敗しました") ||
                        rawMessage.localizedCaseInsensitiveContains("failed to load the model") ||
                        rawMessage.localizedCaseInsensitiveContains("failed to load model")
                    )

                    if embeddedLoadMismatch {
                        self.cachedAvailability = .savedOnly
                        let diagnostic = LocalAssistantRuntimeDiagnostic(
                            stage: .selfCheck,
                            kind: .modelLoadFailed,
                            summary: "埋め込み確認では Gemma 4 を読めませんでした。この端末でのローカル実行はまだ確認できていません。",
                            detail: rawMessage,
                            terminationStatus: nil,
                            runnerPath: nil,
                            modelPath: modelPath
                        )
                        self.lastRuntimeDiagnostic = diagnostic
                        self.lastRuntimeError = nil
                    } else {
                        self.cachedAvailability = .recentFailure
                        let diagnostic = self.classifyRuntimeFailure(
                            stage: .selfCheck,
                            rawMessage: result.errorMessage,
                            terminationStatus: nil
                        )
                        self.lastRuntimeDiagnostic = diagnostic
                        self.lastRuntimeError = diagnostic.detailedMessage
                    }
#if os(macOS)
                    VIUKEmbeddedRuntime.shared().clearCachedModel()
#endif
                }
                continuation.resume(returning: self.cachedAvailability)
            }
        }
    }

    func generationRuntimeEngineOrderForTesting(modelPath: String?) -> [String] {
        generationRuntimeEngines(forModelPath: modelPath).map(runtimeEngineDebugLabel)
    }

    func prewarmRuntimeEngineForTesting(modelPath: String?) -> String {
        runtimeEngineDebugLabel(prewarmRuntimeEngine(forModelPath: modelPath))
    }

    func selfCheckRuntimeEngineOrderForTesting(modelPath: String?) -> [String] {
        selfCheckRuntimeEngines(forModelPath: modelPath).map(runtimeEngineDebugLabel)
    }

    func shouldSkipChatParsingForTesting(modelPath: String) -> Bool {
        shouldSkipChatParsing(forModelPath: modelPath)
    }

    func shouldForceConservativeCPURuntimeForTesting(modelPath: String) -> Bool {
        shouldForceConservativeCPURuntime(forModelPath: modelPath)
    }

    func shouldDisableNativeThinkingForTesting(modelPath: String) -> Bool {
        shouldDisableNativeThinking(forModelPath: modelPath)
    }

    func bundledServerRuntimePresetForTesting(modelPath: String) -> LocalAssistantModelProfile.RuntimePreset {
        bundledServerRuntimePreset(forModelPath: modelPath)
    }

    func parseStructuredTurnForTesting(
        _ text: String,
        enabledToolNames: [String] = AIToolCatalog.toolNames
    ) -> LocalAssistantStructuredTurn {
        parseStructuredTurnOutput(text, enabledToolNames: enabledToolNames)
    }

    func nextAvailabilityAfterGenerationFailureForTesting(
        previousAvailability: LocalAssistantRuntimeAvailability
    ) -> LocalAssistantRuntimeAvailability {
        nextAvailabilityAfterGenerationFailure(previousAvailability: previousAvailability)
    }

    private func runtimeEngineDebugLabel(_ engine: RuntimeEngine) -> String {
        switch engine {
        case .embedded:
            return "embedded"
        case .bundledServer:
            return "bundledServer"
        case .bundledCLI:
            return "bundledCLI"
        case .liteRTLM:
            return "liteRTLM"
        case .unavailable:
            return "unavailable"
        }
    }

    private func makeLiteRTLMUnavailableDiagnostic(
        stage: LocalAssistantRuntimeDiagnostic.Stage,
        modelPath: String?
    ) -> LocalAssistantRuntimeDiagnostic {
        LocalAssistantRuntimeDiagnostic(
            stage: stage,
            kind: .runnerUnavailable,
            summary: LocalAssistantLiteRTLMRuntime.shared.unavailableReason,
            detail: "LiteRT-LM native runtime を読み込めません。LiteRT-LM パッケージの解決状態と、端末上の .litertlm モデルを確認してください。",
            terminationStatus: nil,
            runnerPath: "LiteRTLM.Engine",
            modelPath: modelPath
        )
    }

    private func markLiteRTLMUnavailable(
        stage: LocalAssistantRuntimeDiagnostic.Stage,
        modelPath: String?
    ) -> LocalAssistantRuntimeAvailability {
        let diagnostic = makeLiteRTLMUnavailableDiagnostic(stage: stage, modelPath: modelPath)
        if let modelPath {
            cacheModelIdentity(forModelPath: modelPath)
        } else {
            clearCachedModelIdentity()
        }
        cachedAvailability = .recentFailure
        lastRuntimeDiagnostic = diagnostic
        lastRuntimeError = diagnostic.detailedMessage
        return .recentFailure
    }

    private func markLocalRuntimeUnavailable(
        stage: LocalAssistantRuntimeDiagnostic.Stage,
        modelPath: String?,
        summary: String,
        detail: String
    ) -> LocalAssistantRuntimeAvailability {
        let diagnostic = LocalAssistantRuntimeDiagnostic(
            stage: stage,
            kind: .runnerUnavailable,
            summary: summary,
            detail: detail,
            terminationStatus: nil,
            runnerPath: nil,
            modelPath: modelPath
        )
        if let modelPath {
            cacheModelIdentity(forModelPath: modelPath)
        } else {
            clearCachedModelIdentity()
        }
        cachedAvailability = .recentFailure
        lastRuntimeDiagnostic = diagnostic
        lastRuntimeError = diagnostic.detailedMessage
        return .recentFailure
    }

    private func readState<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueSpecificKey) != nil {
            return body()
        }
        return queue.sync(execute: body)
    }

    func latestDebugSnapshot() -> LocalAssistantRuntimeDebugSnapshot {
        readState {
            LocalAssistantRuntimeDebugSnapshot(
                stage: lastRuntimeStage,
                runnerLabel: lastRuntimeRunnerLabel,
                rawOutputPreview: lastRuntimeRawOutputPreview,
                errorMessage: lastRuntimeError,
                diagnosticMessage: lastRuntimeDiagnostic?.detailedMessage
            )
        }
    }

    private func emitStatus(
        _ stage: LocalExecutionStage,
        title: String,
        detail: String,
        estimatedProgress: Int,
        runnerLabel: String? = nil,
        warmState: LocalRuntimeWarmState? = nil,
        startedAt: Date,
        onUpdate: (@MainActor @Sendable (LocalAssistantStructuredTurnUpdate) -> Void)?
    ) {
        guard let onUpdate else { return }

        let status = LocalExecutionStatusUpdate(
            stage: stage,
            title: title,
            detail: detail,
            estimatedProgress: estimatedProgress,
            runnerLabel: runnerLabel,
            warmState: warmState,
            elapsedSeconds: Date().timeIntervalSince(startedAt)
        )

        Task { @MainActor in
            onUpdate(.status(status))
        }
    }

    private func warmState(for engine: RuntimeEngine, modelPath: String) -> LocalRuntimeWarmState? {
        switch engine {
        case .bundledServer:
            if hasWarmBundledServer(forModelPath: modelPath) {
                return .reusedWarmSession
            }
            if prewarmingModelPaths.contains(modelPath) {
                return .warming
            }
            if prewarmedModelPath == modelPath {
                return .warmReady
            }
            return .coldStart
        case .bundledCLI, .embedded, .liteRTLM:
            if prewarmingModelPaths.contains(modelPath) {
                return .warming
            }
            if prewarmedModelPath == modelPath {
                return .warmReady
            }
            return .coldStart
        case .unavailable:
            return nil
        }
    }

    private func loadingStatusDetail(
        modelPath: String,
        warmState: LocalRuntimeWarmState?,
        structured: Bool
    ) -> String {
        if hasSevereDiskPressure(forModelPath: modelPath) {
            return "Gemma 4 をロード中です。空き容量が少ないため、初回応答は通常より遅くなります。"
        }

        switch warmState {
        case .reusedWarmSession:
            return "温まったランタイムを再利用しています。本文の準備に入ります。"
        case .warming:
            return "バックグラウンドで温めていたランタイムを仕上げています。"
        case .warmReady:
            return structured
                ? "温め済みの Gemma 4 で tools/thinking を準備しています。"
                : "温め済みの Gemma 4 で本文生成を始めています。"
        case .coldStart, .none:
            return "Gemma 4 を初回ロード中です。モデル読込が終わると本文生成に進みます。"
        }
    }

    func generateReply(
        prompt: String,
        contextPrompt: String?,
        coachMode: AICoachService.CoachMode,
        reasoningMode: ReasoningMode,
        researchMode: ResearchMode = .on,
        childAge: Int,
        pageInfo: AICoachService.PageInfo?,
        safetySnapshot: AICoachService.SafetySnapshot?,
        advancedSettings: GemmaAdvancedSettings = makeRuntimeDefaultGemmaAdvancedSettings(),
        /// 指定した場合 `runtimeSystemPrompt(...)` をスキップして直接この文字列を system prompt に使う。
        /// 音声会話など、ガイドライン/フォーマット指示を極小に保ちたい用途向け。
        overrideSystemPrompt: String? = nil,
        /// LiteRT-LMへrole付きで渡す短い会話履歴。SDK非対応のruntimeでは使わない。
        initialMessages: [LocalAssistantLiteRTLMHistoryMessage] = [],
        overrideModelURL: URL? = nil,
        onUpdate: (@MainActor @Sendable (LocalAssistantStructuredTurnUpdate) -> Void)? = nil
    ) async -> String? {
        guard let installedModelURL = overrideModelURL ?? LocalAssistantModelManager.shared.installedModelURL else {
            return nil
        }

        guard availability(installedModelURL: installedModelURL) == .executable else {
            return nil
        }

        let preferredEngine = preferredRuntimeEngine(forModelPath: installedModelURL.path)
        guard hasAvailableRuntimeEngine(preferredEngine) else {
            return nil
        }

        let conversationPrompt = runtimeConversationPrompt(for: prompt, contextPrompt: contextPrompt)
        let systemPrompt: String
        if let overrideSystemPrompt {
            systemPrompt = overrideSystemPrompt
        } else {
            systemPrompt = runtimeSystemPrompt(
                coachMode: coachMode,
                researchMode: researchMode,
                reasoningMode: reasoningMode,
                childAge: childAge,
                pageInfo: pageInfo,
                safetySnapshot: safetySnapshot,
                advancedSettings: advancedSettings
            )
        }
        let fullPrompt = buildRuntimePrompt(
            conversationPrompt: conversationPrompt,
            systemPrompt: systemPrompt,
            appendGemmaThinkingTrigger: shouldAppendInlineGemmaThinkingTrigger(
                modelPath: installedModelURL.path,
                reasoningMode: reasoningMode
            )
        )
        let parameters = generationParameters(
            for: reasoningMode,
            researchMode: researchMode,
            advancedSettings: advancedSettings
        )
        let startedAt = Date()

        if preferredEngine == .liteRTLM {
            let usesSplitTransport = usesSplitPromptTransport(preferredEngine)
            let result = await generateWithLiteRTLMRuntime(
                prompt: usesSplitTransport ? conversationPrompt : fullPrompt,
                systemPrompt: usesSplitTransport ? systemPrompt : nil,
                modelPath: installedModelURL.path,
                reasoningMode: reasoningMode,
                parameters: parameters,
                stage: .generation,
                startedAt: startedAt,
                initialMessages: initialMessages,
                onUpdate: onUpdate
            )
            return await withCheckedContinuation { continuation in
                queue.async {
                    if result.success,
                       let text = result.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !text.isEmpty {
                        self.cacheModelIdentity(forModelPath: installedModelURL.path)
                        self.cachedAvailability = .executable
                        self.lastRuntimeError = nil
                        self.lastRuntimeDiagnostic = nil
                        continuation.resume(returning: text)
                    } else {
                        self.recordGenerationFailure(
                            modelPath: installedModelURL.path,
                            rawMessage: result.errorMessage,
                            terminationStatus: nil
                        )
                        continuation.resume(returning: nil)
                    }
                }
            }
        }

        return await withCheckedContinuation { continuation in
            queue.async {
                let usesSplitTransport = self.usesSplitPromptTransport(preferredEngine)
                let result = self.generateWithPreferredRuntime(
                    prompt: usesSplitTransport ? conversationPrompt : fullPrompt,
                    systemPrompt: usesSplitTransport ? systemPrompt : nil,
                    modelPath: installedModelURL.path,
                    reasoningMode: reasoningMode,
                    parameters: parameters,
                    stage: .generation,
                    startedAt: startedAt,
                    onUpdate: onUpdate
                )
                if result.success, let text = result.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    self.cacheModelIdentity(forModelPath: installedModelURL.path)
                    self.cachedAvailability = .executable
                    self.lastRuntimeError = nil
                    self.lastRuntimeDiagnostic = nil
                    continuation.resume(returning: text)
                } else {
                    self.recordGenerationFailure(
                        modelPath: installedModelURL.path,
                        rawMessage: result.errorMessage,
                        terminationStatus: nil
                    )
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func performStructuredTurn(
        prompt: String,
        contextPrompt: String?,
        coachMode: AICoachService.CoachMode,
        reasoningMode: ReasoningMode,
        researchMode: ResearchMode = .on,
        childAge: Int,
        pageInfo: AICoachService.PageInfo?,
        safetySnapshot: AICoachService.SafetySnapshot?,
        advancedSettings: GemmaAdvancedSettings = makeRuntimeDefaultGemmaAdvancedSettings(),
        toolResults: [LocalAssistantToolResult] = [],
        onUpdate: (@MainActor @Sendable (LocalAssistantStructuredTurnUpdate) -> Void)? = nil
    ) async -> LocalAssistantStructuredTurn? {
        guard let installedModelURL = LocalAssistantModelManager.shared.installedModelURL else {
            return nil
        }

        guard availability(installedModelURL: installedModelURL) == .executable else {
            return nil
        }

        let conversationPrompt = runtimeConversationPrompt(for: prompt, contextPrompt: contextPrompt)
        let systemPrompt = structuredTurnSystemPrompt(
            coachMode: coachMode,
            reasoningMode: reasoningMode,
            researchMode: researchMode,
            childAge: childAge,
            pageInfo: pageInfo,
            safetySnapshot: safetySnapshot,
            advancedSettings: advancedSettings
        )
        let enabledToolNames = advancedSettings.allowToolUsage
            ? AIToolCatalog.toolNames.filter { advancedSettings.isToolEnabled($0) }
            : []
        let userPrompt = buildStructuredTurnUserPrompt(
            conversationPrompt: conversationPrompt,
            toolResults: toolResults
        )
        let fullPrompt = buildRuntimePrompt(
            conversationPrompt: userPrompt,
            systemPrompt: systemPrompt,
            appendGemmaThinkingTrigger: shouldAppendInlineGemmaThinkingTrigger(
                modelPath: installedModelURL.path,
                reasoningMode: reasoningMode
            )
        )
        let parameters = generationParameters(
            for: reasoningMode,
            researchMode: researchMode,
            advancedSettings: advancedSettings
        )
        let startedAt = Date()

        let preferredEngine = preferredRuntimeEngine(forModelPath: installedModelURL.path)
        guard hasAvailableRuntimeEngine(preferredEngine) else {
            return nil
        }

        if preferredEngine == .liteRTLM {
            let usesSplitTransport = usesSplitPromptTransport(preferredEngine)
            let result = await generateStructuredTurnWithLiteRTLMRuntime(
                prompt: usesSplitTransport ? userPrompt : fullPrompt,
                systemPrompt: usesSplitTransport ? systemPrompt : nil,
                modelPath: installedModelURL.path,
                parameters: parameters,
                reasoningMode: reasoningMode,
                researchMode: researchMode,
                enabledToolNames: enabledToolNames,
                startedAt: startedAt,
                onUpdate: onUpdate
            )
            return await withCheckedContinuation { continuation in
                queue.async {
                    if let turn = result.turn,
                       self.isAcceptableStructuredTurn(turn) {
                        self.cacheModelIdentity(forModelPath: installedModelURL.path)
                        self.cachedAvailability = .executable
                        self.lastRuntimeError = nil
                        self.lastRuntimeDiagnostic = nil
                        continuation.resume(returning: turn)
                    } else {
                        self.recordGenerationFailure(
                            modelPath: installedModelURL.path,
                            rawMessage: result.errorMessage ?? "Gemma 4 の structured turn に失敗しました。",
                            terminationStatus: result.terminationStatus
                        )
                        continuation.resume(returning: nil)
                    }
                }
            }
        }

        return await withCheckedContinuation { continuation in
            queue.async {
                let usesSplitTransport = self.usesSplitPromptTransport(preferredEngine)
                let result = self.generateStructuredTurnWithPreferredRuntime(
                    prompt: usesSplitTransport ? userPrompt : fullPrompt,
                    systemPrompt: usesSplitTransport ? systemPrompt : nil,
                    modelPath: installedModelURL.path,
                    parameters: parameters,
                    reasoningMode: reasoningMode,
                    researchMode: researchMode,
                    enabledToolNames: enabledToolNames,
                    startedAt: startedAt,
                    onUpdate: onUpdate
                )

                if let turn = result.turn,
                   self.isAcceptableStructuredTurn(turn) {
                    self.cacheModelIdentity(forModelPath: installedModelURL.path)
                    self.cachedAvailability = .executable
                    self.lastRuntimeError = nil
                    self.lastRuntimeDiagnostic = nil
                    continuation.resume(returning: turn)
                } else {
                    self.recordGenerationFailure(
                        modelPath: installedModelURL.path,
                        rawMessage: result.errorMessage ?? "Gemma 4 の structured turn に失敗しました。",
                        terminationStatus: result.terminationStatus
                    )
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func recordGenerationFailure(
        modelPath: String,
        rawMessage: String?,
        terminationStatus: Int32?
    ) {
        let previousAvailability = cachedModelIdentityMatches(modelPath: modelPath) ? cachedAvailability : .savedOnly
        cacheModelIdentity(forModelPath: modelPath)
        cachedAvailability = nextAvailabilityAfterGenerationFailure(previousAvailability: previousAvailability)
        let diagnostic = classifyRuntimeFailure(
            stage: .generation,
            rawMessage: rawMessage,
            terminationStatus: terminationStatus
        )
        lastRuntimeDiagnostic = diagnostic
        lastRuntimeError = diagnostic.detailedMessage
    }

    private func nextAvailabilityAfterGenerationFailure(
        previousAvailability: LocalAssistantRuntimeAvailability
    ) -> LocalAssistantRuntimeAvailability {
        previousAvailability == .executable ? .executable : .recentFailure
    }

    func generateSupportModelBrief(
        question: String,
        searchSummary: String,
        reasoningMode: ReasoningMode,
        advancedSettings: GemmaAdvancedSettings = makeRuntimeDefaultGemmaAdvancedSettings()
    ) async -> String? {
        guard let installedModelURL = LocalAssistantModelManager.shared.installedModelURL else {
            return nil
        }

        let preferredEngine = preferredRuntimeEngine(forModelPath: installedModelURL.path)
        guard hasAvailableRuntimeEngine(preferredEngine) else {
            return nil
        }

        let prompt = buildSupportBriefPrompt(question: question, searchSummary: searchSummary)
        let userPrompt = buildSupportBriefUserPrompt(question: question, searchSummary: searchSummary)
        let systemPrompt = supportBriefSystemPrompt
        let parameters = supportBriefGenerationParameters(for: reasoningMode, advancedSettings: advancedSettings)

        if preferredEngine == .liteRTLM {
            let usesSplitTransport = usesSplitPromptTransport(preferredEngine)
            let result = await generateWithLiteRTLMRuntime(
                prompt: usesSplitTransport ? userPrompt : prompt,
                systemPrompt: usesSplitTransport ? systemPrompt : nil,
                modelPath: installedModelURL.path,
                reasoningMode: reasoningMode,
                parameters: parameters,
                stage: .supportBrief,
                startedAt: Date(),
                initialMessages: []
            )
            return await withCheckedContinuation { continuation in
                queue.async {
                    if result.success,
                       let text = result.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !text.isEmpty {
                        self.cacheModelIdentity(forModelPath: installedModelURL.path)
                        self.cachedAvailability = .executable
                        self.lastRuntimeError = nil
                        self.lastRuntimeDiagnostic = nil
                        continuation.resume(returning: text)
                    } else {
                        self.cacheModelIdentity(forModelPath: installedModelURL.path)
                        self.cachedAvailability = .recentFailure
                        let diagnostic = self.classifyRuntimeFailure(
                            stage: .supportBrief,
                            rawMessage: result.errorMessage,
                            terminationStatus: nil
                        )
                        self.lastRuntimeDiagnostic = diagnostic
                        self.lastRuntimeError = diagnostic.detailedMessage
                        continuation.resume(returning: nil)
                    }
                }
            }
        }

        return await withCheckedContinuation { continuation in
            queue.async {
                let usesSplitTransport = self.usesSplitPromptTransport(preferredEngine)
                let result = self.generateWithPreferredRuntime(
                    prompt: usesSplitTransport ? userPrompt : prompt,
                    systemPrompt: usesSplitTransport ? systemPrompt : nil,
                    modelPath: installedModelURL.path,
                    reasoningMode: reasoningMode,
                    parameters: parameters,
                    stage: .supportBrief,
                    startedAt: Date()
                )

                if result.success,
                   let text = result.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    self.cacheModelIdentity(forModelPath: installedModelURL.path)
                    self.cachedAvailability = .executable
                    self.lastRuntimeError = nil
                    self.lastRuntimeDiagnostic = nil
                    continuation.resume(returning: text)
                } else {
                    self.cacheModelIdentity(forModelPath: installedModelURL.path)
                    self.cachedAvailability = .recentFailure
                    let diagnostic = self.classifyRuntimeFailure(
                        stage: .supportBrief,
                        rawMessage: result.errorMessage,
                        terminationStatus: nil
                    )
                    self.lastRuntimeDiagnostic = diagnostic
                    self.lastRuntimeError = diagnostic.detailedMessage
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private var embeddedRuntimeSupported: Bool {
#if os(macOS) || os(iOS)
        return true
#else
        return false
#endif
    }

    private enum RuntimeEngine {
        case embedded
        case bundledServer
        case bundledCLI
        case liteRTLM
        case unavailable
    }

    private var preferredRuntimeEngine: RuntimeEngine {
        preferredRuntimeEngine(forModelPath: LocalAssistantModelManager.shared.installedModelURL?.path)
    }

    private func prewarmRuntimeEngine(forModelPath modelPath: String?) -> RuntimeEngine {
#if os(macOS)
        if shouldPreferBundledServer(forModelPath: modelPath),
           bundledServerCandidateURLs.isEmpty == false {
            return .bundledServer
        }
#endif
        return preferredRuntimeEngine(forModelPath: modelPath)
    }

    private func preferredRuntimeEngine(forModelPath modelPath: String?) -> RuntimeEngine {
#if os(iOS)
        if modelPath?.lowercased().hasSuffix(".litertlm") == true {
            return .liteRTLM
        }
        if modelPath?.lowercased().hasSuffix(".gguf") == true
            || modelPath?.lowercased().hasSuffix(".bin") == true {
            return .embedded
        }
#endif
#if os(macOS)
        if shouldPreferBundledCLI(forModelPath: modelPath) {
            if bundledServerCandidateURLs.isEmpty == false {
                return .bundledServer
            }
            if bundledCLICandidateURLs.isEmpty == false {
                return .bundledCLI
            }
            if embeddedRuntimeSupported {
                return .embedded
            }
            return .unavailable
        }
        if embeddedRuntimeSupported {
            return .embedded
        }
        if bundledServerCandidateURLs.isEmpty == false {
            return .bundledServer
        }
        if bundledCLICandidateURLs.isEmpty == false {
            return .bundledCLI
        }
#endif
        return .unavailable
    }

    private var generationRuntimeEngines: [RuntimeEngine] {
        generationRuntimeEngines(forModelPath: LocalAssistantModelManager.shared.installedModelURL?.path)
    }

    private func generationRuntimeEngines(forModelPath modelPath: String?) -> [RuntimeEngine] {
#if os(macOS)
        if shouldPreferBundledServer(forModelPath: modelPath) {
            var engines: [RuntimeEngine] = []
            func appendUnique(_ engine: RuntimeEngine) {
                guard engines.contains(where: { $0 == engine }) == false else { return }
                engines.append(engine)
            }
            if hasWarmBundledServer(forModelPath: modelPath) {
                appendUnique(.bundledServer)
            }
            if bundledServerCandidateURLs.isEmpty == false {
                appendUnique(.bundledServer)
            }
            if bundledCLICandidateURLs.isEmpty == false {
                appendUnique(.bundledCLI)
            }
            if embeddedRuntimeSupported {
                appendUnique(.embedded)
            }
            return engines.isEmpty ? [.unavailable] : engines
        }
        if shouldPreferBundledCLI(forModelPath: modelPath) {
            var engines: [RuntimeEngine] = []
            if bundledServerCandidateURLs.isEmpty == false {
                engines.append(.bundledServer)
            }
            if bundledCLICandidateURLs.isEmpty == false {
                engines.append(.bundledCLI)
            }
            if embeddedRuntimeSupported {
                engines.append(.embedded)
            }
            return engines.isEmpty ? [.unavailable] : engines
        }
        var engines: [RuntimeEngine] = []
        func appendUnique(_ engine: RuntimeEngine) {
            guard engines.contains(where: { $0 == engine }) == false else { return }
            engines.append(engine)
        }
        if embeddedRuntimeSupported {
            appendUnique(.embedded)
        }
        if bundledServerCandidateURLs.isEmpty == false {
            appendUnique(.bundledServer)
        }
        if bundledCLICandidateURLs.isEmpty == false {
            appendUnique(.bundledCLI)
        }
        return engines.isEmpty ? [.unavailable] : engines
#else
        if modelPath?.lowercased().hasSuffix(".litertlm") == true {
            return [.liteRTLM]
        }
        if modelPath?.lowercased().hasSuffix(".gguf") == true
            || modelPath?.lowercased().hasSuffix(".bin") == true {
            return [.embedded]
        }
        return [.unavailable]
#endif
    }

    private var selfCheckRuntimeEngine: RuntimeEngine {
        selfCheckRuntimeEngine(forModelPath: LocalAssistantModelManager.shared.installedModelURL?.path)
    }

    private func selfCheckRuntimeEngine(forModelPath modelPath: String?) -> RuntimeEngine {
#if os(macOS)
        if shouldPreferBundledServer(forModelPath: modelPath),
           hasWarmBundledServer(forModelPath: modelPath) {
            return .bundledServer
        }
        if shouldPreferBundledCLI(forModelPath: modelPath) {
            if bundledCLICandidateURLs.isEmpty == false {
                return .bundledCLI
            }
            if bundledServerCandidateURLs.isEmpty == false {
                return .bundledServer
            }
            if embeddedRuntimeSupported {
                return .embedded
            }
            return .unavailable
        }
        if bundledServerCandidateURLs.isEmpty == false {
            return .bundledServer
        }
        if bundledCLICandidateURLs.isEmpty == false {
            return .bundledCLI
        }
        if embeddedRuntimeSupported {
            return .embedded
        }
#endif
        return preferredRuntimeEngine
    }

    private func shouldPreferBundledCLI(forModelPath modelPath: String?) -> Bool {
        guard let modelPath else { return false }
        return modelPathLooksLikeGemma4(modelPath)
    }

    private func shouldPreferBundledServer(forModelPath modelPath: String?) -> Bool {
        guard let modelPath else { return false }
        return modelPathLooksLikeGemma4(modelPath)
    }

    private func shouldForceConservativeCPURuntime(forModelPath modelPath: String) -> Bool {
        modelPathLooksLikeGemma4(modelPath)
    }

    private func shouldDisableNativeThinking(forModelPath modelPath: String) -> Bool {
        false
    }

    private func shouldEnableNativeThinking(forModelPath modelPath: String, reasoningMode: ReasoningMode) -> Bool {
        // fastモードは即答経路のまま維持する。
        // KizunaのpersonaはGemma 4のテンプレート仕様に合わせてThinkingを有効化する。
        guard reasoningMode != .fast else { return false }
        return modelPathLooksLikeGemma4(modelPath)
    }

    /// iOSのGGUF埋め込み経路にはchat-template kwargsがないため、
    /// Gemma 4のThinking開始タグを生成前に直接渡す。
    /// server/LiteRT-LM経路はそれぞれのテンプレートに任せる。
    private func shouldAppendInlineGemmaThinkingTrigger(
        modelPath: String,
        reasoningMode: ReasoningMode
    ) -> Bool {
#if os(iOS)
        guard reasoningMode == .persona else { return false }
        let lowercased = modelPath.lowercased()
        return modelPathLooksLikeGemma4(modelPath) && lowercased.hasSuffix(".gguf")
#else
        _ = modelPath
        _ = reasoningMode
        return false
#endif
    }

    private func shouldSkipChatParsing(forModelPath modelPath: String) -> Bool {
        !modelPathLooksLikeGemma4(modelPath)
    }

    private func modelPathLooksLikeGemma4(_ modelPath: String) -> Bool {
        let fileName = URL(fileURLWithPath: modelPath).lastPathComponent.lowercased()
        return fileName.contains("gemma-4") || fileName.contains("gemma4")
    }

    /// このモデルで n-gram ベースの投機デコード (`--spec-type ngram-map-k4v` 等) が有効に効きそうかを判定する。
    /// 大半のモデルで安全に効くため、明示的にスキップしたい特殊モデルがある時だけここで除外する。
    private func modelSupportsNgramSpeculation(_ modelPath: String) -> Bool {
        // n-gram 推測はモデル依存性が低い。今のところ全モデルで許可。
        _ = modelPath
        return true
    }

    /// 真の MTP (Multi-Token Prediction) ヘッドを GGUF 内に持つ既知のモデルか。
    /// 注意: `--spec-type mtp` を使うには、対応する llama-server ビルド + MTP ヘッド入り GGUF の両方が必要。
    /// 該当しなければ自動的に n-gram 推測へフォールバックする。
    private func modelHasMTPHeads(_ modelPath: String) -> Bool {
        let fileName = URL(fileURLWithPath: modelPath).lastPathComponent.lowercased()
        // Google 公式の Gemma 4 MTP drafter (GGUF 化されたものを assistant としてマージしている場合)。
        // ファイル名規則は配布元に依存するため、両方のパターンを許容する。
        let mtpPatterns = [
            "gemma-4-mtp",
            "gemma4-mtp",
            "-assistant",          // gemma-4-E4B-it-assistant 等
            "deepseek-v3",
            "deepseek_v3",
            "deepseekv3",
        ]
        return mtpPatterns.contains(where: { fileName.contains($0) })
    }

    /// llama-server バイナリの `--help` を解析して capability を検出する。
    /// 結果は runner パスごとにキャッシュされる（プロセス起動コストを 1 回に抑える）。
    private func detectServerCapabilities(runnerURL: URL) -> ServerCapabilities {
        let key = runnerURL.path
        if let cached = serverCapabilityCache[key] {
            return cached
        }

        let process = Process()
        process.executableURL = runnerURL
        process.arguments = ["--help"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            let capabilities = ServerCapabilities(availableSpecTypes: [], supportsDraftMax: false)
            serverCapabilityCache[key] = capabilities
            return capabilities
        }

        // --help は短時間で終わる。ただし詰まる場合に備えて 5 秒で諦める。
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning { process.terminate() }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let helpText = String(data: data, encoding: .utf8) ?? ""

        // `--spec-type [none|ngram-cache|ngram-simple|...|mtp]` の括弧内を抽出する
        var availableSpecTypes: Set<String> = []
        if let range = helpText.range(of: "--spec-type") {
            // --spec-type の後ろから次の改行まで読む
            let tail = helpText[range.upperBound...]
            if let openBracket = tail.firstIndex(of: "["),
               let closeBracket = tail[openBracket...].firstIndex(of: "]") {
                let inside = tail[tail.index(after: openBracket)..<closeBracket]
                for option in inside.split(separator: "|") {
                    let trimmed = option.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty == false {
                        availableSpecTypes.insert(trimmed)
                    }
                }
            }
        }

        let supportsDraftMax = helpText.contains("--draft-max") || helpText.contains("--draft, --draft-n")
        let capabilities = ServerCapabilities(
            availableSpecTypes: availableSpecTypes,
            supportsDraftMax: supportsDraftMax
        )
        serverCapabilityCache[key] = capabilities
        return capabilities
    }

    /// AICoachService 等から呼ぶ公開 API。設定 UI 変更時にこれを呼ぶと、次回サーバー起動時から反映される。
    func updateSpeculativeDecodingMode(_ mode: SpeculativeDecodingMode) {
        queue.async {
            guard self.userSpeculativeDecodingMode != mode else { return }
            self.userSpeculativeDecodingMode = mode
            // 既存セッションは設定変更で stale になるため次回呼び出し時に再構築させる
            self.terminateBundledServer()
        }
    }

    /// 現在の選択を取得 (UI 同期用)。
    var currentSpeculativeDecodingMode: SpeculativeDecodingMode {
        readState { userSpeculativeDecodingMode }
    }

    /// バンドル llama-server で実際に利用可能な spec-type を返す (UI で選択肢をフィルタする用)。
    func availableSpeculativeDecodingModes() -> [SpeculativeDecodingMode] {
        guard let runnerURL = bundledServerCandidateURLs.first else {
            return [.off, .auto]
        }
        let cap = detectServerCapabilities(runnerURL: runnerURL)
        var modes: [SpeculativeDecodingMode] = [.off, .auto]
        for mode in SpeculativeDecodingMode.allCases where mode != .off && mode != .auto {
            if let raw = mode.rawSpecType, cap.availableSpecTypes.contains(raw) {
                modes.append(mode)
            }
        }
        return modes
    }

    /// `userSpeculativeDecodingMode` とバイナリ capability、モデル特性から
    /// 実際に渡す `--spec-type` 名を解決する。返り値が nil なら投機デコードを無効化する。
    /// auto モードは: mtp (対応モデル+対応バイナリ) > ngram-map-k4v > ngram-cache > nil の順で選ぶ。
    private func resolveSpecType(
        userMode: SpeculativeDecodingMode,
        modelPath: String,
        capabilities: ServerCapabilities
    ) -> String? {
        // ユーザーが明示的に OFF を選んだ場合は何も付けない
        if userMode == .off { return nil }

        // 明示選択 (auto 以外) はそのまま尊重しつつ、未対応ならフォールバック
        if let raw = userMode.rawSpecType {
            if capabilities.availableSpecTypes.contains(raw) {
                // mtp の場合はモデルの MTP ヘッド有無も確認 + 過去に拒否されてないか
                if raw == "mtp" {
                    guard modelHasMTPHeads(modelPath),
                          mtpUnsupportedModelPaths.contains(modelPath) == false else {
                        return resolveAutoFallback(modelPath: modelPath, capabilities: capabilities)
                    }
                }
                return raw
            }
            // ユーザー選択がバイナリで未対応 → auto と同じフォールバック
            return resolveAutoFallback(modelPath: modelPath, capabilities: capabilities)
        }

        // userMode == .auto
        return resolveAutoFallback(modelPath: modelPath, capabilities: capabilities)
    }

    /// 自動選択ロジック: mtp > ngram-map-k4v > ngram-cache > nil
    private func resolveAutoFallback(
        modelPath: String,
        capabilities: ServerCapabilities
    ) -> String? {
        if capabilities.availableSpecTypes.contains("mtp"),
           modelHasMTPHeads(modelPath),
           mtpUnsupportedModelPaths.contains(modelPath) == false {
            return "mtp"
        }
        if modelSupportsNgramSpeculation(modelPath) {
            for candidate in ["ngram-map-k4v", "ngram-cache", "ngram-simple"] {
                if capabilities.availableSpecTypes.contains(candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    /// llama-server が起動時に MTP 関連エラーを返した場合に呼び、以降の自動選択から MTP を除外する。
    func recordMTPLoadFailure(forModelPath modelPath: String) {
        queue.async {
            self.mtpUnsupportedModelPaths.insert(modelPath)
        }
    }

    private func hasWarmBundledServer(forModelPath modelPath: String?) -> Bool {
        guard let modelPath,
              let session = bundledServerSession else {
            return false
        }
        guard session.modelPath == modelPath, session.process.isRunning else {
            return false
        }
        guard let lastUsedAt = bundledServerLastUsedAt else {
            return true
        }
        return Date().timeIntervalSince(lastUsedAt) <= bundledServerIdleReuseWindow
    }

    private func runtimePreset(for reasoningMode: ReasoningMode) -> LocalAssistantModelProfile.RuntimePreset {
        switch reasoningMode {
        case .persona:
            return LocalAssistantModelProfile.personaRuntimePreset
        case .fast:
            return LocalAssistantModelProfile.fastRuntimePreset
        case .thinking, .deepThinking:
            return LocalAssistantModelProfile.runtimePreset
        }
    }

    private func bundledServerRuntimePreset(
        forModelPath modelPath: String,
        reasoningMode: ReasoningMode = .thinking
    ) -> LocalAssistantModelProfile.RuntimePreset {
        let base = runtimePreset(for: reasoningMode)
        guard shouldPreferBundledServer(forModelPath: modelPath) else {
            return base
        }

        let severeDiskPressure = hasSevereDiskPressure(forModelPath: modelPath)
        // bundled server は Apple Silicon 統合メモリを活用するため GPU layers を有効にする。
        // CLI の conservativeCPU 制約とは独立して、base preset の GPU 設定を継承する。
        // prefill 速度を上げるため base preset 相当の batch/ubatch を採用。
        // Kizuna personaだけ16kを使い、共有のfast/thinking系は従来値を使う。
        let targetContextSize: Int
        if severeDiskPressure {
            targetContextSize = 2048
        } else if reasoningMode == .persona {
            targetContextSize = 16_384
        } else {
            targetContextSize = base.contextSize
        }
        return LocalAssistantModelProfile.RuntimePreset(
            contextSize: targetContextSize,
            batchSize: severeDiskPressure ? 64 : base.batchSize,
            microBatchSize: severeDiskPressure ? 16 : base.microBatchSize,
            threadCount: base.threadCount,
            batchThreadCount: base.batchThreadCount,
            gpuLayers: base.gpuLayers,
            flashAttentionEnabled: base.flashAttentionEnabled,
            disableKVOffload: false
        )
    }

    private func selfCheckRuntimeEngines(forModelPath modelPath: String?) -> [RuntimeEngine] {
        let preferredEngine = selfCheckRuntimeEngine(forModelPath: modelPath)
        guard preferredEngine != .unavailable else {
            return [.unavailable]
        }

        var engines: [RuntimeEngine] = []
        func appendUnique(_ engine: RuntimeEngine) {
            guard engine != .unavailable else { return }
            guard hasAvailableRuntimeEngine(engine) else { return }
            guard engines.contains(where: { $0 == engine }) == false else { return }
            engines.append(engine)
        }

        appendUnique(preferredEngine)
        for engine in generationRuntimeEngines(forModelPath: modelPath) {
            appendUnique(engine)
        }
        return engines.isEmpty ? [.unavailable] : engines
    }

    private var bundledCLICandidateURLs: [URL] {
#if os(macOS)
        let bundleCandidate = Bundle.main.resourceURL?.appendingPathComponent("llama-cli")
        let legacyBundleCandidate = Bundle.main.resourceURL?.appendingPathComponent("AI/LocalRuntime/llama-cli")
        let candidates = [bundleCandidate, legacyBundleCandidate].compactMap { $0 }
        var seen = Set<String>()
        return candidates.filter {
            seen.insert($0.standardizedFileURL.path).inserted &&
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
#else
        return []
#endif
    }

    private var bundledServerCandidateURLs: [URL] {
#if os(macOS)
        let bundleCandidate = Bundle.main.resourceURL?.appendingPathComponent("llama-server")
        let legacyBundleCandidate = Bundle.main.resourceURL?.appendingPathComponent("AI/LocalRuntime/llama-server")
        let candidates = [bundleCandidate, legacyBundleCandidate].compactMap { $0 }
        var seen = Set<String>()
        return candidates.filter {
            seen.insert($0.standardizedFileURL.path).inserted &&
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
#else
        return []
#endif
    }

    private func performRuntimeSelfCheck(modelPath: String) -> VIUKEmbeddedRuntimeResult {
        var lastFailure: VIUKEmbeddedRuntimeResult?
        for engine in selfCheckRuntimeEngines(forModelPath: modelPath) {
            let result: VIUKEmbeddedRuntimeResult
            switch engine {
            case .embedded:
#if os(macOS) || os(iOS)
                result = VIUKEmbeddedRuntime.shared().performSelfCheck(withModelPath: modelPath, maxTokens: 24)
#else
                result = VIUKEmbeddedRuntimeResult(success: false, text: nil, errorMessage: "このプラットフォームでは埋め込み runtime を使えません。")
#endif
            case .bundledServer:
                guard let session = ensureBundledServer(modelPath: modelPath, timeoutSeconds: 60) else {
                    result = VIUKEmbeddedRuntimeResult(success: false, text: nil, errorMessage: bundledServerFailureMessage("ローカル server の起動に失敗しました。"))
                    break
                }
                let response = requestBundledServerChat(
                    session: session,
                    messages: makeServerMessages(
                        systemPrompt: """
                        あなたは VIUK AI tiny のローカル Gemma 4 runtime check です。
                        出力は必ず `ok` のみで、前置きや説明は不要です。
                        """,
                        userPrompt: "これは Gemma 4 の runtime check です。必ず `ok` とだけ短く返答してください。"
                    ),
                    maxTokens: 16,
                    temperature: 0.0,
                    topP: 0.9,
                    topK: 20,
                    seed: 7,
                    timeoutSeconds: 30,
                    reasoningMode: .fast,
                    enabledToolNames: []
                )
                guard let response else {
                    result = VIUKEmbeddedRuntimeResult(success: false, text: nil, errorMessage: "ローカル server への接続確認に失敗しました。")
                    break
                }
                let cleaned = cleanCLIOutput(response.content)
                guard cleaned.localizedCaseInsensitiveContains("ok") else {
                    result = VIUKEmbeddedRuntimeResult(success: false, text: nil, errorMessage: cleaned.isEmpty ? "ローカル server の確認結果が空でした。" : cleaned)
                    break
                }
                validatedStructuredCapabilityModelPath = modelPath
                result = VIUKEmbeddedRuntimeResult(success: true, text: "ok", errorMessage: nil)
            case .bundledCLI:
                if validatedStructuredCapabilityModelPath == modelPath {
                    result = VIUKEmbeddedRuntimeResult(success: true, text: "ok", errorMessage: nil)
                    break
                }

                let basicPrompt = "これは Gemma 4 の runtime check です。必ず `ok` とだけ短く返答してください。"
                let basicSystemPrompt = """
                あなたは VIUK AI tiny のローカル Gemma 4 runtime check です。
                出力は必ず `ok` のみで、前置きや説明は不要です。
                """
                let basicResult = runCLI(
                    prompt: basicPrompt,
                    systemPrompt: basicSystemPrompt,
                    modelPath: modelPath,
                    reasoningMode: .fast,
                    maxTokens: 16,
                    temperature: 0.0,
                    topP: 0.9,
                    topK: 20,
                    seed: 7,
                    timeoutSeconds: 45,
                    stage: .selfCheck
                    ,
                    startedAt: Date()
                )
                guard basicResult.success else {
                    result = basicResult
                    break
                }
                // Self-check is intentionally lightweight. Native thinking / tool use
                // is exercised during real requests so the debugger does not stop on
                // aggressive capability probes every time the user rechecks runtime.
                validatedStructuredCapabilityModelPath = modelPath
                result = VIUKEmbeddedRuntimeResult(success: true, text: "ok", errorMessage: nil)
            case .liteRTLM:
                result = LocalAssistantLiteRTLMRuntime.shared.performSelfCheck(modelPath: modelPath)
            case .unavailable:
                result = VIUKEmbeddedRuntimeResult(success: false, text: nil, errorMessage: "ローカル runtime が見つかりません。")
            }

            if result.success {
                return result
            }
            lastFailure = result
        }

        return lastFailure ?? VIUKEmbeddedRuntimeResult(success: false, text: nil, errorMessage: "ローカル runtime が見つかりません。")
    }

    private func generateWithLiteRTLMRuntime(
        prompt: String,
        systemPrompt: String?,
        modelPath: String,
        reasoningMode: ReasoningMode,
        parameters: (maxTokens: Int, temperature: Float, topP: Float, topK: Int, seed: UInt32),
        stage: LocalAssistantRuntimeDiagnostic.Stage,
        startedAt: Date,
        initialMessages: [LocalAssistantLiteRTLMHistoryMessage],
        onUpdate: (@MainActor @Sendable (LocalAssistantStructuredTurnUpdate) -> Void)? = nil
    ) async -> VIUKEmbeddedRuntimeResult {
        // A fixed seed made every retry repeat the same poor first token path.
        // Story chat is intentionally creative, so vary the sampler per turn
        // while retaining the preset as its reproducible base.
        let turnSeed = parameters.seed &+ UInt32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970 * 1_000))
        let warmState = warmState(for: .liteRTLM, modelPath: modelPath)
        let runnerLabel = runtimeRunnerLabel(for: .liteRTLM, runnerPath: nil)
        emitStatus(
            .loadingModel,
            title: "Gemma 4 E2B をロード中",
            detail: "iOS 用 LiteRT-LM runtime でスマホ向けモデルを準備しています。",
            estimatedProgress: 48,
            runnerLabel: runnerLabel,
            warmState: warmState,
            startedAt: startedAt,
            onUpdate: onUpdate
        )
        if shouldEnableNativeThinking(forModelPath: modelPath, reasoningMode: reasoningMode), let onUpdate {
            emitStatus(
                .thinking,
                title: "回答方針を整理中",
                detail: "質問の意図と、回答に使う情報の順番を整理しています。",
                estimatedProgress: 64,
                runnerLabel: runnerLabel,
                warmState: warmState,
                startedAt: startedAt,
                onUpdate: onUpdate
            )
            let preview = liteRTLMUserFacingThinkingPreview(
                prompt: prompt,
                researchMode: nil,
                enabledToolNames: []
            )
            Task { @MainActor in onUpdate(.thinkingPreview(preview)) }
        }
        emitStatus(
            .generating,
            title: "本文を生成中",
            detail: "Gemma 4 がスマホ上で返答を組み立てています。",
            estimatedProgress: reasoningMode == .fast ? 84 : 70,
            runnerLabel: runnerLabel,
            warmState: warmState,
            startedAt: startedAt,
            onUpdate: onUpdate
        )
        return await LocalAssistantLiteRTLMRuntime.shared.generateAsync(
            LocalAssistantLiteRTLMRequest(
                prompt: prompt,
                systemPrompt: systemPrompt,
                modelPath: modelPath,
                maxTokens: parameters.maxTokens,
                temperature: parameters.temperature,
                topP: parameters.topP,
                topK: parameters.topK,
                seed: turnSeed,
                initialMessages: initialMessages
            )
        )
    }

    private func generateWithPreferredRuntime(
        prompt: String,
        systemPrompt: String?,
        modelPath: String,
        reasoningMode: ReasoningMode,
        parameters: (maxTokens: Int, temperature: Float, topP: Float, topK: Int, seed: UInt32),
        stage: LocalAssistantRuntimeDiagnostic.Stage,
        startedAt: Date,
        onUpdate: (@MainActor @Sendable (LocalAssistantStructuredTurnUpdate) -> Void)? = nil
    ) -> VIUKEmbeddedRuntimeResult {
        var lastFailure: VIUKEmbeddedRuntimeResult?
        for engine in generationRuntimeEngines(forModelPath: modelPath) {
            let warmState = warmState(for: engine, modelPath: modelPath)
            let runnerLabel = runtimeRunnerLabel(for: engine, runnerPath: nil)
            switch engine {
            case .embedded:
                emitStatus(
                    .loadingModel,
                    title: "Gemma 4 をロード中",
                    detail: loadingStatusDetail(modelPath: modelPath, warmState: warmState, structured: false),
                    estimatedProgress: 48,
                    runnerLabel: runnerLabel,
                    warmState: warmState,
                    startedAt: startedAt,
                    onUpdate: onUpdate
                )
#if os(macOS) || os(iOS)
                let result = VIUKEmbeddedRuntime.shared().generate(
                    withPrompt: prompt,
                    modelPath: modelPath,
                    maxTokens: parameters.maxTokens,
                    temperature: parameters.temperature,
                    topP: parameters.topP,
                    topK: parameters.topK,
                    seed: parameters.seed
                )
                recordRuntimeDebugSnapshot(
                    stage: stage,
                    engine: .embedded,
                    runnerPath: nil,
                    rawOutput: result.text,
                    errorMessage: result.errorMessage
                )
                if result.success {
                    emitStatus(
                        .streaming,
                        title: "本文を書き出し中",
                        detail: "Gemma 4 の本文を受信しました。画面へ反映しています。",
                        estimatedProgress: 92,
                        runnerLabel: runnerLabel,
                        warmState: warmState,
                        startedAt: startedAt,
                        onUpdate: onUpdate
                    )
                    lastRuntimeDiagnostic = nil
                    lastRuntimeError = nil
                    return result
                }
                lastFailure = result
#else
                lastFailure = VIUKEmbeddedRuntimeResult(success: false, text: nil, errorMessage: "このプラットフォームでは埋め込み runtime を使えません。")
#endif
            case .liteRTLM:
                emitStatus(
                    .loadingModel,
                    title: "Gemma 4 E2B をロード中",
                    detail: "iOS 用 LiteRT-LM runtime でスマホ向けモデルを準備しています。",
                    estimatedProgress: 48,
                    runnerLabel: runnerLabel,
                    warmState: warmState,
                    startedAt: startedAt,
                    onUpdate: onUpdate
                )
                if shouldEnableNativeThinking(forModelPath: modelPath, reasoningMode: reasoningMode), let onUpdate {
                    emitStatus(
                        .thinking,
                        title: "回答方針を整理中",
                        detail: "質問の意図と、回答に使う情報の順番を整理しています。",
                        estimatedProgress: 64,
                        runnerLabel: runnerLabel,
                        warmState: warmState,
                        startedAt: startedAt,
                        onUpdate: onUpdate
                    )
                    let preview = liteRTLMUserFacingThinkingPreview(
                        prompt: prompt,
                        researchMode: nil,
                        enabledToolNames: []
                    )
                    Task { @MainActor in onUpdate(.thinkingPreview(preview)) }
                }
                let result = LocalAssistantLiteRTLMRuntime.shared.generate(
                    LocalAssistantLiteRTLMRequest(
                        prompt: prompt,
                        systemPrompt: systemPrompt,
                        modelPath: modelPath,
                        maxTokens: parameters.maxTokens,
                        temperature: parameters.temperature,
                        topP: parameters.topP,
                        topK: parameters.topK,
                        seed: parameters.seed
                    )
                )
                recordRuntimeDebugSnapshot(
                    stage: stage,
                    engine: .liteRTLM,
                    runnerPath: nil,
                    rawOutput: result.text,
                    errorMessage: result.errorMessage
                )
                if result.success {
                    emitStatus(
                        .streaming,
                        title: "本文を書き出し中",
                        detail: "LiteRT-LM の本文を受信しました。画面へ反映しています。",
                        estimatedProgress: 92,
                        runnerLabel: runnerLabel,
                        warmState: warmState,
                        startedAt: startedAt,
                        onUpdate: onUpdate
                    )
                    lastRuntimeDiagnostic = nil
                    lastRuntimeError = nil
                    return result
                }
                lastFailure = result
            case .bundledServer:
                let tuning = effectiveCLITuning(
                    for: prompt,
                    modelPath: modelPath,
                    reasoningMode: reasoningMode,
                    requestedMaxTokens: parameters.maxTokens,
                    structured: false
                )
                emitStatus(
                    .warmingRuntime,
                    title: "ローカル runtime を準備中",
                    detail: warmState == .reusedWarmSession
                        ? "温まったランタイムを再利用中です。"
                        : "ローカル server を起動して Gemma 4 を使える状態にしています。",
                    estimatedProgress: 30,
                    runnerLabel: runtimeRunnerLabel(for: engine, runnerPath: bundledServerCandidateURLs.first?.path),
                    warmState: warmState,
                    startedAt: startedAt,
                    onUpdate: onUpdate
                )
                guard let session = ensureBundledServer(modelPath: modelPath, timeoutSeconds: 60, reasoningMode: reasoningMode) else {
                    lastFailure = VIUKEmbeddedRuntimeResult(success: false, text: nil, errorMessage: bundledServerFailureMessage("ローカル server の起動に失敗しました。"))
                    recordRuntimeDebugSnapshot(
                        stage: stage,
                        engine: .bundledServer,
                        runnerPath: bundledServerCandidateURLs.first?.path,
                        rawOutput: nil,
                        errorMessage: lastFailure?.errorMessage
                    )
                    continue
                }
                emitStatus(
                    .loadingModel,
                    title: "Gemma 4 をロード中",
                    detail: loadingStatusDetail(modelPath: modelPath, warmState: warmState == .reusedWarmSession ? .reusedWarmSession : .coldStart, structured: false),
                    estimatedProgress: 48,
                    runnerLabel: runtimeRunnerLabel(for: engine, runnerPath: session.runnerPath),
                    warmState: warmState == .reusedWarmSession ? .reusedWarmSession : .coldStart,
                    startedAt: startedAt,
                    onUpdate: onUpdate
                )
                let nativeThinkingEnabled = session.nativeThinkingEnabled
                let generationStage: LocalExecutionStage = nativeThinkingEnabled ? .thinking : .generating
                emitStatus(
                    generationStage,
                    title: nativeThinkingEnabled ? "推論を整理中" : "本文を生成中",
                    detail: nativeThinkingEnabled
                        ? "Gemma 4 の native thinking を受信しながら推論を整理しています。"
                        : "Gemma 4 が回答本文を組み立てています。",
                    estimatedProgress: reasoningMode == .fast ? 84 : 70,
                    runnerLabel: runtimeRunnerLabel(for: engine, runnerPath: session.runnerPath),
                    warmState: warmState == .reusedWarmSession ? .reusedWarmSession : .coldStart,
                    startedAt: startedAt,
                    onUpdate: onUpdate
                )
                // multi-turn が staging されていれば KV キャッシュが前ターンを再利用できる形式で送信。
                let history = consumeStagedChatHistory()
                let serverMessages: [[String: Any]]
                if let history, !history.isEmpty {
                    // 最新の user メッセージ = prompt のみ（conversation 履歴は separate turns として渡す）
                    serverMessages = makeMultiTurnMessages(
                        systemPrompt: systemPrompt,
                        history: history,
                        latestUserContent: prompt
                    )
                } else {
                    serverMessages = makeServerMessages(systemPrompt: systemPrompt, userPrompt: prompt)
                }
                // ストリーミングコールバック: 各チャンクを受けてプレビューを更新する。
                // 初回 visible content 到着時に .streaming ステータスも emit する。
                let streamRunnerLabel = runtimeRunnerLabel(for: engine, runnerPath: session.runnerPath)
                let streamWarmState: LocalRuntimeWarmState = warmState == .reusedWarmSession ? .reusedWarmSession : .coldStart
                let serverStreamCallback: ((String, String) -> Void)? = onUpdate.map { update in
                    var streamingStatusEmitted = false
                    // 高速化: tool_calls は必ず先頭から現れる。最初の可視テキストが確認できた後は
                    // 正規表現（stripStructuredMarkup / extractFunctionCalls）をスキップし、
                    // 差分のみ追加して O(n²) を O(n) に抑える。
                    var cleanVisibleAccum = ""
                    var prevContentLen = 0
                    // (Win #2) Fast モード + thinking 無効時は per-token MainActor hop を 16ms にコアレス。
                    // ストリーム中の partialVisiblePreview / partialThinkingPreview を完全にスキップし
                    // 単純な差分蓄積だけで済ませる。Sonar 風の体感速度に直結する。
                    let isFastBypass = reasoningMode == .fast && !nativeThinkingEnabled
                    var lastVisibleEmitAt: Date = .distantPast
                    var lastThinkingEmitAt: Date = .distantPast
                    var lastThinkingReasoningLen = 0
                    var lastEmittedThinking = ""
                    let coalesceInterval: TimeInterval = 0.016 // ~60fps
                    return { [weak self] accContent, accReasoning in
                        guard let self else { return }
                        // ── 診断ログ (chat path) ──
                        NSLog("[ThinkDiag-Chat] onDelta fired: accContent.count=%d accReasoning.count=%d nativeThinking=%d isFastBypass=%d",
                              accContent.count, accReasoning.count,
                              nativeThinkingEnabled ? 1 : 0, isFastBypass ? 1 : 0)
                        if accContent.count <= 300 {
                            NSLog("[ThinkDiag-Chat] accContent(raw): %@", accContent)
                        } else {
                            NSLog("[ThinkDiag-Chat] accContent first300: %@", String(accContent.prefix(300)))
                        }
                        // vendored llama.cpp は Gemma 4 の `<|channel>thought\n...<channel|>` を
                        // reasoning_content に振り分けない。そのため accContent 側に来た raw を
                        // 自前で (thinking, visible) に分解して両プレビューを更新する。
                        // 既存の `<|`-stripper (stripSpecialTokenFragments / containsSpecialTokenLeakFragment) を
                        // 通すと channel タグ周辺ごと visible が空にされてしまうので、
                        // この分割は sanitize より前に行う必要がある。
                        let useChannelSplit = nativeThinkingEnabled && !isFastBypass
                        let split: (thinking: String, visible: String)
                        if useChannelSplit {
                            split = self.splitGemma4ChannelStream(accContent)
                        } else {
                            split = ("", accContent)
                        }
                        NSLog("[ThinkDiag-Chat] split: thinking.count=%d visible.count=%d useChannelSplit=%d",
                              split.thinking.count, split.visible.count, useChannelSplit ? 1 : 0)
                        let visibleSource = split.thinking.isEmpty && self.containsThinkingMarkup(accContent)
                            ? self.cleanStructuredCLIOutput(accContent)
                            : split.visible
                        let v: String
                        if isFastBypass {
                            // 高速パス: 正規表現ゼロ、差分のみ蓄積、トリムは末尾だけで十分
                            let delta = String(visibleSource.dropFirst(min(prevContentLen, visibleSource.count)))
                            prevContentLen = visibleSource.count
                            cleanVisibleAccum += delta
                            v = cleanVisibleAccum
                        } else if useChannelSplit {
                            // Channel split を使う時は visibleSource が delta ベースではなく
                            // 既に thinking を除いた visible のみなので、accum はそのまま採用する。
                            cleanVisibleAccum = visibleSource
                            prevContentLen = visibleSource.count
                            v = visibleSource.trimmingCharacters(in: .whitespacesAndNewlines)
                        } else if cleanVisibleAccum.isEmpty {
                            let checked = self.partialVisiblePreview(from: visibleSource)
                            if !checked.isEmpty {
                                cleanVisibleAccum = checked
                                prevContentLen = visibleSource.count
                            }
                            v = checked
                        } else {
                            let delta = String(visibleSource.dropFirst(min(prevContentLen, visibleSource.count)))
                            prevContentLen = visibleSource.count
                            cleanVisibleAccum += delta
                            v = cleanVisibleAccum.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        // thinking 出力: reasoning_content（サーバー抽出）と channel split（自前抽出）の
                        // どちらか非空を採用する。長さ変化なしのデルタはコスト節約のためスキップ。
                        let t: String
                        if isFastBypass || !nativeThinkingEnabled {
                            t = ""
                        } else if !accReasoning.isEmpty {
                            if accReasoning.count == lastThinkingReasoningLen {
                                t = ""
                            } else {
                                t = self.partialThinkingPreview(from: accReasoning)
                            }
                        } else {
                            // accReasoning が空でも accContent 側に thinking が来ていれば拾う。
                            // channel split から来たテキストは `<|channel>thought\n...<channel|>` を
                            // 自前で剥がした「モデル純粋出力」なので、sanitizeThinkingPreview は
                            // 一切通さない。truncateMarkers (`user:` / `assistant:` / `request:` 等) や
                            // looksLikeGenericThinkingOnly (count≤320, japaneseCount≤2) で
                            // モデル出力が空に潰されて表示されなくなるため。
                            let channelThinking = split.thinking.trimmingCharacters(in: .whitespacesAndNewlines)
                            t = !channelThinking.isEmpty
                                ? channelThinking
                                : (self.containsThinkingMarkup(accContent) ? self.partialThinkingPreview(from: accContent) : "")
                        }
                        // ── 診断ログ (chat path): t 計算結果 ──
                        NSLog("[ThinkDiag-Chat] t.count=%d v.count=%d lastEmittedThinking.count=%d",
                              t.count, v.count, lastEmittedThinking.count)
                        if !t.isEmpty, t.count <= 200 {
                            NSLog("[ThinkDiag-Chat] t=%@", t)
                        }
                        if !v.isEmpty {
                            if !streamingStatusEmitted {
                                streamingStatusEmitted = true
                                self.emitStatus(
                                    .streaming,
                                    title: "本文を書き出し中",
                                    detail: "Gemma 4 の本文を受信しました。画面へ反映しています。",
                                    estimatedProgress: 92,
                                    runnerLabel: streamRunnerLabel,
                                    warmState: streamWarmState,
                                    startedAt: startedAt,
                                    onUpdate: update
                                )
                            }
                            if isFastBypass {
                                let now = Date()
                                if now.timeIntervalSince(lastVisibleEmitAt) >= coalesceInterval {
                                    lastVisibleEmitAt = now
                                    Task { @MainActor in update(.visiblePreview(v)) }
                                }
                            } else {
                                Task { @MainActor in update(.visiblePreview(v)) }
                            }
                        }
                        if !t.isEmpty, t != lastEmittedThinking {
                            NSLog("[ThinkDiag-Chat] ✅ EMITTING .thinkingPreview t.count=%d", t.count)
                            // visiblePreview と同じ ~60fps コアレスで MainActor hop を抑える。
                            // さらに t が前回と完全に同一なら再 emit しない (visible 流入中の
                            // 「閉じた thinking を毎 16ms に再送」を防ぐ)。
                            let now = Date()
                            if lastEmittedThinking.isEmpty || now.timeIntervalSince(lastThinkingEmitAt) >= coalesceInterval {
                                lastThinkingEmitAt = now
                                lastThinkingReasoningLen = accReasoning.count
                                lastEmittedThinking = t
                                Task { @MainActor in update(.thinkingPreview(t)) }
                            }
                        } else if t.isEmpty {
                            NSLog("[ThinkDiag-Chat] ⚠️ t is EMPTY → no thinkingPreview emit")
                        }
                    }
                }
                var response = requestBundledServerChat(
                    session: session,
                    messages: serverMessages,
                    maxTokens: tuning.maxTokens,
                    temperature: parameters.temperature,
                    topP: parameters.topP,
                    topK: parameters.topK,
                    seed: parameters.seed,
                    timeoutSeconds: tuning.timeoutSeconds,
                    reasoningMode: reasoningMode,
                    enabledToolNames: [],
                    onStreamUpdate: serverStreamCallback
                )
                // 失敗したら server を再起動して 1 回だけリトライ（再試行は非ストリーミング）
                if response == nil {
                    terminateBundledServer()
                    if let retrySession = ensureBundledServer(modelPath: modelPath, timeoutSeconds: 45, reasoningMode: reasoningMode) {
                        response = requestBundledServerChat(
                            session: retrySession,
                            messages: serverMessages,
                            maxTokens: tuning.maxTokens,
                            temperature: parameters.temperature,
                            topP: parameters.topP,
                            topK: parameters.topK,
                            seed: parameters.seed,
                            timeoutSeconds: tuning.timeoutSeconds,
                            reasoningMode: reasoningMode,
                            enabledToolNames: []
                        )
                    }
                }
                guard let response else {
                    lastFailure = VIUKEmbeddedRuntimeResult(success: false, text: nil, errorMessage: "ローカル server からの応答に失敗しました。")
                    recordRuntimeDebugSnapshot(
                        stage: stage,
                        engine: .bundledServer,
                        runnerPath: session.runnerPath,
                        rawOutput: nil,
                        errorMessage: lastFailure?.errorMessage
                    )
                    continue
                }
                let cleanedBase = cleanCLIOutput(response.content)
                // server は CLI のような stdout ノイズがないため、cleaned が空でも raw content を優先。
                // 「生成されているのに失敗」現象を防ぐ。
                let cleaned: String
                if cleanedBase.isEmpty && !response.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    NSLog("[BundledServer] ⚠️ cleanCLIOutput が全て除去。raw content を使用 (len=%d)", response.content.count)
                    cleaned = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    cleaned = cleanedBase
                }
                let thinkingPreview = sanitizeThinkingPreview(response.reasoningContent)
                if !thinkingPreview.isEmpty {
                    emitStatus(
                        .thinking,
                        title: "推論方針を整理中",
                        detail: "Gemma 4 が推論の筋道を整理しています。",
                        estimatedProgress: 70,
                        runnerLabel: runtimeRunnerLabel(for: engine, runnerPath: session.runnerPath),
                        warmState: warmState == .reusedWarmSession ? .reusedWarmSession : .coldStart,
                        startedAt: startedAt,
                        onUpdate: onUpdate
                    )
                    Task { @MainActor in onUpdate?(.thinkingPreview(thinkingPreview)) }
                }
                recordRuntimeDebugSnapshot(
                    stage: stage,
                    engine: .bundledServer,
                    runnerPath: session.runnerPath,
                    rawOutput: response.content,
                    errorMessage: cleaned.isEmpty ? "ローカル server の生成結果が空でした。" : nil
                )
                if !cleaned.isEmpty {
                    emitStatus(
                        .streaming,
                        title: "本文を書き出し中",
                        detail: "Gemma 4 の本文を受信しました。画面へ反映しています。",
                        estimatedProgress: 92,
                        runnerLabel: runtimeRunnerLabel(for: engine, runnerPath: session.runnerPath),
                        warmState: warmState == .reusedWarmSession ? .reusedWarmSession : .coldStart,
                        startedAt: startedAt,
                        onUpdate: onUpdate
                    )
                    lastRuntimeDiagnostic = nil
                    lastRuntimeError = nil
                    return VIUKEmbeddedRuntimeResult(success: true, text: cleaned, errorMessage: nil)
                }
                lastFailure = VIUKEmbeddedRuntimeResult(success: false, text: nil, errorMessage: "ローカル server の生成結果が空でした。")
            case .bundledCLI:
                let result = runCLI(
                    prompt: prompt,
                    systemPrompt: systemPrompt,
                    modelPath: modelPath,
                    reasoningMode: reasoningMode,
                    maxTokens: parameters.maxTokens,
                    temperature: parameters.temperature,
                    topP: parameters.topP,
                    topK: parameters.topK,
                    seed: parameters.seed,
                    timeoutSeconds: cliGenerationTimeoutSeconds(for: reasoningMode, structured: false),
                    stage: stage,
                    startedAt: startedAt,
                    onUpdate: onUpdate
                )
                if result.success {
                    return result
                }
                lastFailure = result
            case .unavailable:
                lastFailure = VIUKEmbeddedRuntimeResult(success: false, text: nil, errorMessage: "ローカル runtime が見つかりません。")
                recordRuntimeDebugSnapshot(
                    stage: stage,
                    engine: .unavailable,
                    runnerPath: nil,
                    rawOutput: nil,
                    errorMessage: lastFailure?.errorMessage
                )
            }
        }

        let failure = lastFailure ?? VIUKEmbeddedRuntimeResult(success: false, text: nil, errorMessage: "ローカル runtime が見つかりません。")
        let diagnostic = classifyRuntimeFailure(stage: stage, rawMessage: failure.errorMessage, terminationStatus: nil)
        lastRuntimeDiagnostic = diagnostic
        lastRuntimeError = diagnostic.detailedMessage
        if lastRuntimeStage == nil {
            recordRuntimeDebugSnapshot(
                stage: stage,
                engine: .unavailable,
                runnerPath: nil,
                rawOutput: nil,
                errorMessage: diagnostic.detailedMessage
            )
        }
        return VIUKEmbeddedRuntimeResult(success: false, text: nil, errorMessage: diagnostic.detailedMessage)
    }

    private struct StructuredTurnExecutionResult {
        let turn: LocalAssistantStructuredTurn?
        let rawOutput: String?
        let errorMessage: String?
        let terminationStatus: Int32?
        let runnerPath: String?
    }

    private func liteRTLMUserFacingThinkingPreview(
        prompt: String,
        researchMode: ResearchMode?,
        enabledToolNames: [String]
    ) -> String {
        let compactPrompt = prompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        let topic = compactPrompt.isEmpty ? "今回の質問" : String(compactPrompt.prefix(80))
        var lines = [
            "「\(topic)」への答え方を整理しています。",
            "まず結論を決め、必要な前提と補足を本文に分けます。"
        ]
        if researchMode == .deep {
            lines.append("Deep Research の結果を本文に統合する順番を確認しています。")
        } else if !enabledToolNames.isEmpty {
            lines.append("使えるツールと参照情報を確認し、必要なものだけ回答に反映します。")
        } else {
            lines.append("外部ツールなしで答えられる範囲を見極めています。")
        }
        return lines.joined(separator: "\n")
    }

    private func generateStructuredTurnWithLiteRTLMRuntime(
        prompt: String,
        systemPrompt: String?,
        modelPath: String,
        parameters: (maxTokens: Int, temperature: Float, topP: Float, topK: Int, seed: UInt32),
        reasoningMode: ReasoningMode,
        researchMode: ResearchMode,
        enabledToolNames: [String],
        startedAt: Date,
        onUpdate: (@MainActor @Sendable (LocalAssistantStructuredTurnUpdate) -> Void)?
    ) async -> StructuredTurnExecutionResult {
        let warmState = warmState(for: .liteRTLM, modelPath: modelPath)
        let runnerLabel = runtimeRunnerLabel(for: .liteRTLM, runnerPath: nil)
        emitStatus(
            .loadingModel,
            title: "Gemma 4 E2B をロード中",
            detail: "iOS 用 LiteRT-LM runtime で会話用モデルを準備しています。",
            estimatedProgress: 48,
            runnerLabel: runnerLabel,
            warmState: warmState,
            startedAt: startedAt,
            onUpdate: onUpdate
        )
        if shouldEnableNativeThinking(forModelPath: modelPath, reasoningMode: reasoningMode), let onUpdate {
            emitStatus(
                .thinking,
                title: "回答方針を整理中",
                detail: "質問の意図、参照情報、答える順番を整理しています。",
                estimatedProgress: 64,
                runnerLabel: runnerLabel,
                warmState: warmState,
                startedAt: startedAt,
                onUpdate: onUpdate
            )
            let preview = liteRTLMUserFacingThinkingPreview(
                prompt: prompt,
                researchMode: researchMode,
                enabledToolNames: enabledToolNames
            )
            Task { @MainActor in onUpdate(.thinkingPreview(preview)) }
        }
        emitStatus(
            .generating,
            title: "本文を生成中",
            detail: "Gemma 4 がスマホ上で返答を組み立てています。",
            estimatedProgress: reasoningMode == .fast ? 84 : 70,
            runnerLabel: runnerLabel,
            warmState: warmState,
            startedAt: startedAt,
            onUpdate: onUpdate
        )
        let result = await LocalAssistantLiteRTLMRuntime.shared.generateAsync(
            LocalAssistantLiteRTLMRequest(
                prompt: prompt,
                systemPrompt: systemPrompt,
                modelPath: modelPath,
                maxTokens: parameters.maxTokens,
                temperature: parameters.temperature,
                topP: parameters.topP,
                topK: parameters.topK,
                seed: parameters.seed
            )
        )
        let rawText = result.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard result.success, !rawText.isEmpty else {
            return StructuredTurnExecutionResult(
                turn: nil,
                rawOutput: rawText.isEmpty ? nil : rawText,
                errorMessage: result.errorMessage ?? "LiteRT-LM の structured turn 出力が空でした。",
                terminationStatus: nil,
                runnerPath: nil
            )
        }

        let turn = parseStructuredTurnOutput(rawText, enabledToolNames: enabledToolNames)
        if let onUpdate {
            let visiblePreview = turn.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !visiblePreview.isEmpty {
                emitStatus(
                    .streaming,
                    title: "本文を書き出し中",
                    detail: "Gemma 4 の本文を受信しました。画面へ反映しています。",
                    estimatedProgress: 92,
                    runnerLabel: runnerLabel,
                    warmState: warmState,
                    startedAt: startedAt,
                    onUpdate: onUpdate
                )
                Task { @MainActor in onUpdate(.visiblePreview(visiblePreview)) }
            }
            let toolPreview = turn.toolCalls
                .prefix(4)
                .map { call -> String in
                    let summary = call.arguments?.queries?.joined(separator: " / ")
                        ?? call.arguments?.query
                        ?? call.arguments?.expression
                        ?? call.arguments?.stopCondition
                        ?? ""
                    return summary.isEmpty ? call.name.rawValue : "\(call.name.rawValue): \(summary)"
                }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !toolPreview.isEmpty {
                Task { @MainActor in onUpdate(.toolCallPreview(toolPreview)) }
            }
        }

        let accepted = isAcceptableStructuredTurn(turn)
        return StructuredTurnExecutionResult(
            turn: accepted ? turn : nil,
            rawOutput: rawText,
            errorMessage: accepted ? nil : "LiteRT-LM の structured turn を解釈できませんでした。",
            terminationStatus: nil,
            runnerPath: nil
        )
    }

    private func generateStructuredTurnWithPreferredRuntime(
        prompt: String,
        systemPrompt: String?,
        modelPath: String,
        parameters: (maxTokens: Int, temperature: Float, topP: Float, topK: Int, seed: UInt32),
        reasoningMode: ReasoningMode,
        researchMode: ResearchMode,
        enabledToolNames: [String],
        startedAt: Date,
        onUpdate: (@MainActor @Sendable (LocalAssistantStructuredTurnUpdate) -> Void)?
    ) -> StructuredTurnExecutionResult {
        var lastFailure = StructuredTurnExecutionResult(
            turn: nil,
            rawOutput: nil,
            errorMessage: "ローカル runtime が見つかりません。",
            terminationStatus: nil,
            runnerPath: nil
        )
        for engine in generationRuntimeEngines(forModelPath: modelPath) {
            let warmState = warmState(for: engine, modelPath: modelPath)
            switch engine {
            case .embedded:
                emitStatus(
                    .loadingModel,
                    title: "Gemma 4 をロード中",
                    detail: loadingStatusDetail(modelPath: modelPath, warmState: warmState, structured: true),
                    estimatedProgress: 48,
                    runnerLabel: runtimeRunnerLabel(for: engine, runnerPath: nil),
                    warmState: warmState,
                    startedAt: startedAt,
                    onUpdate: onUpdate
                )
#if os(macOS) || os(iOS)
                let result = VIUKEmbeddedRuntime.shared().generate(
                    withPrompt: prompt,
                    modelPath: modelPath,
                    maxTokens: parameters.maxTokens,
                    temperature: parameters.temperature,
                    topP: parameters.topP,
                    topK: parameters.topK,
                    seed: parameters.seed
                )
                recordRuntimeDebugSnapshot(
                    stage: .generation,
                    engine: .embedded,
                    runnerPath: nil,
                    rawOutput: result.text,
                    errorMessage: result.errorMessage
                )
                if result.success, let text = result.text {
                    let turn = parseStructuredTurnOutput(text, enabledToolNames: enabledToolNames)
                    if !turn.finalText.isEmpty || !turn.toolCalls.isEmpty {
                        emitStatus(
                            .streaming,
                            title: "本文を書き出し中",
                            detail: "Gemma 4 の本文を受信しました。画面へ反映しています。",
                            estimatedProgress: 92,
                            runnerLabel: runtimeRunnerLabel(for: engine, runnerPath: nil),
                            warmState: warmState,
                            startedAt: startedAt,
                            onUpdate: onUpdate
                        )
                        lastRuntimeDiagnostic = nil
                        lastRuntimeError = nil
                        return StructuredTurnExecutionResult(
                            turn: turn,
                            rawOutput: text,
                            errorMessage: nil,
                            terminationStatus: nil,
                            runnerPath: nil
                        )
                    }
                }
                lastFailure = StructuredTurnExecutionResult(
                    turn: nil,
                    rawOutput: result.text,
                    errorMessage: result.errorMessage,
                    terminationStatus: nil,
                    runnerPath: nil
                )
#else
                lastFailure = StructuredTurnExecutionResult(turn: nil, rawOutput: nil, errorMessage: "このプラットフォームでは埋め込み runtime を使えません。", terminationStatus: nil, runnerPath: nil)
#endif
            case .bundledServer:
                let tuning = effectiveCLITuning(
                    for: prompt,
                    modelPath: modelPath,
                    reasoningMode: reasoningMode,
                    requestedMaxTokens: parameters.maxTokens,
                    structured: true
                )
                emitStatus(
                    .warmingRuntime,
                    title: "ローカル runtime を準備中",
                    detail: warmState == .reusedWarmSession
                        ? "温まったランタイムを再利用中です。"
                        : "ローカル server を起動して Deep Research の準備をしています。",
                    estimatedProgress: 30,
                    runnerLabel: runtimeRunnerLabel(for: engine, runnerPath: bundledServerCandidateURLs.first?.path),
                    warmState: warmState,
                    startedAt: startedAt,
                    onUpdate: onUpdate
                )
                guard let session = ensureBundledServer(modelPath: modelPath, timeoutSeconds: 60, reasoningMode: reasoningMode) else {
                    lastFailure = StructuredTurnExecutionResult(
                        turn: nil,
                        rawOutput: nil,
                        errorMessage: bundledServerFailureMessage("ローカル server の起動に失敗しました。"),
                        terminationStatus: nil,
                        runnerPath: bundledServerCandidateURLs.first?.path
                    )
                    recordRuntimeDebugSnapshot(
                        stage: .generation,
                        engine: .bundledServer,
                        runnerPath: bundledServerCandidateURLs.first?.path,
                        rawOutput: nil,
                        errorMessage: lastFailure.errorMessage
                    )
                    continue
                }
                emitStatus(
                    .loadingModel,
                    title: "Gemma 4 をロード中",
                    detail: loadingStatusDetail(modelPath: modelPath, warmState: warmState == .reusedWarmSession ? .reusedWarmSession : .coldStart, structured: true),
                    estimatedProgress: 48,
                    runnerLabel: runtimeRunnerLabel(for: engine, runnerPath: session.runnerPath),
                    warmState: warmState == .reusedWarmSession ? .reusedWarmSession : .coldStart,
                    startedAt: startedAt,
                    onUpdate: onUpdate
                )
                let nativeThinkingEnabledForStructured = session.nativeThinkingEnabled
                let structuredGenerationStage: LocalExecutionStage = nativeThinkingEnabledForStructured ? .thinking : .generating
                emitStatus(
                    structuredGenerationStage,
                    title: nativeThinkingEnabledForStructured ? "推論を整理中" : "本文を生成中",
                    detail: nativeThinkingEnabledForStructured
                        ? "Gemma 4 の native thinking と tool 結果を推論として整理しています。"
                        : "Gemma 4 が最終 answer を組み立てています。",
                    estimatedProgress: reasoningMode == .fast ? 84 : 70,
                    runnerLabel: runtimeRunnerLabel(for: engine, runnerPath: session.runnerPath),
                    warmState: warmState == .reusedWarmSession ? .reusedWarmSession : .coldStart,
                    startedAt: startedAt,
                    onUpdate: onUpdate
                )
                let structuredHistory = consumeStagedChatHistory()
                let structuredServerMessages: [[String: Any]]
                if let structuredHistory, !structuredHistory.isEmpty {
                    structuredServerMessages = makeMultiTurnMessages(
                        systemPrompt: systemPrompt,
                        history: structuredHistory,
                        latestUserContent: prompt
                    )
                } else {
                    structuredServerMessages = makeServerMessages(systemPrompt: systemPrompt, userPrompt: prompt)
                }
                // ストリーミングコールバック。
                // thinking preview はリアルタイム表示し、tool call 本体は完成後に summary だけ流す。
                let sRunnerLabel = runtimeRunnerLabel(for: engine, runnerPath: session.runnerPath)
                let sWarmState: LocalRuntimeWarmState = warmState == .reusedWarmSession ? .reusedWarmSession : .coldStart
                let structuredStreamCallback: ((String, String) -> Void)? = onUpdate.map { update in
                    var streamingStatusEmitted = false
                    // 高速化: 最初の可視テキスト確認後は差分追加のみ（正規表現スキップ）
                    var cleanVisibleAccum = ""
                    var prevContentLen = 0
                    var lastThinkingEmitAt: Date = .distantPast
                    var lastThinkingReasoningLen = 0
                    let coalesceInterval: TimeInterval = 0.016 // ~60fps
                    return { [weak self] accContent, accReasoning in
                        guard let self else { return }
                        NSLog("[ThinkDiag-Struct] onDelta fired: accContent.count=%d accReasoning.count=%d nativeThinking=%d",
                              accContent.count, accReasoning.count, nativeThinkingEnabledForStructured ? 1 : 0)
                        // 構造化側でも Gemma 4 channel 形式が content に来たケースを救済する。
                        let useChannelSplit = nativeThinkingEnabledForStructured
                        let split: (thinking: String, visible: String)
                        if useChannelSplit {
                            split = self.splitGemma4ChannelStream(accContent)
                        } else {
                            split = ("", accContent)
                        }
                        let visibleSource = split.thinking.isEmpty && self.containsThinkingMarkup(accContent)
                            ? self.cleanStructuredCLIOutput(accContent)
                            : split.visible
                        let v: String
                        if useChannelSplit {
                            cleanVisibleAccum = visibleSource
                            prevContentLen = visibleSource.count
                            v = visibleSource.trimmingCharacters(in: .whitespacesAndNewlines)
                        } else if cleanVisibleAccum.isEmpty {
                            let checked = self.partialVisiblePreview(from: visibleSource)
                            if !checked.isEmpty {
                                cleanVisibleAccum = checked
                                prevContentLen = visibleSource.count
                            }
                            v = checked
                        } else {
                            let delta = String(visibleSource.dropFirst(min(prevContentLen, visibleSource.count)))
                            prevContentLen = visibleSource.count
                            cleanVisibleAccum += delta
                            v = cleanVisibleAccum.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        // thinking 出力: reasoning_content と channel split の非空を優先採用。
                        let t: String
                        if !nativeThinkingEnabledForStructured {
                            t = ""
                        } else if !accReasoning.isEmpty {
                            if accReasoning.count == lastThinkingReasoningLen {
                                t = ""
                            } else {
                                t = self.partialThinkingPreview(from: accReasoning)
                            }
                        } else {
                            // channel split のテキストは sanitize 不要。truncateMarkers に
                            // 引っかかるとモデル出力途中で表示が止まるため、また
                            // looksLikeGenericThinkingOnly (count≤320 / japaneseCount≤2) で
                            // 英語主体の短い思考が完全に潰されるため、trim だけで素通しする。
                            let channelThinking = split.thinking.trimmingCharacters(in: .whitespacesAndNewlines)
                            t = !channelThinking.isEmpty
                                ? channelThinking
                                : (self.containsThinkingMarkup(accContent) ? self.partialThinkingPreview(from: accContent) : "")
                        }
                        if !v.isEmpty {
                            if !streamingStatusEmitted {
                                streamingStatusEmitted = true
                                self.emitStatus(
                                    .streaming,
                                    title: "本文を書き出し中",
                                    detail: "Gemma 4 の本文を受信しました。画面へ反映しています。",
                                    estimatedProgress: 92,
                                    runnerLabel: sRunnerLabel,
                                    warmState: sWarmState,
                                    startedAt: startedAt,
                                    onUpdate: update
                                )
                            }
                            Task { @MainActor in update(.visiblePreview(v)) }
                        }
                        if !t.isEmpty {
                            // ~60fps コアレスで MainActor hop と UI 再レンダリングを抑える。
                            let now = Date()
                            if lastThinkingEmitAt == .distantPast || now.timeIntervalSince(lastThinkingEmitAt) >= coalesceInterval {
                                lastThinkingEmitAt = now
                                lastThinkingReasoningLen = accReasoning.count
                                Task { @MainActor in update(.thinkingPreview(t)) }
                            }
                        }
                    }
                }
                var response = requestBundledServerChat(
                    session: session,
                    messages: structuredServerMessages,
                    maxTokens: tuning.maxTokens,
                    temperature: parameters.temperature,
                    topP: parameters.topP,
                    topK: parameters.topK,
                    seed: parameters.seed,
                    timeoutSeconds: tuning.timeoutSeconds,
                    reasoningMode: reasoningMode,
                    enabledToolNames: enabledToolNames,
                    onStreamUpdate: structuredStreamCallback
                )
                // 失敗したら server を再起動して 1 回だけリトライ（再試行は非ストリーミング）
                if response == nil {
                    terminateBundledServer()
                    if let retrySession = ensureBundledServer(modelPath: modelPath, timeoutSeconds: 45, reasoningMode: reasoningMode) {
                        response = requestBundledServerChat(
                            session: retrySession,
                            messages: structuredServerMessages,
                            maxTokens: tuning.maxTokens,
                            temperature: parameters.temperature,
                            topP: parameters.topP,
                            topK: parameters.topK,
                            seed: parameters.seed,
                            timeoutSeconds: tuning.timeoutSeconds,
                            reasoningMode: reasoningMode,
                            enabledToolNames: enabledToolNames
                        )
                    }
                }
                guard let response else {
                    lastFailure = StructuredTurnExecutionResult(
                        turn: nil,
                        rawOutput: nil,
                        errorMessage: "ローカル server からの応答に失敗しました。",
                        terminationStatus: nil,
                        runnerPath: session.runnerPath
                    )
                    recordRuntimeDebugSnapshot(
                        stage: .generation,
                        engine: .bundledServer,
                        runnerPath: session.runnerPath,
                        rawOutput: nil,
                        errorMessage: lastFailure.errorMessage
                    )
                    continue
                }
                if let onUpdate {
                    let thinkingPreview = sanitizeThinkingPreview(response.reasoningContent)
                    if !thinkingPreview.isEmpty {
                        emitStatus(
                            .thinking,
                            title: "推論方針を整理中",
                            detail: "Gemma 4 が reasoning を整理しています。",
                            estimatedProgress: 70,
                            runnerLabel: runtimeRunnerLabel(for: engine, runnerPath: session.runnerPath),
                            warmState: warmState == .reusedWarmSession ? .reusedWarmSession : .coldStart,
                            startedAt: startedAt,
                            onUpdate: onUpdate
                        )
                        Task { @MainActor in onUpdate(.thinkingPreview(thinkingPreview)) }
                    }
                    let visiblePreview = cleanStructuredCLIOutput(response.content)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !visiblePreview.isEmpty {
                        emitStatus(
                            .streaming,
                            title: "本文を書き出し中",
                            detail: "Gemma 4 の本文を受信しました。画面へ反映しています。",
                            estimatedProgress: 92,
                            runnerLabel: runtimeRunnerLabel(for: engine, runnerPath: session.runnerPath),
                            warmState: warmState == .reusedWarmSession ? .reusedWarmSession : .coldStart,
                            startedAt: startedAt,
                            onUpdate: onUpdate
                        )
                        Task { @MainActor in onUpdate(.visiblePreview(visiblePreview)) }
                    }
                }
	                let turn = makeStructuredTurnFromServerResponse(response, enabledToolNames: enabledToolNames)
	                if let onUpdate, !turn.toolCalls.isEmpty {
	                    let preview = turn.toolCalls
	                        .prefix(4)
	                        .map { call -> String in
	                            let queries = call.arguments?.queries?.joined(separator: " / ")
	                                ?? call.arguments?.query
	                                ?? call.arguments?.expression
	                                ?? call.arguments?.stopCondition
	                                ?? ""
	                            return queries.isEmpty ? call.name.rawValue : "\(call.name.rawValue): \(queries)"
	                        }
	                        .joined(separator: "\n")
	                    if !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
	                        Task { @MainActor in onUpdate(.toolCallPreview(preview)) }
	                    }
	                }
	                recordRuntimeDebugSnapshot(
                    stage: .generation,
                    engine: .bundledServer,
                    runnerPath: session.runnerPath,
                    rawOutput: response.content,
                    errorMessage: isAcceptableStructuredTurn(turn) ? nil : "ローカル server の structured turn を解釈できませんでした。"
                )
                if isAcceptableStructuredTurn(turn) {
                    lastRuntimeDiagnostic = nil
                    lastRuntimeError = nil
                    return StructuredTurnExecutionResult(
                        turn: turn,
                        rawOutput: response.content,
                        errorMessage: nil,
                        terminationStatus: 0,
                        runnerPath: session.runnerPath
                    )
                }
                lastFailure = StructuredTurnExecutionResult(
                    turn: nil,
                    rawOutput: response.content,
                    errorMessage: "ローカル server の structured turn を解釈できませんでした。",
                    terminationStatus: nil,
                    runnerPath: session.runnerPath
                )
            case .bundledCLI:
                let result = runStructuredCLI(
                    prompt: prompt,
                    systemPrompt: systemPrompt,
                    modelPath: modelPath,
                    maxTokens: parameters.maxTokens,
                    temperature: parameters.temperature,
                    topP: parameters.topP,
                    topK: parameters.topK,
                    seed: parameters.seed,
                    timeoutSeconds: cliGenerationTimeoutSeconds(for: reasoningMode, structured: true),
                    reasoningMode: reasoningMode,
                    enabledToolNames: enabledToolNames,
                    stage: .generation,
                    startedAt: startedAt,
                    onUpdate: onUpdate
                )
                if result.turn != nil {
                    return result
                }
                lastFailure = result
            case .liteRTLM:
                emitStatus(
                    .loadingModel,
                    title: "Gemma 4 E2B をロード中",
                    detail: "iOS 用 LiteRT-LM runtime で会話用モデルを準備しています。",
                    estimatedProgress: 48,
                    runnerLabel: runtimeRunnerLabel(for: engine, runnerPath: nil),
                    warmState: warmState,
                    startedAt: startedAt,
                    onUpdate: onUpdate
                )
                if shouldEnableNativeThinking(forModelPath: modelPath, reasoningMode: reasoningMode), let onUpdate {
                    emitStatus(
                        .thinking,
                        title: "回答方針を整理中",
                        detail: "質問の意図、参照情報、答える順番を整理しています。",
                        estimatedProgress: 64,
                        runnerLabel: runtimeRunnerLabel(for: engine, runnerPath: nil),
                        warmState: warmState,
                        startedAt: startedAt,
                        onUpdate: onUpdate
                    )
                    let preview = liteRTLMUserFacingThinkingPreview(
                        prompt: prompt,
                        researchMode: researchMode,
                        enabledToolNames: enabledToolNames
                    )
                    Task { @MainActor in onUpdate(.thinkingPreview(preview)) }
                }
                emitStatus(
                    .generating,
                    title: "本文を生成中",
                    detail: "Gemma 4 がスマホ上で返答を組み立てています。",
                    estimatedProgress: reasoningMode == .fast ? 84 : 70,
                    runnerLabel: runtimeRunnerLabel(for: engine, runnerPath: nil),
                    warmState: warmState,
                    startedAt: startedAt,
                    onUpdate: onUpdate
                )
                let result = LocalAssistantLiteRTLMRuntime.shared.generate(
                    LocalAssistantLiteRTLMRequest(
                        prompt: prompt,
                        systemPrompt: systemPrompt,
                        modelPath: modelPath,
                        maxTokens: parameters.maxTokens,
                        temperature: parameters.temperature,
                        topP: parameters.topP,
                        topK: parameters.topK,
                        seed: parameters.seed
                    )
                )
                let rawText = result.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                recordRuntimeDebugSnapshot(
                    stage: .generation,
                    engine: .liteRTLM,
                    runnerPath: nil,
                    rawOutput: rawText.isEmpty ? nil : rawText,
                    errorMessage: result.success ? nil : result.errorMessage
                )
                if result.success, !rawText.isEmpty {
                    let turn = parseStructuredTurnOutput(rawText, enabledToolNames: enabledToolNames)
                    if let onUpdate {
                        let visiblePreview = turn.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !visiblePreview.isEmpty {
                            emitStatus(
                                .streaming,
                                title: "本文を書き出し中",
                                detail: "Gemma 4 の本文を受信しました。画面へ反映しています。",
                                estimatedProgress: 92,
                                runnerLabel: runtimeRunnerLabel(for: engine, runnerPath: nil),
                                warmState: warmState,
                                startedAt: startedAt,
                                onUpdate: onUpdate
                            )
                            Task { @MainActor in onUpdate(.visiblePreview(visiblePreview)) }
                        }
                        let toolPreview = turn.toolCalls
                            .prefix(4)
                            .map { call -> String in
                                let summary = call.arguments?.queries?.joined(separator: " / ")
                                    ?? call.arguments?.query
                                    ?? call.arguments?.expression
                                    ?? call.arguments?.stopCondition
                                    ?? ""
                                return summary.isEmpty ? call.name.rawValue : "\(call.name.rawValue): \(summary)"
                            }
                            .joined(separator: "\n")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !toolPreview.isEmpty {
                            Task { @MainActor in onUpdate(.toolCallPreview(toolPreview)) }
                        }
                    }
                    if isAcceptableStructuredTurn(turn) {
                        lastRuntimeDiagnostic = nil
                        lastRuntimeError = nil
                        return StructuredTurnExecutionResult(
                            turn: turn,
                            rawOutput: rawText,
                            errorMessage: nil,
                            terminationStatus: 0,
                            runnerPath: nil
                        )
                    }
                }
                lastFailure = StructuredTurnExecutionResult(
                    turn: nil,
                    rawOutput: rawText.isEmpty ? nil : rawText,
                    errorMessage: result.errorMessage ?? "LiteRT-LM の structured turn を解釈できませんでした。",
                    terminationStatus: nil,
                    runnerPath: nil
                )
            case .unavailable:
                lastFailure = StructuredTurnExecutionResult(turn: nil, rawOutput: nil, errorMessage: "ローカル runtime が見つかりません。", terminationStatus: nil, runnerPath: nil)
                recordRuntimeDebugSnapshot(
                    stage: .generation,
                    engine: .unavailable,
                    runnerPath: nil,
                    rawOutput: nil,
                    errorMessage: lastFailure.errorMessage
                )
            }
        }

        let diagnostic = classifyRuntimeFailure(
            stage: .generation,
            rawMessage: lastFailure.errorMessage ?? "Gemma 4 の structured turn に失敗しました。",
            terminationStatus: lastFailure.terminationStatus,
            runnerPath: lastFailure.runnerPath,
            modelPath: modelPath
        )
        lastRuntimeDiagnostic = diagnostic
        lastRuntimeError = diagnostic.detailedMessage
        if lastRuntimeStage == nil {
            recordRuntimeDebugSnapshot(
                stage: .generation,
                engine: .unavailable,
                runnerPath: lastFailure.runnerPath,
                rawOutput: lastFailure.rawOutput,
                errorMessage: diagnostic.detailedMessage
            )
        }
        return StructuredTurnExecutionResult(
            turn: nil,
            rawOutput: lastFailure.rawOutput,
            errorMessage: diagnostic.detailedMessage,
            terminationStatus: lastFailure.terminationStatus,
            runnerPath: lastFailure.runnerPath
        )
    }

    private func makeServerMessages(systemPrompt: String?, userPrompt: String) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        if let systemPrompt, !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(["role": "system", "content": systemPrompt])
        }
        messages.append(["role": "user", "content": userPrompt])
        return messages
    }

    /// 会話履歴を proper multi-turn 形式で組み立てる。
    /// - history: 過去ターン (最新ターンは含まない)
    /// - latestUserContent: 最新のユーザーメッセージ本文
    /// KV キャッシュが system + 全過去ターンを再利用でき、TTFT が劇的に改善する。
    private func makeMultiTurnMessages(
        systemPrompt: String?,
        history: [AICoachService.ChatMessage],
        latestUserContent: String
    ) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        if let systemPrompt, !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(["role": "system", "content": systemPrompt])
        }
        // 直近 8 ターンのみ。古いターンは省略してプリフィル長を抑える。
        // 各メッセージは 600 字以内にトリム（生成品質と速度のバランス）。
        let trimLimit = 600
        for msg in history.suffix(8) {
            let roleStr = msg.role == .user ? "user" : "assistant"
            let trimmed = String(msg.content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(trimLimit))
            guard !trimmed.isEmpty else { continue }
            messages.append(["role": roleStr, "content": trimmed])
        }
        messages.append(["role": "user", "content": latestUserContent])
        return messages
    }

    /// stagedChatHistory を消費して返す。nil ならニル。
    private func consumeStagedChatHistory() -> [AICoachService.ChatMessage]? {
        defer { stagedChatHistory = nil }
        return stagedChatHistory
    }

    // onStreamUpdate: ストリーミング時に (累積content, 累積reasoning) を受け取るコールバック。
    // nil の場合または tool calls が有効な場合は非ストリーミングで動作する。
    private func requestBundledServerChat(
        session: BundledServerSession,
        messages: [[String: Any]],
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        topK: Int,
        seed: UInt32,
        timeoutSeconds: Int,
        reasoningMode: ReasoningMode,
        enabledToolNames: [String],
        onStreamUpdate: ((String, String) -> Void)? = nil
    ) -> BundledServerChatResponse? {
        let sendStartedAt = Date()
        bundledServerLastUsedAt = Date()
        guard let url = URL(string: "http://127.0.0.1:\(session.port)/v1/chat/completions") else {
            return nil
        }

        // tool_calls の SSE delta も累積するようにしたので、tools 有効時もストリーミング可能
        let useStreaming = onStreamUpdate != nil
        var body: [String: Any] = [
            "model": "viuk-local",
            "messages": messages,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "top_p": topP,
            "top_k": topK,
            "seed": Int(seed),
            "stream": useStreaming,
            "cache_prompt": true
        ]
        if useStreaming {
            // OpenAI 互換: 最後の SSE チャンクに usage を載せてもらう。
            body["stream_options"] = ["include_usage": true]
        }

        // Kizuna personaでは生成開始前のThinkingを有効にする。
        // ただし reasoningBudget は小さく固定し、計算資源を制限する。
        if !session.nativeThinkingEnabled {
            body["reasoning_format"] = "none"
            body["chat_template_kwargs"] = ["enable_thinking": false]
        } else {
            body["reasoning_format"] = "auto"
            body["chat_template_kwargs"] = ["enable_thinking": true]
            body["thinking_budget_tokens"] = reasoningBudget(for: reasoningMode)
        }

        if !enabledToolNames.isEmpty {
            body["tools"] = AIToolCatalog.openAIToolPayloads(enabledToolNames: enabledToolNames)
            body["tool_choice"] = "auto"
            body["parallel_tool_calls"] = true
            body["parse_tool_calls"] = true
        }

        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = TimeInterval(max(60, timeoutSeconds + 60))
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // ローカル server は 127.0.0.1 専用。apiKey がある互換モードの時だけ認証ヘッダーを送る。
        if !session.apiKey.isEmpty {
            request.setValue(session.apiKey, forHTTPHeaderField: "X-API-Key")
            request.setValue("Bearer \(session.apiKey)", forHTTPHeaderField: "Authorization")
        }

        NSLog("[BundledServer] 送信開始 port=%d maxTokens=%d stream=%d", session.port, maxTokens, useStreaming ? 1 : 0)

        // ── ストリーミングパス ──────────────────────────────────────────────
        if useStreaming, let onStreamUpdate {
            let collector = BundledSSECollector()
            var firstTokenLogged = false
            collector.onDelta = { [weak self] _, _ in
                guard self != nil else { return }
                if !firstTokenLogged {
                    firstTokenLogged = true
                    let elapsed = Date().timeIntervalSince(sendStartedAt)
                    NSLog("[BundledServer] 初回トークン受信 elapsed=%.2fs", elapsed)
                }
                onStreamUpdate(collector.accContent, collector.accReasoning)
            }
            let delegateQueue = OperationQueue()
            delegateQueue.maxConcurrentOperationCount = 1
            let streamSession = URLSession(configuration: .default, delegate: collector, delegateQueue: delegateQueue)
            let task = streamSession.dataTask(with: request)
            setActiveBundledRequestTask(task)
            task.resume()
            let waitResult = collector.semaphore.wait(timeout: .now() + .seconds(max(60, timeoutSeconds + 90)))
            setActiveBundledRequestTask(nil)
            // [DONE] 受信で即復帰するため、残っている dataTask は cancel して即座に invalidate する。
            // finishTasksAndInvalidate は接続クローズを待つため、「生成終了後のラグ」の原因になっていた。
            task.cancel()
            streamSession.invalidateAndCancel()
            let elapsed = Date().timeIntervalSince(sendStartedAt)
            NSLog("[BundledServer] 生成完了(stream) elapsed=%.2fs finishReason=%@ contentLen=%d reasoningLen=%d status=%d waitResult=%@",
                  elapsed, collector.finishReason ?? "nil",
                  collector.accContent.count, collector.accReasoning.count,
                  collector.statusCode,
                  waitResult == .success ? "success" : "timeout")
            if collector.finishReason == "length" {
                NSLog("[BundledServer] ⚠️ finish_reason=length: maxTokens=%d に達して打ち切られました", maxTokens)
            }
            // 思考ブロックが閉じトークン未到着で終わっていないか診断ログ。
            // 「thinking 分の生成が止まる」現象の原因切り分け用。
            if session.nativeThinkingEnabled {
                let hasOpen = collector.accContent.contains("<|channel>")
                let hasClose = collector.accContent.contains("<channel|>")
                if hasOpen && !hasClose {
                    NSLog("[BundledServer] ⚠️ 思考ブロックが <channel|> 未到着で終了: maxTokens=%d finishReason=%@ contentLen=%d ─ 思考トークンが上限/EOS で打ち切られた可能性。maxTokens 増量か reasoning-budget の見直しが必要。",
                          maxTokens, collector.finishReason ?? "nil", collector.accContent.count)
                } else if !hasOpen {
                    NSLog("[BundledServer] ℹ️ thinking 有効だが accContent に <|channel> が無い: reasoningContent に分岐したか、テンプレートで think が無効化された可能性。reasoningLen=%d",
                          collector.accReasoning.count)
                }
            }
            // statusCode != 200 やタイムアウトでも、コンテンツが既に受信できていれば
            // それを成功扱いで返す（「生成されているのに失敗」現象を防ぐ）。
            let hasContent = !collector.accContent.isEmpty || !collector.accReasoning.isEmpty
            if collector.statusCode != 200 && !hasContent {
                let bodyPreview = collector.accContent.isEmpty ? collector.accReasoning : collector.accContent
                if !bodyPreview.isEmpty {
                    NSLog("[BundledServer] stream error body=%@", String(bodyPreview.prefix(240)))
                }
                return nil
            }
            if collector.statusCode != 200 && hasContent {
                NSLog("[BundledServer] ⚠️ statusCode=%d だが content を受信済み → 成功として返却", collector.statusCode)
            }
            if waitResult == .timedOut && hasContent {
                NSLog("[BundledServer] ⚠️ semaphore timeout だが content を受信済み → 成功として返却")
            }
            bundledServerLastUsedAt = Date()
            let streamedToolCalls = decodeServerToolCalls(
                from: collector.accToolCalls,
                enabledToolNames: enabledToolNames
            )
            // vendored llama.cpp が Gemma 4 の channel 思考を reasoning_content に
            // 振り分けていない時は、ここで content 側を split して正しい列に並べ替える。
            let (normContent, normReasoning) = normalizeGemma4ChannelResponse(
                content: collector.accContent,
                reasoningContent: collector.accReasoning,
                nativeThinkingEnabled: session.nativeThinkingEnabled,
                hasToolCalls: !streamedToolCalls.isEmpty,
                finishReason: collector.finishReason
            )

            // streamedToolCalls (OpenAI 形式) と visible content の両方が空で reasoning がある場合、
            // tool_calls JSON が reasoning channel に紛れ込んでいる可能性があるので救出する。
            let finalToolCalls: [LocalAssistantToolCall]
            if !streamedToolCalls.isEmpty {
                finalToolCalls = streamedToolCalls
            } else if normContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !normReasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let recovered = extractFunctionCalls(from: normReasoning, enabledToolNames: enabledToolNames)
                if !recovered.isEmpty {
                    NSLog("[BundledServer/stream] ✅ tool_calls を reasoning channel から救出: count=%d", recovered.count)
                }
                finalToolCalls = recovered
            } else {
                finalToolCalls = []
            }
            let streamResponse = BundledServerChatResponse(
                content: normContent,
                reasoningContent: normReasoning,
                toolCalls: finalToolCalls,
                finishReason: collector.finishReason,
                promptTokens: collector.promptTokens,
                completionTokens: collector.completionTokens
            )
            recordChatTokenUsage(streamResponse)
            return streamResponse
        }

        // ── 非ストリーミングパス ───────────────────────────────────────────
        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var statusCode = -1

        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            responseData = data
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            semaphore.signal()
        }
        setActiveBundledRequestTask(task)
        task.resume()
        _ = semaphore.wait(timeout: .now() + .seconds(max(60, timeoutSeconds + 90)))
        setActiveBundledRequestTask(nil)
        let elapsed = Date().timeIntervalSince(sendStartedAt)
        NSLog("[BundledServer] 完了(非stream) elapsed=%.2fs statusCode=%d", elapsed, statusCode)
        if statusCode != 200,
           let responseData,
           let body = String(data: responseData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !body.isEmpty {
            NSLog("[BundledServer] error body=%@", String(body.prefix(240)))
        }

        guard statusCode == 200,
              let responseData,
              let object = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let choice = choices.first,
              let message = choice["message"] as? [String: Any] else {
            return nil
        }

        let content = flattenedServerMessageContent(message["content"])
        let reasoningContent = serverMessageReasoningContent(message)
        let finishReason = choice["finish_reason"] as? String
        var capturedPromptTokens: Int?
        var capturedCompletionTokens: Int?
        if let usage = object["usage"] as? [String: Any] {
            let pt = usage["prompt_tokens"] as? Int ?? -1
            let ct = usage["completion_tokens"] as? Int ?? -1
            capturedPromptTokens = pt >= 0 ? pt : nil
            capturedCompletionTokens = ct >= 0 ? ct : nil
            NSLog("[BundledServer] usage: promptTokens=%d completionTokens=%d maxTokens=%d finishReason=%@",
                  pt, ct, maxTokens, finishReason ?? "nil")
            if finishReason == "length" {
                NSLog("[BundledServer] ⚠️ finish_reason=length: maxTokens=%d に達して打ち切られました", maxTokens)
            }
        }
        let openAIToolCalls = decodeServerToolCalls(
            from: message["tool_calls"],
            enabledToolNames: enabledToolNames
        )
        bundledServerLastUsedAt = Date()

        // 非ストリーミングパスでも同じく Gemma 4 channel の取り違えを補正する。
        let (normContent, normReasoning) = normalizeGemma4ChannelResponse(
            content: content,
            reasoningContent: reasoningContent,
            nativeThinkingEnabled: session.nativeThinkingEnabled,
            hasToolCalls: !openAIToolCalls.isEmpty,
            finishReason: finishReason
        )

        // Gemma 4 が tool_calls JSON を reasoning channel に書いて visible channel を
        // 閉じないまま終わるケースがある。OpenAI tool_calls も visible content も空のとき、
        // reasoning 側から tool_calls を救出する。
        let toolCalls: [LocalAssistantToolCall]
        if !openAIToolCalls.isEmpty {
            toolCalls = openAIToolCalls
        } else if normContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !normReasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let recovered = extractFunctionCalls(from: normReasoning, enabledToolNames: enabledToolNames)
            if !recovered.isEmpty {
                NSLog("[BundledServer] ✅ tool_calls を reasoning channel から救出: count=%d", recovered.count)
            }
            toolCalls = recovered
        } else {
            toolCalls = []
        }

        let nonStreamResponse = BundledServerChatResponse(
            content: normContent,
            reasoningContent: normReasoning,
            toolCalls: toolCalls,
            finishReason: finishReason,
            promptTokens: capturedPromptTokens,
            completionTokens: capturedCompletionTokens
        )
        recordChatTokenUsage(nonStreamResponse)
        return nonStreamResponse
    }

    /// vendored llama.cpp が Gemma 4 の `<|channel>thought\n...<channel|>` を
    /// reasoning_content に振り分けていない時、content 側を split して並べ替える。
    /// reasoningContent が既に非空ならそちら優先（サーバー側で抽出済み）。
    private func normalizeGemma4ChannelResponse(
        content: String,
        reasoningContent: String,
        nativeThinkingEnabled: Bool,
        hasToolCalls: Bool = false,
        finishReason: String? = nil
    ) -> (String, String) {
        guard nativeThinkingEnabled else { return (content, reasoningContent) }
        // tool_calls が伴うターン (finish_reason=tool_calls もしくは OpenAI tool_calls 配列が
        // 非空) で content が空なのは正常な状態。上位層が tool_calls を見て次ターンへ進めるので、
        // 偽の「失敗」メッセージを content に注入してはいけない。
        let isToolCallTurn = hasToolCalls || (finishReason?.lowercased() == "tool_calls")
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReasoning = reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedReasoning.isEmpty {
            // サーバーが reasoning_content の抽出に成功している。
            // ただし content が空 (= 最終回答が生成される前に max_tokens 等で切れた) の場合、
            // 空文字を返すと「生成結果が空でした」で画面が真っ白になるため、
            // reasoning を回答側にも流用してユーザーが何も見えない状態を避ける。
            if trimmedContent.isEmpty {
                // tool_calls のあるターンでは content が空でも fallback を注入しない。
                // 上位層が tool_calls を実行して次ターンへ進める。
                if isToolCallTurn {
                    NSLog("[BundledServer] ℹ️ content が空だが tool_calls あり → fallback 注入をスキップ (reasoningLen=%d)",
                          trimmedReasoning.count)
                    return ("", trimmedReasoning)
                }
                NSLog("[BundledServer] ⚠️ content が空・reasoning_content だけ存在。reasoning を回答として fallback (len=%d)",
                      trimmedReasoning.count)
                let fallback = (isBrokenEnglishPreambleOnly(trimmedReasoning) || trimmedReasoning.count < 80)
                    ? "（応答の生成に失敗しました。もう一度送信してください。）"
                    : """
                    （回答本文が出力されませんでした。以下は内部推論です。）

                    \(trimmedReasoning)
                    """
                return (fallback, trimmedReasoning)
            }
            return (content, reasoningContent)
        }
        let split = splitGemma4ChannelStream(content)
        if split.thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let thinkingSegments = sanitizeThinkingSegments(extractThinkingSegments(from: content))
            guard !thinkingSegments.isEmpty else {
                return (content, reasoningContent)
            }
            let visible = cleanStructuredCLIOutput(content).trimmingCharacters(in: .whitespacesAndNewlines)
            return (visible, thinkingSegments.joined(separator: "\n\n"))
        }
        // 思考ブロックは見つかったが、close マーカー `<channel|>` が出ないまま終了し
        // visible が空のケース。モデルが max_tokens / context 上限に達して回答前で
        // 切れた時に起きる。空文字を返すと「生成結果が空でした」エラーになり画面が真っ白になる。
        // → 内部推論テキストを「途中まで生成された結果」として answer 側にも回し、
        //    ユーザーが何も見えない状態を回避する。
        if split.visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            NSLog("[BundledServer] ⚠️ Gemma 4 visible が空（close マーカー未到着）。thinking を fallback 表示: thinkingLen=%d",
                  split.thinking.count)
            let trimmedThinking = split.thinking.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackVisible = (isBrokenEnglishPreambleOnly(trimmedThinking) || trimmedThinking.count < 80)
                ? "（応答の生成に失敗しました。もう一度送信してください。）"
                : """
                （回答本文が出力されませんでした。以下は内部推論です。）

                \(trimmedThinking)
                """
            return (fallbackVisible, trimmedThinking)
        }
        NSLog("[BundledServer] Gemma 4 channel を content から抽出: thinkingLen=%d visibleLen=%d",
              split.thinking.count, split.visible.count)
        return (split.visible, split.thinking)
    }

    /// "1. Analyze the..." / "Thinking Process: ..." 等、Gemma 4 が思考冒頭に出す
    /// 英語 preamble だけで終わったケースを判定。これは UI に出すと不自然なので
    /// 汎用のエラーメッセージに置換する。
    private func isBrokenEnglishPreambleOnly(_ text: String) -> Bool {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"[\*_`#]+"#, with: "", options: .regularExpression)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count < 220 else { return false }
        let markers = [
            "1. analyze",
            "analyze the",
            "thinking process",
            "construct the desired response",
            "construct the detailed answer",
            "desired answer",
            "desired response",
            "here is a thinking process",
            "here's a thinking process"
        ]
        return markers.contains { normalized.hasPrefix($0) || normalized.contains($0) }
    }

    private func flattenedServerMessageContent(_ rawValue: Any?) -> String {
        if let text = rawValue as? String {
            return text
        }
        guard let items = rawValue as? [[String: Any]] else {
            return ""
        }
        let parts = items.compactMap { item -> String? in
            if let text = item["text"] as? String {
                return text
            }
            if let type = item["type"] as? String,
               type == "text",
               let text = item["content"] as? String {
                return text
            }
            return nil
        }
        return parts.joined(separator: "\n")
    }

    private func serverMessageReasoningContent(_ message: [String: Any]) -> String {
        let keys = [
            "reasoning_content",
            "reasoningContent",
            "reasoning",
            "thinking",
            "thought",
            "thoughts"
        ]
        return keys
            .map { flattenedServerMessageContent(message[$0]) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func decodeServerToolCalls(
        from rawValue: Any?,
        enabledToolNames: [String]
    ) -> [LocalAssistantToolCall] {
        guard let items = rawValue as? [[String: Any]] else {
            return []
        }

        let decoded = items.compactMap { item -> LocalAssistantToolCall? in
            guard let function = item["function"] as? [String: Any],
                  let rawName = function["name"] as? String else {
                return nil
            }

            if let argumentText = function["arguments"] as? String {
                return decodeLocalToolCall(name: rawName, payload: argumentText)
            }

            if let argumentObject = function["arguments"] as? [String: Any],
               let toolName = LocalAssistantToolName(rawValue: rawName) {
                return LocalAssistantToolCall(
                    name: toolName,
                    arguments: decodeLocalToolCallArguments(from: argumentObject),
                    reason: nil
                )
            }

            return nil
        }

        return validateToolCalls(decoded, enabledToolNames: enabledToolNames)
    }

    private func makeStructuredTurnFromServerResponse(
        _ response: BundledServerChatResponse,
        enabledToolNames: [String]
    ) -> LocalAssistantStructuredTurn {
        let thinkingSegments = sanitizeThinkingSegments(
            response.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? []
                : [response.reasoningContent]
        )
        let toolCalls = validateToolCalls(response.toolCalls, enabledToolNames: enabledToolNames)
        let visibleText = cleanStructuredCLIOutput(response.content).trimmingCharacters(in: .whitespacesAndNewlines)
        let finalText = visibleText
        let rawThinkingStream = thinkingSegments.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEvents = buildNormalizedEvents(
            thinkingSegments: thinkingSegments,
            toolCalls: toolCalls,
            finalText: finalText
        )

        return LocalAssistantStructuredTurn(
            finalText: finalText,
            visibleText: visibleText,
            thinkingSegments: thinkingSegments,
            rawThinkingStream: rawThinkingStream,
            toolCalls: toolCalls,
            normalizedEvents: normalizedEvents,
            finishReason: response.finishReason
        )
    }

    private func runCLI(
        prompt: String,
        systemPrompt: String?,
        modelPath: String,
        reasoningMode: ReasoningMode,
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        topK: Int,
        seed: UInt32,
        timeoutSeconds: Int,
        stage: LocalAssistantRuntimeDiagnostic.Stage,
        startedAt: Date,
        onUpdate: (@MainActor @Sendable (LocalAssistantStructuredTurnUpdate) -> Void)? = nil
    ) -> VIUKEmbeddedRuntimeResult {
        let runnerCandidates = bundledCLICandidateURLs
        guard runnerCandidates.isEmpty == false else {
            let diagnostic = classifyRuntimeFailure(stage: stage, rawMessage: "ローカル runtime が見つかりません。", terminationStatus: nil)
            lastRuntimeDiagnostic = diagnostic
            lastRuntimeError = diagnostic.detailedMessage
            recordRuntimeDebugSnapshot(
                stage: stage,
                engine: .bundledCLI,
                runnerPath: nil,
                rawOutput: nil,
                errorMessage: diagnostic.detailedMessage
            )
            return VIUKEmbeddedRuntimeResult(success: false, text: nil, errorMessage: diagnostic.detailedMessage)
        }

        let runtimePreset = runtimePreset(for: reasoningMode)
        let forceConservativeCPURuntime = shouldForceConservativeCPURuntime(forModelPath: modelPath)
        let disableNativeThinking = !shouldEnableNativeThinking(forModelPath: modelPath, reasoningMode: reasoningMode)
        let tuning = effectiveCLITuning(
            for: prompt,
            modelPath: modelPath,
            reasoningMode: reasoningMode,
            requestedMaxTokens: maxTokens,
            structured: false
        )
        let initialWarmState = warmState(for: .bundledCLI, modelPath: modelPath)
        let flashAttentionEnabled = forceConservativeCPURuntime ? false : runtimePreset.flashAttentionEnabled
        let gpuLayers = forceConservativeCPURuntime ? 0 : runtimePreset.gpuLayers
        let disableKVOffload = forceConservativeCPURuntime ? true : runtimePreset.disableKVOffload
        var baseArguments = [
            "--simple-io",
            "--log-disable",
            "--no-display-prompt",
            "--single-turn",
            "--model", modelPath,
            "--predict", String(tuning.maxTokens),
            "--ctx-size", String(tuning.contextSize),
            "--batch-size", String(tuning.batchSize),
            "--ubatch-size", String(tuning.microBatchSize),
            "--threads", String(runtimePreset.threadCount),
            "--threads-batch", String(runtimePreset.batchThreadCount),
            "--flash-attn", flashAttentionEnabled ? "on" : "off",
            "--temp", String(temperature),
            "--top-p", String(topP),
            "--top-k", String(topK),
            "--seed", String(seed)
        ]
        if disableNativeThinking {
            baseArguments.append(contentsOf: [
                "--reasoning", "off",
                "--chat-template-kwargs", #"{"enable_thinking":false}"#
            ])
        } else {
            // Gemma 4 では `enable_thinking:true` を明示しないと
            // `<|think|>` トリガーがテンプレートに注入されず思考が空になる。
            baseArguments.append(contentsOf: [
                "--reasoning", "on",
                "--reasoning-format", "auto",
                "--reasoning-budget", String(reasoningBudget(for: reasoningMode)),
                "--chat-template-kwargs", #"{"enable_thinking":true}"#
            ])
        }
        if let systemPrompt, systemPrompt.isEmpty == false {
            baseArguments.append(contentsOf: ["--system-prompt", systemPrompt])
        }
        baseArguments.append(contentsOf: ["--prompt", prompt])
        if forceConservativeCPURuntime {
            baseArguments.append(contentsOf: ["--device", "none"])
        } else if gpuLayers > 0 {
            baseArguments.append(contentsOf: ["--gpu-layers", String(gpuLayers)])
        }
        if disableKVOffload {
            baseArguments.append("--no-kv-offload")
        }
        var lastFailure: LocalAssistantRuntimeDiagnostic?
        for runnerURL in runnerCandidates {
            let runnerLabel = runtimeRunnerLabel(for: .bundledCLI, runnerPath: runnerURL.path)
            let process = Process()
            process.executableURL = runnerURL
            process.arguments = baseArguments

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            let terminationSemaphore = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in
                terminationSemaphore.signal()
            }
            let lock = NSLock()
            var stdoutBuffer = Data()
            var stderrBuffer = Data()
            var latestDecodedStdout = ""
            var latestDecodedStderr = ""
            var latestThinkingPreview = ""
            var latestVisiblePreview = ""
            var lastVisibleOutputActivityAt = Date.distantPast

            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                lock.lock()
                stdoutBuffer.append(data)
                if let decoded = String(data: stdoutBuffer, encoding: .utf8) {
                    latestDecodedStdout = decoded
                }
                let rawText = latestDecodedStdout.isEmpty
                    ? String(decoding: stdoutBuffer, as: UTF8.self)
                    : latestDecodedStdout
                // disableNativeThinking = true (Gemma 4) の場合は <think> タグが存在しないため
                // partialThinkingPreview のフォールバックが応答全文を thinking として返してしまう。
                // ネイティブ Thinking が無効なら常に空文字列を使い、<Thinking> ブロックを表示しない。
                let thinkingPreview = disableNativeThinking ? "" : self.partialThinkingPreview(from: rawText)
                let visiblePreview = self.partialVisiblePreview(from: rawText)
                let shouldPublishThinking = !thinkingPreview.isEmpty && thinkingPreview != latestThinkingPreview
                let shouldPublishVisible = !visiblePreview.isEmpty && visiblePreview != latestVisiblePreview
                if shouldPublishThinking {
                    latestThinkingPreview = thinkingPreview
                }
                if shouldPublishVisible {
                    latestVisiblePreview = visiblePreview
                    lastVisibleOutputActivityAt = Date()
                }
                lock.unlock()

                if let onUpdate {
                    if shouldPublishThinking {
                        self.emitStatus(
                            .thinking,
                            title: "推論方針を整理中",
                            detail: "Gemma 4 が推論の筋道を整理しています。",
                            estimatedProgress: 70,
                            runnerLabel: runnerLabel,
                            warmState: initialWarmState,
                            startedAt: startedAt,
                            onUpdate: onUpdate
                        )
                        Task { @MainActor in onUpdate(.thinkingPreview(thinkingPreview)) }
                    }
                    if shouldPublishVisible {
                        self.emitStatus(
                            .streaming,
                            title: "本文を書き出し中",
                            detail: "Gemma 4 の本文を受信しました。画面へ反映しています。",
                            estimatedProgress: 92,
                            runnerLabel: runnerLabel,
                            warmState: initialWarmState,
                            startedAt: startedAt,
                            onUpdate: onUpdate
                        )
                        Task { @MainActor in onUpdate(.visiblePreview(visiblePreview)) }
                    }
                }
            }
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                lock.lock()
                stderrBuffer.append(data)
                if let decoded = String(data: stderrBuffer, encoding: .utf8) {
                    latestDecodedStderr = decoded
                }
                lock.unlock()
            }

            do {
                try process.run()
                emitStatus(
                    .loadingModel,
                    title: "Gemma 4 をロード中",
                    detail: tuning.loadingPreview ?? loadingStatusDetail(modelPath: modelPath, warmState: initialWarmState, structured: false),
                    estimatedProgress: 48,
                    runnerLabel: runnerLabel,
                    warmState: initialWarmState,
                    startedAt: startedAt,
                    onUpdate: onUpdate
                )
                emitStatus(
                    disableNativeThinking ? .generating : .thinking,
                    title: disableNativeThinking ? "本文を生成中" : "推論を整理中",
                    detail: disableNativeThinking
                        ? "Gemma 4 が回答を生成しています。"
                        : (reasoningMode == .fast
                            ? "Gemma 4 が回答本文を組み立てています。"
                            : "Gemma 4 が推論方針を整理しています。"),
                    estimatedProgress: reasoningMode == .fast ? 84 : 70,
                    runnerLabel: runnerLabel,
                    warmState: initialWarmState,
                    startedAt: startedAt,
                    onUpdate: onUpdate
                )
            } catch {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                let diagnostic = classifyRuntimeFailure(
                    stage: stage,
                    rawMessage: "ローカル runtime の起動に失敗しました: \(error.localizedDescription)",
                    terminationStatus: nil,
                    runnerPath: runnerURL.path,
                    modelPath: modelPath
                )
                lastFailure = diagnostic
                recordRuntimeDebugSnapshot(
                    stage: stage,
                    engine: .bundledCLI,
                    runnerPath: runnerURL.path,
                    rawOutput: nil,
                    errorMessage: diagnostic.detailedMessage
                )
                continue
            }

            let completion = waitForCLIProcessToSettle(
                process,
                terminationSemaphore: terminationSemaphore,
                timeoutSeconds: max(timeoutSeconds, tuning.timeoutSeconds),
                hasVisibleOutput: {
                    lock.lock()
                    defer { lock.unlock() }
                    return !latestVisiblePreview.isEmpty
                },
                secondsSinceLastVisibleOutput: {
                    lock.lock()
                    defer { lock.unlock() }
                    guard lastVisibleOutputActivityAt != .distantPast else { return .infinity }
                    return Date().timeIntervalSince(lastVisibleOutputActivityAt)
                }
            )

            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            lock.lock()
            if !completion.idleCompleted {
                stdoutBuffer.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
                stderrBuffer.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
            }
            if let decoded = String(data: stdoutBuffer, encoding: .utf8) {
                latestDecodedStdout = decoded
            }
            if let decoded = String(data: stderrBuffer, encoding: .utf8) {
                latestDecodedStderr = decoded
            }
            let stdout = latestDecodedStdout.isEmpty
                ? String(decoding: stdoutBuffer, as: UTF8.self)
                : latestDecodedStdout
            let stderr = latestDecodedStderr.isEmpty
                ? String(decoding: stderrBuffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                : latestDecodedStderr.trimmingCharacters(in: .whitespacesAndNewlines)
            lock.unlock()

            if completion.timedOut {
                let diagnostic = classifyRuntimeFailure(
                    stage: stage,
                    rawMessage: "ローカル実行が長引いたため停止しました。",
                    terminationStatus: nil,
                    runnerPath: runnerURL.path,
                    modelPath: modelPath
                )
                lastFailure = diagnostic
                recordRuntimeDebugSnapshot(
                    stage: stage,
                    engine: .bundledCLI,
                    runnerPath: runnerURL.path,
                    rawOutput: stdout.isEmpty ? nil : stdout,
                    errorMessage: diagnostic.detailedMessage
                )
                continue
            }

            if process.terminationStatus != 0 && !completion.idleCompleted {
                let message = stderr.isEmpty ? stdout : stderr
                let diagnostic = classifyRuntimeFailure(
                    stage: stage,
                    rawMessage: message.isEmpty ? "ローカル runtime が終了コード \(process.terminationStatus) で終了しました。" : message,
                    terminationStatus: process.terminationStatus,
                    runnerPath: runnerURL.path,
                    modelPath: modelPath
                )
                lastFailure = diagnostic
                recordRuntimeDebugSnapshot(
                    stage: stage,
                    engine: .bundledCLI,
                    runnerPath: runnerURL.path,
                    rawOutput: message,
                    errorMessage: diagnostic.detailedMessage
                )
                continue
            }

            let cleaned = cleanCLIOutput(stdout)
            guard cleaned.isEmpty == false else {
                let diagnostic = classifyRuntimeFailure(
                    stage: stage,
                    rawMessage: stderr.isEmpty ? "ローカル生成の結果が空でした。" : stderr,
                    terminationStatus: process.terminationStatus,
                    runnerPath: runnerURL.path,
                    modelPath: modelPath
                )
                lastFailure = diagnostic
                recordRuntimeDebugSnapshot(
                    stage: stage,
                    engine: .bundledCLI,
                    runnerPath: runnerURL.path,
                    rawOutput: stdout.isEmpty ? stderr : stdout,
                    errorMessage: diagnostic.detailedMessage
                )
                continue
            }

            recordRuntimeDebugSnapshot(
                stage: stage,
                engine: .bundledCLI,
                runnerPath: runnerURL.path,
                rawOutput: stdout,
                errorMessage: nil
            )
            emitStatus(
                .streaming,
                title: "本文を書き出し中",
                detail: "Gemma 4 の本文を受信しました。画面へ反映しています。",
                estimatedProgress: 92,
                runnerLabel: runnerLabel,
                warmState: initialWarmState,
                startedAt: startedAt,
                onUpdate: onUpdate
            )
            lastRuntimeDiagnostic = nil
            lastRuntimeError = nil
            return VIUKEmbeddedRuntimeResult(success: true, text: cleaned, errorMessage: nil)
        }
        let fallbackDiagnostic = lastFailure ?? classifyRuntimeFailure(
            stage: stage,
            rawMessage: "ローカル実行に失敗しました。",
            terminationStatus: nil,
            runnerPath: runnerCandidates.first?.path,
            modelPath: modelPath
        )
        lastRuntimeDiagnostic = fallbackDiagnostic
        lastRuntimeError = fallbackDiagnostic.detailedMessage
        recordRuntimeDebugSnapshot(
            stage: stage,
            engine: .bundledCLI,
            runnerPath: runnerCandidates.first?.path,
            rawOutput: nil,
            errorMessage: fallbackDiagnostic.detailedMessage
        )
        return VIUKEmbeddedRuntimeResult(success: false, text: nil, errorMessage: fallbackDiagnostic.detailedMessage)
    }

    private func runStructuredCLI(
        prompt: String,
        systemPrompt: String?,
        modelPath: String,
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        topK: Int,
        seed: UInt32,
        timeoutSeconds: Int,
        reasoningMode: ReasoningMode,
        enabledToolNames: [String],
        stage: LocalAssistantRuntimeDiagnostic.Stage,
        startedAt: Date,
        onUpdate: (@MainActor @Sendable (LocalAssistantStructuredTurnUpdate) -> Void)?
    ) -> StructuredTurnExecutionResult {
        let runnerCandidates = bundledCLICandidateURLs
        guard runnerCandidates.isEmpty == false else {
            let diagnostic = classifyRuntimeFailure(stage: stage, rawMessage: "ローカル runtime が見つかりません。", terminationStatus: nil)
            lastRuntimeDiagnostic = diagnostic
            lastRuntimeError = diagnostic.detailedMessage
            recordRuntimeDebugSnapshot(
                stage: stage,
                engine: .bundledCLI,
                runnerPath: nil,
                rawOutput: nil,
                errorMessage: diagnostic.detailedMessage
            )
            return StructuredTurnExecutionResult(
                turn: nil,
                rawOutput: nil,
                errorMessage: diagnostic.detailedMessage,
                terminationStatus: nil,
                runnerPath: nil
            )
        }

        let runtimePreset = runtimePreset(for: reasoningMode)
        let forceConservativeCPURuntime = shouldForceConservativeCPURuntime(forModelPath: modelPath)
        let disableNativeThinking = !shouldEnableNativeThinking(forModelPath: modelPath, reasoningMode: reasoningMode)
        let tuning = effectiveCLITuning(
            for: prompt,
            modelPath: modelPath,
            reasoningMode: reasoningMode,
            requestedMaxTokens: maxTokens,
            structured: true
        )
        let initialWarmState = warmState(for: .bundledCLI, modelPath: modelPath)
        let flashAttentionEnabled = forceConservativeCPURuntime ? false : runtimePreset.flashAttentionEnabled
        let gpuLayers = forceConservativeCPURuntime ? 0 : runtimePreset.gpuLayers
        let disableKVOffload = forceConservativeCPURuntime ? true : runtimePreset.disableKVOffload
        var baseArguments = [
            "--simple-io",
            "--log-disable",
            "--no-display-prompt",
            "--single-turn",
            "--model", modelPath,
            "--predict", String(max(tuning.maxTokens, reasoningMode == .fast ? 40 : 64)),
            "--ctx-size", String(tuning.contextSize),
            "--batch-size", String(tuning.batchSize),
            "--ubatch-size", String(tuning.microBatchSize),
            "--threads", String(runtimePreset.threadCount),
            "--threads-batch", String(runtimePreset.batchThreadCount),
            "--flash-attn", flashAttentionEnabled ? "on" : "off",
            "--temp", String(temperature),
            "--top-p", String(topP),
            "--top-k", String(topK),
            "--seed", String(seed)
        ]
        if shouldSkipChatParsing(forModelPath: modelPath) {
            baseArguments.append("--skip-chat-parsing")
        }
        if disableNativeThinking {
            baseArguments.append(contentsOf: [
                "--reasoning", "off",
                "--chat-template-kwargs", #"{"enable_thinking":false}"#
            ])
        } else {
            // Gemma 4 では `enable_thinking:true` を明示しないと
            // `<|think|>` トリガーがテンプレートに注入されず思考が空になる。
            baseArguments.append(contentsOf: [
                "--reasoning", "on",
                "--reasoning-format", "auto",
                "--reasoning-budget", String(reasoningBudget(for: reasoningMode)),
                "--chat-template-kwargs", #"{"enable_thinking":true}"#
            ])
        }
        if let systemPrompt, !systemPrompt.isEmpty {
            baseArguments.append(contentsOf: ["--system-prompt", systemPrompt])
        }
        baseArguments.append(contentsOf: ["--prompt", prompt])
        if forceConservativeCPURuntime {
            baseArguments.append(contentsOf: ["--device", "none"])
        } else if gpuLayers > 0 {
            baseArguments.append(contentsOf: ["--gpu-layers", String(gpuLayers)])
        }
        if disableKVOffload {
            baseArguments.append("--no-kv-offload")
        }

        var lastFailure: LocalAssistantRuntimeDiagnostic?
        for runnerURL in runnerCandidates {
            let runnerLabel = runtimeRunnerLabel(for: .bundledCLI, runnerPath: runnerURL.path)
            let process = Process()
            process.executableURL = runnerURL
            process.arguments = baseArguments

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            let terminationSemaphore = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in
                terminationSemaphore.signal()
            }

            let lock = NSLock()
            var stdoutBuffer = Data()
            var stderrBuffer = Data()
            var latestDecodedStdout = ""
            var latestDecodedStderr = ""
            var latestThinkingPreview = ""
            var latestVisiblePreview = ""
            var lastVisibleOutputActivityAt = Date.distantPast

            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                lock.lock()
                stdoutBuffer.append(data)
                if let decoded = String(data: stdoutBuffer, encoding: .utf8) {
                    latestDecodedStdout = decoded
                }
                let rawText = latestDecodedStdout.isEmpty
                    ? String(decoding: stdoutBuffer, as: UTF8.self)
                    : latestDecodedStdout
                // disableNativeThinking = true (Gemma 4) の場合は <think> タグが存在しないため
                // partialThinkingPreview のフォールバックが応答全文を thinking として返してしまう。
                // ネイティブ Thinking が無効なら常に空文字列を使い、<Thinking> ブロックを表示しない。
                let thinkingPreview = disableNativeThinking ? "" : self.partialThinkingPreview(from: rawText)
                let visiblePreview = self.partialVisiblePreview(from: rawText)
                let shouldPublishThinking = !thinkingPreview.isEmpty && thinkingPreview != latestThinkingPreview
                let shouldPublishVisible = !visiblePreview.isEmpty && visiblePreview != latestVisiblePreview
                if shouldPublishThinking {
                    latestThinkingPreview = thinkingPreview
                }
                if shouldPublishVisible {
                    latestVisiblePreview = visiblePreview
                    lastVisibleOutputActivityAt = Date()
                }
                lock.unlock()

                if let onUpdate {
                    if shouldPublishThinking {
                        self.emitStatus(
                            .thinking,
                            title: "推論方針を整理中",
                            detail: "Gemma 4 が tool 利用前後の方針を整理しています。",
                            estimatedProgress: 70,
                            runnerLabel: runnerLabel,
                            warmState: initialWarmState,
                            startedAt: startedAt,
                            onUpdate: onUpdate
                        )
                        Task { @MainActor in onUpdate(.thinkingPreview(thinkingPreview)) }
                    }
                    if shouldPublishVisible {
                        self.emitStatus(
                            .streaming,
                            title: "本文を書き出し中",
                            detail: "Gemma 4 の本文を受信しました。画面へ反映しています。",
                            estimatedProgress: 92,
                            runnerLabel: runnerLabel,
                            warmState: initialWarmState,
                            startedAt: startedAt,
                            onUpdate: onUpdate
                        )
                        Task { @MainActor in onUpdate(.visiblePreview(visiblePreview)) }
                    }
                }
            }
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                lock.lock()
                stderrBuffer.append(data)
                if let decoded = String(data: stderrBuffer, encoding: .utf8) {
                    latestDecodedStderr = decoded
                }
                lock.unlock()
            }

            do {
                try process.run()
                emitStatus(
                    .loadingModel,
                    title: "Gemma 4 をロード中",
                    detail: tuning.loadingPreview ?? loadingStatusDetail(modelPath: modelPath, warmState: initialWarmState, structured: true),
                    estimatedProgress: 48,
                    runnerLabel: runnerLabel,
                    warmState: initialWarmState,
                    startedAt: startedAt,
                    onUpdate: onUpdate
                )
                emitStatus(
                    disableNativeThinking ? .generating : .thinking,
                    title: disableNativeThinking ? "本文を生成中" : "推論を整理中",
                    detail: disableNativeThinking
                        ? "Gemma 4 が回答を生成しています。"
                        : (reasoningMode == .fast
                            ? "Gemma 4 が最終本文を組み立てています。"
                            : "Gemma 4 が tool 結果と reasoning を推論として整理しています。"),
                    estimatedProgress: reasoningMode == .fast ? 84 : 70,
                    runnerLabel: runnerLabel,
                    warmState: initialWarmState,
                    startedAt: startedAt,
                    onUpdate: onUpdate
                )
            } catch {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                let diagnostic = classifyRuntimeFailure(
                    stage: stage,
                    rawMessage: "ローカル runtime の起動に失敗しました: \(error.localizedDescription)",
                    terminationStatus: nil,
                    runnerPath: runnerURL.path,
                    modelPath: modelPath
                )
                lastFailure = diagnostic
                recordRuntimeDebugSnapshot(
                    stage: stage,
                    engine: .bundledCLI,
                    runnerPath: runnerURL.path,
                    rawOutput: nil,
                    errorMessage: diagnostic.detailedMessage
                )
                continue
            }

            let completion = waitForCLIProcessToSettle(
                process,
                terminationSemaphore: terminationSemaphore,
                timeoutSeconds: max(timeoutSeconds, tuning.timeoutSeconds),
                hasVisibleOutput: {
                    lock.lock()
                    defer { lock.unlock() }
                    return !latestVisiblePreview.isEmpty
                },
                secondsSinceLastVisibleOutput: {
                    lock.lock()
                    defer { lock.unlock() }
                    guard lastVisibleOutputActivityAt != .distantPast else { return .infinity }
                    return Date().timeIntervalSince(lastVisibleOutputActivityAt)
                }
            )

            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            lock.lock()
            if !completion.idleCompleted {
                stdoutBuffer.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
                stderrBuffer.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
            }
            if let decoded = String(data: stdoutBuffer, encoding: .utf8) {
                latestDecodedStdout = decoded
            }
            if let decoded = String(data: stderrBuffer, encoding: .utf8) {
                latestDecodedStderr = decoded
            }
            let stdout = latestDecodedStdout.isEmpty
                ? String(decoding: stdoutBuffer, as: UTF8.self)
                : latestDecodedStdout
            let stderr = latestDecodedStderr.isEmpty
                ? String(decoding: stderrBuffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                : latestDecodedStderr.trimmingCharacters(in: .whitespacesAndNewlines)
            lock.unlock()

            if completion.timedOut {
                let diagnostic = classifyRuntimeFailure(
                    stage: stage,
                    rawMessage: "ローカル実行が長引いたため停止しました。",
                    terminationStatus: nil,
                    runnerPath: runnerURL.path,
                    modelPath: modelPath
                )
                lastFailure = diagnostic
                recordRuntimeDebugSnapshot(
                    stage: stage,
                    engine: .bundledCLI,
                    runnerPath: runnerURL.path,
                    rawOutput: stdout.isEmpty ? nil : stdout,
                    errorMessage: diagnostic.detailedMessage
                )
                continue
            }

            if process.terminationStatus != 0 && !completion.idleCompleted {
                let message = stderr.isEmpty ? stdout : stderr
                let diagnostic = classifyRuntimeFailure(
                    stage: stage,
                    rawMessage: message.isEmpty ? "ローカル runtime が終了コード \(process.terminationStatus) で終了しました。" : message,
                    terminationStatus: process.terminationStatus,
                    runnerPath: runnerURL.path,
                    modelPath: modelPath
                )
                lastFailure = diagnostic
                recordRuntimeDebugSnapshot(
                    stage: stage,
                    engine: .bundledCLI,
                    runnerPath: runnerURL.path,
                    rawOutput: message,
                    errorMessage: diagnostic.detailedMessage
                )
                continue
            }

            let cleaned = cleanStructuredCLIOutput(stdout)
            let turn = parseStructuredTurnOutput(cleaned, enabledToolNames: enabledToolNames)
            if !isAcceptableStructuredTurn(turn) {
                let diagnostic = classifyRuntimeFailure(
                    stage: stage,
                    rawMessage: stderr.isEmpty ? "Gemma 4 の structured turn 本文が空または破損していました。" : stderr,
                    terminationStatus: process.terminationStatus,
                    runnerPath: runnerURL.path,
                    modelPath: modelPath
                )
                lastFailure = diagnostic
                recordRuntimeDebugSnapshot(
                    stage: stage,
                    engine: .bundledCLI,
                    runnerPath: runnerURL.path,
                    rawOutput: stdout,
                    errorMessage: diagnostic.detailedMessage
                )
                continue
            }

            recordRuntimeDebugSnapshot(
                stage: stage,
                engine: .bundledCLI,
                runnerPath: runnerURL.path,
                rawOutput: stdout,
                errorMessage: nil
            )
            emitStatus(
                .streaming,
                title: "本文を書き出し中",
                detail: "Gemma 4 の本文を受信しました。画面へ反映しています。",
                estimatedProgress: 92,
                runnerLabel: runnerLabel,
                warmState: initialWarmState,
                startedAt: startedAt,
                onUpdate: onUpdate
            )
            lastRuntimeDiagnostic = nil
            lastRuntimeError = nil
            return StructuredTurnExecutionResult(
                turn: turn,
                rawOutput: cleaned,
                errorMessage: nil,
                terminationStatus: process.terminationStatus,
                runnerPath: runnerURL.path
            )
        }

        let fallbackDiagnostic = lastFailure ?? classifyRuntimeFailure(
            stage: stage,
            rawMessage: "ローカル実行に失敗しました。",
            terminationStatus: nil,
            runnerPath: runnerCandidates.first?.path,
            modelPath: modelPath
        )
        lastRuntimeDiagnostic = fallbackDiagnostic
        lastRuntimeError = fallbackDiagnostic.detailedMessage
        recordRuntimeDebugSnapshot(
            stage: stage,
            engine: .bundledCLI,
            runnerPath: runnerCandidates.first?.path,
            rawOutput: nil,
            errorMessage: fallbackDiagnostic.detailedMessage
        )
        return StructuredTurnExecutionResult(
            turn: nil,
            rawOutput: nil,
            errorMessage: fallbackDiagnostic.detailedMessage,
            terminationStatus: fallbackDiagnostic.terminationStatus,
            runnerPath: fallbackDiagnostic.runnerPath
        )
    }

    private func waitForCLIProcessToSettle(
        _ process: Process,
        terminationSemaphore: DispatchSemaphore,
        timeoutSeconds: Int,
        hasVisibleOutput: @escaping () -> Bool,
        secondsSinceLastVisibleOutput: @escaping () -> TimeInterval
    ) -> (timedOut: Bool, idleCompleted: Bool) {
        let hardDeadline = Date().addingTimeInterval(TimeInterval(max(timeoutSeconds, 1)))

        func forceStop(_ process: Process) {
            guard process.isRunning else { return }
            process.terminate()
            if terminationSemaphore.wait(timeout: .now() + .milliseconds(700)) == .success || !process.isRunning {
                return
            }

            process.interrupt()
            if terminationSemaphore.wait(timeout: .now() + .milliseconds(700)) == .success || !process.isRunning {
                return
            }

            kill(process.processIdentifier, SIGKILL)
            _ = terminationSemaphore.wait(timeout: .now() + .seconds(1))
        }

        while process.isRunning {
            if terminationSemaphore.wait(timeout: .now() + .milliseconds(200)) == .success {
                return (false, false)
            }

            if hasVisibleOutput(), secondsSinceLastVisibleOutput() >= 4.0 {
                forceStop(process)
                return (false, true)
            }

            if Date() >= hardDeadline {
                forceStop(process)
                return (true, false)
            }
        }

        return (false, false)
    }

    private func cleanCLIOutput(_ rawText: String) -> String {
        var filteredLines: [String] = []
        var skippingPromptEcho = false
        for line in rawText.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.hasPrefix("> ") {
                skippingPromptEcho = true
                continue
            }
            if skippingPromptEcho {
                if trimmed.isEmpty {
                    skippingPromptEcho = false
                }
                continue
            }

            if trimmed == "Loading model..." ||
                trimmed.hasPrefix("build      :") ||
                trimmed.hasPrefix("model      :") ||
                trimmed.hasPrefix("modalities :") ||
                trimmed == "using custom system prompt" ||
                trimmed == "available commands:" ||
                trimmed.hasPrefix("/exit ") ||
                trimmed.hasPrefix("/regen") ||
                trimmed.hasPrefix("/clear") ||
                trimmed.hasPrefix("/read ") ||
                trimmed.hasPrefix("/glob ") ||
                trimmed.hasPrefix("[ Prompt:") ||
                trimmed == "Exiting..." ||
                trimmed.hasPrefix("warning:") ||
                trimmed.allSatisfy({ $0 == "▄" || $0 == "█" || $0 == "▀" || $0 == " " }) {
                continue
            }

            filteredLines.append(line)
        }

        var cleaned = filteredLines
            .joined(separator: "\n")
            .replacingOccurrences(of: "<end_of_turn>", with: "")
            .replacingOccurrences(of: "<start_of_turn>model", with: "")
            .replacingOccurrences(of: "<start_of_turn>assistant", with: "")
            .replacingOccurrences(of: "<start_of_turn>user", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        cleaned = stripANSIEscapeSequences(from: stripSpecialTokenFragments(from: cleaned))

        // <think>...</think> / <reasoning>...</reasoning> / <reflect>...</reflect> ブロックを除去。
        // case-insensitive 対応で <THINK>, <Think> 等の変種も削除。
        // 旧実装は <think> 以降を全削除していたが、</think> 後ろに本回答が続く場合に
        // 本回答まで失われていた問題を修正済み。
        cleaned = removeReasoningMarkupForCleaning(cleaned)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned
    }

    private func removeReasoningMarkupForCleaning(_ text: String) -> String {
        var cleaned = text
        let tagNames = ["think", "reasoning", "reflect", "thought"]
        for tag in tagNames {
            let pairedPattern = "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)\\s*>"
            cleaned = cleaned.replacingOccurrences(
                of: pairedPattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            let openOnlyPattern = "<\(tag)\\b[^>]*>"
            if let openRange = cleaned.range(
                of: openOnlyPattern,
                options: [.regularExpression, .caseInsensitive]
            ) {
                cleaned = String(cleaned[..<openRange.lowerBound])
            }
        }
        return cleaned
    }

    private func recordRuntimeDebugSnapshot(
        stage: LocalAssistantRuntimeDiagnostic.Stage,
        engine: RuntimeEngine,
        runnerPath: String?,
        rawOutput: String?,
        errorMessage: String?
    ) {
        lastRuntimeStage = stage
        lastRuntimeRunnerLabel = runtimeRunnerLabel(for: engine, runnerPath: runnerPath)
        lastRuntimeRawOutputPreview = compactRuntimeDebugText(rawOutput)
        if let errorMessage, !errorMessage.isEmpty {
            lastRuntimeError = errorMessage
        }
    }

    private func runtimeRunnerLabel(for engine: RuntimeEngine, runnerPath: String?) -> String {
        switch engine {
        case .embedded:
            return "embedded"
        case .bundledServer:
            return runnerPath.map { "llama-server (\(URL(fileURLWithPath: $0).lastPathComponent))" } ?? "llama-server"
        case .bundledCLI:
            return runnerPath.map { "llama-cli (\(URL(fileURLWithPath: $0).lastPathComponent))" } ?? "llama-cli"
        case .liteRTLM:
            return "LiteRT-LM"
        case .unavailable:
            return "unavailable"
        }
    }

    private func compactRuntimeDebugText(_ text: String?, limit: Int = 1800) -> String? {
        guard let text else { return nil }
        let compact = text
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return nil }
        if compact.count <= limit {
            return compact
        }
        return String(compact.prefix(limit)) + "..."
    }

    private func cleanStructuredCLIOutput(_ rawText: String) -> String {
        var filteredLines: [String] = []
        var skippingPromptEcho = false
        var skippingThinkingBlock = false
        for line in rawText.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.hasPrefix("> ") {
                skippingPromptEcho = true
                continue
            }
            if skippingPromptEcho {
                if trimmed.isEmpty {
                    skippingPromptEcho = false
                }
                continue
            }

            if trimmed == "[Start thinking]" {
                skippingThinkingBlock = true
                continue
            }
            if skippingThinkingBlock {
                if trimmed == "[End thinking]" {
                    skippingThinkingBlock = false
                }
                continue
            }

            if trimmed == "Loading model..." ||
                trimmed.hasPrefix("build      :") ||
                trimmed.hasPrefix("model      :") ||
                trimmed.hasPrefix("modalities :") ||
                trimmed == "using custom system prompt" ||
                trimmed == "available commands:" ||
                trimmed.hasPrefix("/exit ") ||
                trimmed.hasPrefix("/regen") ||
                trimmed.hasPrefix("/clear") ||
                trimmed.hasPrefix("/read ") ||
                trimmed.hasPrefix("/glob ") ||
                trimmed == "Exiting..." ||
                trimmed.hasPrefix("warning:") ||
                trimmed.allSatisfy({ $0 == "▄" || $0 == "█" || $0 == "▀" || $0 == " " }) {
                continue
            }

            filteredLines.append(line)
        }

        return stripANSIEscapeSequences(from: stripSpecialTokenFragments(from: filteredLines
            .joined(separator: "\n")
            .replacingOccurrences(of: "<end_of_turn>", with: "")
            .replacingOccurrences(of: "<start_of_turn>model", with: "")
            .replacingOccurrences(of: "<start_of_turn>assistant", with: "")
            .replacingOccurrences(of: "<start_of_turn>user", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private func stripSpecialTokenFragments(from text: String) -> String {
        var cleaned = text
        // モデル系統ごとの特殊トークンを除去する。
        // Gemma 4 / 軽量モデル混在環境で稀にテンプレートの一部が出力に漏れるケースを救済。
        let patterns = [
            // ChatML / generic angle-pipe トークン: <|im_start|>, <|im_end|>, <|user|>, <|assistant|>, <|system|>
            #"<\|[^\n]*?(?:\|>|$)"#,
            // ストレイ |> マーカー（行頭のみ、本文中の比較記号は除外）
            #"(?m)^\s*\|>\s*$"#,
            // Llama 系インストラクションタグ
            #"\[/?INST\]"#,
            #"<<\s*/?\s*SYS\s*>>"#,
            // 汎用特殊トークン
            #"<(?:bos|eos|unk|pad|sep|cls|mask|turn_start|turn_end|start_of_text|end_of_text|begin_of_text|end_of_message)>"#,
            // BOS/EOS の <s> / </s>
            #"</?s>"#
        ]

        for pattern in patterns {
            cleaned = cleaned.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripANSIEscapeSequences(from text: String) -> String {
        text
            .replacingOccurrences(
                of: #"\u{001B}\[[0-9;?]*[ -/]*[@-~]"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?<![0-9A-Za-z])\[[0-9;]{1,12}[A-Za-z](?![0-9A-Za-z])"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func containsSpecialTokenLeakFragment(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        return trimmed == "<|" ||
            trimmed == "|>" ||
            trimmed.hasPrefix("<|") ||
            trimmed.contains("<start_of_turn>") ||
            trimmed.contains("<end_of_turn>")
    }

    private func isAcceptableStructuredTurn(_ turn: LocalAssistantStructuredTurn) -> Bool {
        if !turn.toolCalls.isEmpty {
            return true
        }

        let trimmed = turn.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !containsSpecialTokenLeakFragment(trimmed) else { return false }

        let normalized = trimmed.lowercased()
        if normalized.hasPrefix("{\"functioncall\"") ||
            normalized.hasPrefix("{\"functioncalls\"") ||
            normalized.hasPrefix("[{\"name\"") ||
            normalized.contains("<tool_call") {
            return false
        }

        return true
    }

    private func classifyRuntimeFailure(
        stage: LocalAssistantRuntimeDiagnostic.Stage,
        rawMessage: String?,
        terminationStatus: Int32?,
        runnerPath: String? = nil,
        modelPath: String? = nil
    ) -> LocalAssistantRuntimeDiagnostic {
        let trimmed = rawMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if trimmed.contains("ローカル runtime が見つかりません") {
            return LocalAssistantRuntimeDiagnostic(
                stage: stage,
                kind: .runnerUnavailable,
                summary: "ローカル runtime が見つかりません。",
                detail: trimmed,
                terminationStatus: terminationStatus,
                runnerPath: runnerPath,
                modelPath: modelPath
            )
        }

        if trimmed.contains("Failed to load the model") || trimmed.contains("failed to load model") {
            return LocalAssistantRuntimeDiagnostic(
                stage: stage,
                kind: .modelLoadFailed,
                summary: "Gemma 4 モデルを読み込めませんでした。",
                detail: trimmed,
                terminationStatus: terminationStatus,
                runnerPath: runnerPath,
                modelPath: modelPath
            )
        }

        if trimmed.localizedCaseInsensitiveContains("unknown model architecture") &&
            trimmed.localizedCaseInsensitiveContains("gemma4") {
            return LocalAssistantRuntimeDiagnostic(
                stage: stage,
                kind: .modelLoadFailed,
                summary: "この runtime は Gemma 4 アーキテクチャをまだ認識できません。モデル破損ではなく、runtime 側の互換性不足の可能性が高いです。",
                detail: trimmed,
                terminationStatus: terminationStatus,
                runnerPath: runnerPath,
                modelPath: modelPath
            )
        }

        if trimmed.localizedCaseInsensitiveContains("no space left on device") ||
            trimmed.localizedCaseInsensitiveContains("not enough free space") {
            return LocalAssistantRuntimeDiagnostic(
                stage: stage,
                kind: .runnerStartupFailed,
                summary: "この端末の空き容量が不足しており、ローカル Gemma 実行が不安定です。",
                detail: trimmed,
                terminationStatus: terminationStatus,
                runnerPath: runnerPath,
                modelPath: modelPath
            )
        }

        if trimmed.localizedCaseInsensitiveContains("failed to create command queue") ||
            trimmed.localizedCaseInsensitiveContains("failed to initialize  backend") ||
            trimmed.localizedCaseInsensitiveContains("failed to initialize backend") {
            return LocalAssistantRuntimeDiagnostic(
                stage: stage,
                kind: .runnerStartupFailed,
                summary: "Metal backend の初期化に失敗しました。Gemma 4 はいま CPU 保守設定で再実行する必要があります。",
                detail: trimmed,
                terminationStatus: terminationStatus,
                runnerPath: runnerPath,
                modelPath: modelPath
            )
        }

        if trimmed.contains("起動に失敗") {
            return LocalAssistantRuntimeDiagnostic(
                stage: stage,
                kind: .runnerStartupFailed,
                summary: "ローカル runtime の起動に失敗しました。",
                detail: trimmed,
                terminationStatus: terminationStatus,
                runnerPath: runnerPath,
                modelPath: modelPath
            )
        }

        if trimmed.contains("長引いたため停止") {
            return LocalAssistantRuntimeDiagnostic(
                stage: stage,
                kind: .timeout,
                summary: "ローカル実行が長引いたため停止しました。",
                detail: trimmed,
                terminationStatus: terminationStatus,
                runnerPath: runnerPath,
                modelPath: modelPath
            )
        }

        if trimmed.contains("結果が空") {
            return LocalAssistantRuntimeDiagnostic(
                stage: stage,
                kind: .emptyOutput,
                summary: "ローカル生成の結果が空でした。",
                detail: trimmed,
                terminationStatus: terminationStatus,
                runnerPath: runnerPath,
                modelPath: modelPath
            )
        }

        if trimmed.contains("native thinking を確認できませんでした") {
            return LocalAssistantRuntimeDiagnostic(
                stage: stage,
                kind: .thinkingUnsupported,
                summary: "Gemma 4 の native thinking を確認できませんでした。",
                detail: trimmed,
                terminationStatus: terminationStatus,
                runnerPath: runnerPath,
                modelPath: modelPath
            )
        }

        if trimmed.contains("native tool calling を確認できませんでした") ||
            trimmed.contains("structured turn を解釈できませんでした") {
            return LocalAssistantRuntimeDiagnostic(
                stage: stage,
                kind: .toolCallingUnsupported,
                summary: "Gemma 4 の native tool calling を確認できませんでした。",
                detail: trimmed,
                terminationStatus: terminationStatus,
                runnerPath: runnerPath,
                modelPath: modelPath
            )
        }

        let defaultSummary: String
        let kind: LocalAssistantRuntimeFailureKind
        switch stage {
        case .selfCheck:
            defaultSummary = "ローカル実行の初期確認に失敗しました。"
            kind = .selfCheckFailed
        case .generation:
            defaultSummary = "ローカル実行に失敗しました。"
            kind = .generationFailed
        case .supportBrief:
            defaultSummary = "ローカル整理に失敗しました。"
            kind = .supportBriefFailed
        }

        return LocalAssistantRuntimeDiagnostic(
            stage: stage,
            kind: kind,
            summary: defaultSummary,
            detail: trimmed.isEmpty ? nil : trimmed,
            terminationStatus: terminationStatus,
            runnerPath: runnerPath,
            modelPath: modelPath
        )
    }

    private func runtimeConversationPrompt(for prompt: String, contextPrompt: String?) -> String {
        let raw = (contextPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? (contextPrompt ?? prompt)
            : prompt
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 6_400 else { return trimmed }
        let suffix = trimmed.suffix(6_400)
        return "直近の会話コンテキスト:\n\(suffix)"
    }

    private func buildRuntimePrompt(
        conversationPrompt: String,
        systemPrompt: String,
        appendGemmaThinkingTrigger: Bool = false
    ) -> String {
        let modelTurn = appendGemmaThinkingTrigger
            ? "<start_of_turn>model\n<|think|>\n"
            : "<start_of_turn>model\n"
        return """
        <start_of_turn>system
        \(systemPrompt)
        <end_of_turn>
        <start_of_turn>user
        \(conversationPrompt)
        <end_of_turn>
        \(modelTurn)
        """
    }

    private func buildSupportBriefPrompt(question: String, searchSummary: String) -> String {
        let userPrompt = buildSupportBriefUserPrompt(question: question, searchSummary: searchSummary)

        return """
        <start_of_turn>system
        \(supportBriefSystemPrompt)
        <end_of_turn>
        <start_of_turn>user
        \(userPrompt)
        <end_of_turn>
        <start_of_turn>model
        """
    }

    private func buildSupportBriefUserPrompt(question: String, searchSummary: String) -> String {
        let trimmedSearch = searchSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let compactSearch = trimmedSearch.isEmpty ? "検索結果なし" : String(trimmedSearch.prefix(1200))

        return """
        原質問:
        \(question)

        検索補足:
        \(compactSearch)

        上の内容を、補助モデルに渡すための要点だけに整理してください。
        """
    }

    private var supportBriefSystemPrompt: String {
        """
        あなたは VIUK AI tiny の内部整理役です。
        実モデルは \(LocalAssistantModelProfile.internalModelName) です。
        目的は、補助モデルへ渡す前に質問を短く安全に整理することです。
        出力は必ず日本語で、3〜6個の箇条書きだけにしてください。
        前置き、結論、挨拶、補足説明は不要です。
        ユーザーの強い表現や不要な文言をそのまま繰り返さず、論点・目的・不足情報だけを残してください。
        Markdown や JSON は使わず、各行を「- 」で始めてください。
        """
    }

    private func runtimeSystemPrompt(
        coachMode: AICoachService.CoachMode,
        researchMode: ResearchMode,
        reasoningMode: ReasoningMode,
        childAge: Int,
        pageInfo: AICoachService.PageInfo?,
        safetySnapshot: AICoachService.SafetySnapshot?,
        advancedSettings: GemmaAdvancedSettings
    ) -> String {
        // 恋愛モードは AI Studio の汎用アシスタントとは振る舞いが大きく異なるので、
        // 通常の指示文を組み立てずにKizuna専用プロンプトを返す。
        if reasoningMode == .persona {
            return buildPersonaSystemPrompt(
                advancedSettings: advancedSettings
            )
        }
        // Fast モードでは Sonar 風の短く・速い応答を最優先する。
        // それ以外のモードは従来どおり「短すぎる返答禁止」を維持して説明性を確保する。
        var lines: [String] = [
            "あなたは VIUK AI Studio のアシスタントです。"
        ]
        if reasoningMode.isFastLike {
            lines.append("出力は日本語で、結論先行・短文・実用的に返してください。冗長な前置きは避けてください。")
        } else {
            lines.append("出力は日本語で、必要十分に具体的かつ実用的に返してください。短すぎる返答で終わらせないでください。")
            // 思考モード: 内部推論 (`<|channel>thought`) も日本語で書いてください。
            // 既定だと英語の汎用 preamble ("To construct the desired response: 1. Analyze the ...")
            // から始まり、表示が「テンプレート的」に見える。日本語で具体的な検討を書くよう促す。
            lines.append("内部推論 (thinking) も日本語で書いてください。最初の1行から今回の質問固有の短文にしてください。例:「質問はGemma 4の概要確認。公開元、特徴、利用条件を整理する。」のように具体化し、英語の前置き、箇条書きテンプレ、To construct the desired response、Analyze the user、1. Analyze は絶対に書かないでください。")
        }
        lines.append("必要な時だけ関数を呼び出し、それ以外では自然な日本語の最終回答だけを返してください。")
        if reasoningMode.isFastLike {
            lines.append("最終回答は最初に1文で結論を述べ、必要なら短い補足を1〜2文だけ添えてください。長い段落は禁止です。")
        } else {
            lines.append("最終回答は、最初に短い結論を示し、そのあとに本文を続けてください。1つの長い段落にしないでください。")
            lines.append("説明が長くなる時は2〜4文ごとに改行し、必要なら箇条書きを使ってください。")
        }
        lines.append("『概要』『要点』『補足』『説明』のようなラベルだけを単独で置かないでください。")

        lines.append(contentsOf: commonLocalAnswerFormattingInstructionLines(reasoningMode: reasoningMode, researchMode: researchMode))
        lines.append(contentsOf: advancedSettings.normalized().safetyInstructionLines())
        if researchMode == .deep && reasoningMode != .fast {
            lines.append("Deep Research 中です。結論だけで終わらせず、根拠・比較・注意点まで整理してください。")
        } else if researchMode == .deep {
            // Fast + Deep: Sonar 同等の引用付き短答に振り切る
            lines.append("Deep Research を有効にしていますが Fast 速度を優先します。結論を最初に1文、根拠と注意点をそれぞれ最大1文で添えてください。")
        }

        switch coachMode {
        case .studio:
            lines.append("AI Studio の会話アシスタントとして、要約・整理・比較・次の行動の提案を行ってください。")
        case .child:
            lines.append("対象年齢は \(childAge) 歳前後です。やさしく安全寄りに答えてください。")
            if let pageInfo {
                let pageLabel = pageInfo.title.isEmpty ? pageInfo.url : pageInfo.title
                lines.append("現在見ているページ: \(pageLabel)")
            }
            if let safetySnapshot {
                lines.append("安全メモ: \(safetySnapshot.level) / \(safetySnapshot.summary)")
            }
        case .guardian:
            lines.append("保護者向けとして、落ち着いて実務的に答えてください。")
            if let pageInfo {
                let pageLabel = pageInfo.title.isEmpty ? pageInfo.url : pageInfo.title
                lines.append("現在見ているページ: \(pageLabel)")
            }
            if let safetySnapshot {
                lines.append("安全メモ: \(safetySnapshot.level) / \(safetySnapshot.summary)")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// 絆モード専用の system prompt。キャラに完全に成りきり、短い LINE メッセージで返す。
    /// 設計方針:
    ///   - **短く・直接的**。長い禁止リストを書くと Gemma 4 が「計画モード」に入って <channel|> リークを起こす。
    ///   - **例示で示す**。OK/NG の具体例を入れて、平叙文の指示に頼らない。
    ///   - **末尾でキャラを Prime する**。assistant turn の冒頭で「[キャラ名]:」が来るような流れを用意。
    /// キャラ設定 (名前・性格・口調・関係性) は `PersonaSettings.shared.active` から
    /// `LocalAssistantRuntimeBridge.personaAddendum` 経由で注入される。
    private func buildPersonaSystemPrompt(advancedSettings: GemmaAdvancedSettings) -> String {
        let persona = LocalAssistantRuntimeBridge.personaAddendum
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = extractPersonaDisplayName(from: persona) ?? "絆"
        let character = CharacterProfile(
            name: displayName,
            displayName: displayName,
            shortDescription: "やさしい話し相手。短く自然に返す。",
            category: .originalFreeform,
            relationshipGenre: .none,
            personality: persona.isEmpty ? "やさしく自然に寄り添う。" : persona,
            speakingStyle: "LINE で送るように短く、自然な一人称で返す。",
            relationshipToUser: "相手と近い距離で会話する。",
            scenario: "LINE で会話中",
            rules: [
                "最初の1文字目から、相手に話しかける一人称の本文を始める。",
                "前置き、ナレーション、自分の状況説明、考察、(案)、選択肢の列挙、Markdown、見出し、コードブロック、引用符、特殊タグは禁止。",
                "1〜2 文、長くて 3 文まで。改行は 0〜1 個まで。絵文字は 0〜1 個まで、口調に合うときだけ。"
            ],
            safetyRules: [
                "性的露骨、暴力煽動、自傷助長、違法加担、医療法律の確定診断は禁止。話題が来たらキャラのまま自然に逸らすか、心配の言葉に切り替える。"
            ]
        )
        let memories = Self.kizunaActiveMemories.prefix(5).map {
            CharacterMemory(
                characterId: character.id,
                text: $0,
                category: .userFact,
                importance: 0.7,
                source: .system
            )
        }
        let safety = advancedSettings.normalized().safetyInstructionLines().joined(separator: " ")
        let decision = SafetyDecision(
            action: .allow,
            addedPromptRules: safety.isEmpty ? [] : [safety]
        )
        return PromptBuilder().build(
            character: character,
            lorebook: nil,
            selectedMemories: Array(memories),
            recentMessages: [],
            userInput: "",
            safetyDecision: decision
        )
    }

    private func extractPersonaDisplayName(from text: String) -> String? {
        guard let open = text.range(of: "「") else { return nil }
        let afterOpen = text[open.upperBound...]
        guard let close = afterOpen.range(of: "」") else { return nil }
        let name = String(afterOpen[..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// 絆モードで使う追記。`PersonaSettings` が UserDefaults 永続化に合わせて上書きする。
    /// nonisolated にしておき、prompt 構築時にだけ参照する。
    nonisolated(unsafe) static var personaAddendum: String = ""
    /// 絆モードで旧 system prompt 経路を通る時に追加注入する短期メモリー。
    nonisolated(unsafe) static var kizunaActiveMemories: [String] = []

    private func commonLocalAnswerFormattingInstructionLines(
        reasoningMode: ReasoningMode,
        researchMode: ResearchMode
    ) -> [String] {
        var lines: [String] = [
            "Markdown は必要な時だけ使ってください。強調は `**太字**`、箇条書きは `- ` を優先してください。",
            "見出しは必要な時だけ使い、ラベルだけの短文にはしないでください。",
            "thinking、内部計画、内部メモ、推論過程は最終回答本文に書かないでください。本文にはユーザー向けの完成した回答だけを書いてください。"
        ]
        switch (reasoningMode, researchMode) {
        case (.fast, .off), (.persona, _):
            // Sonar 体感: 結論先行 + 補足 1〜2 文 (恋愛モードもここに合流)
            lines.append("Fast モードです。3〜5 文以内、結論先行で返してください。前置きや言い換えは禁止です。")
        case (.fast, _):
            // 検索結果がある場合も短文化を強制。引用 [N] は許容
            lines.append("Fast モードです。3〜5 文以内、結論先行。背景は最大 1 文。検索結果からの引用は [1] [2] 形式で本文中に置いてください。")
        case (.thinking, .off):
            lines.append("Thinking モードです。結論のあとに理由と補足を短い段落で続けてください。")
        case (.thinking, _):
            lines.append("Thinking + 検索モードです。検索結果が渡された説明系の質問では、短い要約で終わらせず、1000〜1600字程度を目安に、結論・背景/根拠・主な特徴・比較/位置づけ・注意点を整理してください。")
        case (.deepThinking, .off):
            lines.append("高精度モードです。結論、根拠、注意点を順に整理してください。")
        case (.deepThinking, _):
            lines.append("高精度 + 検索モードです。検索結果が渡された説明系の質問では、1500〜2400字程度を目安に、結論・根拠・比較/背景・注意点・次の一手まで整理してください。")
        }
        if researchMode == .deep && reasoningMode != .fast {
            // Fast + Deep の場合は短文化を優先するため Deep の追記は付けない
            lines.append("Deep Research では、短い要約だけで止めず、根拠と背景まで含めてください。")
        }
        return lines
    }

    private func structuredTurnSystemPrompt(
        coachMode: AICoachService.CoachMode,
        reasoningMode: ReasoningMode,
        researchMode: ResearchMode,
        childAge: Int,
        pageInfo: AICoachService.PageInfo?,
        safetySnapshot: AICoachService.SafetySnapshot?,
        advancedSettings: GemmaAdvancedSettings
    ) -> String {
        let enabledToolNames = advancedSettings.allowToolUsage
            ? AIToolCatalog.toolNames.filter { advancedSettings.isToolEnabled($0) }
            : []
        let finalSynthesisOnly = researchMode == .deep && enabledToolNames.isEmpty
        if coachMode == .studio {
            let reasoningGuidance: String
            switch (reasoningMode, researchMode) {
            case (.fast, .deep):
                reasoningGuidance = finalSynthesisOnly
                    ? "Deep Research の検索フェーズは完了済みです。追加関数を使わず、渡された検索結果と補助メモを最終 answer に統合してください。"
                    : "素早く判断しつつ、最終 answer は短すぎない見出し構成にしてください。要約だけで切り上げず、根拠と注意点まで入れてください。"
            case (.fast, _), (.persona, _):
                reasoningGuidance = "素早く判断しつつも、1〜2文だけで打ち切らず、必要十分に答えてください。"
            case (.thinking, .deep):
                reasoningGuidance = finalSynthesisOnly
                    ? "標準の reasoning で、追加関数を使わず Deep Research の最終 answer を統合してください。根拠・比較・背景も整理してください。"
                    : "標準の reasoning を使い、Deep Research の検索フェーズでは不足観点を見つけたら複数の tool call を優先してください。十分なソースがある時だけ最終 answer に進んでください。"
            case (.thinking, _):
                reasoningGuidance = "標準の reasoning を使い、必要な時だけ関数を呼び出してください。検索結果が渡された説明系の質問では、短い要約で終わらせず、1000〜1600字程度の本文にしてください。"
            case (.deepThinking, .deep):
                reasoningGuidance = finalSynthesisOnly
                    ? "丁寧に reasoning し、追加検索や関数は使わず、収集済みソースだけで Deep Research の最終 answer を統合してください。概要・根拠・比較・注意点を意識してください。"
                    : "丁寧に reasoning し、Deep Research の検索フェーズでは不足観点を見つけたら複数の tool call を優先してください。十分なソースがある時だけ最終 answer に進んでください。"
            case (.deepThinking, _):
                reasoningGuidance = "丁寧に reasoning し、必要なら検索や関数を使ってください。検索結果が渡された説明系の質問では、1500〜2400字程度の本文にし、比較・背景・注意点まで含めてください。"
            }

            var sections = [
                "日本語で答えてください。",
                "短すぎる答えは避け、必要十分な情報量を入れてください。",
                "finalText は、最初に短い結論を示し、そのあとに見出しや箇条書きで整理してください。1つの長い段落にしないでください。",
                "検索結果が渡された場合は、結果の要約だけで終わらず、根拠を統合した説明本文にしてください。",
                "説明が長くなる時は2〜4文ごとに改行してください。",
                advancedSettings.normalized().safetyInstructionLines().joined(separator: "\n"),
                reasoningGuidance,
                AIToolCatalog.localStructuredPromptSection(
                    enabledToolNames: enabledToolNames,
                    strictJSONToolCalls: advancedSettings.strictJSONToolCalls,
                    allowDirectAnswersWithoutTools: advancedSettings.allowDirectAnswersWithoutTools
                )
            ]
            if researchMode == .deep {
                if finalSynthesisOnly {
                    sections.append("Deep Research の最終 answer は、短い要約のあとに見出し付き本文を続け、根拠・比較または背景・注意点・次の一手のうち複数を含めてください。")
                } else {
                    sections.append("Deep Research の検索フェーズでは、最終本文より tool call を優先してください。external_search は 1 回で複数 queries を出し、必要なら複数ラウンドで不足観点を確認してください。")
                    sections.append("検索語はユーザーの長文をそのまま使わず、固有名詞・比較軸・法律・仕様・公式情報などに分解してください。")
                }
            }
            return sections.joined(separator: "\n\n")
        }

        let basePrompt = runtimeSystemPrompt(
            coachMode: coachMode,
            researchMode: researchMode,
            reasoningMode: reasoningMode,
            childAge: childAge,
            pageInfo: pageInfo,
            safetySnapshot: safetySnapshot,
            advancedSettings: advancedSettings
        )
        let reasoningGuidance: String
        switch (reasoningMode, researchMode) {
        case (.fast, .deep):
            reasoningGuidance = finalSynthesisOnly
                ? "今回は Deep Research の最終統合です。追加関数を使わず、渡された検索結果と補助メモだけで短すぎない本文を返してください。"
                : "今回は素早く判断しつつも、短すぎない本文で返してください。"
        case (.fast, _), (.persona, _):
            reasoningGuidance = "今回は素早く判断しつつ、必要十分に答えてください。"
        case (.thinking, .deep):
            reasoningGuidance = finalSynthesisOnly
                ? "今回は標準の reasoning で Deep Research の最終統合を行います。追加関数を使わず、根拠や補足も含めて整理してください。"
                : "今回は標準の reasoning を使い、Deep Research の検索フェーズでは不足観点を見つけたら複数の tool call を優先してください。"
        case (.thinking, _):
            reasoningGuidance = "今回は標準の reasoning を使い、必要な時だけ関数を呼び出してください。検索結果が渡された説明系の質問では、1000〜1600字程度の本文にしてください。"
        case (.deepThinking, .deep):
            reasoningGuidance = finalSynthesisOnly
                ? "今回は丁寧に reasoning し、追加検索や関数を使わず、収集済みソースを Deep Research として背景・比較・注意点まで統合してください。"
                : "今回は丁寧に reasoning し、Deep Research の検索フェーズでは不足観点を見つけたら複数の tool call を優先してください。"
        case (.deepThinking, _):
            reasoningGuidance = "今回は丁寧に reasoning し、必要なら検索や関数を使ってください。検索結果が渡された説明系の質問では、1500〜2400字程度の本文にしてください。"
        }

        var sections = [
            basePrompt,
            "Gemma 4 の reasoning を使って、日本語で答えてください。",
            "短い要約だけで終わらせず、必要な情報量を残してください。",
            "finalText は、最初に短い結論を示し、そのあとに見出しや箇条書きで整理してください。1つの長い段落にしないでください。",
            "検索結果が渡された場合は、結果の要約だけで終わらず、根拠を統合した説明本文にしてください。",
            "説明が長くなる時は2〜4文ごとに改行してください。",
            reasoningGuidance,
            AIToolCatalog.localStructuredPromptSection(
                enabledToolNames: enabledToolNames,
                strictJSONToolCalls: advancedSettings.strictJSONToolCalls,
                allowDirectAnswersWithoutTools: advancedSettings.allowDirectAnswersWithoutTools
            )
        ]
        if researchMode == .deep {
            if finalSynthesisOnly {
                sections.append("Deep Research の最終 answer は、見出し付きで整理し、根拠・比較または背景・注意点・次の一手のうち複数を本文に含めてください。")
            } else {
                sections.append("Deep Research の検索フェーズでは、最終本文より tool call を優先してください。external_search は 1 回で複数 queries を出し、必要なら複数ラウンドで不足観点を確認してください。")
                sections.append("検索語はユーザーの長文をそのまま使わず、固有名詞・比較軸・法律・仕様・公式情報などに分解してください。")
            }
        }
        return sections.joined(separator: "\n\n")
    }

    private func buildStructuredTurnUserPrompt(
        conversationPrompt: String,
        toolResults: [LocalAssistantToolResult]
    ) -> String {
        var sections: [String] = []

        if !toolResults.isEmpty {
            let payload = toolResults.map { result in
                """
                {
                  "name": "\(result.toolName)",
                  "summary": "\(escapeJSONString(result.visibleSummary))",
                  "result": "\(escapeJSONString(result.contextText))"
                }
                """
            }.joined(separator: ",\n")
            sections.append(
                """
                function results:
                [
                \(indent(payload, spaces: 2))
                ]
                """
            )
        }

        sections.append(
            """
            request:
            \(conversationPrompt)
            """
        )

        return sections.joined(separator: "\n\n")
    }

    private func reasoningBudget(for reasoningMode: ReasoningMode) -> Int {
        switch reasoningMode {
        case .fast:
            // 即答経路。Thinkingは使わない。
            return 0
        case .persona:
            // KizunaはThinkingを有効にするが、1ターンの推論予算は512に制限。
            return 512
        case .thinking:
            return 1024
        case .deepThinking:
            return 2048
        }
    }

    func hasSevereDiskPressure(forModelPath modelPath: String?) -> Bool {
        guard let freeBytes = freeDiskSpaceBytes(forModelPath: modelPath) else { return false }
        return freeBytes < 512 * 1024 * 1024
    }

    private func freeDiskSpaceBytes(forModelPath modelPath: String?) -> Int64? {
        let basePath: String
        if let modelPath {
            basePath = URL(fileURLWithPath: modelPath).deletingLastPathComponent().path
        } else {
            basePath = NSHomeDirectory()
        }

        guard
            let attributes = try? FileManager.default.attributesOfFileSystem(forPath: basePath),
            let freeBytes = attributes[.systemFreeSize] as? NSNumber
        else {
            return nil
        }
        return freeBytes.int64Value
    }

    private func effectiveCLITuning(
        for prompt: String,
        modelPath: String,
        reasoningMode: ReasoningMode,
        requestedMaxTokens: Int,
        structured: Bool
    ) -> (
        contextSize: Int,
        batchSize: Int,
        microBatchSize: Int,
        maxTokens: Int,
        timeoutSeconds: Int,
        loadingPreview: String?
    ) {
        let runtimePreset = runtimePreset(for: reasoningMode)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let shortPrompt = trimmedPrompt.count <= 120
        let mediumPrompt = trimmedPrompt.count > 120 && trimmedPrompt.count <= 1600
        let forceConservativeCPURuntime = shouldForceConservativeCPURuntime(forModelPath: modelPath)
        let severeDiskPressure = hasSevereDiskPressure(forModelPath: modelPath)

        var contextSize: Int
        if reasoningMode == .persona {
            // Storyの履歴を保持するのはKizuna personaだけ。
            contextSize = 16_384
        } else if requestedMaxTokens >= 16_384 {
            contextSize = 24_576
        } else if reasoningMode == .deepThinking || requestedMaxTokens >= 12_288 {
            contextSize = 20_480
        } else if requestedMaxTokens >= 9_216 {
            contextSize = 16_384
        } else if reasoningMode == .thinking || requestedMaxTokens >= 4_096 || (!mediumPrompt && !shortPrompt) {
            contextSize = 12_288
        } else if mediumPrompt || structured {
            contextSize = 8_192
        } else {
            contextSize = 4_096
        }

        let isFast = reasoningMode == .fast || reasoningMode == .persona
        var batchSize = isFast ? 24 : 40
        var microBatchSize = isFast ? 12 : 20
        let maxTokens = requestedMaxTokens
        var timeoutSeconds = cliGenerationTimeoutSeconds(for: reasoningMode, structured: structured)

        if forceConservativeCPURuntime || severeDiskPressure {
            batchSize = min(batchSize, shortPrompt ? 12 : (mediumPrompt ? 20 : 28))
            microBatchSize = min(microBatchSize, shortPrompt ? 6 : (mediumPrompt ? 10 : 14))
            timeoutSeconds = max(timeoutSeconds, structured ? 120 : 90)
        }

        if severeDiskPressure {
            batchSize = min(batchSize, 12)
            microBatchSize = min(microBatchSize, 6)
            timeoutSeconds = max(timeoutSeconds, structured ? 150 : 105)
        }

        if shortPrompt && isFast && !structured {
            timeoutSeconds = min(timeoutSeconds, 75)
        }

        let loadingPreview: String?
        if forceConservativeCPURuntime || severeDiskPressure {
            if severeDiskPressure {
                loadingPreview = shortPrompt
                    ? "Gemma 4 を読み込んでいます。空き容量が少ないため、最初の一文を慎重に生成しています..."
                    : "Gemma 4 を読み込んでいます。空き容量が少ないため、応答の立ち上がりが遅くなっています..."
            } else {
                loadingPreview = shortPrompt
                    ? "Gemma 4 を読み込んでいます。最初の一文を生成中です..."
                    : "Gemma 4 を読み込んでいます。応答を組み立てています..."
            }
        } else {
            loadingPreview = nil
        }

        return (
            contextSize: min(contextSize, max(runtimePreset.contextSize, contextSize)),
            batchSize: batchSize,
            microBatchSize: microBatchSize,
            maxTokens: max(maxTokens, structured ? 40 : 24),
            timeoutSeconds: timeoutSeconds,
            loadingPreview: loadingPreview
        )
    }

    func effectiveCLITuningForTesting(
        prompt: String,
        modelPath: String,
        reasoningMode: ReasoningMode,
        requestedMaxTokens: Int,
        structured: Bool
    ) -> (contextSize: Int, batchSize: Int, microBatchSize: Int, maxTokens: Int, timeoutSeconds: Int) {
        let tuning = effectiveCLITuning(
            for: prompt,
            modelPath: modelPath,
            reasoningMode: reasoningMode,
            requestedMaxTokens: requestedMaxTokens,
            structured: structured
        )
        return (
            contextSize: tuning.contextSize,
            batchSize: tuning.batchSize,
            microBatchSize: tuning.microBatchSize,
            maxTokens: tuning.maxTokens,
            timeoutSeconds: tuning.timeoutSeconds
        )
    }

    private func cliGenerationTimeoutSeconds(for reasoningMode: ReasoningMode, structured: Bool) -> Int {
        // maxTokens 拡張に合わせてタイムアウトも延長
        // M2 16GB で ~40 tok/s として: fast 2048≈51s、thinking 4096≈102s、deepThinking 6144≈154s
        // システムプロンプトのプリフィルや web 検索待ちを加味して 2倍程度の余裕を設ける
        switch (reasoningMode, structured) {
        case (.fast, false), (.persona, false), (.persona, true):
            return 150
        case (.fast, true):
            return 180
        case (.thinking, false):
            return 360
        case (.thinking, true):
            return 420
        case (.deepThinking, false):
            return 600
        case (.deepThinking, true):
            return 720
        }
    }

    private func parseStructuredTurnOutput(
        _ text: String,
        enabledToolNames: [String] = AIToolCatalog.toolNames
    ) -> LocalAssistantStructuredTurn {
        let thinkingSegments = sanitizeThinkingSegments(extractThinkingSegments(from: text))
        let jsonToolCalls = extractFunctionCalls(from: text, enabledToolNames: enabledToolNames)
        let toolCalls = jsonToolCalls.isEmpty
            ? extractToolCalls(from: text, enabledToolNames: enabledToolNames)
            : jsonToolCalls
        let visibleText = stripStructuredMarkup(from: text, parsedToolCalls: toolCalls)
        let finalText = visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawThinkingStream = thinkingSegments.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEvents = buildNormalizedEvents(
            thinkingSegments: thinkingSegments,
            toolCalls: toolCalls,
            finalText: finalText
        )

        return LocalAssistantStructuredTurn(
            finalText: finalText,
            visibleText: visibleText,
            thinkingSegments: thinkingSegments,
            rawThinkingStream: rawThinkingStream,
            toolCalls: toolCalls,
            normalizedEvents: normalizedEvents,
            finishReason: nil
        )
    }

    private func buildNormalizedEvents(
        thinkingSegments: [String],
        toolCalls: [LocalAssistantToolCall],
        finalText: String
    ) -> [LocalAssistantNormalizedEvent] {
        var events: [LocalAssistantNormalizedEvent] = []
        events.append(contentsOf: thinkingSegments.map(LocalAssistantNormalizedEvent.thought))
        events.append(contentsOf: toolCalls.map(LocalAssistantNormalizedEvent.toolCall))
        if !finalText.isEmpty {
            events.append(.finalText(finalText))
        }
        return events
    }

    private func extractFunctionCalls(
        from text: String,
        enabledToolNames: [String] = AIToolCatalog.toolNames
    ) -> [LocalAssistantToolCall] {
        let withoutThinking = removeThinkingMarkup(from: text)
        let candidates = jsonPayloadCandidates(in: withoutThinking)

        for candidate in candidates {
            guard let payload = decodedFunctionPayload(from: candidate) else {
                continue
            }

            let invocations: [LocalFunctionInvocation]
            if let single = payload.functionCall {
                invocations = [single]
            } else if let many = payload.functionCalls {
                invocations = many
            } else if let toolCalls = payload.toolCalls {
                invocations = toolCalls
            } else if let name = payload.name {
                invocations = [LocalFunctionInvocation(name: name, arguments: payload.arguments, reason: payload.reason)]
            } else {
                invocations = []
            }

            let decoded = validateToolCalls(
                invocations.compactMap(decodeLocalToolCall(from:)),
                enabledToolNames: enabledToolNames
            )
            if !decoded.isEmpty {
                return decoded
            }
        }

        return []
    }

    private func extractThinkingSegments(from text: String) -> [String] {
        // `<think>...</think>` (DeepSeek 互換) と
        // `<|channel>thought\n...<channel|>` (Gemma 4 ネイティブ) の両形式を抽出する。
        let patterns = [
            #"<think>([\s\S]*?)</think>"#,
            #"<\|?channel\|?>\s*thought\s*\n([\s\S]*?)<channel\|>"#
        ]
        var segments: [String] = []
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            for match in regex.matches(in: text, range: range) {
                guard match.numberOfRanges >= 2,
                      let captured = Range(match.range(at: 1), in: text) else {
                    continue
                }
                let segment = String(text[captured]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !segment.isEmpty { segments.append(segment) }
            }
        }
        return segments
    }

    /// Gemma 4 の channel 形式 raw 出力を (thinking, visible) に分解する。
    /// vendored llama.cpp は Gemma 4 の `<|channel>thought` を `reasoning_content` に
    /// 振り分けないため、`content` 側に来た raw を自前で分割する。
    /// - 入力例: `<|channel>thought\n[内部推論]<channel|>[最終回答]`
    /// - 戻り値: (thinking=`[内部推論]`, visible=`[最終回答]`)
    /// ストリーミング途中で `<channel|>` 未到着の場合は thinking のみが返り visible は空。
    /// thinking ブロックが無い純粋な visible 出力なら thinking は空、visible はそのまま。
    func splitGemma4ChannelStream(_ text: String) -> (thinking: String, visible: String) {
        let openMarkers = ["<|channel>thought", "<|channel|>thought", "<channel>thought"]
        let closeMarkers = ["<channel|>", "<|channel|>", "<channel>"]
        guard openMarkers.contains(where: { text.range(of: $0, options: .caseInsensitive) != nil }) ||
              closeMarkers.contains(where: { text.range(of: $0, options: .caseInsensitive) != nil }) else {
            return ("", text)
        }

        var cursor = text.startIndex
        var thinkingParts: [String] = []
        var visibleParts: [String] = []

        while cursor < text.endIndex {
            guard let openMatch = firstMarkerMatch(in: text, markers: openMarkers, from: cursor) else {
                visibleParts.append(String(text[cursor...]))
                break
            }

            if openMatch.range.lowerBound > cursor {
                visibleParts.append(String(text[cursor..<openMatch.range.lowerBound]))
            }

            let bodyStart = openMatch.range.upperBound
            if let closeMatch = firstMarkerMatch(in: text, markers: closeMarkers, from: bodyStart) {
                thinkingParts.append(cleanGemma4ThoughtBody(String(text[bodyStart..<closeMatch.range.lowerBound])))
                cursor = closeMatch.range.upperBound
            } else {
                thinkingParts.append(cleanGemma4ThoughtBody(String(text[bodyStart...])))
                cursor = text.endIndex
            }
        }

        return (
            thinkingParts.filter { !$0.isEmpty }.joined(separator: "\n"),
            visibleParts.joined()
        )
    }

    private func firstMarkerMatch(
        in text: String,
        markers: [String],
        from start: String.Index
    ) -> (range: Range<String.Index>, marker: String)? {
        markers
            .compactMap { marker -> (range: Range<String.Index>, marker: String)? in
                guard let range = text.range(of: marker, options: .caseInsensitive, range: start..<text.endIndex) else {
                    return nil
                }
                return (range, marker)
            }
            .min { $0.range.lowerBound < $1.range.lowerBound }
    }

    private func cleanGemma4ThoughtBody(_ text: String) -> String {
        var cleaned = text
        while let first = cleaned.first, first == "\n" || first == "\r" || first == " " || first == "\t" {
            cleaned.removeFirst()
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Gemma 4 のネイティブ思考ブロックを抽出する。
    /// 形式: `<|channel>thought\n[内部推論]<channel|>` または `<channel>thought\n...<channel|>`
    /// ストリーミング途中で末尾が閉じていないケースにも対応する。
    private func extractGemma4ThoughtSegment(from text: String) -> String? {
        let openPatterns = ["<|channel>thought", "<channel>thought", "<|channel|>thought"]
        var openIndex: String.Index?
        for marker in openPatterns {
            if let r = text.range(of: marker, options: [.backwards, .caseInsensitive]) {
                openIndex = r.upperBound
                break
            }
        }
        guard let start = openIndex else { return nil }
        let remaining = text[start...]
        // 直後の改行は thought ヘッダーの区切りとして読み飛ばす。
        let body: Substring
        if let nl = remaining.firstIndex(of: "\n") {
            body = remaining[remaining.index(after: nl)...]
        } else {
            body = remaining
        }
        let closePatterns = ["<channel|>", "<|channel|>", "<channel>"]
        for marker in closePatterns {
            if let r = body.range(of: marker, options: [.caseInsensitive]) {
                return String(body[..<r.lowerBound])
            }
        }
        // 閉じトークンが未到着のストリーミング中は受信済み部分をそのまま返す。
        return body.isEmpty ? nil : String(body)
    }

    private func extractToolCalls(
        from text: String,
        enabledToolNames: [String] = AIToolCatalog.toolNames
    ) -> [LocalAssistantToolCall] {
        let pattern = #"<tool_call\s+name=\"([a-zA-Z0-9_]+)\">([\s\S]*?)</tool_call>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return validateToolCalls(regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges >= 3,
                  let nameRange = Range(match.range(at: 1), in: text),
                  let bodyRange = Range(match.range(at: 2), in: text) else {
                return nil
            }
            let rawName = String(text[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let payload = String(text[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            return decodeLocalToolCall(name: rawName, payload: payload)
        }, enabledToolNames: enabledToolNames)
    }

    private func decodeLocalToolCall(from invocation: LocalFunctionInvocation) -> LocalAssistantToolCall? {
        guard let toolName = LocalAssistantToolName(rawValue: invocation.name) else { return nil }
        let arguments = decodeLocalToolCallArguments(from: invocation.arguments)
        return LocalAssistantToolCall(name: toolName, arguments: arguments, reason: invocation.reason)
    }

    private func decodeLocalToolCall(name rawName: String, payload: String) -> LocalAssistantToolCall? {
        guard let toolName = LocalAssistantToolName(rawValue: rawName) else { return nil }
        let arguments = decodeLocalToolCallArguments(from: payload)
        let reason = extractStringValue(forKey: "reason", from: payload)
        return LocalAssistantToolCall(name: toolName, arguments: arguments, reason: reason)
    }

    private func decodeLocalToolCallArguments(from payload: String) -> LocalAssistantToolCallArguments? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return decodeLocalToolCallArguments(from: object)
    }

    private func decodeLocalToolCallArguments(from object: [String: JSONValue]?) -> LocalAssistantToolCallArguments? {
        guard let object else { return nil }
        return decodeLocalToolCallArguments(from: object.mapValues(\.anyValue))
    }

    private func decodeLocalToolCallArguments(from object: [String: Any]) -> LocalAssistantToolCallArguments? {
        let query = object["query"] as? String
        let queries = object["queries"] as? [String]
        let code = object["code"] as? String
        let source = object["source"] as? String
        let expression = object["expression"] as? String
        let limit = object["limit"] as? Int
        let stopCondition = object["stopCondition"] as? String

        return LocalAssistantToolCallArguments(
            query: query,
            queries: queries,
            code: code,
            source: source,
            expression: expression,
            limit: limit,
            stopCondition: stopCondition
        )
    }

    private func extractStringValue(forKey key: String, from payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object[key] as? String
    }

    private func decodedFunctionPayload(from candidate: String) -> LocalFunctionCallPayload? {
        guard !candidate.isEmpty else { return nil }
        let decoder = JSONDecoder()

        if let data = candidate.data(using: .utf8),
           let payload = try? decoder.decode(LocalFunctionCallPayload.self, from: data) {
            return payload
        }

        let repaired = candidate
            .replacingOccurrences(of: ",}", with: "}")
            .replacingOccurrences(of: ",]", with: "]")

        guard repaired != candidate,
              let data = repaired.data(using: .utf8),
              let payload = try? decoder.decode(LocalFunctionCallPayload.self, from: data) else {
            return nil
        }

        return payload
    }

    private func validateToolCalls(
        _ toolCalls: [LocalAssistantToolCall],
        enabledToolNames: [String] = AIToolCatalog.toolNames
    ) -> [LocalAssistantToolCall] {
        var seen = Set<String>()
        var validated: [LocalAssistantToolCall] = []
        let allowedToolNames = Set(enabledToolNames)

        for toolCall in toolCalls {
            guard let normalized = validateToolCall(
                toolCall,
                allowedToolNames: allowedToolNames,
                seenFingerprints: &seen
            ) else {
                continue
            }
            validated.append(normalized)
        }

        return validated
    }

    // Treat malformed or duplicate tool calls as plain text output so we fail safely.
    private func validateToolCall(
        _ toolCall: LocalAssistantToolCall,
        allowedToolNames: Set<String>,
        seenFingerprints: inout Set<String>
    ) -> LocalAssistantToolCall? {
        let toolName = toolCall.name.rawValue
        guard allowedToolNames.contains(toolName) else {
            return nil
        }
        guard let definition = AIToolCatalog.definition(named: toolName) else {
            return nil
        }

        let normalizedReason = toolCall.reason?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        let normalizedArguments = normalizeValidatedArguments(toolCall.arguments, for: definition)

        if AIToolCatalog.requiresNonEmptyQuery(forToolNamed: toolName),
           normalizedQueryValues(from: normalizedArguments).isEmpty {
            return nil
        }

        if AIToolCatalog.requiredArgumentNames(forToolNamed: toolName).contains("code"),
           normalizedArguments?.code?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return nil
        }

        if AIToolCatalog.requiredArgumentNames(forToolNamed: toolName).contains("source"),
           normalizedArguments?.source?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return nil
        }

        if AIToolCatalog.requiredArgumentNames(forToolNamed: toolName).contains("expression"),
           normalizedArguments?.expression?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return nil
        }

        let normalizedCall = LocalAssistantToolCall(
            name: toolCall.name,
            arguments: normalizedArguments,
            reason: normalizedReason
        )
        let fingerprint = toolCallFingerprint(for: normalizedCall)
        guard seenFingerprints.insert(fingerprint).inserted else {
            return nil
        }

        return normalizedCall
    }

    private func normalizeValidatedArguments(
        _ arguments: LocalAssistantToolCallArguments?,
        for definition: AIToolDefinition
    ) -> LocalAssistantToolCallArguments? {
        guard let arguments else { return nil }

        let query = normalizedOptionalString(arguments.query, toolName: definition.name, argumentName: "query")
        let queries = normalizedOptionalQueryArray(arguments.queries, toolName: definition.name, argumentName: "queries")
        let code = normalizedOptionalString(arguments.code, toolName: definition.name, argumentName: "code")
        let source = normalizedOptionalString(arguments.source, toolName: definition.name, argumentName: "source")
        let expression = normalizedOptionalString(arguments.expression, toolName: definition.name, argumentName: "expression")
        let stopCondition = normalizedOptionalString(arguments.stopCondition, toolName: definition.name, argumentName: "stopCondition")
        let limit = AIToolCatalog.acceptsArgument(named: "limit", forToolNamed: definition.name) ? arguments.limit : nil

        if query == nil &&
            queries == nil &&
            code == nil &&
            source == nil &&
            expression == nil &&
            stopCondition == nil &&
            limit == nil {
            return nil
        }

        return LocalAssistantToolCallArguments(
            query: query,
            queries: queries,
            code: code,
            source: source,
            expression: expression,
            limit: limit,
            stopCondition: stopCondition
        )
    }

    private func normalizedOptionalString(_ value: String?, toolName: String, argumentName: String) -> String? {
        guard AIToolCatalog.acceptsArgument(named: argumentName, forToolNamed: toolName) else {
            return nil
        }
        return value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private func normalizedOptionalQueryArray(_ values: [String]?, toolName: String, argumentName: String) -> [String]? {
        guard AIToolCatalog.acceptsArgument(named: argumentName, forToolNamed: toolName),
              let values else {
            return nil
        }

        var seen = Set<String>()
        let normalized = values.compactMap { item -> String? in
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let fingerprint = trimmed.lowercased()
            guard seen.insert(fingerprint).inserted else { return nil }
            return trimmed
        }

        return normalized.isEmpty ? nil : normalized
    }

    private func normalizedQueryValues(from arguments: LocalAssistantToolCallArguments?) -> [String] {
        var values: [String] = []
        if let query = arguments?.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            values.append(query)
        }
        if let queries = arguments?.queries {
            values.append(contentsOf: queries.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        }
        return values
    }

    private func toolCallFingerprint(for toolCall: LocalAssistantToolCall) -> String {
        let arguments = toolCall.arguments
        let queryPart = normalizedQueryValues(from: arguments).joined(separator: "|")
        let codePart = arguments?.code?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sourcePart = arguments?.source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let expressionPart = arguments?.expression?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stopConditionPart = arguments?.stopCondition?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let limitPart = arguments?.limit.map(String.init) ?? ""
        return [
            toolCall.name.rawValue,
            queryPart,
            codePart,
            sourcePart,
            expressionPart,
            stopConditionPart,
            limitPart
        ].joined(separator: "||")
    }

    private func stripStructuredMarkup(from text: String, parsedToolCalls: [LocalAssistantToolCall] = []) -> String {
        var stripped = text
        let patterns = [
            #"<think>[\s\S]*?</think>"#,
            #"<tool_call\s+name=\"[a-zA-Z0-9_]+\">[\s\S]*?</tool_call>"#,
            #"</?final>"#,
            #"</?answer>"#
        ]

        for pattern in patterns {
            stripped = stripped.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        if !parsedToolCalls.isEmpty {
            for candidate in jsonPayloadCandidates(in: stripped) {
                stripped = stripped.replacingOccurrences(of: candidate, with: "")
            }
        }

        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func containsThinkingMarkup(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("<think") ||
            lowered.contains("[start thinking]") ||
            lowered.contains("<|channel") ||
            lowered.contains("<channel")
    }

    private func partialThinkingPreview(from text: String) -> String {
        // sanitizeThinkingPreview は CLI ノイズ用の truncateMarkers
        // (`user:` `assistant:` `request:` 等) で本文途中を切るが、reasoning_content
        // 経由のテキストはモデル純粋出力なので、これらの語を含んだ瞬間に末尾が
        // 永久に切れて「思考が止まって見える / 出てこない」原因になる。
        // → live preview では trim だけして返す。最終結果のクリーニングは
        //   別レイヤー (response 確定後) に任せる。
        // 高速パス: タグなし素テキスト
        if !text.contains("<") && !text.contains("[") {
            return cleanCLIOutput(text).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let openRange = text.range(of: "<think>", options: [.backwards, .caseInsensitive]) {
            let remaining = text[openRange.upperBound...]
            if let closing = remaining.range(of: "</think>", options: [.caseInsensitive]) {
                return String(remaining[..<closing.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return String(remaining).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let openRange = text.range(of: "[Start thinking]", options: [.backwards, .caseInsensitive]) {
            let remaining = text[openRange.upperBound...]
            if let closing = remaining.range(of: "[End thinking]", options: [.caseInsensitive]) {
                return String(remaining[..<closing.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return String(remaining).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Gemma 4 のネイティブ思考ブロック: `<|channel>thought\n[内部推論]<channel|>`
        if let gemmaSegment = extractGemma4ThoughtSegment(from: text) {
            return gemmaSegment.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let fromSegments = extractThinkingSegments(from: text).last ?? ""
        if !fromSegments.isEmpty {
            return fromSegments.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func partialVisiblePreview(from text: String) -> String {
        let stripped = cleanStructuredCLIOutput(stripStructuredMarkup(from: text))
        if !extractFunctionCalls(from: stripped).isEmpty ||
            stripped.localizedCaseInsensitiveContains("<tool_call") ||
            stripped.localizedCaseInsensitiveContains("\"functioncall\"") ||
            stripped.localizedCaseInsensitiveContains("\"functioncalls\"") ||
            containsSpecialTokenLeakFragment(stripped) {
            return ""
        }
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sanitizeThinkingSegments(_ segments: [String]) -> [String] {
        segments
            .map(sanitizeThinkingPreview(_:))
            .filter { !$0.isEmpty }
    }

    private func sanitizeThinkingPreview(_ text: String) -> String {
        // 「文脈漏れ」マーカー: これより後ろは system prompt や RAG の漏れなので破棄する。
        let truncateMarkers = [
            "using custom system prompt",
            "loading model...",
            "build      :",
            "model      :",
            "modalities :",
            "available commands:",
            "ai studio の文脈境界",
            "safe browse の保護設定",
            "conversation:",
            "memories:",
            "retrieved context:",
            "known facts:",
            "answer preference:",
            "request:",
            "user:",
            "assistant:",
            "images:",
            "直近の会話:",
            "承認済みメモリー:",
            "過去会話の検索結果:",
            "すでに得た情報:",
            "回答方針:",
            "今回の依頼:",
            "このスレッドの会話",
            "ai studio 内の過去会話",
            "承認済みaiメモリー",
            "aiツール結果",
            "実行モード:",
            "検索上限:",
            "function calling setup",
            "function calling setup:",
            "function definitions",
            "function definitions:",
            "user request:",
            "function results:",
            "/exit",
            "/regen",
            "/clear",
            "/read",
            "/glob"
        ]
        // 「思考の前置き」マーカー: モデルが思考の冒頭で言いがちな決まり文句。
        // 中身を残したいのでマーカー自身を取り除き、後続テキストを保持する。
        let preambleMarkers = [
            "[start thinking]",
            "to construct the desired response:",
            "to construct the desired response.",
            "to construct the desired response",
            "to construct the detailed answer:",
            "to construct the detailed answer.",
            "to construct the detailed answer",
            "construct the desired response:",
            "construct the desired response.",
            "construct the detailed answer:",
            "construct the detailed answer.",
            "here's a thinking process to construct an answer:",
            "here's a thinking process to construct an answer.",
            "here's a thinking process",
            "here is a thinking process to construct an answer:",
            "here is a thinking process to construct an answer.",
            "here is a thinking process",
            "thinking process to construct",
            "thought process:"
        ]

        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("{\"functionCall\"") ||
            cleaned.hasPrefix("{\"functionCalls\"") ||
            cleaned.hasPrefix("{\"tool_calls\"") ||
            cleaned.hasPrefix("{\"toolCalls\"") ||
            cleaned.hasPrefix("[{\"name\"") {
            return ""
        }

        // 1) 前置きマーカーは「マーカーごと削除」して中身を残す
        //    cleaned が "Here's a thinking process to construct an answer:\n\n1. First..."
        //    → "1. First..." として返す
        var madeChange = true
        while madeChange {
            madeChange = false
            for marker in preambleMarkers {
                if let range = cleaned.range(of: marker, options: [.caseInsensitive]),
                   range.lowerBound == cleaned.startIndex {
                    cleaned = String(cleaned[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    madeChange = true
                    break
                }
            }
        }

        cleaned = stripGenericThinkingPreambleLines(from: cleaned)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || looksLikeGenericThinkingOnly(cleaned) {
            return ""
        }

        // 2) 文脈漏れマーカーは「マーカー以降を全削除」する
        for marker in truncateMarkers {
            if let range = cleaned.range(of: marker, options: [.caseInsensitive]) {
                cleaned = String(cleaned[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return cleaned
    }

    private func stripGenericThinkingPreambleLines(from text: String) -> String {
        var lines = text.components(separatedBy: .newlines)
        while let first = lines.first {
            let normalized = first
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"[\*_`]+"#, with: "", options: .regularExpression)
                .lowercased()
            let isGeneric = normalized.isEmpty ||
                normalized.hasPrefix("to construct the desired response") ||
                normalized.hasPrefix("to construct the detailed answer") ||
                normalized.hasPrefix("about ") ||
                normalized.hasPrefix("1. analyze") ||
                normalized.hasPrefix("1 analyze") ||
                normalized.hasPrefix("analyze the user") ||
                normalized.hasPrefix("analyze the request") ||
                normalized.hasPrefix("analyze the question")
            guard isGeneric else { break }
            lines.removeFirst()
        }
        return lines.joined(separator: "\n")
    }

    private func looksLikeGenericThinkingOnly(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        // 200 文字を超えるテキストは本物の思考内容。プリアンブル語句が含まれていても
        // 思考全文を捨てるべきではないため、ここで即 false を返す。
        // (Gemma 4 の native thinking は通常数千文字になる)
        guard trimmed.count < 200 else { return false }
        let normalized = trimmed
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"[\*_`]+"#, with: "", options: .regularExpression)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 短いテキストが先頭からプリアンブルで始まる場合のみ "汎用のみ" と判定。
        // contains はやめて hasPrefix に限定することで、思考本文中のフレーズに
        // 誤ってマッチするのを防ぐ。
        let prefixMarkers = [
            "to construct the desired response",
            "to construct the detailed answer",
            "construct the desired response",
            "construct the detailed answer",
            "about "
        ]
        return prefixMarkers.contains(where: { normalized.hasPrefix($0) }) ||
               normalized.hasPrefix("1. analyze") ||
               normalized.hasPrefix("1 analyze")
    }

    private func removeThinkingMarkup(from text: String) -> String {
        text.replacingOccurrences(
            of: #"<think>[\s\S]*?</think>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private func jsonPayloadCandidates(in text: String) -> [String] {
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var candidates: [String] = []
        let appendIfNew: (String) -> Void = { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !candidates.contains(trimmed) else { return }
            candidates.append(trimmed)
        }

        if cleaned.hasPrefix("{"), cleaned.hasSuffix("}") {
            appendIfNew(cleaned)
        }
        if cleaned.hasPrefix("["), cleaned.hasSuffix("]") {
            appendIfNew(cleaned)
        }

        // ブレース平衡走査: 文字列内の `{` `}` を depth 計算から除外し、
        // 最初に閉じる対応 `}` を見つけて候補化する。
        // 「説明 + JSON + 余計なトークン」混在テキストでも正しい本体を抽出できる。
        for balanced in balancedJSONCandidates(in: cleaned, opening: "{", closing: "}") {
            appendIfNew(balanced)
        }
        for balanced in balancedJSONCandidates(in: cleaned, opening: "[", closing: "]") {
            appendIfNew(balanced)
        }

        // 旧来の first/last フォールバック（バランス走査が失敗するケースの保険）。
        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}"),
           start <= end {
            appendIfNew(String(cleaned[start...end]))
        }
        if let start = cleaned.firstIndex(of: "["),
           let end = cleaned.lastIndex(of: "]"),
           start <= end {
            appendIfNew(String(cleaned[start...end]))
        }

        return candidates
    }

    private func balancedJSONCandidates(
        in text: String,
        opening: Character,
        closing: Character
    ) -> [String] {
        var results: [String] = []
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            if chars[index] == opening,
               let endIndex = balancedDelimiterEndIndex(
                in: chars,
                startingAt: index,
                opening: opening,
                closing: closing
               ) {
                results.append(String(chars[index...endIndex]))
                index = endIndex + 1
                continue
            }
            index += 1
        }
        return results
    }

    private func balancedDelimiterEndIndex(
        in chars: [Character],
        startingAt start: Int,
        opening: Character,
        closing: Character
    ) -> Int? {
        var depth = 0
        var inString = false
        var escape = false
        var index = start
        while index < chars.count {
            let character = chars[index]
            if escape {
                escape = false
                index += 1
                continue
            }
            if inString {
                if character == "\\" {
                    escape = true
                } else if character == "\"" {
                    inString = false
                }
                index += 1
                continue
            }
            if character == "\"" {
                inString = true
            } else if character == opening {
                depth += 1
            } else if character == closing {
                depth -= 1
                if depth == 0 {
                    return index
                }
                if depth < 0 {
                    return nil
                }
            }
            index += 1
        }
        return nil
    }

    private func escapeJSONString(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private func indent(_ text: String, spaces: Int) -> String {
        let prefix = String(repeating: " ", count: spaces)
        return text
            .components(separatedBy: .newlines)
            .map { $0.isEmpty ? $0 : prefix + $0 }
            .joined(separator: "\n")
    }

    private func generationParameters(
        for reasoningMode: ReasoningMode,
        researchMode: ResearchMode = .on,
        advancedSettings: GemmaAdvancedSettings = makeRuntimeDefaultGemmaAdvancedSettings()
    ) -> (maxTokens: Int, temperature: Float, topP: Float, topK: Int, seed: UInt32) {
        let preset = LocalAssistantModelProfile.generationPreset(
            for: reasoningMode,
            researchMode: researchMode
        )
        let normalized = advancedSettings.normalized()
        let effectiveTemperature: Float
        if researchMode != .off {
            effectiveTemperature = 0.0
        } else {
            effectiveTemperature = normalized.useAutomaticTemperature
                ? preset.temperature
                : Float(normalized.clampedTemperature)
        }
        return (
            maxTokens: preset.maxTokens,
            temperature: effectiveTemperature,
            topP: preset.topP,
            topK: preset.topK,
            seed: preset.seed
        )
    }

    private func supportBriefGenerationParameters(
        for reasoningMode: ReasoningMode,
        advancedSettings: GemmaAdvancedSettings = makeRuntimeDefaultGemmaAdvancedSettings()
    ) -> (maxTokens: Int, temperature: Float, topP: Float, topK: Int, seed: UInt32) {
        let preset = LocalAssistantModelProfile.supportBriefPreset(for: reasoningMode)
        let normalized = advancedSettings.normalized()
        let effectiveTemperature: Float
        if reasoningMode != .fast {
            effectiveTemperature = 0.0
        } else {
            effectiveTemperature = normalized.useAutomaticTemperature
                ? preset.temperature
                : min(Float(normalized.clampedTemperature), preset.temperature + 0.12)
        }
        return (
            maxTokens: preset.maxTokens,
            temperature: effectiveTemperature,
            topP: preset.topP,
            topK: preset.topK,
            seed: preset.seed
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
