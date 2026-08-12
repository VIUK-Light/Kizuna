/*
  LiteRT-LM adapter for iOS.

  This runtime deliberately starts on the CPU path.  It is still native
  on-device LiteRT-LM execution; CPU first avoids entering an iOS Metal
  accelerator before its framework packaging has been proven on the device.
*/
import Foundation
import CryptoKit

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

    /// Caller-owned turn identity used to scope native cancellation. A delayed
    /// cancel from turn A must never stop the newer conversation B.
    let generationID: UUID?

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
        preferGPU: Bool = false,
        generationID: UUID? = nil
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
        self.generationID = generationID
    }
}

#if os(iOS) && !targetEnvironment(simulator) && VIUK_ENABLE_LITERTLM_NATIVE
#if canImport(LiteRTLM)
private struct LiteRTLMEngineConfiguration: Equatable, Sendable {
    let modelPath: String
    let cacheDirectory: String
    let modelKey: String
    let modelIdentity: String
    let maxNumTokens: Int
}

/// `Conversation.sendMessage` はネイティブ推論中も戻らないため、SwiftのTask cancel
/// だけでは停止しない。現在のConversationを保持してSDKのcancelを直接呼ぶ。
private actor LiteRTLMActiveConversation {
    private var conversation: Conversation?
    private var generationID: UUID?
    // Keep cancellation requests by generation rather than silently dropping
    // a request just because another generation currently owns Conversation.
    // This includes work still waiting for the execution gate.
    private var inFlightGenerationIDs: Set<UUID> = []
    private var cancellationRequests: Set<UUID> = []
    // A caller can request cancellation immediately after creating its Swift
    // Task, before that task reaches `begin`. Keep those IDs bounded and move
    // one into `cancellationRequests` only when its generation actually starts.
    private var pendingGenerationCancellationIDs: [UUID] = []
    private var completedGenerationIDs: [UUID] = []
    private var unscopedGenerationCount = 0
    private var unscopedCancellationRequested = false
    private let completedGenerationHistoryLimit = 64
    private let pendingCancellationHistoryLimit = 64

    func begin(generationID: UUID?) {
        guard let generationID else {
            unscopedGenerationCount += 1
            return
        }
        inFlightGenerationIDs.insert(generationID)
        completedGenerationIDs.removeAll { $0 == generationID }
        if let pendingIndex = pendingGenerationCancellationIDs.firstIndex(of: generationID) {
            pendingGenerationCancellationIDs.remove(at: pendingIndex)
            cancellationRequests.insert(generationID)
        }
    }

    func finish(generationID: UUID?) {
        guard let generationID else {
            guard unscopedGenerationCount > 0 else { return }
            unscopedGenerationCount -= 1
            if unscopedGenerationCount == 0 {
                unscopedCancellationRequested = false
            }
            return
        }

        inFlightGenerationIDs.remove(generationID)
        cancellationRequests.remove(generationID)
        pendingGenerationCancellationIDs.removeAll { $0 == generationID }
        guard !completedGenerationIDs.contains(generationID) else { return }
        completedGenerationIDs.append(generationID)
        if completedGenerationIDs.count > completedGenerationHistoryLimit {
            completedGenerationIDs.removeFirst(
                completedGenerationIDs.count - completedGenerationHistoryLimit
            )
        }
    }

    func set(_ conversation: Conversation, generationID: UUID?) async {
        self.conversation = conversation
        self.generationID = generationID

        let shouldCancel = generationID.map { cancellationRequests.contains($0) }
            ?? unscopedCancellationRequested
        if shouldCancel {
            try? await conversation.cancel()
        }
    }

    func clear(_ conversation: Conversation) {
        if self.conversation === conversation {
            self.conversation = nil
            self.generationID = nil
        }
    }

    /// A supplied generation only cancels its own conversation. Nil is used by
    /// app lifecycle cancellation and intentionally cancels any active turn.
    func cancel(generationID requestedGenerationID: UUID? = nil) async {
        if let requestedGenerationID {
            // A cancellation task can be scheduled after the matching Swift
            // task has already returned. Remember recent completions so that
            // a stale request cannot be retained for a UUID that will never
            // run again.
            guard !completedGenerationIDs.contains(requestedGenerationID) else {
                return
            }
            if inFlightGenerationIDs.contains(requestedGenerationID) {
                cancellationRequests.insert(requestedGenerationID)
            } else {
                retainPendingCancellation(for: requestedGenerationID)
            }
            guard generationID == requestedGenerationID,
                  let activeConversation = conversation else {
                return
            }
            try? await activeConversation.cancel()
            return
        }

        for generationID in inFlightGenerationIDs {
            cancellationRequests.insert(generationID)
        }
        if unscopedGenerationCount > 0 {
            unscopedCancellationRequested = true
        }
        if let activeConversation = conversation {
            try? await activeConversation.cancel()
        }
    }

    func consumeCancellation(for requestedGenerationID: UUID?) -> Bool {
        if let requestedGenerationID {
            return cancellationRequests.remove(requestedGenerationID) != nil
        }
        // Every active unscoped generation must observe a lifecycle-level
        // cancellation. `finish` clears this only after the final one exits.
        return unscopedCancellationRequested
    }

    private func retainPendingCancellation(for generationID: UUID) {
        guard !pendingGenerationCancellationIDs.contains(generationID) else { return }
        pendingGenerationCancellationIDs.append(generationID)
        if pendingGenerationCancellationIDs.count > pendingCancellationHistoryLimit {
            pendingGenerationCancellationIDs.removeFirst(
                pendingGenerationCancellationIDs.count - pendingCancellationHistoryLimit
            )
        }
    }
}

private actor LiteRTLMEngineStore {
    private var engine: Engine?
    private var loadedConfiguration: LiteRTLMEngineConfiguration?
    private var reportedContextLimits: [String: Int] = [:]

    func reportedContextLimit(for modelKey: String) -> Int? {
        reportedContextLimits[modelKey]
    }

    func rememberReportedContextLimit(_ limit: Int, for modelKey: String) {
        reportedContextLimits[modelKey] = min(reportedContextLimits[modelKey] ?? limit, limit)
    }

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
        NSLog("[KizunaLiteRTLM] initializing CPU engine with %ld-token context", configuration.maxNumTokens)
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

private enum LiteRTLMTokenBudgetError: LocalizedError {
    case unableToFit(actual: Int, target: Int, context: Int)

    var errorDescription: String? {
        switch self {
        case let .unableToFit(actual, target, context):
            return "LiteRT-LM input could not fit the requested context budget (input=\(actual), target=\(target), context=\(context))."
        }
    }
}

final class LocalAssistantLiteRTLMRuntime: @unchecked Sendable {
    static let shared = LocalAssistantLiteRTLMRuntime()

    private enum Tuning {
        // Gemma 4 E2B's published iOS benchmark uses a 2,048-token context.
        nonisolated static let contextTokenLimit = 2_048
        // Gemma 4 E2B's compiled prefill tensors need a context at least as
        // large as their 1,024-token prefill shape. Keep the canary at the
        // same 2,048-token production context so it validates the path users
        // will actually run and the prepared Engine can be reused.
        nonisolated static let runtimeCheckContextTokenLimit = 2_048
        // Story turns need enough room for Gemma 4's native reasoning plus
        // a visible narration/dialogue pair. 512 cut the conversation short
        // before the model could reliably reach the answer channel.
        nonisolated static let maximumOutputTokens = 1_024
        nonisolated static let minimumOutputTokens = 64
        // A conservative byte budget preserves the most recent user context
        // without allowing a character-count-based prompt to overrun the KV cache.
        // 2,048-token KV cacheのうち、最大1,024 tokenを生成に残す。日本語では
        // UTF-8 byte数がほぼ文字数の3倍になるため、入力全体は約3KBへ収める。
        nonisolated static let maximumInputUTF8Bytes = 3_000
        nonisolated static let maximumSystemUTF8Bytes = 1_250
        nonisolated static let maximumHistoryMessages = 3
        nonisolated static let maximumHistoryMessageUTF8Bytes = 240
        nonisolated static let minimumPromptUTF8Bytes = 480
        // LiteRT-LMのモデルごとに実際の入力形状が異なるため、文字数だけで
        // 判断せず、モデル自身のtokenizerでこの値を超えないように再圧縮する。
        // これはコンテキスト全体の上限ではなく、会話1ターンの安全な入力目標。
        nonisolated static let safeInputTokenTarget = 960
        nonisolated static let minimumInputTokenTarget = 128
        // Engine.tokenCount measures raw text, while Conversation applies the
        // model's chat template to the system/history/user messages. Reserve
        // a conservative template budget for those rendered markers.
        nonisolated static let conversationTemplateTokenReserve = 256
        // Separate this cache from the earlier 512-token experiment so the
        // next launch compiles the official 2,048-token configuration fresh.
        nonisolated static let runtimeCacheVersion = "v0.14.0-cpu-baseline-1"
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
#if os(iOS) && !targetEnvironment(simulator) && VIUK_ENABLE_LITERTLM_NATIVE
#if canImport(LiteRTLM)
            await activeConversation.finish(generationID: request.generationID)
#endif
#endif
            return VIUKEmbeddedRuntimeResult(success: false, text: nil, errorMessage: reason)
        }

#if os(iOS) && !targetEnvironment(simulator) && VIUK_ENABLE_LITERTLM_NATIVE
#if canImport(LiteRTLM)
        // Do not race a timeout against native initialization.  A completed UI
        // timeout cannot safely cancel the C++ load, and starting another Engine
        // while it is still loading was one source of phone-side pressure.
        _ = timeoutSeconds
        await activeConversation.begin(generationID: request.generationID)
        if await consumeStopRequest(request) {
            await activeConversation.finish(generationID: request.generationID)
            return cancelledGenerationResult()
        }

        let acquired = await executionGate.acquire()
        guard acquired else {
            await activeConversation.finish(generationID: request.generationID)
            return cancelledGenerationResult()
        }
        let result = if await consumeStopRequest(request) {
            cancelledGenerationResult()
        } else {
            await runLiteRTLMAttempt(request)
        }
        await releaseExecutionSlotAndFinishGeneration(request)
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
    nonisolated func cancelActiveGeneration(generationID: UUID? = nil) {
#if os(iOS) && !targetEnvironment(simulator) && VIUK_ENABLE_LITERTLM_NATIVE
#if canImport(LiteRTLM)
        // Conversationとgeneration IDを同じactorで管理する。呼び出し側は
        // 同一actorへ順番にenqueueされるため、Aの取消しがBの登録と競合しない。
        Task { await activeConversation.cancel(generationID: generationID) }
#endif
#endif
    }

    /// アプリがバックグラウンドへ移った時だけモデルとKVキャッシュを解放する。
    /// 画面遷移では解放しないため、通常の会話継続の速度は保つ。
    nonisolated func releaseResourcesForBackground() {
#if os(iOS) && !targetEnvironment(simulator) && VIUK_ENABLE_LITERTLM_NATIVE
#if canImport(LiteRTLM)
        Task { await activeConversation.cancel() }
        Task(priority: .utility) {
            guard await executionGate.acquire() else { return }
            await engineStore.release()
            await executionGate.release()
        }
#endif
#endif
    }

#if os(iOS) && !targetEnvironment(simulator) && VIUK_ENABLE_LITERTLM_NATIVE
#if canImport(LiteRTLM)
    nonisolated private func cancelledGenerationResult() -> VIUKEmbeddedRuntimeResult {
        VIUKEmbeddedRuntimeResult(
            success: false,
            text: nil,
            errorMessage: "LiteRT-LM generation was cancelled."
        )
    }

    /// Consumes a generation-scoped cancellation request that may have arrived
    /// while another turn owned the native Conversation. Do not use this for a
    /// non-consuming status check.
    nonisolated private func consumeStopRequest(
        _ request: LocalAssistantLiteRTLMRequest
    ) async -> Bool {
        if Task.isCancelled {
            return true
        }
        return await activeConversation.consumeCancellation(for: request.generationID)
    }

    nonisolated private func releaseExecutionSlotAndFinishGeneration(
        _ request: LocalAssistantLiteRTLMRequest
    ) async {
        await executionGate.release()
        await activeConversation.finish(generationID: request.generationID)
    }

    nonisolated private func runLiteRTLMAttempt(
        _ request: LocalAssistantLiteRTLMRequest
    ) async -> VIUKEmbeddedRuntimeResult {
        if await consumeStopRequest(request) {
            return cancelledGenerationResult()
        }
        let modelKey = modelCacheKey(for: request.modelPath)
        let defaultContextTokenLimit = request.isRuntimeCheck
            ? Tuning.runtimeCheckContextTokenLimit
            : Tuning.contextTokenLimit
        let requestedContextTokenLimit = defaultContextTokenLimit
        var contextTokenLimit = await engineStore.reportedContextLimit(for: modelKey)
            ?? requestedContextTokenLimit
        if await consumeStopRequest(request) {
            return cancelledGenerationResult()
        }
        var configuration = engineConfiguration(
            for: request.modelPath,
            isRuntimeCheck: request.isRuntimeCheck,
            contextTokenLimitOverride: contextTokenLimit
        )

        // A compiled model can reject a prompt with a smaller limit than the
        // app requested in EngineConfig. If the native error exposes that
        // limit, rebuild the engine once with the model-reported value instead
        // of retrying the same oversized request.
        for attempt in 0..<2 {
            if await consumeStopRequest(request) {
                return cancelledGenerationResult()
            }
            do {
                return try await runLiteRTLMSingleAttempt(
                    request,
                    configuration: configuration,
                    contextTokenLimit: contextTokenLimit,
                    requestedContextTokenLimit: requestedContextTokenLimit
                )
            } catch {
                let cancellationRequested = await consumeStopRequest(request)
                if cancellationRequested {
                    return cancelledGenerationResult()
                }
                // LiteRT-LM currently reports a cancelled native turn through
                // the same `.invalidResponse(String)` channel as other native
                // failures. Treat it as cancellation only when this runtime
                // recorded a stop request; otherwise preserve the real error
                // and invalidate the engine instead of inferring from text.
                if attempt == 0,
                   let reportedLimit = LocalAssistantLiteRTLMContextLimit
                    .reportedMaximumTokenCount(from: error.localizedDescription),
                   reportedLimit >= 256,
                   reportedLimit < contextTokenLimit {
                    NSLog(
                        "[KizunaLiteRTLM] model reported context limit=%d; app requested=%d; retrying with reported limit",
                        reportedLimit,
                        contextTokenLimit
                    )
                    await engineStore.rememberReportedContextLimit(
                        reportedLimit,
                        for: configuration.modelKey
                    )
                    await engineStore.invalidate(configuration: configuration)
                    contextTokenLimit = reportedLimit
                    configuration = engineConfiguration(
                        for: request.modelPath,
                        isRuntimeCheck: request.isRuntimeCheck,
                        contextTokenLimitOverride: contextTokenLimit
                    )
                    continue
                }

                if let budgetError = error as? LiteRTLMTokenBudgetError {
                    return VIUKEmbeddedRuntimeResult(
                        success: false,
                        text: nil,
                        errorMessage: budgetError.localizedDescription
                    )
                }
                NSLog("[KizunaLiteRTLM] native CPU turn failed: %@", error.localizedDescription)
                await engineStore.invalidate(configuration: configuration)
                return VIUKEmbeddedRuntimeResult(
                    success: false,
                    text: nil,
                    errorMessage: "LiteRT-LM runtime error: \(error.localizedDescription)"
                )
            }
        }

        return VIUKEmbeddedRuntimeResult(
            success: false,
            text: nil,
            errorMessage: "LiteRT-LM runtime could not determine a safe context budget."
        )
    }

    nonisolated private func runLiteRTLMSingleAttempt(
        _ request: LocalAssistantLiteRTLMRequest,
        configuration: LiteRTLMEngineConfiguration,
        contextTokenLimit: Int,
        requestedContextTokenLimit: Int
    ) async throws -> VIUKEmbeddedRuntimeResult {
        if await consumeStopRequest(request) {
            return cancelledGenerationResult()
        }
        var sizedRequest = runtimeSizedRequest(request)
        let modelName = URL(fileURLWithPath: sizedRequest.modelPath).lastPathComponent
        let promptBytes = sizedRequest.prompt.lengthOfBytes(using: .utf8)
        let systemBytes = sizedRequest.systemPrompt?.lengthOfBytes(using: .utf8) ?? 0
        let historyBytes = sizedRequest.initialMessages.reduce(0) {
            $0 + $1.text.lengthOfBytes(using: .utf8)
        }
        let inputBytes = promptBytes + systemBytes + historyBytes
        NSLog(
            "[KizunaLiteRTLM] starting native CPU turn (model=%@, requestedContext=%ld, appliedContext=%ld, input=%ld bytes, prompt=%ld, system=%ld, history=%ld, output<=%ld)",
            modelName,
            requestedContextTokenLimit,
            contextTokenLimit,
            inputBytes,
            promptBytes,
            systemBytes,
            historyBytes,
            sizedRequest.maxTokens
        )
        let engine = try await engineStore.engine(for: configuration)
        if await consumeStopRequest(request) {
            return cancelledGenerationResult()
        }
        sizedRequest = try await fitRequestToTokenBudget(
            sizedRequest,
            engine: engine,
            contextTokenLimit: contextTokenLimit
        )
        if await consumeStopRequest(request) {
            return cancelledGenerationResult()
        }
        let sampler = try SamplerConfig(
            topK: max(sizedRequest.topK, 1),
            topP: max(0, min(sizedRequest.topP, 1)),
            temperature: max(sizedRequest.temperature, 0),
            seed: Int(sizedRequest.seed)
        )
        let initialMessages = sizedRequest.initialMessages.map { message -> Message in
            switch message.role {
            case .user:
                return Message(message.text, role: .user)
            case .model:
                return Message(message.text, role: .model)
            }
        }
        NSLog(
            "[KizunaLiteRTLM] creating conversation (context=%ld, system=%ld bytes, historyMessages=%ld)",
            contextTokenLimit,
            systemBytes,
            initialMessages.count
        )
        let conversation = try await engine.createConversation(
            with: ConversationConfig(
                systemMessage: sizedRequest.systemPrompt.map { Message($0, role: .system) },
                initialMessages: initialMessages,
                samplerConfig: sampler,
                maxOutputTokens: sizedRequest.maxTokens
            )
        )
        await activeConversation.set(conversation, generationID: sizedRequest.generationID)
        if await consumeStopRequest(request) {
            await activeConversation.clear(conversation)
            return cancelledGenerationResult()
        }
        NSLog("[KizunaLiteRTLM] conversation ready; sending message")
        let response: Message
        do {
            response = try await conversation.sendMessage(Message(sizedRequest.prompt))
        } catch {
            await activeConversation.clear(conversation)
            throw error
        }
        let cancellationRequested = await consumeStopRequest(request)
        await activeConversation.clear(conversation)
        if cancellationRequested {
            return cancelledGenerationResult()
        }
        let cleaned = response.toString.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasMeaningfulText = hasMeaningfulResponseText(cleaned)
        // 本文や個人情報はログへ出さない。LiteRT-LM側で停止理由を取得できないため、
        // その事実を明示しつつ、後段の StorySession が保存IDと照合できる長さだけ記録する。
        NSLog(
            "[KizunaLiteRTLM] native CPU turn finished (context=%ld, empty=%@, meaningful=%@, chars=%ld, stopReason=unavailable)",
            contextTokenLimit,
            cleaned.isEmpty ? "true" : "false",
            hasMeaningfulText ? "true" : "false",
            cleaned.count
        )
        return VIUKEmbeddedRuntimeResult(
            success: hasMeaningfulText,
            text: hasMeaningfulText ? cleaned : nil,
            errorMessage: cleaned.isEmpty
                ? "LiteRT-LM runtime の応答が空でした。"
                : "LiteRT-LM runtime が記号だけの応答を返しました。"
        )
    }

    nonisolated private func engineConfiguration(
        for modelPath: String,
        isRuntimeCheck: Bool,
        contextTokenLimitOverride: Int? = nil
    ) -> LiteRTLMEngineConfiguration {
        let modelKey = modelCacheKey(for: modelPath)
        let contextTokenLimit = contextTokenLimitOverride ?? (isRuntimeCheck
            ? Tuning.runtimeCheckContextTokenLimit
            : Tuning.contextTokenLimit)
        let modelIdentity = "\(modelKey)-ctx\(contextTokenLimit)"
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
            modelKey: modelKey,
            modelIdentity: modelIdentity,
            maxNumTokens: contextTokenLimit
        )
    }

    nonisolated private func modelCacheKey(for modelPath: String) -> String {
        let modelURL = URL(fileURLWithPath: modelPath)
        let attributes = (try? FileManager.default.attributesOfItem(atPath: modelPath)) ?? [:]
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let fileName = modelURL.deletingPathExtension().lastPathComponent
        let safeName = fileName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let normalizedPath = modelURL.standardizedFileURL.path
        let pathDigest = SHA256.hash(data: Data(normalizedPath.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(safeName.isEmpty ? "model" : safeName)-\(size)-\(Int(modifiedAt))-\(pathDigest)"
    }

    /// LiteRT-LMの内部tokenizerで、system・履歴・今回の入力を実測する。
    /// 日本語ではUTF-8バイト数とtoken数の比率がモデルにより変わるため、
    /// 固定byte上限だけでは「1937 >= 1280」のような実機エラーを防げない。
    /// Conversationのモデル固有テンプレート分は、保守的な予約枠を別に残す。
    nonisolated private func fitRequestToTokenBudget(
        _ request: LocalAssistantLiteRTLMRequest,
        engine: Engine,
        contextTokenLimit: Int
    ) async throws -> LocalAssistantLiteRTLMRequest {
        var candidate = request
        let safetyMargin = 32
        let templateReserve = Tuning.conversationTemplateTokenReserve
        let minimumOutputTokenCount = candidate.isRuntimeCheck
            ? 1
            : Tuning.minimumOutputTokens
        let maximumInputCapacity = contextTokenLimit
            - minimumOutputTokenCount
            - safetyMargin
            - templateReserve
        guard maximumInputCapacity >= Tuning.minimumInputTokenTarget else {
            throw LiteRTLMTokenBudgetError.unableToFit(
                actual: maximumInputCapacity,
                target: Tuning.minimumInputTokenTarget,
                context: contextTokenLimit
            )
        }

        let maximumOutputTokenCount = contextTokenLimit
            - Tuning.minimumInputTokenTarget
            - safetyMargin
            - templateReserve
        guard maximumOutputTokenCount >= minimumOutputTokenCount else {
            throw LiteRTLMTokenBudgetError.unableToFit(
                actual: maximumOutputTokenCount,
                target: minimumOutputTokenCount,
                context: contextTokenLimit
            )
        }
        let adjustedOutputTokenCount = min(candidate.maxTokens, maximumOutputTokenCount)
        guard adjustedOutputTokenCount >= minimumOutputTokenCount else {
            throw LiteRTLMTokenBudgetError.unableToFit(
                actual: adjustedOutputTokenCount,
                target: minimumOutputTokenCount,
                context: contextTokenLimit
            )
        }
        if adjustedOutputTokenCount != candidate.maxTokens {
            candidate = LocalAssistantLiteRTLMRequest(
                prompt: candidate.prompt,
                systemPrompt: candidate.systemPrompt,
                modelPath: candidate.modelPath,
                maxTokens: adjustedOutputTokenCount,
                temperature: candidate.temperature,
                topP: candidate.topP,
                topK: candidate.topK,
                seed: candidate.seed,
                initialMessages: candidate.initialMessages,
                isRuntimeCheck: candidate.isRuntimeCheck,
                preferGPU: candidate.preferGPU,
                generationID: candidate.generationID
            )
        }
        let target = min(
            Tuning.safeInputTokenTarget,
            contextTokenLimit
                - candidate.maxTokens
                - safetyMargin
                - templateReserve
        )
        guard target >= Tuning.minimumInputTokenTarget else {
            throw LiteRTLMTokenBudgetError.unableToFit(
                actual: target,
                target: Tuning.minimumInputTokenTarget,
                context: contextTokenLimit
            )
        }

        for attempt in 0..<8 {
            let tokenCount = try await engine.tokenCount(for: tokenProbeText(for: candidate))
            NSLog(
                "[KizunaLiteRTLM] token budget probe attempt=%d input=%d target<=%d context=%d",
                attempt + 1,
                tokenCount,
                target,
                contextTokenLimit
            )
            if tokenCount <= target {
                return candidate
            }

            let ratio = max(0.28, min(0.82, Double(target) / Double(max(tokenCount, 1)) * 0.9))
            let promptLimit = max(220, Int(Double(candidate.prompt.lengthOfBytes(using: .utf8)) * ratio))
            let systemLimit = candidate.systemPrompt.map {
                max(360, Int(Double($0.lengthOfBytes(using: .utf8)) * ratio))
            } ?? Tuning.maximumSystemUTF8Bytes
            let historyLimits = candidate.initialMessages.map {
                max(80, Int(Double($0.text.lengthOfBytes(using: .utf8)) * ratio))
            }

            candidate = LocalAssistantLiteRTLMRequest(
                prompt: clipped(candidate.prompt, maxUTF8Bytes: promptLimit, keepingTail: true),
                systemPrompt: candidate.systemPrompt.map {
                    clipped($0, maxUTF8Bytes: systemLimit, keepingTail: false)
                },
                modelPath: candidate.modelPath,
                maxTokens: candidate.maxTokens,
                temperature: candidate.temperature,
                topP: candidate.topP,
                topK: candidate.topK,
                seed: candidate.seed,
                initialMessages: candidate.initialMessages.enumerated().map { index, message in
                    LocalAssistantLiteRTLMHistoryMessage(
                        role: message.role,
                        text: clipped(message.text, maxUTF8Bytes: historyLimits[index], keepingTail: true)
                    )
                },
                isRuntimeCheck: candidate.isRuntimeCheck,
                preferGPU: false,
                generationID: candidate.generationID
            )
        }

        // 8回圧縮してもモデルのtokenizerが目標を超える場合は送信しない。
        // これを返してしまうと、モデル側の実コンテキスト上限に対して
        // 「安全側に計算したつもり」の入力を再び送ってしまう。
        let finalCount = try await engine.tokenCount(for: tokenProbeText(for: candidate))
        NSLog("[KizunaLiteRTLM] token budget probe reached final input=%d target<=%d", finalCount, target)
        guard finalCount <= target else {
            throw LiteRTLMTokenBudgetError.unableToFit(
                actual: finalCount,
                target: target,
                context: contextTokenLimit
            )
        }
        return candidate
    }

    nonisolated private func tokenProbeText(for request: LocalAssistantLiteRTLMRequest) -> String {
        var pieces: [String] = []
        if let systemPrompt = request.systemPrompt, !systemPrompt.isEmpty {
            pieces.append("system\n" + systemPrompt)
        }
        for message in request.initialMessages {
            let role: String
            switch message.role {
            case .user: role = "user"
            case .model: role = "model"
            }
            pieces.append(role + "\n" + message.text)
        }
        pieces.append("user\n" + request.prompt)
        return pieces.joined(separator: "\n")
    }

    nonisolated private func runtimeSizedRequest(
        _ request: LocalAssistantLiteRTLMRequest
    ) -> LocalAssistantLiteRTLMRequest {
        let systemPrompt = request.systemPrompt.map {
            clipped($0, maxUTF8Bytes: Tuning.maximumSystemUTF8Bytes, keepingTail: false)
        }
        let systemByteCount = systemPrompt?.lengthOfBytes(using: .utf8) ?? 0
        let initialMessages = request.initialMessages
            .suffix(Tuning.maximumHistoryMessages)
            .map { message in
                LocalAssistantLiteRTLMHistoryMessage(
                    role: message.role,
                    text: clipped(message.text, maxUTF8Bytes: Tuning.maximumHistoryMessageUTF8Bytes, keepingTail: true)
                )
            }
        let historyByteCount = initialMessages.reduce(0) {
            $0 + $1.text.lengthOfBytes(using: .utf8)
        }
        let promptByteBudget = max(
            Tuning.minimumPromptUTF8Bytes,
            Tuning.maximumInputUTF8Bytes - systemByteCount - historyByteCount
        )
        return LocalAssistantLiteRTLMRequest(
            prompt: clipped(request.prompt, maxUTF8Bytes: promptByteBudget, keepingTail: true),
            systemPrompt: systemPrompt,
            modelPath: request.modelPath,
            maxTokens: request.isRuntimeCheck
                ? min(max(request.maxTokens, 1), 32)
                : min(max(request.maxTokens, Tuning.minimumOutputTokens), Tuning.maximumOutputTokens),
            temperature: request.temperature,
            topP: request.topP,
            topK: request.topK,
            seed: request.seed,
            initialMessages: initialMessages,
            isRuntimeCheck: request.isRuntimeCheck,
            preferGPU: false,
            generationID: request.generationID
        )
    }

    nonisolated private func clipped(
        _ value: String,
        maxUTF8Bytes: Int,
        keepingTail: Bool
    ) -> String {
        guard value.lengthOfBytes(using: .utf8) > maxUTF8Bytes else { return value }

        var bytes = 0
        var result = ""
        if keepingTail {
            for character in value.reversed() {
                let piece = String(character)
                let pieceBytes = piece.lengthOfBytes(using: .utf8)
                guard bytes + pieceBytes <= maxUTF8Bytes else { break }
                bytes += pieceBytes
                result = piece + result
            }
        } else {
            for character in value {
                let piece = String(character)
                let pieceBytes = piece.lengthOfBytes(using: .utf8)
                guard bytes + pieceBytes <= maxUTF8Bytes else { break }
                bytes += pieceBytes
                result += piece
            }
        }

        if keepingTail {
            return "（長い文脈は直近の内容を優先しています）\n\n\(result)"
        }
        return "\(result)\n\n（ここまでが重要な前提です）"
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
