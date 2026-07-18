/*
仕様:
- 役割: iOS 向け LiteRT-LM 推論経路の薄いアダプタ。
- 主な型: `LocalAssistantLiteRTLMRuntime`.
- 編集ポイント: Google AI Edge LiteRT-LM の iOS SDK / ネイティブバイナリを接続したら
  `isRuntimeLinked` と `generate(...)` の中身を差し替える。
*/
import Foundation
// LiteRT-LM integration enforcement (optional):
// Define -DUSE_LITERTLM in the iOS target's "Other Swift Flags" to require the SDK at build time.
// Define -DVIUK_ENABLE_LITERTLM_NATIVE only when the native Engine init path is stable on real iOS devices.
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

struct LocalAssistantLiteRTLMRequest {
    let prompt: String
    let systemPrompt: String?
    let modelPath: String
    let maxTokens: Int
    let temperature: Float
    let topP: Float
    let topK: Int
    let seed: UInt32
}

private final class LiteRTLMResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var completed = false
    private var storedResult: VIUKEmbeddedRuntimeResult

    init(initialResult: VIUKEmbeddedRuntimeResult) {
        self.storedResult = initialResult
    }

    func finish(_ result: VIUKEmbeddedRuntimeResult) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        storedResult = result
        completed = true
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: DispatchTime) -> Bool {
        semaphore.wait(timeout: timeout) == .success
    }

    func snapshot() -> VIUKEmbeddedRuntimeResult {
        lock.lock()
        let result = storedResult
        lock.unlock()
        return result
    }
}

private final class LiteRTLMAsyncResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var storedResult: VIUKEmbeddedRuntimeResult?
    private var continuation: CheckedContinuation<VIUKEmbeddedRuntimeResult, Never>?

    func finish(_ result: VIUKEmbeddedRuntimeResult) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        storedResult = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }

    func wait() async -> VIUKEmbeddedRuntimeResult {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let storedResult {
                lock.unlock()
                continuation.resume(returning: storedResult)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

final class LocalAssistantLiteRTLMRuntime: @unchecked Sendable {
    static let shared = LocalAssistantLiteRTLMRuntime()

    private let executionLock = NSLock()

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
        return "LiteRT-LM native runtime はこのiOSビルドでは停止中です。Engine初期化で実機クラッシュするため、安定確認できるまでローカル実行に入りません。"
#endif
#else
        return "LiteRT-LM runtime はこのビルドに含まれていません。"
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
        if let reason = preflightFailureReason(forModelPath: modelPath) {
            return VIUKEmbeddedRuntimeResult(
                success: false,
                text: nil,
                errorMessage: reason
            )
        }

        return await generateAsync(
            LocalAssistantLiteRTLMRequest(
                prompt: "これは Gemma 4 E2B LiteRT-LM runtime check です。必ず `ok` とだけ短く返答してください。",
                systemPrompt: "あなたは VIUK AI tiny の LiteRT-LM runtime check です。出力は必ず `ok` のみです。",
                modelPath: modelPath,
                maxTokens: 16,
                temperature: 0,
                topP: 0.9,
                topK: 20,
                seed: 7
            )
        )
    }

    nonisolated func performSelfCheck(modelPath: String) -> VIUKEmbeddedRuntimeResult {
        if let reason = preflightFailureReason(forModelPath: modelPath) {
            return VIUKEmbeddedRuntimeResult(
                success: false,
                text: nil,
                errorMessage: reason
            )
        }

        return VIUKEmbeddedRuntimeResult(
            success: false,
            text: nil,
            errorMessage: "LiteRT-LM の起動確認は非同期 self-check で実行してください。同期起動はスマホの停止を避けるため無効です。"
        )
    }

    nonisolated func generateAsync(
        _ request: LocalAssistantLiteRTLMRequest,
        timeoutSeconds: TimeInterval = 60
    ) async -> VIUKEmbeddedRuntimeResult {
        if let reason = preflightFailureReason(forModelPath: request.modelPath) {
            return VIUKEmbeddedRuntimeResult(
                success: false,
                text: nil,
                errorMessage: reason
            )
        }

#if os(iOS) && !targetEnvironment(simulator) && VIUK_ENABLE_LITERTLM_NATIVE
#if canImport(LiteRTLM)
        return await runLiteRTLMAsync(request, timeoutSeconds: timeoutSeconds)
#else
        return VIUKEmbeddedRuntimeResult(
            success: false,
            text: nil,
            errorMessage: "LiteRT-LM runtime はこのビルドに含まれていません。"
        )
#endif
#else
        return VIUKEmbeddedRuntimeResult(
            success: false,
            text: nil,
            errorMessage: "LiteRT-LM runtime はこのビルドに含まれていません。"
        )
#endif
    }

    nonisolated func generate(_ request: LocalAssistantLiteRTLMRequest) -> VIUKEmbeddedRuntimeResult {
        if let reason = preflightFailureReason(forModelPath: request.modelPath) {
            return VIUKEmbeddedRuntimeResult(
                success: false,
                text: nil,
                errorMessage: reason
            )
        }

#if os(iOS) && !targetEnvironment(simulator) && VIUK_ENABLE_LITERTLM_NATIVE
#if canImport(LiteRTLM)
        return VIUKEmbeddedRuntimeResult(
            success: false,
            text: nil,
            errorMessage: "LiteRT-LM 生成は非同期入口で実行してください。同期起動はスマホの停止を避けるため無効です。"
        )
#else
        return VIUKEmbeddedRuntimeResult(
            success: false,
            text: nil,
            errorMessage: "LiteRT-LM runtime はこのビルドに含まれていません。"
        )
#endif
#else
        return VIUKEmbeddedRuntimeResult(
            success: false,
            text: nil,
            errorMessage: "LiteRT-LM runtime はこのビルドに含まれていません。"
        )
#endif
    }

#if os(iOS) && !targetEnvironment(simulator) && VIUK_ENABLE_LITERTLM_NATIVE
#if canImport(LiteRTLM)
    nonisolated private func runLiteRTLMAsync(
        _ request: LocalAssistantLiteRTLMRequest,
        timeoutSeconds: TimeInterval
    ) async -> VIUKEmbeddedRuntimeResult {
        guard executionLock.try() else {
            return VIUKEmbeddedRuntimeResult(
                success: false,
                text: nil,
                errorMessage: "LiteRT-LM runtime は別の生成を実行中です。完了後に再試行してください。"
            )
        }

        let resultBox = LiteRTLMAsyncResultBox()
        Task.detached(priority: .userInitiated) {
            defer { self.executionLock.unlock() }
            let result = await self.runLiteRTLMAttempt(request)
            resultBox.finish(result)
        }

        Task.detached(priority: .utility) {
            let nanoseconds = UInt64(max(timeoutSeconds, 1) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            resultBox.finish(VIUKEmbeddedRuntimeResult(
                success: false,
                text: nil,
                errorMessage: "LiteRT-LM runtime の起動がタイムアウトしました。生成タスクは停止処理中です。"
            ))
        }

        return await withTaskCancellationHandler {
            await resultBox.wait()
        } onCancel: {
            resultBox.finish(VIUKEmbeddedRuntimeResult(
                success: false,
                text: nil,
                errorMessage: "LiteRT-LM runtime の起動をキャンセルしました。"
            ))
        }
    }

    nonisolated private func runLiteRTLMAttempt(_ request: LocalAssistantLiteRTLMRequest) async -> VIUKEmbeddedRuntimeResult {
        do {
            let cacheURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("VIUKLiteRTLMCache", isDirectory: true)
            try? FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

            let sizedRequest = self.runtimeSizedRequest(request)
            let maxNumTokens = max(768, min(sizedRequest.maxTokens + 768, 2048))
            let cpuThreadCount = min(max(ProcessInfo.processInfo.activeProcessorCount / 2, 2), 4)
            var lastError: Error?

            do {
                let text = try await self.generateText(
                    sizedRequest,
                    backend: .gpu,
                    maxNumTokens: maxNumTokens,
                    cachePath: cacheURL.path
                )
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return VIUKEmbeddedRuntimeResult(
                    success: !cleaned.isEmpty,
                    text: cleaned.isEmpty ? nil : cleaned,
                    errorMessage: cleaned.isEmpty ? "LiteRT-LM runtime の応答が空でした。" : nil
                )
            } catch {
                lastError = error
            }

            do {
                let text = try await self.generateText(
                    sizedRequest,
                    backend: .cpu(threadCount: cpuThreadCount),
                    maxNumTokens: maxNumTokens,
                    cachePath: cacheURL.path
                )
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return VIUKEmbeddedRuntimeResult(
                    success: !cleaned.isEmpty,
                    text: cleaned.isEmpty ? nil : cleaned,
                    errorMessage: cleaned.isEmpty ? "LiteRT-LM runtime の応答が空でした。" : nil
                )
            } catch {
                lastError = error
            }

            return VIUKEmbeddedRuntimeResult(
                success: false,
                text: nil,
                errorMessage: "LiteRT-LM runtime error: \(lastError?.localizedDescription ?? "unknown error")。GPU から CPU へ切り替えても初期化できませんでした。"
            )
        }
    }

	    nonisolated private func runLiteRTLM(_ request: LocalAssistantLiteRTLMRequest) -> VIUKEmbeddedRuntimeResult {
        guard executionLock.try() else {
            return VIUKEmbeddedRuntimeResult(
                success: false,
                text: nil,
                errorMessage: "LiteRT-LM runtime は別の生成を実行中です。完了後に再試行してください。"
            )
        }
        defer { executionLock.unlock() }

        let resultBox = LiteRTLMResultBox(initialResult: VIUKEmbeddedRuntimeResult(
            success: false,
            text: nil,
            errorMessage: "LiteRT-LM runtime が応答しませんでした。"
        ))

        Task.detached(priority: .userInitiated) {
            do {
                let cacheURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("VIUKLiteRTLMCache", isDirectory: true)
                try? FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

                let sizedRequest = self.runtimeSizedRequest(request)
                let maxNumTokens = max(768, min(sizedRequest.maxTokens + 768, 2048))
                let cpuThreadCount = min(max(ProcessInfo.processInfo.activeProcessorCount / 2, 2), 4)
                var lastError: Error?

                do {
                    let text = try await self.generateText(
                        sizedRequest,
                        backend: .gpu,
                        maxNumTokens: maxNumTokens,
                        cachePath: cacheURL.path
                    )
                    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    resultBox.finish(VIUKEmbeddedRuntimeResult(
                        success: !cleaned.isEmpty,
                        text: cleaned.isEmpty ? nil : cleaned,
                        errorMessage: cleaned.isEmpty ? "LiteRT-LM runtime の応答が空でした。" : nil
                    ))
                    return
                } catch {
                    lastError = error
                }

                do {
                    let text = try await self.generateText(
                        sizedRequest,
                        backend: .cpu(threadCount: cpuThreadCount),
                        maxNumTokens: maxNumTokens,
                        cachePath: cacheURL.path
                    )
                    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    resultBox.finish(VIUKEmbeddedRuntimeResult(
                        success: !cleaned.isEmpty,
                        text: cleaned.isEmpty ? nil : cleaned,
                        errorMessage: cleaned.isEmpty ? "LiteRT-LM runtime の応答が空でした。" : nil
                    ))
                    return
                } catch {
                    lastError = error
                }

                resultBox.finish(VIUKEmbeddedRuntimeResult(
                    success: false,
                    text: nil,
                    errorMessage: "LiteRT-LM runtime error: \(lastError?.localizedDescription ?? "unknown error")。GPU から CPU へ切り替えても初期化できませんでした。"
                ))
            }
        }

        if !resultBox.wait(timeout: .now() + 60) {
            resultBox.finish(VIUKEmbeddedRuntimeResult(
                success: false,
                text: nil,
                errorMessage: "LiteRT-LM runtime の起動がタイムアウトしました。"
            ))
        }
        return resultBox.snapshot()
    }

	    nonisolated private func generateText(
        _ request: LocalAssistantLiteRTLMRequest,
        backend: Backend,
        maxNumTokens: Int,
        cachePath: String
    ) async throws -> String {
                let engineConfig = try EngineConfig(
                    modelPath: request.modelPath,
            backend: backend,
            maxNumTokens: maxNumTokens,
            cacheDir: cachePath
                )
                let engine = Engine(engineConfig: engineConfig)
                try await engine.initialize()
                let sampler = try SamplerConfig(
                    topK: max(request.topK, 1),
                    topP: max(0, min(request.topP, 1)),
                    temperature: max(request.temperature, 0),
                    seed: Int(request.seed)
                )
                let conversation = try await engine.createConversation(
                    with: ConversationConfig(
                        systemMessage: request.systemPrompt.map { Message($0, role: .system) },
                        samplerConfig: sampler
                    )
                )
                let response = try await conversation.sendMessage(
                    Message(request.prompt)
                )
        return response.toString
    }

	    nonisolated private func runtimeSizedRequest(_ request: LocalAssistantLiteRTLMRequest) -> LocalAssistantLiteRTLMRequest {
	        LocalAssistantLiteRTLMRequest(
	            prompt: clipped(request.prompt, maxCharacters: 6_000),
	            systemPrompt: request.systemPrompt.map { clipped($0, maxCharacters: 2_000) },
	            modelPath: request.modelPath,
	            maxTokens: min(request.maxTokens, 512),
	            temperature: request.temperature,
            topP: request.topP,
            topK: request.topK,
            seed: request.seed
        )
    }

	    nonisolated private func clipped(_ value: String, maxCharacters: Int) -> String {
        guard value.count > maxCharacters else { return value }
        let suffix = value.suffix(maxCharacters)
        return """
        以下は長すぎる文脈の末尾です。直近のユーザー質問を優先して答えてください。

        \(suffix)
        """
    }
#endif
#endif

    private func combinedPrompt(for request: LocalAssistantLiteRTLMRequest) -> String {
        guard let systemPrompt = request.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !systemPrompt.isEmpty else {
            return request.prompt
        }
        return """
        \(systemPrompt)

        ユーザー:
        \(request.prompt)
        """
    }
}
