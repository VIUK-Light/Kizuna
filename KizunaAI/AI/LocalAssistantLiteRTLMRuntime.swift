/*
  LiteRT-LM adapter for iOS.

  This runtime deliberately starts on the CPU path.  It is still native
  on-device LiteRT-LM execution; CPU first avoids entering an iOS Metal
  accelerator before its framework packaging has been proven on the device.
*/
import Foundation

#if os(iOS) && !targetEnvironment(simulator)
#if USE_LITERTLM
#if !canImport(LiteRTLM)
#error("USE_LITERTLM is set but the LiteRTLM SDK is not linked. Add the LiteRT-LM package/xcframework to the iOS target.")
#endif
#endif
#if canImport(LiteRTLM)
import LiteRTLM
#endif
#endif

/// LiteRT-LMへroleを保ったまま渡す短い会話履歴。
/// 文字列へ疑似chat templateを埋め込むのではなく、SDKのConversationConfigへ
/// `user` / `model` として渡す。
struct LocalAssistantLiteRTLMHistoryMessage: Sendable {
    enum Role: Sendable {
        case user
        case model
    }

    let role: Role
    let text: String
}

struct LocalAssistantLiteRTLMRequest {
    let prompt: String
    let systemPrompt: String?
    let modelPath: String
    let maxTokens: Int
    let temperature: Float
    let topP: Float
    let topK: Int
    let seed: UInt32
    let initialMessages: [LocalAssistantLiteRTLMHistoryMessage]
    // The automatic readiness check keeps a short decode budget while using
    // the same production-shaped context as ordinary conversations. It proves
    // the full Engine -> Conversation -> sendMessage path before UI enables
    // local execution.
    let isRuntimeCheck: Bool

    // GPU is intentionally opt-in.  The current iOS release establishes a
    // stable CPU baseline first, rather than treating a native crash as a
    // recoverable Swift error.
    let preferGPU: Bool

    nonisolated init(
        prompt: String,
        systemPrompt: String?,
        modelPath: String,
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        topK: Int,
        seed: UInt32,
        initialMessages: [LocalAssistantLiteRTLMHistoryMessage] = [],
        isRuntimeCheck: Bool = false,
        preferGPU: Bool = false
    ) {
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.modelPath = modelPath
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.seed = seed
        self.initialMessages = initialMessages
        self.isRuntimeCheck = isRuntimeCheck
        self.preferGPU = preferGPU
    }
}

#if os(iOS) && !targetEnvironment(simulator) && VIUK_ENABLE_LITERTLM_NATIVE
#if canImport(LiteRTLM)
private struct LiteRTLMEngineConfiguration: Equatable, Sendable {
    let modelPath: String
    let cacheDirectory: String
    let modelIdentity: String
    let maxNumTokens: Int
}

private actor LiteRTLMExecutionGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard !isLocked else {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
            return
        }
        isLocked = true
    }

    func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        waiters.removeFirst().resume()
    }
}

/// `Conversation.sendMessage` はネイティブ推論中も戻らないため、SwiftのTask cancel
/// だけでは停止しない。現在のConversationを保持してSDKのcancelを直接呼ぶ。
private final class LiteRTLMActiveConversation: @unchecked Sendable {
    private let lock = NSLock()
    private var conversation: Conversation?

    func set(_ conversation: Conversation) {
        lock.lock()
        self.conversation = conversation
        lock.unlock()
    }

    func clear(_ conversation: Conversation) {
        lock.lock()
        if self.conversation === conversation {
            self.conversation = nil
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let activeConversation = conversation
        lock.unlock()
        try? activeConversation?.cancel()
    }
}

private actor LiteRTLMEngineStore {
    private var engine: Engine?
    private var loadedConfiguration: LiteRTLMEngineConfiguration?

    func engine(for configuration: LiteRTLMEngineConfiguration) async throws -> Engine {
        if let engine, loadedConfiguration == configuration {
            NSLog("[KizunaLiteRTLM] reusing prepared CPU engine")
            return engine
        }

        // Release the old engine before allocating a new model.  This prevents
        // a self-check and its first user turn from overlapping two model loads.
        engine = nil
        loadedConfiguration = nil

        let engineConfig = try EngineConfig(
            modelPath: configuration.modelPath,
            backend: .cpu(),
            maxNumTokens: configuration.maxNumTokens,
            cacheDir: configuration.cacheDirectory
        )
        let nextEngine = Engine(engineConfig: engineConfig)
        NSLog("[KizunaLiteRTLM] initializing CPU engine with %d-token context", configuration.maxNumTokens)
        try await nextEngine.initialize()
        NSLog("[KizunaLiteRTLM] CPU engine initialized")
        engine = nextEngine
        loadedConfiguration = configuration
        return nextEngine
    }

    func invalidate(configuration: LiteRTLMEngineConfiguration) {
        guard loadedConfiguration == configuration else { return }
        engine = nil
        loadedConfiguration = nil
    }

    func release() {
        engine = nil
        loadedConfiguration = nil
        NSLog("[KizunaLiteRTLM] released CPU engine while app is in background")
    }
}
#endif
#endif

final class LocalAssistantLiteRTLMRuntime: @unchecked Sendable {
    static let shared = LocalAssistantLiteRTLMRuntime()

    private enum Tuning {
        // Gemma 4 E2B LiteRT-LMの標準エンジン設定。
        nonisolated static let contextTokenLimit = 2_048
        nonisolated static let runtimeCheckContextTokenLimit = 2_048
        nonisolated static let maximumOutputTokens = 768
        nonisolated static let minimumOutputTokens = 64
        // 会話テンプレート・roleタグに使われる分を必ず残す。
        nonisolated static let chatTemplateReserveTokens = 128
        nonisolated static let runtimeCacheVersion = "v0.17.0-gemma4-token-budget"
    }

#if os(iOS) && !targetEnvironment(simulator) && VIUK_ENABLE_LITERTLM_NATIVE
#if canImport(LiteRTLM)
    nonisolated private let executionGate = LiteRTLMExecutionGate()
    nonisolated private let engineStore = LiteRTLMEngineStore()
    nonisolated private let activeConversation = LiteRTLMActiveConversation()
#endif
#endif

    private init() {}

    nonisolated var unavailableReason: String {
#if os(iOS) && !targetEnvironment(simulator)
#if VIUK_ENABLE_LITERTLM_NATIVE
#if canImport(LiteRTLM)
        return ""
#else
        return "LiteRT-LM SDK がこのビルドにリンクされていません。"
#endif
#else
        return "LiteRT-LM native runtime が有効になっていません。"
#endif
#else
        return "LiteRT-LM runtime はこのプラットフォームのビルドに含まれていません。"
#endif
    }

    nonisolated var isRuntimeLinked: Bool {
#if os(iOS) && !targetEnvironment(simulator) && VIUK_ENABLE_LITERTLM_NATIVE
#if canImport(LiteRTLM)
        return true
#else
        return false
#endif
#else
        return false
#endif
    }

    nonisolated func canRunModel(atPath modelPath: String) -> Bool {
#if os(iOS)
        guard isRuntimeLinked else { return false }
        return modelPath.lowercased().hasSuffix(".litertlm")
#else
        return false
#endif
    }

    nonisolated func preflightFailureReason(forModelPath modelPath: String) -> String? {
#if os(iOS) && !targetEnvironment(simulator)
        guard isRuntimeLinked else {
            return unavailableReason
        }
        let lowercasedPath = modelPath.lowercased()
        guard lowercasedPath.hasSuffix(".litertlm") else {
            return "LiteRT-LM は .litertlm モデルだけを実行できます。現在のモデル形式: \(URL(fileURLWithPath: modelPath).pathExtension)"
        }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            return "モデルファイルが見つかりません。"
        }
        guard FileManager.default.isReadableFile(atPath: modelPath) else {
            return "モデルファイルを読み取れません。ファイル権限または保存場所を確認してください。"
        }
        let attributes = (try? FileManager.default.attributesOfItem(atPath: modelPath)) ?? [:]
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize >= LocalAssistantModelProfile.minimumAcceptedModelSizeBytes else {
            return "モデルファイルが小さすぎます。ダウンロードが途中で止まっている可能性があります。"
        }
        guard ProcessInfo.processInfo.physicalMemory >= 4 * 1024 * 1024 * 1024 else {
            return "この端末のメモリでは LiteRT-LM ローカル実行を開始しません。"
        }
        return nil
#else
        return unavailableReason
#endif
    }

    nonisolated func performSelfCheckAsync(modelPath: String) async -> VIUKEmbeddedRuntimeResult {
        await generateAsync(
            LocalAssistantLiteRTLMRequest(
                prompt: "Reply with exactly: ok",
                systemPrompt: nil,
                modelPath: modelPath,
                maxTokens: 16,
                temperature: 0,
                topP: 0.9,
                topK: 20,
                seed: 7,
                isRuntimeCheck: true,
                preferGPU: false
            )
        )
    }

    nonisolated func performSelfCheck(modelPath: String) -> VIUKEmbeddedRuntimeResult {
        if let reason = preflightFailureReason(forModelPath: modelPath) {
            return VIUKEmbeddedRuntimeResult(success: false, text: nil, errorMessage: reason)
        }
        return VIUKEmbeddedRuntimeResult(
            success: false,
            text: nil,
            errorMessage: "LiteRT-LM の起動確認は非同期の自動チェックで実行されます。"
        )
    }

    nonisolated func generateAsync(
        _ request: LocalAssistantLiteRTLMRequest,
        timeoutSeconds: TimeInterval = 180
    ) async -> VIUKEmbeddedRuntimeResult {
        if let reason = preflightFailureReason(forModelPath: request.modelPath) {
            return VIUKEmbeddedRuntimeResult(success: false, text: nil, errorMessage: reason)
        }

#if os(iOS) && !targetEnvironment(simulator) && VIUK_ENABLE_LITERTLM_NATIVE
#if canImport(LiteRTLM)
        // Do not race a timeout against native initialization.  A completed UI
        // timeout cannot safely cancel the C++ load, and starting another Engine
        // while it is still loading was one source of phone-side pressure.
        _ = timeoutSeconds
        await executionGate.acquire()
        let result = await runLiteRTLMAttempt(request)
        await executionGate.release()
        return result
#else
        return VIUKEmbeddedRuntimeResult(success: false, text: nil, errorMessage: "LiteRT-LM runtime はこのビルドに含まれていません。")
#endif
#else
        return VIUKEmbeddedRuntimeResult(success: false, text: nil, errorMessage: "LiteRT-LM runtime はこのビルドに含まれていません。")
#endif
    }

    nonisolated func generate(_ request: LocalAssistantLiteRTLMRequest) -> VIUKEmbeddedRuntimeResult {
        if let reason = preflightFailureReason(forModelPath: request.modelPath) {
            return VIUKEmbeddedRuntimeResult(success: false, text: nil, errorMessage: reason)
        }
        return VIUKEmbeddedRuntimeResult(
            success: false,
            text: nil,
            errorMessage: "LiteRT-LM の生成は非同期の実行経路から開始されます。"
        )
    }

    /// UIの停止・watchdogから呼ぶ。Swift TaskだけでなくネイティブConversationにも
    /// cancelを届け、次ターンがexecution gateで待ち続けないようにする。
    nonisolated func cancelActiveGeneration() {
#if os(iOS) && !targetEnvironment(simulator) && VIUK_ENABLE_LITERTLM_NATIVE
#if canImport(LiteRTLM)
        activeConversation.cancel()
#endif
#endif
    }

    /// アプリがバックグラウンドへ移った時だけモデルとKVキャッシュを解放する。
    /// 画面遷移では解放しないため、通常の会話継続の速度は保つ。
    nonisolated func releaseResourcesForBackground() {
#if os(iOS) && !targetEnvironment(simulator) && VIUK_ENABLE_LITERTLM_NATIVE
#if canImport(LiteRTLM)
        activeConversation.cancel()
        Task(priority: .utility) {
            await executionGate.acquire()
            await engineStore.release()
            await executionGate.release()
        }
#endif
#endif
    }

#if os(iOS) && !targetEnvironment(simulator) && VIUK_ENABLE_LITERTLM_NATIVE
#if canImport(LiteRTLM)
    nonisolated private func runLiteRTLMAttempt(
        _ request: LocalAssistantLiteRTLMRequest
    ) async -> VIUKEmbeddedRuntimeResult {
        let sizedRequest = runtimeSizedRequest(request)
        let configuration = engineConfiguration(
            for: sizedRequest.modelPath,
            isRuntimeCheck: sizedRequest.isRuntimeCheck
        )

        do {
            NSLog("[KizunaLiteRTLM] starting native CPU turn (input=%d bytes, output<=%d)", sizedRequest.prompt.lengthOfBytes(using: .utf8), sizedRequest.maxTokens)
            let engine = try await engineStore.engine(for: configuration)
            let fittedRequest = try await fitInputToNativeContext(
                sizedRequest,
                engine: engine,
                engineCapacity: configuration.maxNumTokens
            )
            let sampler = try SamplerConfig(
                topK: max(sizedRequest.topK, 1),
                topP: max(0, min(sizedRequest.topP, 1)),
                temperature: max(sizedRequest.temperature, 0),
                seed: Int(sizedRequest.seed)
            )
            let initialMessages = fittedRequest.initialMessages.map { message -> Message in
                switch message.role {
                case .user:
                    return Message(message.text, role: .user)
                case .model:
                    return Message(message.text, role: .model)
                }
            }
            NSLog("[KizunaLiteRTLM] creating conversation (system=%d bytes, history=%d)", fittedRequest.systemPrompt?.lengthOfBytes(using: .utf8) ?? 0, initialMessages.count)
            let conversation = try await engine.createConversation(
                with: ConversationConfig(
                    systemMessage: fittedRequest.systemPrompt.map { Message($0, role: .system) },
                    initialMessages: initialMessages,
                    samplerConfig: sampler,
                    maxOutputTokens: fittedRequest.maxTokens
                )
            )
            activeConversation.set(conversation)
            defer { activeConversation.clear(conversation) }
            NSLog("[KizunaLiteRTLM] conversation ready; sending message")
            let response = try await conversation.sendMessage(Message(fittedRequest.prompt))
            let cleaned = response.toString.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasMeaningfulText = hasMeaningfulResponseText(cleaned)
            let outputPreview = String(cleaned.prefix(180)).replacingOccurrences(of: "\n", with: "\\n")
            NSLog("[KizunaLiteRTLM] native CPU turn finished (empty=%@, meaningful=%@, chars=%d, preview=%@)", cleaned.isEmpty ? "true" : "false", hasMeaningfulText ? "true" : "false", cleaned.count, outputPreview)
            return VIUKEmbeddedRuntimeResult(
                success: hasMeaningfulText,
                text: hasMeaningfulText ? cleaned : nil,
                errorMessage: cleaned.isEmpty
                    ? "LiteRT-LM runtime の応答が空でした。"
                    : "LiteRT-LM runtime が記号だけの応答を返しました。"
            )
        } catch {
            NSLog("[KizunaLiteRTLM] native CPU turn failed: %@", error.localizedDescription)
            await engineStore.invalidate(configuration: configuration)
            return VIUKEmbeddedRuntimeResult(
                success: false,
                text: nil,
                errorMessage: "LiteRT-LM runtime error: \(error.localizedDescription)"
            )
        }
    }

    nonisolated private func engineConfiguration(
        for modelPath: String,
        isRuntimeCheck: Bool
    ) -> LiteRTLMEngineConfiguration {
        let modelURL = URL(fileURLWithPath: modelPath)
        let attributes = (try? FileManager.default.attributesOfItem(atPath: modelPath)) ?? [:]
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let fileName = modelURL.deletingPathExtension().lastPathComponent
        let safeName = fileName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let contextTokenLimit = isRuntimeCheck
            ? Tuning.runtimeCheckContextTokenLimit
            : Tuning.contextTokenLimit
        let modelIdentity = "\(safeName.isEmpty ? "model" : safeName)-\(size)-\(Int(modifiedAt))-ctx\(contextTokenLimit)"
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let cacheDirectory = cachesDirectory
            .appendingPathComponent("VIUK", isDirectory: true)
            .appendingPathComponent("LiteRTLM", isDirectory: true)
            .appendingPathComponent(Tuning.runtimeCacheVersion, isDirectory: true)
            .appendingPathComponent("cpu", isDirectory: true)
            .appendingPathComponent(modelIdentity, isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        return LiteRTLMEngineConfiguration(
            modelPath: modelPath,
            cacheDirectory: cacheDirectory.path,
            modelIdentity: modelIdentity,
            maxNumTokens: contextTokenLimit
        )
    }

    nonisolated private func runtimeSizedRequest(
        _ request: LocalAssistantLiteRTLMRequest
    ) -> LocalAssistantLiteRTLMRequest {
        return LocalAssistantLiteRTLMRequest(
            prompt: request.prompt,
            systemPrompt: request.systemPrompt,
            modelPath: request.modelPath,
            maxTokens: request.isRuntimeCheck
                ? min(max(request.maxTokens, 1), 32)
                : min(max(request.maxTokens, Tuning.minimumOutputTokens), Tuning.maximumOutputTokens),
            temperature: request.temperature,
            topP: request.topP,
            topK: request.topK,
            seed: request.seed,
            initialMessages: request.initialMessages,
            isRuntimeCheck: request.isRuntimeCheck,
            preferGPU: false
        )
    }

    nonisolated private func fitInputToNativeContext(
        _ request: LocalAssistantLiteRTLMRequest,
        engine: Engine,
        engineCapacity: Int
    ) async throws -> LocalAssistantLiteRTLMRequest {
        // EngineConfigの総枠から生成予約とテンプレート予約を引いた、実トークン予算。
        let inputBudget = max(
            128,
            engineCapacity - request.maxTokens - Tuning.chatTemplateReserveTokens
        )
        var remaining = inputBudget

        let systemPrompt: String?
        if let value = request.systemPrompt,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let capped = try await trimmedToTokenBudget(
                value,
                maxTokens: min(1_024, max(1, remaining / 2)),
                keepingSuffix: false,
                engine: engine
            )
            remaining -= try await engine.tokenCount(for: capped)
            systemPrompt = capped
        } else {
            systemPrompt = nil
        }

        let prompt = try await trimmedToTokenBudget(
            request.prompt,
            maxTokens: min(512, max(1, remaining)),
            keepingSuffix: true,
            engine: engine
        )
        remaining -= try await engine.tokenCount(for: prompt)

        var retainedHistory: [LocalAssistantLiteRTLMHistoryMessage] = []
        for message in request.initialMessages.reversed() where remaining > 0 {
            let text = try await trimmedToTokenBudget(
                message.text,
                maxTokens: min(160, remaining),
                keepingSuffix: true,
                engine: engine
            )
            let tokenCount = try await engine.tokenCount(for: text)
            guard tokenCount > 0, tokenCount <= remaining else { continue }
            remaining -= tokenCount
            retainedHistory.insert(
                LocalAssistantLiteRTLMHistoryMessage(role: message.role, text: text),
                at: 0
            )
        }

        let systemTokens: Int
        if let systemPrompt {
            systemTokens = try await engine.tokenCount(for: systemPrompt)
        } else {
            systemTokens = 0
        }
        let promptTokens = try await engine.tokenCount(for: prompt)
        let historyTokens = inputBudget - remaining - systemTokens - promptTokens
        NSLog("[KizunaLiteRTLM] token budget system=%d user=%d history=%d input=%d total=%d", systemTokens, promptTokens, historyTokens, inputBudget, systemTokens + promptTokens + historyTokens)

        return LocalAssistantLiteRTLMRequest(
            prompt: prompt,
            systemPrompt: systemPrompt,
            modelPath: request.modelPath,
            maxTokens: request.maxTokens,
            temperature: request.temperature,
            topP: request.topP,
            topK: request.topK,
            seed: request.seed,
            initialMessages: retainedHistory,
            isRuntimeCheck: request.isRuntimeCheck,
            preferGPU: request.preferGPU
        )
    }

    nonisolated private func trimmedToTokenBudget(
        _ value: String,
        maxTokens: Int,
        keepingSuffix: Bool,
        engine: Engine
    ) async throws -> String {
        guard try await engine.tokenCount(for: value) > maxTokens else { return value }
        let characters = Array(value)
        var lowerBound = 0
        var upperBound = characters.count
        while lowerBound < upperBound {
            let count = (lowerBound + upperBound + 1) / 2
            let candidate = keepingSuffix
                ? String(characters.suffix(count))
                : String(characters.prefix(count))
            if try await engine.tokenCount(for: candidate) <= maxTokens {
                lowerBound = count
            } else {
                upperBound = count - 1
            }
        }
        return keepingSuffix
            ? String(characters.suffix(lowerBound))
            : String(characters.prefix(lowerBound))
    }

    /// 空白や句読点だけ（例: "…" / "..."）は、会話の本文として成立していない。
    /// これを成功扱いするとStory側の補正が同じ場面描写を足してしまうため、
    /// runtime段階で失敗として返し、再試行・NAGI切替の正しい導線へ流す。
    nonisolated private func hasMeaningfulResponseText(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            scalar.properties.isAlphabetic || scalar.properties.numericType != nil
        }
    }
#endif
#endif
}
