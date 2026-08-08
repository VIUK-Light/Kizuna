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
            let modelName = URL(fileURLWithPath: sizedRequest.modelPath).lastPathComponent
            NSLog("[KizunaLiteRTLM] starting native CPU turn (model=%@, input=%d bytes, output<=%d)", modelName, sizedRequest.prompt.lengthOfBytes(using: .utf8), sizedRequest.maxTokens)
            let engine = try await engineStore.engine(for: configuration)
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
            NSLog("[KizunaLiteRTLM] creating conversation (system=%d bytes, history=%d)", sizedRequest.systemPrompt?.lengthOfBytes(using: .utf8) ?? 0, initialMessages.count)
            let conversation = try await engine.createConversation(
                with: ConversationConfig(
                    systemMessage: sizedRequest.systemPrompt.map { Message($0, role: .system) },
                    initialMessages: initialMessages,
                    samplerConfig: sampler,
                    maxOutputTokens: sizedRequest.maxTokens
                )
            )
            activeConversation.set(conversation)
            defer { activeConversation.clear(conversation) }
            NSLog("[KizunaLiteRTLM] conversation ready; sending message")
            let response = try await conversation.sendMessage(Message(sizedRequest.prompt))
            let cleaned = response.toString.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasMeaningfulText = hasMeaningfulResponseText(cleaned)
            // 本文や個人情報はログへ出さない。LiteRT-LM側で停止理由を取得できないため、
            // その事実を明示しつつ、後段の StorySession が保存IDと照合できる長さだけ記録する。
            NSLog("[KizunaLiteRTLM] native CPU turn finished (empty=%@, meaningful=%@, chars=%d, stopReason=unavailable)", cleaned.isEmpty ? "true" : "false", hasMeaningfulText ? "true" : "false", cleaned.count)
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
            preferGPU: false
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
