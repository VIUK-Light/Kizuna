/*
仕様:
- 役割: ペルソナチャットの送信・ストリーミング受信・履歴更新を担う。AICoachService とは独立し、
  ペルソナモードの会話だけを扱う。バックエンドは LocalAssistantRuntimeBridge.generateReply を
  reasoningMode: .persona で呼び出す。
- 主な型: `PersonaChatService` (ObservableObject, MainActor)。
- 編集ポイント: 履歴の渡し方、max_tokens、ストリーミング差分の扱い、安全用 advancedSettings を変えるときに触る。
*/

import Foundation
import Combine

/// Defines which Persona output may cross the history persistence boundary.
/// The Story pipeline has the same contract, but this local policy keeps the
/// Persona fix independent so it can be merged without changing Story's PR.
enum PersonaOutputSafetyPolicy {
    /// Only a runtime-completed reply may cross into the output-safety stage.
    /// A nil/empty result means the runtime failed, timed out, or was
    /// cancelled; the last visible stream preview must never be promoted to
    /// a completed assistant message.
    static func completedText(from reply: String?) -> String? {
        guard let reply else { return nil }
        let sanitized = PersonaResponseSanitizer.sanitize(reply)
        let cleaned = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let placeholders: Set<String> = ["…", "・・・", "・・", "...", "..", "."]
        guard !placeholders.contains(cleaned) else { return nil }
        return sanitized
    }

    /// Safety rewrites come from a separate pipeline and must cross the same
    /// protocol/reasoning sanitization boundary as runtime output before they
    /// can be displayed or persisted.
    static func sanitizedRewrite(_ rewritten: String?) -> String? {
        guard let completed = completedText(from: rewritten) else { return nil }
        let trimmed = completed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func persistableText(
        action: SafetyAction,
        original: String,
        rewritten: String?
    ) -> String? {
        switch action {
        case .block, .requireEdit:
            return nil
        case .soften:
            return sanitizedRewrite(rewritten)
        case .allow, .warn:
            return original
        }
    }
}

/// Persona can use the same local/API generation families as Story while
/// keeping its persisted preference separate from Story worlds.
enum PersonaGenerationModel: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case local
    case nagi

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local: return "iori"
        case .nagi: return "NAGI"
        }
    }

    var localizedDisplayName: String {
        switch self {
        case .local:
            return KizunaCopy.text(japanese: "iori（端末内）", english: "iori (on device)")
        case .nagi:
            return KizunaCopy.text(japanese: "NAGI（Gemma API）", english: "NAGI (Gemma API)")
        }
    }

    var isAvailable: Bool {
        switch self {
        case .local:
            return LocalAssistantModelManager.shared.runtimeAvailability == .executable
        case .nagi:
            return StoryGemma31BAPIService.shared.availability.isUsable
        }
    }
}

/// The small runtime surface Persona needs. Keeping this separate from the
/// large runtime bridge makes completion, cancellation, and watchdog paths
/// deterministic in tests without changing the production runtime.
protocol PersonaReplyGenerating: AnyObject {
    func generatePersonaReply(
        prompt: String,
        contextPrompt: String?,
        coachMode: AICoachService.CoachMode,
        reasoningMode: ReasoningMode,
        childAge: Int,
        pageInfo: AICoachService.PageInfo?,
        safetySnapshot: AICoachService.SafetySnapshot?,
        advancedSettings: GemmaAdvancedSettings,
        overrideSystemPrompt: String?,
        generationID: UUID?,
        onUpdate: (@MainActor @Sendable (LocalAssistantStructuredTurnUpdate) -> Void)?
    ) async -> String?

    /// Same generation boundary with runtime provenance. The default keeps
    /// existing test doubles source-compatible while production runtimes can
    /// report the actual local artifact/provider model.
    func generatePersonaReplyResult(
        prompt: String,
        contextPrompt: String?,
        coachMode: AICoachService.CoachMode,
        reasoningMode: ReasoningMode,
        childAge: Int,
        pageInfo: AICoachService.PageInfo?,
        safetySnapshot: AICoachService.SafetySnapshot?,
        advancedSettings: GemmaAdvancedSettings,
        overrideSystemPrompt: String?,
        generationID: UUID?,
        onUpdate: (@MainActor @Sendable (LocalAssistantStructuredTurnUpdate) -> Void)?
    ) async -> LocalAssistantGenerationResult

    /// Route one Persona request through the selected model family. The
    /// default implementation preserves existing test doubles and provides a
    /// real NAGI adapter plus cross-family fallback for production.
    func generatePersonaReplyResult(
        prompt: String,
        contextPrompt: String?,
        coachMode: AICoachService.CoachMode,
        reasoningMode: ReasoningMode,
        childAge: Int,
        pageInfo: AICoachService.PageInfo?,
        safetySnapshot: AICoachService.SafetySnapshot?,
        advancedSettings: GemmaAdvancedSettings,
        overrideSystemPrompt: String?,
        generationID: UUID?,
        model: PersonaGenerationModel,
        onUpdate: (@MainActor @Sendable (LocalAssistantStructuredTurnUpdate) -> Void)?
    ) async -> LocalAssistantGenerationResult

    /// Generate through one exact registry configuration. This is used for
    /// conversation-local selections and deliberately does not fallback to a
    /// different provider.
    func generatePersonaReplyResult(
        prompt: String,
        contextPrompt: String?,
        coachMode: AICoachService.CoachMode,
        reasoningMode: ReasoningMode,
        childAge: Int,
        pageInfo: AICoachService.PageInfo?,
        safetySnapshot: AICoachService.SafetySnapshot?,
        advancedSettings: GemmaAdvancedSettings,
        overrideSystemPrompt: String?,
        generationID: UUID?,
        configurationID: UUID,
        onUpdate: (@MainActor @Sendable (LocalAssistantStructuredTurnUpdate) -> Void)?
    ) async -> LocalAssistantGenerationResult

    func cancelActiveGeneration(generationID: UUID?)
}

extension PersonaReplyGenerating {
    func generatePersonaReplyResult(
        prompt: String,
        contextPrompt: String?,
        coachMode: AICoachService.CoachMode,
        reasoningMode: ReasoningMode,
        childAge: Int,
        pageInfo: AICoachService.PageInfo?,
        safetySnapshot: AICoachService.SafetySnapshot?,
        advancedSettings: GemmaAdvancedSettings,
        overrideSystemPrompt: String?,
        generationID: UUID?,
        onUpdate: (@MainActor @Sendable (LocalAssistantStructuredTurnUpdate) -> Void)?
    ) async -> LocalAssistantGenerationResult {
        LocalAssistantGenerationResult(
            text: await generatePersonaReply(
                prompt: prompt,
                contextPrompt: contextPrompt,
                coachMode: coachMode,
                reasoningMode: reasoningMode,
                childAge: childAge,
                pageInfo: pageInfo,
                safetySnapshot: safetySnapshot,
                advancedSettings: advancedSettings,
                overrideSystemPrompt: overrideSystemPrompt,
                generationID: generationID,
                onUpdate: onUpdate
            ),
            modelIdentity: nil
        )
    }

    func generatePersonaReplyResult(
        prompt: String,
        contextPrompt: String?,
        coachMode: AICoachService.CoachMode,
        reasoningMode: ReasoningMode,
        childAge: Int,
        pageInfo: AICoachService.PageInfo?,
        safetySnapshot: AICoachService.SafetySnapshot?,
        advancedSettings: GemmaAdvancedSettings,
        overrideSystemPrompt: String?,
        generationID: UUID?,
        model: PersonaGenerationModel,
        onUpdate: (@MainActor @Sendable (LocalAssistantStructuredTurnUpdate) -> Void)?
    ) async -> LocalAssistantGenerationResult {
        let preservesAdvancedProviderBoundary = Self.preservesAdvancedProviderBoundary(
            AIModelTuningStore.shared.preferences
        )
        func generateThroughRegistry() async -> LocalAssistantGenerationResult? {
            // Preserve injected test/future runtimes. The shared production
            // bridge is the composition root that opts into the provider
            // registry; a fake should keep its own deterministic contract.
            guard self is LocalAssistantRuntimeBridge else { return nil }
            let providerID: AIProviderID = model == .nagi
                ? .googleGenerativeLanguage
                : .localRuntime
            let personaConfigurations = AIModelRegistry.shared.configurations(for: .persona)
            let preferred = AIModelTuningStore.shared.configurationIDForCurrentMode(
                for: .persona,
                configurations: personaConfigurations,
                fallbackProviderID: providerID
            )
            let combinedPrompt: String
            if let contextPrompt,
               !contextPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                combinedPrompt = contextPrompt + "\n\n" + prompt
            } else {
                combinedPrompt = prompt
            }
            let request = AIGenerationRequest(
                systemPrompt: overrideSystemPrompt ?? "",
                userPrompt: combinedPrompt,
                temperature: 0.72,
                maxOutputTokens: 1_024,
                onUpdate: onUpdate
            )
            guard let response = try? await AIModelRouter.shared.generate(
                request: request,
                role: .persona,
                preferredConfigurationID: preferred,
                allowsFallback: false
            ) else {
                return nil
            }
            return LocalAssistantGenerationResult(
                text: response.text,
                modelIdentity: response.identity.stableID
            )
        }

        if let routed = await generateThroughRegistry() {
            return routed
        }
        if preservesAdvancedProviderBoundary {
            // An Advanced UUID is an explicit provider boundary. A failed
            // registry request must not cross back into the legacy local/NAGI
            // family switch and silently change where the prompt is sent.
            return LocalAssistantGenerationResult(text: nil, modelIdentity: nil)
        }

        func generateNAGI() async -> LocalAssistantGenerationResult? {
            guard StoryGemma31BAPIService.shared.hasAPIKey else { return nil }
            let userPrompt: String
            if let contextPrompt, !contextPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                userPrompt = contextPrompt + "\n\n" + prompt
            } else {
                userPrompt = prompt
            }
            guard let generation = try? await StoryGemma31BAPIService.shared.generate(
                systemPrompt: overrideSystemPrompt ?? "",
                userPrompt: userPrompt,
                temperature: 0.72,
                maxOutputTokens: 1_024
            ) else {
                return nil
            }
            if let onUpdate {
                await onUpdate(.visiblePreview(generation.text))
            }
            return LocalAssistantGenerationResult(
                text: generation.text,
                modelIdentity: generation.identity.stableID
            )
        }

        func generateLocal() async -> LocalAssistantGenerationResult {
            await generatePersonaReplyResult(
                prompt: prompt,
                contextPrompt: contextPrompt,
                coachMode: coachMode,
                reasoningMode: reasoningMode,
                childAge: childAge,
                pageInfo: pageInfo,
                safetySnapshot: safetySnapshot,
                advancedSettings: advancedSettings,
                overrideSystemPrompt: overrideSystemPrompt,
                generationID: generationID,
                onUpdate: onUpdate
            )
        }

        switch model {
        case .local:
            return await generateLocal()
        case .nagi:
            return await generateNAGI()
                ?? LocalAssistantGenerationResult(text: nil, modelIdentity: nil)
        }
    }

    static func preservesAdvancedProviderBoundary(
        _ preferences: AIModelTuningPreferences
    ) -> Bool {
        preferences.mode == .advanced
            && preferences.preferredConfigurationID(for: .persona) != nil
    }

    func generatePersonaReplyResult(
        prompt: String,
        contextPrompt: String?,
        coachMode: AICoachService.CoachMode,
        reasoningMode: ReasoningMode,
        childAge: Int,
        pageInfo: AICoachService.PageInfo?,
        safetySnapshot: AICoachService.SafetySnapshot?,
        advancedSettings: GemmaAdvancedSettings,
        overrideSystemPrompt: String?,
        generationID: UUID?,
        configurationID: UUID,
        onUpdate: (@MainActor @Sendable (LocalAssistantStructuredTurnUpdate) -> Void)?
    ) async -> LocalAssistantGenerationResult {
        // Preserve injected test/future runtimes. The production bridge is
        // the composition root that opts into the provider registry.
        guard self is LocalAssistantRuntimeBridge else {
            return LocalAssistantGenerationResult(
                text: await generatePersonaReply(
                    prompt: prompt,
                    contextPrompt: contextPrompt,
                    coachMode: coachMode,
                    reasoningMode: reasoningMode,
                    childAge: childAge,
                    pageInfo: pageInfo,
                    safetySnapshot: safetySnapshot,
                    advancedSettings: advancedSettings,
                    overrideSystemPrompt: overrideSystemPrompt,
                    generationID: generationID,
                    onUpdate: onUpdate
                ),
                modelIdentity: nil
            )
        }

        let combinedPrompt: String
        if let contextPrompt,
           !contextPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            combinedPrompt = contextPrompt + "\n\n" + prompt
        } else {
            combinedPrompt = prompt
        }
        let request = AIGenerationRequest(
            systemPrompt: overrideSystemPrompt ?? "",
            userPrompt: combinedPrompt,
            temperature: 0.72,
            maxOutputTokens: 1_024,
            onUpdate: onUpdate
        )
        guard let response = try? await AIModelRouter.shared.generate(
            request: request,
            configurationID: configurationID,
            role: .persona
        ) else {
            return LocalAssistantGenerationResult(text: nil, modelIdentity: nil)
        }
        return LocalAssistantGenerationResult(
            text: response.text,
            modelIdentity: response.identity.stableID
        )
    }
}

extension LocalAssistantRuntimeBridge: PersonaReplyGenerating {
    func generatePersonaReplyResult(
        prompt: String,
        contextPrompt: String?,
        coachMode: AICoachService.CoachMode,
        reasoningMode: ReasoningMode,
        childAge: Int,
        pageInfo: AICoachService.PageInfo?,
        safetySnapshot: AICoachService.SafetySnapshot?,
        advancedSettings: GemmaAdvancedSettings,
        overrideSystemPrompt: String?,
        generationID: UUID?,
        onUpdate: (@MainActor @Sendable (LocalAssistantStructuredTurnUpdate) -> Void)?
    ) async -> LocalAssistantGenerationResult {
        await generateReply(
            prompt: prompt,
            contextPrompt: contextPrompt,
            coachMode: coachMode,
            reasoningMode: reasoningMode,
            researchMode: .off,
            childAge: childAge,
            pageInfo: pageInfo,
            safetySnapshot: safetySnapshot,
            advancedSettings: advancedSettings,
            overrideSystemPrompt: overrideSystemPrompt,
            generationID: generationID,
            onUpdate: onUpdate
        )
    }

    func generatePersonaReply(
        prompt: String,
        contextPrompt: String?,
        coachMode: AICoachService.CoachMode,
        reasoningMode: ReasoningMode,
        childAge: Int,
        pageInfo: AICoachService.PageInfo?,
        safetySnapshot: AICoachService.SafetySnapshot?,
        advancedSettings: GemmaAdvancedSettings,
        overrideSystemPrompt: String?,
        generationID: UUID?,
        onUpdate: (@MainActor @Sendable (LocalAssistantStructuredTurnUpdate) -> Void)?
    ) async -> String? {
        let result = await generateReply(
            prompt: prompt,
            contextPrompt: contextPrompt,
            coachMode: coachMode,
            reasoningMode: reasoningMode,
            researchMode: .off,
            childAge: childAge,
            pageInfo: pageInfo,
            safetySnapshot: safetySnapshot,
            advancedSettings: advancedSettings,
            overrideSystemPrompt: overrideSystemPrompt,
            generationID: generationID,
            onUpdate: onUpdate
        )
        return result.text
    }
}

@MainActor
final class PersonaChatService: ObservableObject {
    static let shared = PersonaChatService()

    enum Phase: Equatable {
        case idle
        case thinking
        case error(String)
    }

    struct GenerationFailure: Equatable {
        let message: String
        let requestText: String
    }

    struct GenerationCompletion: Equatable {
        let threadID: UUID
        let messageID: UUID
    }

    @Published private(set) var phase: Phase = .idle
    /// ストリーミング中の最新応答テキスト。完了時に PersonaChatStore に永続化される。
    @Published private(set) var streamingResponse: String = ""
    /// 生成中/失敗中の表示を現在のスレッドだけに紐付けるためのID。
    /// phase はサービス全体の状態なので、スレッド切替時にそのままUIへ使うと
    /// Aの生成表示がBへ伝播してしまう。
    @Published private(set) var activeGenerationThreadID: UUID?
    @Published private(set) var activeAssistantMessageID: UUID?
    @Published private(set) var lastErrorThreadID: UUID?
    /// 失敗と再試行本文はサービス全体で1件だけにせず、スレッドごとに保持する。
    @Published private(set) var generationFailures: [UUID: GenerationFailure] = [:]
    @Published private(set) var lastCompletedGeneration: GenerationCompletion?
    @Published private(set) var cancelledRequests: [UUID: String] = [:]
    @Published private(set) var memorySaveError: String?
    @Published var generationModel: PersonaGenerationModel {
        didSet {
            UserDefaults.standard.set(generationModel.rawValue, forKey: Self.generationModelKey)
        }
    }

    private static let generationModelKey = "persona.generationModel"

    private var generationTask: Task<Void, Never>?
    private var pendingMemoryTask: Task<Void, Never>? = nil
    private var pendingMemoryTaskID: UUID? = nil
    private var pendingMemoryCharacterID: UUID? = nil
    private var pendingMemorySaves: [UUID: [CharacterMemory]] = [:]
    private var streamSanitizationTask: Task<Void, Never>?
    /// A later runtime preview always supersedes a prior cumulative preview.
    /// This prevents a slow background sanitizer result from overwriting the
    /// newest text after it returns to the main actor.
    private var streamPreviewRevision = 0
    private var activeGenerationID: UUID?
    private var activeThreadID: UUID?
    private var lastRequestThreadID: UUID?
    private var lastRequestText: String?
    private var activeRequestText: String?

    private let runtime: PersonaReplyGenerating
    private let store: PersonaChatStore
    private let watchdogNanoseconds: UInt64

    init(
        runtime: PersonaReplyGenerating = LocalAssistantRuntimeBridge.shared,
        store: PersonaChatStore = PersonaChatStore.shared,
        safetyPipeline: SafetyPipeline = SafetyPipeline.shared,
        characterRepo: CharacterRepository = LocalJSONCharacterRepository(),
        memoryRepo: MemoryRepository = LocalJSONMemoryRepository(),
        smallClassifier: SmallModelClassifying? = nil,
        memorySelector: MemorySelecting? = nil,
        memorySummarizer: MemorySummarizing? = nil,
        watchdogNanoseconds: UInt64 = 75_000_000_000
    ) {
        self.generationModel = UserDefaults.standard.string(forKey: Self.generationModelKey)
            .flatMap(PersonaGenerationModel.init(rawValue:)) ?? .local
        self.runtime = runtime
        self.store = store
        self.safetyPipeline = safetyPipeline
        self.characterRepo = characterRepo
        self.memoryRepo = memoryRepo
        self.smallClassifier = smallClassifier ?? RuntimeSmallModelClassifier()
        self.memorySelector = memorySelector ?? RuntimeMemorySelector()
        self.memorySummarizer = memorySummarizer ?? RuntimeMemorySummarizer()
        self.watchdogNanoseconds = watchdogNanoseconds
    }

    /// 指定スレッドにユーザー発話を追加し、Gemma 4 のペルソナモードで応答を生成する。
    // MARK: - Character Library pipeline dependencies
    /// 既存挙動を壊さないために、スレッドに characterID が紐付いている場合だけ使う。
    private let characterRepo: CharacterRepository
    private let memoryRepo: MemoryRepository
    private let safetyPipeline: SafetyPipeline
    private let smallClassifier: SmallModelClassifying
    private let memorySelector: MemorySelecting
    private let memorySummarizer: MemorySummarizing
    private let promptBuilder = PromptBuilder()

    @discardableResult
    func send(_ userText: String, to thread: PersonaThread) -> Bool {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard phase != .thinking else { return false }
        // PersonaChatStore deliberately blocks all mutations while corrupt
        // history recovery is required. Do not start a generation that can
        // never persist its user turn or final assistant reply.
        guard !store.isPersistenceRecoveryRequired else { return false }

        // 旧バージョンが残したpending assistant枠を先に整理する。
        // 新しい生成ではユーザー発話だけを先に保存し、assistant本文はSafety評価を通過した
        // 完成時にだけ追加し、アプリ終了やキャンセルで未確定の空枠を残さない。
        store.removePendingAssistantMessage(in: thread.id)
        if cancelledRequests[thread.id] == trimmed,
           let storedThread = store.thread(id: thread.id),
           storedThread.messages.last?.role == .user,
           storedThread.messages.last?.text == trimmed {
            store.removeLastUserMessage(in: thread.id, matching: trimmed)
        }
        guard store.appendMessage(
            PersonaMessage(role: .user, text: trimmed),
            toThread: thread.id
        ) else { return false }
        let assistantMessageID = UUID()

        phase = .thinking
        streamingResponse = ""
        lastCompletedGeneration = nil
        generationFailures.removeValue(forKey: thread.id)
        cancelledRequests.removeValue(forKey: thread.id)
        lastErrorThreadID = nil
        invalidatePendingStreamSanitization()
        lastRequestThreadID = thread.id
        lastRequestText = trimmed
        activeRequestText = trimmed
        let generationID = UUID()
        let selectedGenerationModel = thread.preferredGenerationModel ?? generationModel
        let selectedConfigurationID = thread.preferredGenerationConfigurationID
        activeGenerationID = generationID
        activeThreadID = thread.id
        activeAssistantMessageID = assistantMessageID
        activeGenerationThreadID = thread.id

        if let charID = thread.characterID {
            // 新パス: キャラライブラリー由来のスレッド → 安全 + メモリーパイプライン
            generationTask = Task { [weak self] in
                await self?.runCharacterPipeline(
                    threadID: thread.id,
                    characterID: charID,
                    userText: trimmed,
                    generationID: generationID,
                    generationModel: selectedGenerationModel,
                    configurationID: selectedConfigurationID
                )
            }
        } else {
            // 旧パス: PersonaSettings由来のスレッド → 既存ストリーミングのまま
            generationTask = Task { [weak self, threadID = thread.id] in
                await self?.runLegacyPersonaGeneration(
                    threadID: threadID,
                    userText: trimmed,
                    generationID: generationID,
                    generationModel: selectedGenerationModel,
                    configurationID: selectedConfigurationID
                )
            }
        }
        startWatchdog(threadID: thread.id, generationID: generationID)
        return true
    }

    private func runLegacyPersonaGeneration(
        threadID: UUID,
        userText: String,
        generationID: UUID,
        generationModel: PersonaGenerationModel,
        configurationID: UUID?
    ) async {
        // A cancelled legacy task can still be scheduled after the caller has
        // switched threads. Do not start another runtime generation for that
        // stale generation.
        guard isGenerationActive(generationID) else { return }
        guard let thread = store.thread(id: threadID) else {
            // スレッド削除・破損などで本文を取得できない場合も、生成タスクを
            // 無反応のまま終了させず、サービス状態を解放してエラー導線を出す。
            await MainActor.run {
                self.failGeneration(
                    threadID: threadID,
                    generationID: generationID,
                    message: KizunaCopy.text(
                        japanese: "会話スレッドを読み込めなかったため、応答を生成できませんでした。もう一度お試しください。",
                        english: "The conversation thread could not be loaded, so no reply was generated. Please try again."
                    )
                )
            }
            return
        }
        let legacySafetyCharacter = safetyCharacter(for: thread.personaSnapshot)
        let inSafety = await safetyPipeline.evaluateInput(
            userText,
            character: legacySafetyCharacter
        )
        guard isGenerationActive(generationID) else { return }
        if inSafety.action == .block || inSafety.action == .requireEdit {
            let polite = PersonaOutputSafetyPolicy.sanitizedRewrite(inSafety.rewrittenText)
                ?? KizunaCopy.text(
                    japanese: "その話題には答えられません。別の話にしましょう。",
                    english: "I can't continue with that topic. Let's talk about something else."
                )
            await MainActor.run {
                self.finalize(
                    reply: polite,
                    threadID: threadID,
                    generationID: generationID,
                    outputSafety: .allow
                )
            }
            return
        }

        guard let effectiveUserText = SafetyInputPolicy.acceptedText(
            action: inSafety.action,
            original: userText,
            rewritten: inSafety.rewrittenText
        ) else {
            AppLog.error("[PersonaService] input safety decision had no accepted text")
            return
        }
        var promptThread = thread
        if let latestUserIndex = promptThread.messages.lastIndex(where: { $0.role == .user }) {
            promptThread.messages[latestUserIndex].text = effectiveUserText
        }
        let composedPrompt = buildPrompt(forThread: promptThread, latestUser: effectiveUserText)
        let personaPrompt = legacyPersonaSystemPrompt(
            for: thread.personaSnapshot,
            safetyPolicyRules: inSafety.addedPromptRules
        )
        let advanced = voiceOptimizedAdvancedSettings
        let onUpdate: (@MainActor @Sendable (LocalAssistantStructuredTurnUpdate) -> Void)? = { @MainActor [weak self] update in
            self?.handleStreamUpdate(update, generationID: generationID)
        }
        let generation: LocalAssistantGenerationResult
        if let configurationID {
            generation = await runtime.generatePersonaReplyResult(
                prompt: composedPrompt,
                contextPrompt: nil,
                coachMode: .studio,
                reasoningMode: .persona,
                childAge: 12,
                pageInfo: nil,
                safetySnapshot: nil,
                advancedSettings: advanced,
                overrideSystemPrompt: personaPrompt,
                generationID: generationID,
                configurationID: configurationID,
                onUpdate: onUpdate
            )
        } else {
            generation = await runtime.generatePersonaReplyResult(
                prompt: composedPrompt,
                contextPrompt: nil,
                coachMode: .studio,
                reasoningMode: .persona,
                childAge: 12,
                pageInfo: nil,
                safetySnapshot: nil,
                advancedSettings: advanced,
                overrideSystemPrompt: personaPrompt,
                generationID: generationID,
                model: generationModel,
                onUpdate: onUpdate
            )
        }
        let reply = generation.text
        guard let rawFinalText = PersonaOutputSafetyPolicy.completedText(from: reply) else {
            await MainActor.run {
                self.failGeneration(
                    threadID: threadID,
                    generationID: generationID,
                    message: KizunaCopy.text(
                        japanese: "応答本文を受け取れませんでした。入力欄からもう一度試してください。",
                        english: "No reply text was received. Try sending the message again."
                    )
                )
            }
            return
        }
        guard isGenerationActive(generationID) else { return }
        let outputSafety = await safetyPipeline.evaluateOutput(
            rawFinalText,
            character: legacySafetyCharacter
        )
        await MainActor.run {
            self.finalize(
                reply: reply,
                threadID: threadID,
                generationID: generationID,
                outputSafety: outputSafety,
                modelIdentity: generation.modelIdentity
            )
        }
    }

    func addNarration(_ text: String, to thread: PersonaThread) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.appendMessage(
            PersonaMessage(role: .narrator, text: trimmed),
            toThread: thread.id
        )
        store.finalizePersist()
    }

    /// CharacterLibrary 由来スレッドのフルパイプライン。
    /// 1) 入力 safety → 2) メモリー候補取得 → 3) 270M 分類 + 選別 → 4) PromptBuilder → 5) E4B 生成
    /// → 6) 出力 safety → 7) async でメモリー抽出・保存。
    private func runCharacterPipeline(
        threadID: UUID,
        characterID: UUID,
        userText: String,
        generationID: UUID,
        generationModel: PersonaGenerationModel,
        configurationID: UUID?
    ) async {
        // ── 1) CharacterProfile / Lorebook 取得 ──
        let allCharacters: [CharacterProfile]
        do {
            allCharacters = try await characterRepo.fetchCharacters()
        } catch {
            // 読み込み失敗を「キャラが存在しない」と扱うと、参照を切り離して
            // 旧Persona経路へ黙って移行し、空のアシスタント枠だけが残る。
            // 保存データの問題は明示的な失敗カードにして、入力を保持したまま
            // ユーザーが再試行できるようにする。
            await MainActor.run {
                self.failGeneration(
                    threadID: threadID,
                    generationID: generationID,
                    message: KizunaCopy.text(
                        japanese: "キャラクターを読み込めなかったため、応答を生成できませんでした。保存データを確認して再試行してください。",
                        english: "The character could not be loaded, so no reply was generated. Check the saved data and try again."
                    )
                )
            }
            return
        }
        guard isGenerationActive(generationID) else { return }
        await waitForPendingMemoryTask()
        await retryPendingMemorySaves()
        guard isGenerationActive(generationID) else { return }
        guard let character = allCharacters.first(where: { $0.id == characterID }) else {
            // キャラ本体が削除されてもスレッドのスナップショットで会話を続ける。
            // 参照だけを残して永久にエラーにするのではなく、旧Personaパスへ移行する。
            store.detachCharacterReference(threadID: threadID)
            let canFallback = await MainActor.run {
                self.isGenerationActive(generationID)
            }
            guard canFallback else { return }
            await runLegacyPersonaGeneration(
                threadID: threadID,
                userText: userText,
                generationID: generationID,
                generationModel: generationModel,
                configurationID: configurationID
            )
            return
        }
        let lorebook: CharacterLorebook?
        do {
            lorebook = try await characterRepo.fetchLorebook(characterId: characterID)
        } catch {
            await MainActor.run {
                self.failGeneration(
                    threadID: threadID,
                    generationID: generationID,
                    message: KizunaCopy.text(
                        japanese: "キャラクター設定を読み込めなかったため、古い設定で応答を生成しませんでした。再試行してください。",
                        english: "The character settings could not be loaded, so no reply was generated from stale settings. Try again."
                    )
                )
            }
            AppLog.error("[PersonaService] lorebook load failed character=%@: %@", characterID.uuidString, error.localizedDescription)
            return
        }
        guard isGenerationActive(generationID) else { return }

        // ── 2) 入力 safety ──
        let inSafety = await safetyPipeline.evaluateInput(userText, character: character)
        guard isGenerationActive(generationID) else { return }
        if inSafety.action == .block || inSafety.action == .requireEdit {
            // ブロックされたらキャラから穏当な拒否メッセージを返して終了
            let polite = PersonaOutputSafetyPolicy.sanitizedRewrite(inSafety.rewrittenText)
                ?? KizunaCopy.text(
                japanese: "ごめん、その話題には乗れないな。別の話、しよ?",
                english: "I can't continue with that topic. Could we talk about something else?"
            )
            await MainActor.run {
                guard self.activeGenerationID == generationID else { return }
                guard self.finalizeAssistantMessage(in: threadID, text: polite) else {
                    self.failGeneration(
                        threadID: threadID,
                        generationID: generationID,
                        message: self.persistenceFailureMessage
                    )
                    return
                }
                self.streamingResponse = ""
                self.phase = .idle
                self.invalidatePendingStreamSanitization()
                self.activeGenerationID = nil
                self.activeThreadID = nil
                self.activeAssistantMessageID = nil
                self.activeGenerationThreadID = nil
            }
            return
        }
        guard let effectiveUserText = SafetyInputPolicy.acceptedText(
            action: inSafety.action,
            original: userText,
            rewritten: inSafety.rewrittenText
        ) else {
            AppLog.error("[PersonaService] character input safety decision had no accepted text")
            return
        }

        // ── 3) メモリー候補と選別 ──
        let candidates: [CharacterMemory]
        do {
            candidates = try await memoryRepo.fetchMemories(characterId: characterID)
        } catch {
            await MainActor.run {
                self.failGeneration(
                    threadID: threadID,
                    generationID: generationID,
                    message: KizunaCopy.text(
                        japanese: "記憶を読み込めなかったため、古い記憶で応答を生成しませんでした。再試行してください。",
                        english: "Memories could not be loaded, so no reply was generated from stale memory context. Try again."
                    )
                )
            }
            AppLog.error("[PersonaService] memory context load failed character=%@: %@", characterID.uuidString, error.localizedDescription)
            return
        }
        guard isGenerationActive(generationID) else { return }
        let needsRecall: Bool
        if candidates.isEmpty {
            needsRecall = false
        } else {
            let c = await smallClassifier.classify(
                text: effectiveUserText,
                labels: ["recall_needed", "casual_chat"]
            )
            guard isGenerationActive(generationID) else { return }
            needsRecall = (c.label == "recall_needed" && c.confidence > 0.35) || candidates.count <= 3
        }
        let selected: [CharacterMemory]
        if needsRecall {
            if candidates.count > 5 {
                selected = await memorySelector.select(query: effectiveUserText, candidates: candidates, topK: 5)
            } else {
                selected = candidates
            }
        } else {
            selected = []
        }
        guard isGenerationActive(generationID) else { return }

        guard isGenerationActive(generationID) else { return }
        // ── 4) PromptBuilder ──
        var recent = await MainActor.run { () -> [PersonaMessage] in
            (store.thread(id: threadID)?.messages ?? [])
                .filter { !($0.role == .assistant && PersonaMessage.isPendingAssistantText($0.text)) }
                .suffix(6)
                .map { $0 }
        }
        if let latestUserIndex = recent.lastIndex(where: { $0.role == .user }) {
            recent[latestUserIndex].text = effectiveUserText
        }
        guard isGenerationActive(generationID) else { return }
        let systemPrompt = promptBuilder.build(
            character: character,
            lorebook: lorebook,
            selectedMemories: selected,
            recentMessages: recent,
            userInput: effectiveUserText,
            safetyDecision: inSafety
        )

        // ── 5) E4B 生成 (overrideSystemPrompt 経路) ──
        let advanced = voiceOptimizedAdvancedSettings
        let onUpdate: (@MainActor @Sendable (LocalAssistantStructuredTurnUpdate) -> Void)? = { @MainActor [weak self] update in
            self?.handleStreamUpdate(update, generationID: generationID)
        }
        let generation: LocalAssistantGenerationResult
        if let configurationID {
            generation = await runtime.generatePersonaReplyResult(
                prompt: effectiveUserText,
                contextPrompt: nil,
                coachMode: .studio,
                reasoningMode: .persona,
                childAge: 12,
                pageInfo: nil,
                safetySnapshot: nil,
                advancedSettings: advanced,
                overrideSystemPrompt: systemPrompt,
                generationID: generationID,
                configurationID: configurationID,
                onUpdate: onUpdate
            )
        } else {
            generation = await runtime.generatePersonaReplyResult(
                prompt: effectiveUserText,
                contextPrompt: nil,
                coachMode: .studio,
                reasoningMode: .persona,
                childAge: 12,
                pageInfo: nil,
                safetySnapshot: nil,
                advancedSettings: advanced,
                overrideSystemPrompt: systemPrompt,
                generationID: generationID,
                model: generationModel,
                onUpdate: onUpdate
            )
        }
        let reply = generation.text
        guard isGenerationActive(generationID) else { return }

        // ── 6) 出力 safety ──
        guard var finalText = PersonaOutputSafetyPolicy.completedText(from: reply) else {
            await MainActor.run {
                self.failGeneration(
                    threadID: threadID,
                    generationID: generationID,
                    message: KizunaCopy.text(
                        japanese: "応答本文を受け取れませんでした。入力欄からもう一度試してください。",
                        english: "No reply text was received. Try sending the message again."
                    )
                )
            }
            return
        }
        let outSafety = await safetyPipeline.evaluateOutput(finalText, character: character)
        guard isGenerationActive(generationID) else { return }
        switch outSafety.action {
        case .block:
            finalText = PersonaOutputSafetyPolicy.sanitizedRewrite(outSafety.rewrittenText)
                ?? KizunaCopy.text(
                japanese: "うまく言えないけど、それは話したくないな。別の話にしよう?",
                english: "I can't put that into words, and I'd rather not discuss it. Let's talk about something else."
            )
        case .soften, .requireEdit:
            guard let persistable = PersonaOutputSafetyPolicy.persistableText(
                action: outSafety.action,
                original: finalText,
                rewritten: outSafety.rewrittenText
            ) else {
                await MainActor.run {
                    self.failGeneration(
                        threadID: threadID,
                        generationID: generationID,
                        message: KizunaCopy.text(
                            japanese: "安全上の理由で応答を保存できませんでした。別の表現で試してください。",
                            english: "The response was not saved for safety reasons. Try a different phrasing."
                        )
                    )
                }
                return
            }
            finalText = persistable
        case .warn, .allow:
            break
        }

        let didPersistAssistant = await MainActor.run { () -> Bool in
            guard self.activeGenerationID == generationID else { return false }
            guard self.finalizeAssistantMessage(in: threadID, text: finalText) else {
                self.failGeneration(
                    threadID: threadID,
                    generationID: generationID,
                    message: self.persistenceFailureMessage
                )
                return false
            }
            if let modelIdentity = generation.modelIdentity,
               !self.store.setLastUsedModelIdentity(modelIdentity, forThread: threadID) {
                AppLog.error("[PersonaChatService] failed to persist model identity thread=%@", threadID.uuidString)
            }
            self.streamingResponse = ""
            if let messageID = self.activeAssistantMessageID {
                self.lastCompletedGeneration = GenerationCompletion(threadID: threadID, messageID: messageID)
            }
            let memoryTaskID = UUID()
            self.pendingMemoryTaskID = memoryTaskID
            self.pendingMemoryCharacterID = character.id
            self.pendingMemoryTask = Task { [weak self] in
                guard let self else { return }
                await self.persistExtractedMemories(
                    userText: userText,
                    assistantText: finalText,
                    character: character,
                    taskID: memoryTaskID
                )
            }
            self.phase = .idle
            self.invalidatePendingStreamSanitization()
            self.activeGenerationID = nil
            self.activeThreadID = nil
            self.activeAssistantMessageID = nil
            self.activeGenerationThreadID = nil
            self.activeRequestText = nil
            self.generationFailures.removeValue(forKey: threadID)
            self.cancelledRequests.removeValue(forKey: threadID)
            return true
        }
        guard didPersistAssistant else { return }

        // Memory usage is durable only after the assistant turn is committed.
        // A stopped or failed generation must not reorder future recall.
        if !selected.isEmpty {
            do {
                try await memoryRepo.markUsed(ids: selected.map(\.id))
            } catch {
                AppLog.error("[PersonaService] memory usage update failed thread=%@: %@", threadID.uuidString, error.localizedDescription)
            }
        }

        // The UI may become idle before this auxiliary task finishes, but the
        // next character turn joins it before fetching prompt memories.
        await waitForPendingMemoryTask()
    }

    private func waitForPendingMemoryTask() async {
        guard let task = pendingMemoryTask else { return }
        let taskID = pendingMemoryTaskID
        await task.value
        if pendingMemoryTaskID == taskID {
            pendingMemoryTask = nil
            pendingMemoryTaskID = nil
            pendingMemoryCharacterID = nil
        }
    }

    func retryPendingMemorySaves() async {
        guard !pendingMemorySaves.isEmpty else {
            memorySaveError = nil
            return
        }
        for characterID in Array(pendingMemorySaves.keys) {
            guard !Task.isCancelled else { return }
            guard let pending = pendingMemorySaves[characterID] else { continue }
            var remaining: [CharacterMemory] = []
            for memory in pending {
                guard !Task.isCancelled else { return }
                do {
                    try await memoryRepo.saveMemory(memory)
                } catch {
                    if let repositoryError = error as? CharacterRepositoryError,
                       case .deletionInProgress = repositoryError {
                        // A completed deletion leaves a durable tombstone, so
                        // this retry can never become valid again.
                        continue
                    }
                    remaining.append(memory)
                    AppLog.error(
                        "[PersonaService] pending memory retry failed character=%@: %@",
                        characterID.uuidString,
                        error.localizedDescription
                    )
                }
            }
            if remaining.isEmpty {
                pendingMemorySaves.removeValue(forKey: characterID)
            } else {
                pendingMemorySaves[characterID] = remaining
            }
        }
        memorySaveError = pendingMemorySaves.isEmpty
            ? nil
            : KizunaCopy.text(
                japanese: "一部の記憶を保存できませんでした。次の会話で再試行します。",
                english: "Some memories could not be saved. They will be retried before the next conversation."
            )
    }

    private func persistExtractedMemories(
        userText: String,
        assistantText: String,
        character: CharacterProfile,
        taskID: UUID
    ) async {
        guard !Task.isCancelled,
              pendingMemoryTaskID == taskID,
              pendingMemoryCharacterID == character.id else { return }
        let newMemories = await memorySummarizer.extract(
            userText: userText,
            assistantText: assistantText,
            character: character
        )
        guard !Task.isCancelled,
              pendingMemoryTaskID == taskID,
              pendingMemoryCharacterID == character.id else { return }
        var failed: [CharacterMemory] = []
        for memory in newMemories {
            guard !Task.isCancelled,
                  pendingMemoryTaskID == taskID,
                  pendingMemoryCharacterID == character.id else { return }
            do {
                try await memoryRepo.saveMemory(memory)
            } catch {
                failed.append(memory)
                AppLog.error(
                    "[PersonaService] memory save failed character=%@ memory=%@: %@",
                    character.id.uuidString,
                    memory.id.uuidString,
                    error.localizedDescription
                )
            }
        }
        guard !Task.isCancelled,
              pendingMemoryTaskID == taskID,
              pendingMemoryCharacterID == character.id else { return }
        if !failed.isEmpty {
            pendingMemorySaves[character.id, default: []].append(contentsOf: failed)
            memorySaveError = KizunaCopy.text(
                japanese: "一部の記憶を保存できませんでした。次の会話で再試行します。",
                english: "Some memories could not be saved. They will be retried before the next conversation."
            )
        }
    }

    func cancel() {
        if let threadID = activeGenerationThreadID,
           let requestText = activeRequestText,
           !requestText.isEmpty {
            cancelledRequests[threadID] = requestText
        }
        generationTask?.cancel()
        generationTask = nil
        invalidatePendingStreamSanitization()
        runtime.cancelActiveGeneration(generationID: activeGenerationID)
        activeGenerationID = nil
        activeThreadID = nil
        activeAssistantMessageID = nil
        activeGenerationThreadID = nil
        activeRequestText = nil
        lastErrorThreadID = nil
        streamingResponse = ""
        phase = .idle
    }

    /// Delete Persona history as one coordinated operation. The store alone
    /// cannot stop an in-flight runtime, so cancel and clear every transient
    /// generation state before removing the persisted threads.
    @discardableResult
    func deleteAllConversations() -> Bool {
        cancel()
        generationFailures.removeAll()
        cancelledRequests.removeAll()
        lastCompletedGeneration = nil
        memorySaveError = nil
        pendingMemoryTask?.cancel()
        pendingMemoryTask = nil
        pendingMemoryTaskID = nil
        pendingMemoryCharacterID = nil
        pendingMemorySaves.removeAll()
        lastRequestThreadID = nil
        lastRequestText = nil
        return store.deleteAllThreads()
    }

    /// 失敗カードから、直前のユーザー入力を重複させずに再送する。
    func retryLastMessage() {
        guard let threadID = lastErrorThreadID else { return }
        retryLastMessage(for: threadID)
    }

    func retryLastMessage(for threadID: UUID) {
        guard phase != .thinking,
              let failure = generationFailures[threadID],
              let storedThread = store.thread(id: threadID),
              let last = storedThread.messages.last,
              last.role == .user,
              last.text == failure.requestText else { return }

        store.removeLastUserMessage(in: threadID, matching: failure.requestText)
        generationFailures.removeValue(forKey: threadID)
        guard let retryThread = store.thread(id: threadID) else { return }
        send(failure.requestText, to: retryThread)
    }

    func dismissError() {
        guard let threadID = lastErrorThreadID else { return }
        dismissError(for: threadID)
    }

    func dismissError(for threadID: UUID) {
        generationFailures.removeValue(forKey: threadID)
        guard lastErrorThreadID == threadID else { return }
        if case .error = phase {
            phase = .idle
            streamingResponse = ""
        }
        lastErrorThreadID = nil
    }

    func generationFailure(for threadID: UUID) -> GenerationFailure? {
        generationFailures[threadID]
    }

    func cancelledRequest(for threadID: UUID) -> String? {
        cancelledRequests[threadID]
    }

    func retryCancelledMessage(for threadID: UUID) {
        guard phase != .thinking,
              let requestText = cancelledRequests[threadID],
              let thread = store.thread(id: threadID),
              thread.messages.last?.role == .user,
              thread.messages.last?.text == requestText else { return }
        store.removeLastUserMessage(in: threadID, matching: requestText)
        cancelledRequests.removeValue(forKey: threadID)
        send(requestText, to: thread)
    }

    func discardCancelledMessage(for threadID: UUID) {
        guard let requestText = cancelledRequests[threadID] else { return }
        store.removeLastUserMessage(in: threadID, matching: requestText)
        cancelledRequests.removeValue(forKey: threadID)
    }

    /// Remove a thread's failure and stop its generation before the store row
    /// disappears. A different thread's active generation is left untouched.
    func removeGenerationState(for threadID: UUID) {
        if activeGenerationThreadID == threadID {
            cancel()
        }
        generationFailures.removeValue(forKey: threadID)
        cancelledRequests.removeValue(forKey: threadID)
        if lastErrorThreadID == threadID {
            lastErrorThreadID = nil
        }
    }

    func cancelGeneration(forCharacterID characterID: UUID) {
        if let threadID = activeGenerationThreadID,
           let thread = store.thread(id: threadID),
           thread.characterID == characterID {
            cancel()
            cancelledRequests.removeValue(forKey: threadID)
        }
        cancelPendingMemory(forCharacterID: characterID)
    }

    /// Character deletion also owns the post-response memory task and any
    /// retry queue. Invalidate both before related repositories are cleaned so
    /// a late extraction cannot enqueue new writes for the deleted profile.
    func cancelPendingMemory(forCharacterID characterID: UUID) {
        guard pendingMemoryCharacterID == characterID
                || pendingMemorySaves[characterID] != nil else { return }
        if pendingMemoryCharacterID == characterID {
            pendingMemoryTask?.cancel()
            pendingMemoryTask = nil
            pendingMemoryTaskID = nil
            pendingMemoryCharacterID = nil
        }
        pendingMemorySaves.removeValue(forKey: characterID)
        memorySaveError = pendingMemorySaves.isEmpty
            ? nil
            : KizunaCopy.text(
                japanese: "一部の記憶を保存できませんでした。次の会話で再試行します。",
                english: "Some memories could not be saved. They will be retried before the next conversation."
            )
    }

    // MARK: - Streaming

    private func handleStreamUpdate(_ update: LocalAssistantStructuredTurnUpdate, generationID: UUID) {
        guard activeGenerationID == generationID else { return }
        guard case let .visiblePreview(text) = update else { return }

        streamPreviewRevision &+= 1
        let revision = streamPreviewRevision
        streamSanitizationTask?.cancel()
        streamSanitizationTask = Task.detached(priority: .utility) { [weak self] in
            // Structured previews are cumulative and can arrive faster than a
            // full sanitization pass. Give a newer update 32 ms to supersede
            // this one, then check cancellation again before scanning text.
            // Task.sleep only throws when this task is cancelled.
            guard !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: 32_000_000)
            guard !Task.isCancelled else { return }
            let sanitized = PersonaResponseSanitizer.sanitize(text)
            guard !Task.isCancelled else { return }
            await self?.applySanitizedStreamPreview(
                sanitized,
                generationID: generationID,
                revision: revision
            )
        }
    }

    private func applySanitizedStreamPreview(
        _ text: String,
        generationID: UUID,
        revision: Int
    ) {
        guard activeGenerationID == generationID,
              streamPreviewRevision == revision else { return }
        streamingResponse = text
    }

    private func invalidatePendingStreamSanitization() {
        streamPreviewRevision &+= 1
        streamSanitizationTask?.cancel()
        streamSanitizationTask = nil
    }

    private func finalize(
        reply: String?,
        threadID: UUID,
        generationID: UUID,
        outputSafety: SafetyDecision,
        modelIdentity: String? = nil
    ) {
        guard activeGenerationID == generationID else { return }
        guard let cleaned = PersonaOutputSafetyPolicy.completedText(from: reply) else {
            failGeneration(
                threadID: threadID,
                generationID: generationID,
                message: KizunaCopy.text(
                    japanese: "応答本文を受け取れませんでした。入力欄からもう一度試してください。",
                    english: "No reply text was received. Try sending the message again."
                )
            )
            return
        }
        let persistableText: String
        switch outputSafety.action {
        case .block:
            if let rewritten = PersonaOutputSafetyPolicy.sanitizedRewrite(outputSafety.rewrittenText) {
                persistableText = rewritten
            } else {
                persistableText = KizunaCopy.text(
                    japanese: "うまく言えないけど、それは話したくないな。別の話にしよう?",
                    english: "I can't put that into words, and I'd rather not discuss it. Let's talk about something else."
                )
            }
        case .soften, .requireEdit:
            guard let safeText = PersonaOutputSafetyPolicy.persistableText(
                action: outputSafety.action,
                original: cleaned,
                rewritten: outputSafety.rewrittenText
            ) else {
                failGeneration(
                    threadID: threadID,
                    generationID: generationID,
                    message: KizunaCopy.text(
                        japanese: "安全上の理由で応答を保存できませんでした。別の表現で試してください。",
                        english: "The response was not saved for safety reasons. Try a different phrasing."
                    )
                )
                return
            }
            persistableText = safeText
        case .warn, .allow:
                persistableText = cleaned
        }
        guard finalizeAssistantMessage(in: threadID, text: persistableText) else {
            failGeneration(
                threadID: threadID,
                generationID: generationID,
                message: persistenceFailureMessage
            )
            return
        }
        if let modelIdentity,
           !store.setLastUsedModelIdentity(modelIdentity, forThread: threadID) {
            AppLog.error("[PersonaChatService] failed to persist model identity thread=%@", threadID.uuidString)
        }
        streamingResponse = ""
        if let messageID = activeAssistantMessageID {
            lastCompletedGeneration = GenerationCompletion(threadID: threadID, messageID: messageID)
        }
        phase = .idle
        invalidatePendingStreamSanitization()
        activeGenerationID = nil
        activeThreadID = nil
        activeAssistantMessageID = nil
        activeGenerationThreadID = nil
        activeRequestText = nil
        generationFailures.removeValue(forKey: threadID)
        cancelledRequests.removeValue(forKey: threadID)
        lastErrorThreadID = nil
    }

    /// Adapt a PersonaProfile to the CharacterProfile context required by the
    /// shared input/output pipeline. The captured rating survives a detached
    /// Character reference; old profiles decode with the general default.
    private func safetyCharacter(for profile: PersonaProfile) -> CharacterProfile {
        CharacterProfile(
            id: profile.id,
            name: profile.name,
            displayName: profile.name,
            category: .chatBuddy,
            relationshipGenre: .none,
            personality: profile.personality,
            scenario: profile.freeFormAddendum,
            safetyRating: profile.safetyRating
        )
    }

    private func startWatchdog(threadID: UUID, generationID: UUID) {
        let watchdogNanoseconds = watchdogNanoseconds
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: watchdogNanoseconds)
            await MainActor.run {
                guard let self,
                      self.activeGenerationID == generationID,
                      self.phase == .thinking else { return }
                self.generationTask?.cancel()
                self.generationTask = nil
                self.runtime.cancelActiveGeneration(generationID: generationID)
                self.failGeneration(
                    threadID: threadID,
                    generationID: generationID,
                    message: KizunaCopy.text(
                        japanese: "応答が時間内に完了しませんでした。もう一度試してください。",
                        english: "The reply did not finish in time. Try again."
                    )
                )
            }
        }
    }

    private func isGenerationActive(_ generationID: UUID) -> Bool {
        !Task.isCancelled && activeGenerationID == generationID
    }

    // MARK: - Prompt assembly

    private func buildPrompt(forThread thread: PersonaThread, latestUser: String) -> String {
        // 履歴は最新 6 メッセージ程度に絞り、レイテンシを抑える。
        let recent = thread.messages.suffix(6)
        let userLabel = KizunaCopy.text(japanese: "相手", english: "User")
        let narrationLabel = KizunaCopy.text(japanese: "ナレーション", english: "Narration")
        var lines: [String] = []
        for msg in recent {
            switch msg.role {
            case .user:
                lines.append(userLabel + ": " + msg.text)
            case .assistant:
                if !PersonaMessage.isPendingAssistantText(msg.text) {
                    lines.append("\(thread.personaSnapshot.name): " + msg.text)
                }
            case .narrator:
                if !msg.text.isEmpty {
                    lines.append(narrationLabel + ": " + msg.text)
                }
            }
        }
        if lines.last != userLabel + ": " + latestUser {
            lines.append(userLabel + ": " + latestUser)
        }
        // 末尾でキャラ名 + ":" でプライム。これにより Gemma 4 は
        // 「\(name): 」の直後にメッセージ本体を続けざるを得なくなり、
        // 思考文 ("〜について考える") を頭に書く余地が消える。
        lines.append("\(thread.personaSnapshot.name):")
        return lines.joined(separator: "\n")
    }

    private func legacyPersonaSystemPrompt(
        for profile: PersonaProfile,
        safetyPolicyRules: [String]
    ) -> String {
        let persona = profile.promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let languageInstruction = KizunaCopy.text(
            japanese: "次の設定を守り、相手へ自然な日本語で返してください。",
            english: "Follow the settings below and reply naturally in English unless the user writes in another language."
        )
        let outputRules = KizunaCopy.text(
            japanese: "前置き、役割説明、内部推論、Markdown、選択肢、特殊タグは本文へ出さないでください。",
            english: "Do not expose preambles, role explanations, internal reasoning, Markdown, choices, or special tags in the reply."
        )
        let safetyRules = KizunaCopy.text(
            japanese: "危険・違法・露骨な性的内容・自傷助長には、人格を崩さず安全な方向へ寄せてください。",
            english: "For dangerous, illegal, explicit sexual, or self-harm content, stay in character while steering toward a safe alternative."
        )
        let policyBlock: String = {
            var seen = Set<String>()
            let rules = safetyPolicyRules.compactMap { rule -> String? in
                let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
                return "- " + trimmed
            }
            guard !rules.isEmpty else { return "" }
            return "\n" + KizunaCopy.text(
                japanese: "現在の安全ポリシー:",
                english: "Current safety policy:"
            ) + "\n" + rules.joined(separator: "\n")
        }()
        return """
        \(KizunaCopy.text(japanese: "あなたは\(KizunaCopy.appName)の会話相手です。", english: "You are the user's \(KizunaCopy.appName) conversation partner.")) \(languageInstruction)
        \(persona)
        \(outputRules)
        \(safetyRules)\(policyBlock)
        """
    }

    private func failGeneration(threadID: UUID, generationID: UUID, message: String) {
        guard activeGenerationID == generationID else { return }
        streamingResponse = ""
        phase = .error(message)
        invalidatePendingStreamSanitization()
        generationFailures[threadID] = GenerationFailure(
            message: message,
            requestText: activeRequestText ?? lastRequestText ?? ""
        )
        activeGenerationID = nil
        activeThreadID = nil
        activeAssistantMessageID = nil
        activeGenerationThreadID = nil
        activeRequestText = nil
        lastErrorThreadID = threadID
    }

    private var persistenceFailureMessage: String {
        KizunaCopy.text(
            japanese: "応答を保存できませんでした。保存先を確認してから再試行してください。",
            english: "The reply could not be saved. Check storage and try again."
        )
    }

    @discardableResult
    private func finalizeAssistantMessage(in threadID: UUID, text: String) -> Bool {
        guard let assistantMessageID = activeAssistantMessageID else { return false }
        let result = store.appendFinalizedAssistantMessage(
            in: threadID,
            messageID: assistantMessageID,
            text: text
        )
        switch result {
        case .inserted, .alreadyPresent:
            return true
        case .rejected:
            return false
        }
    }

    /// ペルソナ会話用 advancedSettings。ツール/検索を切り、内部システム指示を最小化する。
    private var voiceOptimizedAdvancedSettings: GemmaAdvancedSettings {
        var s = GemmaAdvancedSettings.default
        s.allowToolUsage = false
        s.strictJSONToolCalls = false
        s.allowDirectAnswersWithoutTools = true
        s.requireSearchForFactualQueries = false
        s.requireExternalSourcesInDeepResearch = false
        s.maxToolRounds = 0
        s.maxSearchRounds = 0
        s.enabledTools = [:]
        s.useAutomaticTemperature = true
        return s
    }

}
