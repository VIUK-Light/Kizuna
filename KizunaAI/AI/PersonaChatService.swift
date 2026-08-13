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
    static func persistableText(
        action: SafetyAction,
        original: String,
        rewritten: String?
    ) -> String? {
        switch action {
        case .block, .requireEdit:
            return nil
        case .soften:
            guard let rewritten,
                  !rewritten.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return rewritten
        case .allow, .warn:
            return original
        }
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

    @Published private(set) var phase: Phase = .idle
    /// ストリーミング中の最新応答テキスト。完了時に PersonaChatStore に永続化される。
    @Published private(set) var streamingResponse: String = ""
    /// 生成中/失敗中の表示を現在のスレッドだけに紐付けるためのID。
    /// phase はサービス全体の状態なので、スレッド切替時にそのままUIへ使うと
    /// Aの生成表示がBへ伝播してしまう。
    @Published private(set) var activeGenerationThreadID: UUID?
    @Published private(set) var lastErrorThreadID: UUID?

    private var generationTask: Task<Void, Never>?
    private var streamSanitizationTask: Task<Void, Never>?
    /// A later runtime preview always supersedes a prior cumulative preview.
    /// This prevents a slow background sanitizer result from overwriting the
    /// newest text after it returns to the main actor.
    private var streamPreviewRevision = 0
    private var lastVisibleText: String = ""
    /// The runtime may finish before the latest background sanitizer returns.
    /// Retain the raw cumulative preview so finalization can still sanitize the
    /// full response synchronously instead of dropping the final update.
    private var latestRawStreamingText: String?
    private var activeGenerationID: UUID?
    private var activeThreadID: UUID?
    private var lastRequestThreadID: UUID?
    private var lastRequestText: String?

    private init() {}

    /// 指定スレッドにユーザー発話を追加し、Gemma 4 のペルソナモードで応答を生成する。
    // MARK: - DI for Character Library pipeline (default: Local + Mock)
    /// 既存挙動を壊さないために、スレッドに characterID が紐付いている場合だけ使う。
    private let characterRepo: CharacterRepository = LocalJSONCharacterRepository()
    private let memoryRepo: MemoryRepository = LocalJSONMemoryRepository()
    private let safetyPipeline = SafetyPipeline.shared
    private let smallClassifier: SmallModelClassifying = MockSmallModelClassifier()
    private let memorySelector: MemorySelecting = MockMemorySelector()
    private let memorySummarizer: MemorySummarizing = MockMemorySummarizer()
    private let promptBuilder = PromptBuilder()

    func send(_ userText: String, to thread: PersonaThread) {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard phase != .thinking else { return }

        // ユーザーメッセージ & 空のアシスタントメッセージを追加 (アシスタント側はストリームで埋める)
        PersonaChatStore.shared.appendMessage(
            PersonaMessage(role: .user, text: trimmed),
            toThread: thread.id
        )
        PersonaChatStore.shared.appendMessage(
            PersonaMessage(role: .assistant, text: ""),
            toThread: thread.id
        )

        phase = .thinking
        streamingResponse = ""
        lastErrorThreadID = nil
        invalidatePendingStreamSanitization()
        lastVisibleText = ""
        latestRawStreamingText = nil
        lastRequestThreadID = thread.id
        lastRequestText = trimmed
        let generationID = UUID()
        activeGenerationID = generationID
        activeThreadID = thread.id
        activeGenerationThreadID = thread.id

        if let charID = thread.characterID {
            // 新パス: キャラライブラリー由来のスレッド → 安全 + メモリーパイプライン
            generationTask = Task { [weak self] in
                await self?.runCharacterPipeline(threadID: thread.id, characterID: charID, userText: trimmed, generationID: generationID)
            }
        } else {
            // 旧パス: PersonaSettings由来のスレッド → 既存ストリーミングのまま
            generationTask = Task { [weak self, threadID = thread.id] in
                await self?.runLegacyPersonaGeneration(
                    threadID: threadID,
                    userText: trimmed,
                    generationID: generationID
                )
            }
        }
        startWatchdog(threadID: thread.id, generationID: generationID)
    }

    private func runLegacyPersonaGeneration(
        threadID: UUID,
        userText: String,
        generationID: UUID
    ) async {
        // A cancelled legacy task can still be scheduled after the caller has
        // switched threads. Do not start another runtime generation for that
        // stale generation.
        guard isGenerationActive(generationID) else { return }
        guard let thread = PersonaChatStore.shared.thread(id: threadID) else {
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
        let composedPrompt = buildPrompt(forThread: thread, latestUser: userText)
        let personaPrompt = legacyPersonaSystemPrompt(for: thread.personaSnapshot)
        let advanced = voiceOptimizedAdvancedSettings
        let reply = await LocalAssistantRuntimeBridge.shared.generateReply(
            prompt: composedPrompt,
            contextPrompt: nil,
            coachMode: .studio,
            reasoningMode: .persona,
            researchMode: .off,
            childAge: 12,
            pageInfo: nil,
            safetySnapshot: nil,
            advancedSettings: advanced,
            overrideSystemPrompt: personaPrompt,
            generationID: generationID,
            onUpdate: { @MainActor [weak self] update in
                self?.handleStreamUpdate(update, threadID: threadID, generationID: generationID)
            }
        )
        let rawFinalText = reply?.isEmpty == false ? reply! : (latestRawStreamingText ?? streamingResponse)
        let outputSafety: SafetyDecision
        if let cleaned = meaningfulResponse(rawFinalText) {
            outputSafety = await safetyPipeline.evaluateOutput(
                cleaned,
                character: safetyCharacter(for: thread.personaSnapshot)
            )
        } else {
            outputSafety = .allow
        }
        await MainActor.run {
            self.finalize(
                reply: reply,
                threadID: threadID,
                generationID: generationID,
                outputSafety: outputSafety
            )
        }
    }

    func addNarration(_ text: String, to thread: PersonaThread) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        PersonaChatStore.shared.appendMessage(
            PersonaMessage(role: .narrator, text: trimmed),
            toThread: thread.id
        )
        PersonaChatStore.shared.finalizePersist()
    }

    /// CharacterLibrary 由来スレッドのフルパイプライン。
    /// 1) 入力 safety → 2) メモリー候補取得 → 3) 270M 分類 + 選別 → 4) PromptBuilder → 5) E4B 生成
    /// → 6) 出力 safety → 7) async でメモリー抽出・保存。
    private func runCharacterPipeline(threadID: UUID, characterID: UUID, userText: String, generationID: UUID) async {
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
        guard let character = allCharacters.first(where: { $0.id == characterID }) else {
            // キャラ本体が削除されてもスレッドのスナップショットで会話を続ける。
            // 参照だけを残して永久にエラーにするのではなく、旧Personaパスへ移行する。
            PersonaChatStore.shared.detachCharacterReference(threadID: threadID)
            let canFallback = await MainActor.run { () -> Bool in
                guard self.isGenerationActive(generationID) else { return false }
                PersonaChatStore.shared.removePendingAssistantMessage(in: threadID)
                // updateLastAssistantMessageは末尾のassistant枠を更新する。
                // 先ほどの削除後に空枠を再追加して、旧応答を上書きせず
                // フォールバック本文をこのターンへ保存できるようにする。
                PersonaChatStore.shared.appendMessage(
                    PersonaMessage(role: .assistant, text: ""),
                    toThread: threadID
                )
                return true
            }
            guard canFallback else { return }
            await runLegacyPersonaGeneration(threadID: threadID, userText: userText, generationID: generationID)
            return
        }
        let lorebook = try? await characterRepo.fetchLorebook(characterId: characterID)
        guard isGenerationActive(generationID) else { return }

        // ── 2) 入力 safety ──
        let inSafety = await safetyPipeline.evaluateInput(userText, character: character)
        guard isGenerationActive(generationID) else { return }
        if inSafety.action == .block {
            // ブロックされたらキャラから穏当な拒否メッセージを返して終了
            let polite = inSafety.rewrittenText ?? KizunaCopy.text(
                japanese: "ごめん、その話題には乗れないな。別の話、しよ?",
                english: "I can't continue with that topic. Could we talk about something else?"
            )
            await MainActor.run {
                guard self.activeGenerationID == generationID else { return }
                PersonaChatStore.shared.finalizeLastAssistantMessage(in: threadID, text: polite)
                self.streamingResponse = polite
                self.phase = .idle
                self.invalidatePendingStreamSanitization()
                self.activeGenerationID = nil
                self.activeThreadID = nil
                self.activeGenerationThreadID = nil
            }
            return
        }
        let effectiveUserText = inSafety.rewrittenText ?? userText

        // ── 3) メモリー候補と選別 ──
        let candidates = (try? await memoryRepo.fetchMemories(characterId: characterID)) ?? []
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

        // 想起したメモリーは lastUsedAt 更新
        if !selected.isEmpty {
            try? await memoryRepo.markUsed(ids: selected.map(\.id))
        }
        guard isGenerationActive(generationID) else { return }
        // ── 4) PromptBuilder ──
        let recent = await MainActor.run { () -> [PersonaMessage] in
            (PersonaChatStore.shared.threads.first(where: { $0.id == threadID })?.messages ?? [])
                .filter { !($0.role == .assistant && $0.text.isEmpty) }
                .suffix(6)
                .map { $0 }
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
        let bridge = LocalAssistantRuntimeBridge.shared
        let reply = await bridge.generateReply(
            prompt: effectiveUserText,
            contextPrompt: nil,
            coachMode: .studio,
            reasoningMode: .persona,
            researchMode: .off,
            childAge: 12,
            pageInfo: nil,
            safetySnapshot: nil,
            advancedSettings: advanced,
            overrideSystemPrompt: systemPrompt,
            generationID: generationID,
            onUpdate: { @MainActor [weak self] update in
                self?.handleStreamUpdate(update, threadID: threadID, generationID: generationID)
            }
        )
        guard isGenerationActive(generationID) else { return }

        // ── 6) 出力 safety ──
        let rawFinalText = reply?.isEmpty == false ? reply! : (latestRawStreamingText ?? streamingResponse)
        guard var finalText = meaningfulResponse(rawFinalText) else {
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
            finalText = outSafety.rewrittenText ?? KizunaCopy.text(
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

        await MainActor.run {
            guard self.activeGenerationID == generationID else { return }
            self.streamingResponse = finalText
            PersonaChatStore.shared.finalizeLastAssistantMessage(in: threadID, text: finalText)
            self.phase = .idle
            self.invalidatePendingStreamSanitization()
            self.activeGenerationID = nil
            self.activeThreadID = nil
            self.activeGenerationThreadID = nil
        }

        // ── 7) メモリー抽出 (UI を idle にした後に await。中断されても致命的ではない) ──
        let newMemories = await memorySummarizer.extract(
            userText: userText,
            assistantText: finalText,
            character: character
        )
        for m in newMemories {
            try? await memoryRepo.saveMemory(m)
        }
    }

    func cancel() {
        generationTask?.cancel()
        generationTask = nil
        invalidatePendingStreamSanitization()
        LocalAssistantRuntimeBridge.shared.cancelActiveGeneration(generationID: activeGenerationID)
        if let threadID = activeThreadID {
            let partial = (latestRawStreamingText ?? streamingResponse)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let meaningful = meaningfulResponse(partial) {
                PersonaChatStore.shared.finalizeLastAssistantMessage(in: threadID, text: meaningful)
            } else {
                PersonaChatStore.shared.removePendingAssistantMessage(in: threadID)
            }
        }
        activeGenerationID = nil
        activeThreadID = nil
        activeGenerationThreadID = nil
        lastErrorThreadID = nil
        streamingResponse = ""
        phase = .idle
    }

    /// 失敗カードから、直前のユーザー入力を重複させずに再送する。
    func retryLastMessage() {
        guard phase != .thinking,
              let threadID = lastRequestThreadID,
              let requestText = lastRequestText,
              let storedThread = PersonaChatStore.shared.thread(id: threadID),
              let last = storedThread.messages.last,
              last.role == .user,
              last.text == requestText else { return }

        PersonaChatStore.shared.removeLastUserMessage(in: threadID, matching: requestText)
        guard let retryThread = PersonaChatStore.shared.thread(id: threadID) else { return }
        send(requestText, to: retryThread)
    }

    func dismissError() {
        guard case .error = phase else { return }
        phase = .idle
        streamingResponse = ""
        lastErrorThreadID = nil
    }

    // MARK: - Streaming

    private func handleStreamUpdate(_ update: LocalAssistantStructuredTurnUpdate, threadID: UUID, generationID: UUID) {
        guard activeGenerationID == generationID else { return }
        guard case let .visiblePreview(text) = update else { return }

        latestRawStreamingText = text
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
                threadID: threadID,
                generationID: generationID,
                revision: revision
            )
        }
    }

    private func applySanitizedStreamPreview(
        _ text: String,
        threadID: UUID,
        generationID: UUID,
        revision: Int
    ) {
        guard activeGenerationID == generationID,
              streamPreviewRevision == revision else { return }
        lastVisibleText = text
        streamingResponse = text
        PersonaChatStore.shared.updateLastAssistantMessage(in: threadID, text: text)
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
        outputSafety: SafetyDecision
    ) {
        guard activeGenerationID == generationID else { return }
        let final = reply?.isEmpty == false ? reply! : (latestRawStreamingText ?? streamingResponse)
        guard let cleaned = meaningfulResponse(final) else {
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
            let rewritten = outputSafety.rewrittenText?.trimmingCharacters(in: .whitespacesAndNewlines)
            persistableText = rewritten?.isEmpty == false
                ? outputSafety.rewrittenText!
                : KizunaCopy.text(
                    japanese: "うまく言えないけど、それは話したくないな。別の話にしよう?",
                    english: "I can't put that into words, and I'd rather not discuss it. Let's talk about something else."
                )
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
        streamingResponse = persistableText
        PersonaChatStore.shared.finalizeLastAssistantMessage(in: threadID, text: persistableText)
        phase = .idle
        invalidatePendingStreamSanitization()
        activeGenerationID = nil
        activeThreadID = nil
        activeGenerationThreadID = nil
        lastErrorThreadID = nil
    }

    /// Adapt a legacy PersonaProfile to the CharacterProfile context required
    /// by the shared output checker. Legacy profiles have no independent
    /// safety-rating field, so they use the existing general-audience default.
    private func safetyCharacter(for profile: PersonaProfile) -> CharacterProfile {
        CharacterProfile(
            id: profile.id,
            name: profile.name,
            displayName: profile.name,
            category: .chatBuddy,
            relationshipGenre: .none,
            personality: profile.personality,
            scenario: profile.freeFormAddendum,
            safetyRating: .general
        )
    }

    private func startWatchdog(threadID: UUID, generationID: UUID) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 75_000_000_000)
            await MainActor.run {
                guard let self,
                      self.activeGenerationID == generationID,
                      self.phase == .thinking else { return }
                self.generationTask?.cancel()
                self.generationTask = nil
                LocalAssistantRuntimeBridge.shared.cancelActiveGeneration(generationID: generationID)
                if let partial = self.meaningfulResponse(
                    self.latestRawStreamingText ?? self.streamingResponse
                ) {
                    PersonaChatStore.shared.finalizeLastAssistantMessage(in: threadID, text: partial)
                    self.streamingResponse = partial
                    self.phase = .idle
                    self.invalidatePendingStreamSanitization()
                    self.activeGenerationID = nil
                    self.activeThreadID = nil
                    self.activeGenerationThreadID = nil
                } else {
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
                if !msg.text.isEmpty {
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

    private func legacyPersonaSystemPrompt(for profile: PersonaProfile) -> String {
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
        return """
        \(KizunaCopy.text(japanese: "あなたはKizunaの会話相手です。", english: "You are the user's kizuna conversation partner.")) \(languageInstruction)
        \(persona)
        \(outputRules)
        \(safetyRules)
        """
    }

    private func meaningfulResponse(_ text: String) -> String? {
        let sanitized = sanitize(text)
        let cleaned = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let placeholders: Set<String> = ["…", "・・・", "・・", "...", "..", "."]
        guard !placeholders.contains(cleaned) else { return nil }
        return sanitized
    }

    private func failGeneration(threadID: UUID, generationID: UUID, message: String) {
        guard activeGenerationID == generationID else { return }
        PersonaChatStore.shared.removeLastAssistantMessage(in: threadID)
        streamingResponse = ""
        phase = .error(message)
        invalidatePendingStreamSanitization()
        activeGenerationID = nil
        activeThreadID = nil
        activeGenerationThreadID = nil
        lastErrorThreadID = threadID
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

    /// The runtime exposes structured visible text. Keep this final safeguard
    /// deliberately non-destructive because the value is persisted to history.
    private func sanitize(_ text: String) -> String {
        PersonaResponseSanitizer.sanitize(text)
    }
}
