/*
仕様:
- 役割: Story モードの会話セッション (StorySession) を駆動するサービス。
  ユーザー発話 → 270M 分類 + シーンキャラ選別 → safety → StoryPromptBuilder → E4B 生成 →
  safety → 話者ごとに分割しメッセージ化 → memory/scene summary 更新。
- 主な型: `StorySessionService` (ObservableObject, MainActor)。
- 編集ポイント: 多話者の応答 parse、active キャラ enforcement、自動 scene 切替トリガ。
*/

import Foundation
import Combine

@MainActor
final class StorySessionService: ObservableObject {
    enum Phase: Equatable {
        case idle
        case thinking
        case error(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var streamingResponse: String = ""
    @Published private(set) var streamingSpeakerName: String?
    @Published private(set) var streamingStatusText: String = ""
    @Published private(set) var savedTurnRevision: Int = 0

    // DI (デフォルトは Local + Mock)
    private let characterRepo: CharacterRepository = LocalJSONCharacterRepository()
    private let memoryRepo: MemoryRepository = LocalJSONMemoryRepository()
    private let worldRepo: StoryWorldRepository = LocalJSONStoryWorldRepository()
    private let castRepo: CastRepository = LocalJSONCastRepository()
    private let sceneRepo: StorySceneRepository = LocalJSONStorySceneRepository()
    private let sessionRepo: StorySessionRepository = LocalJSONStorySessionRepository()
    private let safetyPipeline = SafetyPipeline.shared
    private let sceneSelector: SceneCharacterSelecting = MockSceneCharacterSelector()
    private let summarizer: SceneSummarizing = MockSceneSummarizer()
    private let nextScene: NextSceneSuggesting = MockNextSceneSuggester()
    private let memorySelector: MemorySelecting = MockMemorySelector()
    private let memorySummarizer: MemorySummarizing = MockMemorySummarizer()
    private let promptBuilder = StoryPromptBuilder()

    private var generationTask: Task<Void, Never>?
    private var lastVisibleText: String = ""
    private var activeGenerationID: UUID?
    private let progressDecoder = JSONDecoder()

    private struct StoryProgressUpdate: Codable {
        var progressLabel: String?
        var currentObjective: String?
        var lastTurnProgress: String?
        var lastSceneSummary: String?
        var unresolvedHooks: [String]?
    }

    /// 入口: ユーザー発話を送る。session/scene は呼び出し側で確定済み前提。
    func send(
        _ userText: String,
        session: StorySession,
        world: StoryWorld,
        scene: StoryScene,
        generationModel: StoryGenerationModel = .e4b
    ) {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, phase != .thinking else { return }
        phase = .thinking
        streamingResponse = ""
        streamingSpeakerName = nil
        streamingStatusText = "準備中"
        lastVisibleText = ""
        let generationID = UUID()
        activeGenerationID = generationID

        generationTask = Task { [weak self] in
            await self?.runPipeline(
                userText: trimmed,
                session: session,
                world: world,
                scene: scene,
                generationModel: generationModel,
                generationID: generationID
            )
        }
        startWatchdog(session: session, generationID: generationID)
    }

    func addNarration(_ text: String, session: StorySession) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var next = session
        next.messages.append(StoryMessage(author: .narrator, text: trimmed))
        Task {
            try? await sessionRepo.saveSession(next)
            await MainActor.run {
                self.savedTurnRevision += 1
            }
        }
    }

    func cancel() {
        generationTask?.cancel()
        LocalAssistantRuntimeBridge.shared.cancelActiveGeneration()
        activeGenerationID = nil
        phase = .idle
        streamingSpeakerName = nil
        streamingStatusText = ""
    }

    // MARK: - Pipeline

    private func runPipeline(
        userText: String,
        session: StorySession,
        world: StoryWorld,
        scene: StoryScene,
        generationModel: StoryGenerationModel,
        generationID: UUID
    ) async {
        var session = session
        var scene = scene

        // user メッセージ append + 空 narration ストリーム先を確保
        streamingStatusText = "会話を保存中"
        let userMsg = StoryMessage(author: .user, text: userText)
        session.messages.append(userMsg)
        try? await sessionRepo.saveSession(session)

        // 1) キャラ index / cast 取得
        streamingStatusText = "登場キャラを確認中"
        let allCharacters = (try? await characterRepo.fetchCharacters()) ?? []
        let charIndex = allCharacters.reduce(into: [UUID: CharacterProfile]()) { result, character in
            guard result[character.id] == nil else { return }
            result[character.id] = character
        }
        var cast = (try? await castRepo.fetchCast(storyWorldId: world.id)) ?? []
        if cast.isEmpty, !world.characterIds.isEmpty {
            cast = defaultCastMembers(for: world, scene: scene)
            for member in cast { try? await castRepo.saveCast(member) }
        }

        // 2) Mock 安全用に CharacterProfile を 1 つ採用 (main または最 importance)。
        //    SafetyPipeline は単一 character を要求するシグネチャなので、世界の代表者として渡す。
        streamingStatusText = "入力を確認中"
        let representativeCharacter: CharacterProfile = {
            if let mainID = world.mainCharacterId, let p = charIndex[mainID] { return p }
            if let firstCast = cast.sorted(by: { $0.importance > $1.importance }).first,
               let p = charIndex[firstCast.characterId] { return p }
            return CharacterProfile(
                name: world.title,
                displayName: world.title,
                category: world.genre,
                relationshipGenre: world.relationshipGenre
            )
        }()

        // 3) 入力 safety
        let inSafety = await safetyPipeline.evaluateInput(userText, character: representativeCharacter)
        if inSafety.action == .block {
            let polite = inSafety.rewrittenText ?? "(ナレーション) その話題はここではそっと脇に置いて、別の場面に進もう。"
            let narration = StoryMessage(author: .narrator, text: polite)
            session.messages.append(narration)
            try? await sessionRepo.saveSession(session)
            await MainActor.run {
                guard self.activeGenerationID == generationID else { return }
                self.streamingResponse = polite
                self.streamingStatusText = ""
                self.phase = .idle
                self.activeGenerationID = nil
            }
            return
        }
        let effectiveUserText = inSafety.rewrittenText ?? userText

        // 4) シーンに居るキャラを 270M (Mock) で選定。最大 3 名。
        streamingStatusText = "場面のキャラを選定中"
        let selectedIDs = await sceneSelector.select(
            userInput: effectiveUserText,
            currentScene: scene,
            cast: cast,
            characterIndex: charIndex,
            maxActive: StoryConstants.maxActiveCharacters
        )
        scene.activeCharacterIds = Array(selectedIDs.prefix(StoryConstants.maxActiveCharacters))
        try? await sceneRepo.saveScene(scene)

        let activeCast = cast.filter { scene.activeCharacterIds.contains($0.characterId) }
        let inactiveCast = cast.filter { !scene.activeCharacterIds.contains($0.characterId) }

        // 5) メモリー候補 + 選別。active を優先しつつ、世界全体の関係継続に必要な inactive の高重要度メモリーも少し入れる。
        streamingStatusText = "記憶を読み込み中"
        var candidates: [CharacterMemory] = []
        for member in activeCast {
            let mems = (try? await memoryRepo.fetchMemories(characterId: member.characterId)) ?? []
            candidates.append(contentsOf: mems)
        }
        for member in inactiveCast {
            let mems = ((try? await memoryRepo.fetchMemories(characterId: member.characterId)) ?? [])
                .filter { $0.importance >= 0.65 }
            candidates.append(contentsOf: mems)
        }
        let selectedMemories: [CharacterMemory]
        if candidates.count > 12 {
            selectedMemories = await memorySelector.select(query: effectiveUserText, candidates: candidates, topK: 12)
        } else {
            selectedMemories = candidates
        }
        if !selectedMemories.isEmpty {
            try? await memoryRepo.markUsed(ids: selectedMemories.map(\.id))
        }

        // 6) StoryPromptBuilder
        streamingStatusText = "物語コンテキストを構築中"
        let prompt = promptBuilder.build(
            world: world,
            scene: scene,
            activeCast: activeCast,
            inactiveCast: inactiveCast,
            characterIndex: charIndex,
            selectedMemories: selectedMemories,
            session: session,
            recentMessages: Array(storyContentMessages(from: session.messages).suffix(48)),
            userInput: effectiveUserText,
            generationModel: generationModel,
            safetyDecision: inSafety
        )

        // 7) Story model 生成。31B を明示選択した時だけ Gemma4 API を使う。
        streamingStatusText = generationModel == .b31 ? "Gemma4 31Bで発話生成中" : "ローカルモデルで発話生成中"
        var reply: String?
        var isRuntimeNotice = false
        var usedBackendName: String
        if generationModel == .b31 {
            if StoryGemma31BAPIService.shared.hasAPIKey {
                usedBackendName = "Gemma4 31B API"
                reply = await generateWithGemma31BAPI(
                    systemPrompt: prompt,
                    userPrompt: effectiveUserText,
                    generationID: generationID
                )
                if isGemma31BRuntimeNotice(reply) {
                    isRuntimeNotice = true
                    usedBackendName = "Gemma4 31B API失敗"
                }
            } else {
                streamingStatusText = "NAGI APIキー未設定"
                isRuntimeNotice = true
                usedBackendName = "Gemma4 31B API未設定"
                reply = "NAGI の Gemma4 31B APIキーが未設定です。モデル詳細からAPIキーを設定してから続けてください。"
            }
        } else {
            let advanced = voiceOptimizedAdvancedSettings()
            let localModelManager = LocalAssistantModelManager.shared
            let selectedModelURL = generationModel.installedModelURL ?? localModelManager.installedModelURL
            if let localUnavailableMessage = localStoryRuntimeUnavailableMessage(
                availability: localModelManager.runtimeAvailability,
                selectedModelURL: selectedModelURL
            ) {
                streamingStatusText = "ローカル未起動"
                isRuntimeNotice = true
                usedBackendName = localStoryBackendStatusName(
                    availability: localModelManager.runtimeAvailability,
                    selectedModelURL: selectedModelURL
                )
                reply = localUnavailableMessage
            } else {
                usedBackendName = localStoryBackendStatusName(
                    availability: localModelManager.runtimeAvailability,
                    selectedModelURL: selectedModelURL
                )
                reply = await LocalAssistantRuntimeBridge.shared.generateReply(
                    prompt: effectiveUserText,
                    contextPrompt: nil,
                    coachMode: .studio,
                    reasoningMode: .persona,
                    researchMode: .off,
                    childAge: 12,
                    pageInfo: nil,
                    safetySnapshot: nil,
                    advancedSettings: advanced,
                    overrideSystemPrompt: prompt,
                    overrideModelURL: selectedModelURL,
                    onUpdate: { @MainActor [weak self] update in
                        self?.handleStreamUpdate(update, generationID: generationID)
                    }
                )
                if reply == nil {
                    streamingStatusText = "ローカル起動失敗"
                    isRuntimeNotice = true
                    usedBackendName = "iori ローカル生成失敗"
                    reply = localStoryGenerationFailureMessage()
                }
            }
        }

        // 8) 出力 safety
        streamingStatusText = "発話を整形中"
        var rawFinal = (reply?.isEmpty == false ? reply! : streamingResponse)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        rawFinal = sanitizedFinalText(rawFinal)
        if isRuntimeNotice {
            let notice = StoryMessage(author: .system, text: textAfterSpeakerDelimiter(rawFinal))
            session.messages.append(notice)
            session.lastSelectedModelName = generationModel.displayName
            session.lastUsedBackendName = usedBackendName
            try? await sessionRepo.saveSession(session)
            await MainActor.run {
                guard self.activeGenerationID == generationID else { return }
                self.streamingResponse = rawFinal
                self.streamingSpeakerName = "システム"
                self.streamingStatusText = ""
                self.savedTurnRevision += 1
                self.phase = .idle
                self.activeGenerationID = nil
            }
            return
        }
        let outSafety = await safetyPipeline.evaluateOutput(rawFinal, character: representativeCharacter)
        switch outSafety.action {
        case .block:
            rawFinal = outSafety.rewrittenText ?? "ナレーション: しばらく沈黙が流れた。別の話題にしよう。"
        case .soften, .requireEdit:
            if let rewritten = outSafety.rewrittenText, !rewritten.isEmpty { rawFinal = rewritten }
        case .warn, .allow:
            break
        }
        rawFinal = ensureStoryNarration(in: rawFinal, scene: scene)
        rawFinal = stabilizeStoryTurn(rawFinal, activeCast: activeCast, characterIndex: charIndex, scene: scene)

        // 9) 「名前: 本文」行ごとに StoryMessage 化
        streamingStatusText = "発話を保存中"
        let newMessages = parseSpeakerLines(rawFinal, cast: cast, characterIndex: charIndex)
        for m in newMessages {
            session.messages.append(m)
        }
        session.lastSelectedModelName = generationModel.displayName
        session.lastUsedBackendName = usedBackendName
        try? await sessionRepo.saveSession(session)

        // 10) Scene summary 更新 (270M)
        streamingStatusText = "場面要約を更新中"
        let newSummary = await summarizer.updateSummary(
            currentSummary: scene.summary,
            recentMessages: Array(storyContentMessages(from: session.messages).suffix(18)),
            characterIndex: charIndex
        )
        if newSummary != scene.summary {
            scene.summary = newSummary
            try? await sceneRepo.saveScene(scene)
        }
        streamingStatusText = "物語進行を更新中"
        let progressUpdate = await generateProgressUpdate(
            world: world,
            scene: scene,
            session: session,
            userText: userText,
            assistantMessages: newMessages,
            fallbackSceneSummary: newSummary,
            generationModel: generationModel
        )
        session.progressLabel = progressUpdate.progressLabel.nonEmpty
            ?? session.progressLabel.nonEmpty
            ?? "第1章 きっかけ"
        session.currentObjective = progressUpdate.currentObjective.nonEmpty
            ?? session.currentObjective.nonEmpty
            ?? scene.sceneGoal.nonEmpty
            ?? world.storyGoal.nonEmpty
        session.lastTurnProgress = progressUpdate.lastTurnProgress.nonEmpty
            ?? session.lastTurnProgress.nonEmpty
        session.lastSceneSummary = progressUpdate.lastSceneSummary.nonEmpty
            ?? newSummary.nonEmpty
            ?? session.lastSceneSummary.nonEmpty
        session.unresolvedHooks = normalizedHooks(
            progressUpdate.unresolvedHooks,
            fallback: unresolvedHooks(world: world, scene: scene, previous: session.unresolvedHooks)
        )
        try? await sessionRepo.saveSession(session)

        await MainActor.run {
            guard self.activeGenerationID == generationID else { return }
            self.streamingResponse = rawFinal
            self.streamingSpeakerName = newMessages.last?.speakerDisplayName
            self.streamingStatusText = ""
            self.savedTurnRevision += 1
            self.phase = .idle
            self.activeGenerationID = nil
        }

        // 11) メモリー抽出 (active キャラ全員に対して同じ抽出を流し込む — 共有体験のため)
        let userVisibleAssistant = newMessages.map(\.text).joined(separator: "\n")
        for member in activeCast {
            guard let profile = charIndex[member.characterId] else { continue }
            let mems = await memorySummarizer.extract(
                userText: userText,
                assistantText: userVisibleAssistant,
                character: profile
            )
            for m in mems { try? await memoryRepo.saveMemory(m) }
        }
    }

    private func storyContentMessages(from messages: [StoryMessage]) -> [StoryMessage] {
        messages.filter { message in
            if case .system = message.author { return false }
            return true
        }
    }

    // MARK: - Stream handling

    private func generateWithGemma31BAPI(
        systemPrompt: String,
        userPrompt: String,
        generationID: UUID
    ) async -> String? {
        await MainActor.run {
            guard self.activeGenerationID == generationID else { return }
            self.streamingSpeakerName = "NAGI"
            self.streamingStatusText = "Gemma4 31Bで発話生成中"
            self.streamingResponse = "ナレーション: NAGIが場面と会話履歴を読み込んでいます。"
        }

        do {
            let text = try await StoryGemma31BAPIService.shared.generate(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                temperature: 0.72,
                maxOutputTokens: 4096
            )
            await MainActor.run {
                guard self.activeGenerationID == generationID else { return }
                self.streamingResponse = text
                self.streamingStatusText = "発話を整形中"
                self.streamingSpeakerName = self.detectCurrentSpeakerName(in: text)
            }
            return text
        } catch {
            let message = "ナレーション: Gemma4 31B API の応答に失敗しました。\(error.localizedDescription)"
            await MainActor.run {
                guard self.activeGenerationID == generationID else { return }
                self.streamingResponse = message
                self.streamingStatusText = ""
                self.streamingSpeakerName = nil
            }
            return message
        }
    }

    private func handleStreamUpdate(_ update: LocalAssistantStructuredTurnUpdate, generationID: UUID) {
        guard activeGenerationID == generationID else { return }
        guard case let .visiblePreview(text) = update else { return }
        let stripped = sanitize(text)
        streamingSpeakerName = detectCurrentSpeakerName(in: stripped)
        streamingStatusText = "発話生成中"
        if stripped.count >= lastVisibleText.count {
            lastVisibleText = stripped
            streamingResponse = stripped
        } else {
            lastVisibleText = stripped
            streamingResponse = stripped
        }
    }

    private func startWatchdog(session: StorySession, generationID: UUID) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 75_000_000_000)
            await MainActor.run {
                guard let self,
                      self.activeGenerationID == generationID,
                      self.phase == .thinking else { return }
                LocalAssistantRuntimeBridge.shared.cancelActiveGeneration()
                let fallback = self.streamingResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "ナレーション: 応答が途切れ、場面はいったん止まった。もう一度話しかけてください。"
                    : self.streamingResponse
                Task {
                    var next = session
                    next.messages.append(StoryMessage(author: .narrator, text: fallback))
                    try? await self.sessionRepo.saveSession(next)
                    await MainActor.run {
                        self.savedTurnRevision += 1
                    }
                }
                self.streamingResponse = fallback
                self.streamingSpeakerName = self.detectCurrentSpeakerName(in: fallback)
                self.streamingStatusText = ""
                self.phase = .idle
                self.activeGenerationID = nil
            }
        }
    }

    // MARK: - Speaker line parsing

    /// 「名前: 本文」「ナレーション: 本文」を含む可能性のあるテキストを行ごとに分割し、
    /// StoryMessage の配列にする。前置きや空行は捨てる。
    private func parseSpeakerLines(
        _ text: String,
        cast: [CastMember],
        characterIndex: [UUID: CharacterProfile]
    ) -> [StoryMessage] {
        let castNames: [(UUID, String)] = cast.compactMap { member in
            if let p = characterIndex[member.characterId] {
                return (member.characterId, p.displayName.isEmpty ? p.name : p.displayName)
            }
            return nil
        }
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var out: [StoryMessage] = []
        for line in lines where !line.isEmpty {
            // 「ナレーション:」
            if line.hasPrefix("ナレーション:") || line.hasPrefix("ナレーション：") || line.hasPrefix("ナレーター:") || line.hasPrefix("ナレーター：") {
                let body = textAfterSpeakerDelimiter(line)
                if !body.isEmpty {
                    out.append(StoryMessage(author: .narrator, text: body))
                }
                continue
            }
            // 「名前: 本文」 — active キャラの名前と前方一致を確認
            var matched: (UUID, String, String)? = nil
            for (id, name) in castNames {
                if line.hasPrefix(name + ":") || line.hasPrefix(name + "：") {
                    let body = textAfterSpeakerDelimiter(line)
                    matched = (id, name, body)
                    break
                }
            }
            if let (id, name, body) = matched, !body.isEmpty {
                out.append(StoryMessage(author: .cast(characterId: id, displayName: name), text: body))
                continue
            }
            // フォールバック: 名前と紐付かない行はナレーション扱い
            out.append(StoryMessage(author: .narrator, text: line))
        }
        if out.isEmpty, !text.isEmpty {
            out.append(StoryMessage(author: .narrator, text: text))
        }
        return out
    }

    private func detectCurrentSpeakerName(in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let last = lines.last else { return nil }
        if last.hasPrefix("ナレーション:") || last.hasPrefix("ナレーション：") ||
            last.hasPrefix("ナレーター:") || last.hasPrefix("ナレーター：") {
            return "ナレーション"
        }
        guard let idx = last.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return nil }
        let speaker = String(last[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
        return speaker.isEmpty ? nil : speaker
    }

    private func textAfterSpeakerDelimiter(_ line: String) -> String {
        guard let idx = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else {
            return line.trimmingCharacters(in: .whitespaces)
        }
        return String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - helpers

    private func voiceOptimizedAdvancedSettings() -> GemmaAdvancedSettings {
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

    private func isGemma31BRuntimeNotice(_ reply: String?) -> Bool {
        guard let reply else { return true }
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.contains("Gemma4 31B API の応答に失敗しました")
            || text.contains("Gemma4 APIキーが未設定")
            || text.contains("Gemma4 31B API に失敗しました")
            || text.contains("Gemma4 31B API が空レスポンス")
            || text.contains("Gemma4 31B API の出力本文が空")
    }

    private func localStoryRuntimeUnavailableMessage(
        availability: LocalAssistantRuntimeAvailability,
        selectedModelURL: URL?
    ) -> String? {
        switch availability {
        case .executable:
            return selectedModelURL == nil
                ? "ローカルモデルの保存先を確認できません。モデル設定で保存状態を確認してください。"
                : nil
        case .checking:
            return "iori はまだ端末内で起動確認中です。確認が終わるまで、この場面のローカル生成は開始しません。"
        case .savedOnly:
            return "iori のモデルファイルは保存済みですが、端末内で起動できる確認がまだ終わっていません。モデル詳細から実行確認をしてください。"
        case .recentFailure:
            let detail = LocalAssistantModelManager.shared.runtimeDiagnosticSummary
                ?? LocalAssistantRuntimeBridge.shared.lastRuntimeError
                ?? "ローカルモデルの起動確認に失敗しました。"
            return "iori のローカル起動に失敗しました。\(detail)"
        case .modelMissing:
            return "iori のローカルモデルが未導入です。モデルを保存し、self-check が成功してからこの場面を続けられます。"
        }
    }

    private func localStoryBackendStatusName(
        availability: LocalAssistantRuntimeAvailability,
        selectedModelURL: URL?
    ) -> String {
        switch availability {
        case .executable:
            if let selectedModelURL {
                return selectedModelURL.pathExtension.lowercased() == "litertlm"
                    ? "iori LiteRT-LM"
                    : "iori ローカル"
            }
            return "iori モデルパス不明"
        case .checking:
            return "iori 起動確認中"
        case .savedOnly:
            return "iori 保存済み・未起動"
        case .recentFailure:
            return "iori 起動失敗"
        case .modelMissing:
            return "iori 未導入"
        }
    }

    private func localStoryGenerationFailureMessage() -> String {
        let detail = LocalAssistantModelManager.shared.runtimeDiagnosticSummary
            ?? LocalAssistantRuntimeBridge.shared.lastRuntimeError
            ?? "ローカル生成が完了しませんでした。"
        return "iori のローカル生成に失敗しました。\(detail)"
    }

    private func sanitize(_ text: String) -> String {
        var out = text
        for token in ["**", "__", "`", "*", "_"] {
            out = out.replacingOccurrences(of: token, with: "")
        }
        // <channel|> 等の thinking マーカー以前を捨てる
        let markers = ["<|channel|>", "<channel|>", "<|channel>", "<channel>"]
        var lastEnd: String.Index?
        for m in markers {
            if let r = out.range(of: m, options: .backwards) {
                if let cur = lastEnd { if r.upperBound > cur { lastEnd = r.upperBound } } else { lastEnd = r.upperBound }
            }
        }
        if let end = lastEnd { out = String(out[end...]) }
        // 余分な空行を圧縮
        while out.contains("\n\n") { out = out.replacingOccurrences(of: "\n\n", with: "\n") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sanitizedFinalText(_ text: String) -> String {
        let cleaned = sanitize(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            return "ナレーション: 一瞬、場面に沈黙が落ちた。誰かが次の言葉を待っている。"
        }
        if cleaned.count <= 1 {
            return "ナレーション: 返事は短く途切れた。もう少しはっきり言葉にしてほしそうだ。"
        }
        return cleaned
    }

    private func ensureStoryNarration(in text: String, scene: StoryScene) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let lines = trimmed.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let hasNarration = lines.contains { line in
            line.hasPrefix("ナレーション:") || line.hasPrefix("ナレーション：") || line.hasPrefix("ナレーター:") || line.hasPrefix("ナレーター：")
        }
        if hasNarration { return trimmed }

        let location = scene.location.trimmingCharacters(in: .whitespacesAndNewlines)
        let mood = scene.mood.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix: String
        if !location.isEmpty, !mood.isEmpty {
            prefix = "ナレーション: \(location)に、\(mood)空気がゆっくり満ちていく。"
        } else if !location.isEmpty {
            prefix = "ナレーション: \(location)で、場面が静かに動き出す。"
        } else if !mood.isEmpty {
            prefix = "ナレーション: \(mood)空気の中、次の言葉を待つ沈黙が落ちる。"
        } else {
            prefix = "ナレーション: 場面が少しだけ動き、誰かの視線が次の言葉を待つ。"
        }
        return ([prefix] + lines).joined(separator: "\n")
    }

    private func stabilizeStoryTurn(
        _ text: String,
        activeCast: [CastMember],
        characterIndex: [UUID: CharacterProfile],
        scene: StoryScene
    ) -> String {
        let activeNames: [(UUID, String)] = activeCast.compactMap { member in
            guard let profile = characterIndex[member.characterId] else { return nil }
            return (member.characterId, profile.displayName.isEmpty ? profile.name : profile.displayName)
        }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var firstNarration: String?
        var speeches: [String] = []
        var speakersUsed = Set<UUID>()

        for line in lines {
            if line.hasPrefix("ナレーション:") || line.hasPrefix("ナレーション：") || line.hasPrefix("ナレーター:") || line.hasPrefix("ナレーター：") {
                if firstNarration == nil {
                    firstNarration = normalizeNarrationLine(line)
                }
                continue
            }

            for (id, name) in activeNames {
                if line.hasPrefix(name + ":") || line.hasPrefix(name + "：") {
                    let body = textAfterSpeakerDelimiter(line)
                    if !body.isEmpty, speeches.count < 3, speakersUsed.insert(id).inserted {
                        speeches.append("\(name): \(body)")
                    }
                    break
                }
            }
        }

        if firstNarration == nil {
            firstNarration = synthesizeNarration(scene: scene)
        }

        if speeches.isEmpty, let first = activeNames.first {
            let fallbackBody = firstNonSpeakerBody(from: lines) ?? "……今の、少し気になります。"
            speeches.append("\(first.1): \(fallbackBody)")
        }

        return ([firstNarration].compactMap { $0 } + speeches)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func normalizeNarrationLine(_ line: String) -> String {
        let body = textAfterSpeakerDelimiter(line)
        return body.isEmpty ? "ナレーション: 場面に短い沈黙が落ちる。" : "ナレーション: \(body)"
    }

    private func synthesizeNarration(scene: StoryScene) -> String {
        let location = scene.location.trimmingCharacters(in: .whitespacesAndNewlines)
        let mood = scene.mood.trimmingCharacters(in: .whitespacesAndNewlines)
        if !location.isEmpty, !mood.isEmpty {
            return "ナレーション: \(location)に、\(mood)空気が静かに残っている。"
        }
        if !location.isEmpty {
            return "ナレーション: \(location)で、相手の反応を待つ間が生まれる。"
        }
        return "ナレーション: ふっと空気が変わり、次の言葉を待つ沈黙が落ちる。"
    }

    private func firstNonSpeakerBody(from lines: [String]) -> String? {
        for line in lines {
            if line.hasPrefix("ナレーション:") || line.hasPrefix("ナレーション：") || line.hasPrefix("ナレーター:") || line.hasPrefix("ナレーター：") {
                continue
            }
            let body = textAfterSpeakerDelimiter(line)
            if !body.isEmpty, body.count <= 80 {
                return body
            }
        }
        return nil
    }

    private func defaultCastMembers(for world: StoryWorld, scene: StoryScene) -> [CastMember] {
        let activeIDs = Set(scene.activeCharacterIds.isEmpty ? Array(world.characterIds.prefix(StoryConstants.maxActiveCharacters)) : scene.activeCharacterIds)
        return world.characterIds.enumerated().map { index, characterID in
            CastMember(
                storyWorldId: world.id,
                characterId: characterID,
                roleInStory: characterID == world.mainCharacterId || index == 0 ? .main : .secondary,
                importance: characterID == world.mainCharacterId || index == 0 ? 1.0 : 0.65,
                introductionTiming: activeIDs.contains(characterID) ? .opening : .early,
                relationshipToUser: "",
                isActiveInCurrentScene: activeIDs.contains(characterID)
            )
        }
    }

    private func generateProgressUpdate(
        world: StoryWorld,
        scene: StoryScene,
        session: StorySession,
        userText: String,
        assistantMessages: [StoryMessage],
        fallbackSceneSummary: String,
        generationModel: StoryGenerationModel
    ) async -> StoryProgressUpdate {
        let fallback = StoryProgressUpdate(
            progressLabel: session.progressLabel.nonEmpty ?? "第1章 きっかけ",
            currentObjective: session.currentObjective.nonEmpty ?? scene.sceneGoal.nonEmpty ?? world.storyGoal.nonEmpty,
            lastTurnProgress: synthesizeTurnProgress(from: assistantMessages),
            lastSceneSummary: fallbackSceneSummary.nonEmpty ?? session.lastSceneSummary.nonEmpty,
            unresolvedHooks: unresolvedHooks(world: world, scene: scene, previous: session.unresolvedHooks)
        )

        let systemPrompt = """
        あなたは物語セッションの進行状態だけを更新する編集者です。
        出力はJSONオブジェクトのみ。Markdown、説明、コードブロックは禁止。
        各値は日本語で短くしてください。
        progressLabel は「第1章 きっかけ」「第1章 すれ違い」「第2章 放課後の約束」のような章と局面名。
        currentObjective は次に向かうこと。
        lastTurnProgress は今回のターンで物語上なにが変わったか。
        lastSceneSummary は再開時に役立つ短い要約。
        unresolvedHooks は未回収の気になる要素を最大4件。
        """
        let userPrompt = """
        世界: \(world.title)
        物語の目標: \(world.storyGoal)
        シーン: \(scene.title)
        場所: \(scene.location)
        空気: \(scene.mood)
        シーン目的: \(scene.sceneGoal)
        葛藤: \(scene.conflict ?? "")

        直前の進行:
        progressLabel: \(session.progressLabel ?? "")
        currentObjective: \(session.currentObjective ?? "")
        lastTurnProgress: \(session.lastTurnProgress ?? "")
        lastSceneSummary: \(session.lastSceneSummary ?? "")
        unresolvedHooks: \((session.unresolvedHooks ?? []).joined(separator: " / "))

        今回のユーザー発言:
        \(userText)

        今回の返答:
        \(assistantMessages.map { messageLine($0) }.joined(separator: "\n"))

        JSON形式:
        {"progressLabel":"第1章 ...","currentObjective":"...","lastTurnProgress":"...","lastSceneSummary":"...","unresolvedHooks":["..."]}
        """

        let raw: String?
        if generationModel == .b31, StoryGemma31BAPIService.shared.hasAPIKey {
            raw = try? await StoryGemma31BAPIService.shared.generate(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                temperature: 0.25,
                maxOutputTokens: 512
            )
        } else {
            var settings = voiceOptimizedAdvancedSettings()
            settings.useAutomaticTemperature = false
            settings.temperature = 0.2
            raw = await LocalAssistantRuntimeBridge.shared.generateReply(
                prompt: userPrompt,
                contextPrompt: nil,
                coachMode: .studio,
                reasoningMode: .persona,
                researchMode: .off,
                childAge: 12,
                pageInfo: nil,
                safetySnapshot: nil,
                advancedSettings: settings,
                overrideSystemPrompt: systemPrompt,
                overrideModelURL: generationModel.installedModelURL ?? LocalAssistantModelManager.shared.installedModelURL,
                onUpdate: nil
            )
        }

        guard let raw,
              let parsed = parseProgressUpdate(raw) else {
            return fallback
        }

        return StoryProgressUpdate(
            progressLabel: parsed.progressLabel.nonEmpty ?? fallback.progressLabel,
            currentObjective: parsed.currentObjective.nonEmpty ?? fallback.currentObjective,
            lastTurnProgress: parsed.lastTurnProgress.nonEmpty ?? fallback.lastTurnProgress,
            lastSceneSummary: parsed.lastSceneSummary.nonEmpty ?? fallback.lastSceneSummary,
            unresolvedHooks: normalizedHooks(parsed.unresolvedHooks, fallback: fallback.unresolvedHooks ?? [])
        )
    }

    private func parseProgressUpdate(_ text: String) -> StoryProgressUpdate? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates: [String] = {
            if let start = trimmed.firstIndex(of: "{"),
               let end = trimmed.lastIndex(of: "}"),
               start <= end {
                return [String(trimmed[start...end]), trimmed]
            }
            return [trimmed]
        }()
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let update = try? progressDecoder.decode(StoryProgressUpdate.self, from: data) else {
                continue
            }
            return update
        }
        return nil
    }

    private func normalizedHooks(_ hooks: [String]?, fallback: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func push(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            out.append(String(trimmed.prefix(80)))
        }
        (hooks ?? []).forEach(push)
        fallback.forEach(push)
        return Array(out.prefix(4))
    }

    private func synthesizeTurnProgress(from messages: [StoryMessage]) -> String? {
        let line = messages.reversed().map(messageLine).first { !$0.isEmpty }
        guard let line else { return nil }
        return String(line.prefix(48))
    }

    private func messageLine(_ message: StoryMessage) -> String {
        switch message.author {
        case .user:
            return "ユーザー: \(message.text)"
        case .system:
            return ""
        case .narrator:
            return "ナレーション: \(message.text)"
        case let .cast(_, displayName):
            return "\(displayName): \(message.text)"
        }
    }

    private func unresolvedHooks(world: StoryWorld, scene: StoryScene, previous: [String]?) -> [String] {
        var hooks: [String] = []
        var seen = Set<String>()
        func push(_ value: String?) {
            let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            hooks.append(trimmed)
        }
        previous?.forEach(push)
        push(scene.conflict)
        push(scene.sceneGoal)
        push(world.storyGoal)
        if !world.openingScene.isEmpty, hooks.count < 6 {
            push("オープニングの出来事: \(world.openingScene)")
        }
        return Array(hooks.prefix(8))
    }

    // MARK: - Scene helpers (UI からも使う)

    func suggestNextScenes(world: StoryWorld, completedScene: StoryScene) async -> [NextSceneSuggestion] {
        let cast = (try? await castRepo.fetchCast(storyWorldId: world.id)) ?? []
        return await nextScene.suggestNext(world: world, completedScene: completedScene, cast: cast)
    }
}

private extension StoryMessage {
    var speakerDisplayName: String? {
        switch author {
        case .user:
            return "あなた"
        case .system:
            return "システム"
        case .narrator:
            return "ナレーション"
        case let .cast(_, displayName):
            return displayName
        }
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
