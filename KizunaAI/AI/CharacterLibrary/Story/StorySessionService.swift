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
    /// 危険な相談の可能性を検知した時だけ、会話とは別にUIへ渡す。
    @Published private(set) var latestSafetyConcern: SafetyConcern?

    // DI (デフォルトは Local + Mock)
    private let characterRepo: CharacterRepository = LocalJSONCharacterRepository()
    private let memoryRepo: MemoryRepository = LocalJSONMemoryRepository()
    private let worldRepo: StoryWorldRepository = LocalJSONStoryWorldRepository()
    private let castRepo: CastRepository = LocalJSONCastRepository()
    private let sceneRepo: StorySceneRepository = LocalJSONStorySceneRepository()
    private let sessionRepo: StorySessionRepository = LocalJSONStorySessionRepository()
    // Lorebookは必要な項目だけを選択してプロンプトへ渡す。
    private let lorebookRepo: StoryLorebookRepository = LocalJSONStoryLorebookRepository()
    // 物語内メモリーは全体メモリー(CharacterMemory)と別ストアで管理する。
    private let storyMemoryRepo: StoryMemoryRepository = LocalJSONStoryMemoryRepository()
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
        // 本文とは別にAIが返す、今回の状態差分。
        var storyState: StoryStatePatch?
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
        latestSafetyConcern = nil
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

    /// 「このまま続ける」を選んだ時の短い了承を、会話本文へ 1 回だけ追加する。
    /// 休憩の判断や再提案はここでは行わず、ViewModel のアプリ側ポリシーに任せる。
    func addRestAcknowledgement(
        characterID: UUID,
        characterName: String,
        session: StorySession
    ) async {
        var next = session
        next.messages.append(
            StoryMessage(
                author: .cast(characterId: characterID, displayName: characterName),
                text: "了解。続けよう。"
            )
        )
        try? await sessionRepo.saveSession(next)
        savedTurnRevision += 1
    }

    /// DEBUG用。会話を変更せず、相談サポートUIだけを表示する。
    func showDebugSafetyConcern() {
        latestSafetyConcern = SafetyConcern.debugSample
        NSLog("[SafetyConcern] debug card published")
    }

    /// 利用者がサポートカードを閉じた時だけ、現在のUI表示を消す。
    func dismissSafetyConcern() {
        latestSafetyConcern = nil
    }

    /// アプリから明示的に依頼された時だけ、休憩提案の本文を 1 回生成する。
    /// 通常の物語ターンからこのメソッドを呼ばないことで、自主提案を防ぐ。
    func generateRestSuggestion(
        character: CharacterProfile?,
        world: StoryWorld,
        scene: StoryScene,
        generationModel: StoryGenerationModel
    ) async -> String? {
        let name = character.map { $0.displayName.isEmpty ? $0.name : $0.displayName } ?? "相手"
        let speakingStyle = character?.speakingStyle ?? "自然で落ち着いた口調"
        let personality = character?.personality ?? "穏やか"
        let systemPrompt = """
        あなたはアプリが休憩提案を表示するときの、キャラクターらしい一文だけを作る補助役です。
        この呼び出しはアプリ側が連続利用60分を検知した時だけ行われます。休憩を提案するかどうかを自分で判断してはいけません。
        出力は短い日本語の1文だけ。罪悪感、依存、催促、強制、睡眠・終了の指示、「必ず戻ってきて」「待っている」などの表現は禁止です。
        強制終了や利用制限を示さず、ユーザーが自由に選べる穏やかな提案にしてください。
        """
        let userPrompt = """
        キャラクター名: \(name)
        性格: \(personality)
        口調: \(speakingStyle)
        現在の物語: \(world.title)
        シーンの空気: \(scene.mood)

        上の設定に合わせて、目や体を少し休める提案を1文だけ書いてください。
        """

        let raw: String?
        switch generationModel {
        case .b31:
            raw = try? await StoryGemma31BAPIService.shared.generate(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                temperature: 0.7,
                maxOutputTokens: 96
            )
        case .e4b:
            let manager = LocalAssistantModelManager.shared
            let selectedModelURL = generationModel.installedModelURL ?? manager.installedModelURL
            guard manager.runtimeAvailability == .executable, selectedModelURL != nil else { return nil }
            raw = await LocalAssistantRuntimeBridge.shared.generateReply(
                prompt: userPrompt,
                contextPrompt: nil,
                coachMode: .studio,
                reasoningMode: .persona,
                researchMode: .off,
                childAge: 12,
                pageInfo: nil,
                safetySnapshot: nil,
                advancedSettings: voiceOptimizedAdvancedSettings(),
                overrideSystemPrompt: systemPrompt,
                overrideModelURL: selectedModelURL,
                onUpdate: nil
            )
        }
        return normalizeRestSuggestion(raw)
    }

    func cancel() {
        generationTask?.cancel()
        generationTask = nil
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
        guard isGenerationActive(generationID) else { return }
        var session = session
        var scene = scene

        // 初回ターンでも、現在シーンを構造化状態としてAIへ渡せるようにする。
        if session.storyState == nil {
            session.storyState = StoryState(
                location: scene.location,
                timeOfDay: scene.timeOfDay,
                mood: scene.mood,
                activeGoals: scene.sceneGoal.isEmpty ? [] : [scene.sceneGoal]
            )
        }

        // user メッセージ append + 空 narration ストリーム先を確保
        streamingStatusText = "会話を保存中"
        let userMsg = StoryMessage(author: .user, text: userText)
        session.messages.append(userMsg)
        try? await sessionRepo.saveSession(session)
        guard isGenerationActive(generationID) else { return }

        // 1) キャラ index / cast 取得
        streamingStatusText = "登場キャラを確認中"
        let allCharacters = (try? await characterRepo.fetchCharacters()) ?? []
        let charIndex = allCharacters.reduce(into: [UUID: CharacterProfile]()) { result, character in
            guard result[character.id] == nil else { return }
            result[character.id] = character
        }
        var cast = (try? await castRepo.fetchCast(storyWorldId: world.id)) ?? []
        let reconciledCast = reconciledCast(cast, for: world, scene: scene)
        if Set(cast.map(\.characterId)) != Set(reconciledCast.map(\.characterId)) || cast.count != reconciledCast.count {
            try? await castRepo.deleteAllCast(storyWorldId: world.id)
            cast = reconciledCast
            for member in cast { try? await castRepo.saveCast(member) }
        } else {
            cast = reconciledCast
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
        // 相談分類は入力/出力を変更しない。本文生成と並行するUI用の情報だけを作る。
        let safetyConcern = await safetyPipeline.classifyConcern(userText)
        guard isGenerationActive(generationID) else { return }
        // 生成完了を待たず、分類できた時点でUIへ通知する。
        // モデルが遅い／利用できない場合でも相談先を表示できるようにする。
        if let safetyConcern {
            self.latestSafetyConcern = safetyConcern
            NSLog(
                "[SafetyConcern] detected category=%@ level=%@ confidence=%.2f",
                safetyConcern.category.rawValue,
                safetyConcern.level.rawValue,
                safetyConcern.confidence
            )
        }
        let inSafety = await safetyPipeline.evaluateInput(userText, character: representativeCharacter)
        guard isGenerationActive(generationID) else { return }
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

        // 4) シーンに居るキャラを 270M (Mock) で選定。
        streamingStatusText = "場面のキャラを選定中"
        // 単体物語は毎ターン「ユーザー + 主役NPC1人」。群像劇だけ最大3人を許可する。
        let activeCharacterLimit = world.isSoloStory
            ? StoryConstants.soloActiveCharacters
            : StoryConstants.maxActiveCharacters
        // ユーザー操作キャラはシーン選定からも外す。表示用のcastには残すが、
        // AIが返すべき候補として選ばれると「主人公:」の代弁につながる。
        let userCharacterID = userControlledCharacterID(
            world: world,
            cast: cast,
            characterIndex: charIndex
        )
        let selectableCast: [CastMember] = {
            let aiCast = cast.filter { $0.characterId != userCharacterID }
            guard world.isSoloStory else { return aiCast }

            // 単体物語では入力に反応して脇役へ切り替えず、主役NPCだけを使う。
            if let mainID = world.mainCharacterId,
               let main = aiCast.first(where: { $0.characterId == mainID }) {
                return [main]
            }
            // 古いデータに mainCharacterId がない場合も、重要度トップ1人へ収束させる。
            return Array(aiCast.sorted { $0.importance > $1.importance }.prefix(StoryConstants.soloActiveCharacters))
        }()
        let selectedIDs = await sceneSelector.select(
            userInput: effectiveUserText,
            currentScene: scene,
            cast: selectableCast,
            characterIndex: charIndex,
            maxActive: activeCharacterLimit
        )
        scene.activeCharacterIds = Array(selectedIDs.prefix(activeCharacterLimit))
        try? await sceneRepo.saveScene(scene)
        guard isGenerationActive(generationID) else { return }

        let activeCast = cast.filter { scene.activeCharacterIds.contains($0.characterId) }
        let inactiveCast = cast.filter { !scene.activeCharacterIds.contains($0.characterId) }

        // ユーザー操作キャラはシーンには表示するが、AIの発話候補からは外す。
        // これをしないと、モデルが「主人公:」としてユーザーの台詞を勝手に書く。
        let userCharacterName: String? = {
            guard let id = userCharacterID, let profile = charIndex[id] else { return nil }
            return profile.displayName.isEmpty ? profile.name : profile.displayName
        }()
        let activeAICast = activeCast.filter { $0.characterId != userCharacterID }
        let inactiveAICast = inactiveCast.filter { $0.characterId != userCharacterID }
        // シーン選定がユーザーだけを返した場合でも、世界にいるNPCを1人だけ候補にする。
        let aiCastForTurn: [CastMember] = {
            if !activeAICast.isEmpty { return activeAICast }
            return Array(selectableCast
                .sorted { $0.importance > $1.importance }
                .prefix(activeCharacterLimit))
        }()

        // 5) 全体メモリー候補 + 選別。active を優先しつつ、世界全体の関係継続に必要な inactive の高重要度メモリーも少し入れる。
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
        guard isGenerationActive(generationID) else { return }
        if !selectedMemories.isEmpty {
            try? await memoryRepo.markUsed(ids: selectedMemories.map(\.id))
        }

        // 5-b) 物語内メモリーは、このStoryWorldの履歴だけから選ぶ。
        let storyMemoryCandidates = (try? await storyMemoryRepo.fetchMemories(storyWorldId: world.id)) ?? []
        guard isGenerationActive(generationID) else { return }
        let selectedStoryMemories = selectStoryMemories(
            query: effectiveUserText,
            candidates: storyMemoryCandidates,
            topK: 12
        )
        if !selectedStoryMemories.isEmpty {
            try? await storyMemoryRepo.markUsed(ids: selectedStoryMemories.map(\.id))
        }

        // 6) Lorebook: キーワード一致した設定だけを選択する。
        streamingStatusText = "Lorebookを選択中"
        var lorebookEntries = (try? await lorebookRepo.fetchEntries(storyWorldId: world.id)) ?? []
        guard isGenerationActive(generationID) else { return }
        // 既存のCharacterLorebookも移行期間は同じ選択器に流し込む。
        for member in cast {
            guard let legacy = try? await characterRepo.fetchLorebook(characterId: member.characterId),
                  !legacy.isEmpty else { continue }
            let keywords = (legacy.importantPeople + legacy.importantPlaces + legacy.importantEvents)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let content = [
                legacy.worldSetting,
                legacy.importantPeople.isEmpty ? "" : "重要人物: " + legacy.importantPeople.joined(separator: " / "),
                legacy.importantPlaces.isEmpty ? "" : "重要な場所: " + legacy.importantPlaces.joined(separator: " / "),
                legacy.importantEvents.isEmpty ? "" : "重要な出来事: " + legacy.importantEvents.joined(separator: " / "),
                legacy.worldRules.isEmpty ? "" : "世界のルール: " + legacy.worldRules.joined(separator: " / "),
                legacy.forbiddenBreaks.isEmpty ? "" : "壊してはいけない設定: " + legacy.forbiddenBreaks.joined(separator: " / ")
            ].filter { !$0.isEmpty }.joined(separator: "\n")
            if !content.isEmpty {
                lorebookEntries.append(
                    StoryLorebookEntry(
                        storyWorldId: world.id,
                        characterId: member.characterId,
                        title: "キャラクター設定",
                        keywords: keywords,
                        content: content,
                        priority: 40
                    )
                )
            }
        }
        let selectedLorebookEntries = promptBuilder.selectLorebookEntries(
            from: lorebookEntries,
            scene: scene,
            userInput: effectiveUserText
        )

        // 7) StoryPromptBuilder
        streamingStatusText = "物語コンテキストを構築中"
        let contentMessages = Array(storyContentMessages(from: session.messages).suffix(96))
        // 現在のユーザー発言は別途sendMessageへ渡す。直前3件だけをSDK本来の
        // user/model roleで初期履歴にし、巨大な文字列テンプレートへ混ぜない。
        let localConversationHistory: [LocalAssistantLiteRTLMHistoryMessage] = contentMessages
            .dropLast()
            .suffix(3)
            .compactMap { message in
                let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                switch message.author {
                case .user:
                    return LocalAssistantLiteRTLMHistoryMessage(role: .user, text: text)
                case .narrator:
                    return LocalAssistantLiteRTLMHistoryMessage(role: .model, text: text)
                case .cast(_, _):
                    return LocalAssistantLiteRTLMHistoryMessage(role: .model, text: text)
                case .system:
                    return nil
                }
            }
        let prompt: String
        if generationModel == .b31 {
            prompt = promptBuilder.build(
                world: world,
                scene: scene,
                activeCast: aiCastForTurn,
                inactiveCast: inactiveAICast,
                characterIndex: charIndex,
                selectedMemories: selectedMemories,
                session: session,
                recentMessages: contentMessages,
                userInput: effectiveUserText,
                generationModel: generationModel,
                safetyDecision: inSafety,
                storyState: session.storyState,
                selectedLorebookEntries: selectedLorebookEntries,
                selectedStoryMemories: selectedStoryMemories,
                userCharacterName: userCharacterName
            )
        } else {
            prompt = promptBuilder.buildLocalRuntimePrompt(
                world: world,
                scene: scene,
                activeCast: aiCastForTurn,
                characterIndex: charIndex,
                userCharacterName: userCharacterName
            )
        }
        guard isGenerationActive(generationID) else { return }

        // 8) Story model 生成。31B を明示選択した時だけ Gemma4 API を使う。
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
                    initialMessages: localConversationHistory,
                    overrideModelURL: selectedModelURL,
                    onUpdate: { @MainActor [weak self] update in
                        self?.handleStreamUpdate(update, generationID: generationID)
                    }
                )
                if reply == nil {
                    let runtimeError = LocalAssistantRuntimeBridge.shared.latestDebugSnapshot().errorMessage
                    streamingStatusText = runtimeError?.contains("記号だけ") == true
                        ? "ローカル出力が無効"
                        : "ローカル起動失敗"
                    isRuntimeNotice = true
                    usedBackendName = "iori ローカル生成失敗"
                    reply = localStoryGenerationFailureMessage(runtimeError: runtimeError)
                }
            }
        }

        // キャンセルやウォッチドッグ後に、古い生成結果を後段へ保存しない。
        guard isGenerationActive(generationID) else { return }

        // 9) 出力 safety
        streamingStatusText = "発話を整形中"
        var rawFinal = (reply?.isEmpty == false ? reply! : streamingResponse)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        rawFinal = sanitizedFinalText(rawFinal)
        if !isMeaningfulStoryText(rawFinal) {
            isRuntimeNotice = true
            usedBackendName += "・無効出力"
            rawFinal = generationModel == .b31
                ? "Gemma4 31B API が有効な本文を返しませんでした。もう一度試してください。"
                : localStoryGenerationFailureMessage(runtimeError: "記号だけの本文")
        }
        if isRuntimeNotice {
            guard isGenerationActive(generationID) else { return }
            let notice = StoryMessage(author: .system, text: textAfterSpeakerDelimiter(rawFinal))
            session.messages.append(notice)
            session.lastSelectedModelName = generationModel.displayName
            session.lastUsedBackendName = usedBackendName
            try? await sessionRepo.saveSession(session)
            await MainActor.run {
                guard self.activeGenerationID == generationID else { return }
                self.latestSafetyConcern = safetyConcern
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
        guard isGenerationActive(generationID) else { return }
        switch outSafety.action {
        case .block:
            rawFinal = outSafety.rewrittenText ?? "ナレーション: しばらく沈黙が流れた。別の話題にしよう。"
        case .soften, .requireEdit:
            if let rewritten = outSafety.rewrittenText, !rewritten.isEmpty { rawFinal = rewritten }
        case .warn, .allow:
            break
        }
        rawFinal = ensureStoryNarration(in: rawFinal, scene: scene)
        rawFinal = stabilizeStoryTurn(rawFinal, activeCast: aiCastForTurn, characterIndex: charIndex, scene: scene)

        // 10) 「名前: 本文」行ごとに StoryMessage 化
        streamingStatusText = "発話を保存中"
        let newMessages = parseSpeakerLines(
            rawFinal,
            cast: aiCastForTurn,
            characterIndex: charIndex,
            forbiddenCharacterID: userCharacterID,
            forbiddenCharacterName: userCharacterName
        )
        for m in newMessages {
            session.messages.append(m)
        }
        session.lastSelectedModelName = generationModel.displayName
        session.lastUsedBackendName = usedBackendName
        try? await sessionRepo.saveSession(session)
        guard isGenerationActive(generationID) else { return }

        // 11) Scene summary 更新 (270M)
        streamingStatusText = "場面要約を更新中"
        let newSummary = await summarizer.updateSummary(
            currentSummary: scene.summary,
            recentMessages: Array(storyContentMessages(from: session.messages).suffix(18)),
            characterIndex: charIndex
        )
        guard isGenerationActive(generationID) else { return }
        if newSummary != scene.summary {
            scene.summary = newSummary
            try? await sceneRepo.saveScene(scene)
            guard isGenerationActive(generationID) else { return }
        }
        // 12) 進行状態は本文の完了を遅らせない。
        // 以前はここで同じローカルモデルへ進行JSONを追加生成していたため、
        // 1ターンの待ち時間が実質2回分になっていた。本文を先に返し、
        // 進行表示に必要な最小状態は決定的に更新する。
        let progressUpdate = StoryProgressUpdate(
            progressLabel: session.progressLabel.nonEmpty ?? "第1章 きっかけ",
            currentObjective: session.currentObjective.nonEmpty
                ?? scene.sceneGoal.nonEmpty
                ?? world.storyGoal.nonEmpty,
            lastTurnProgress: synthesizeTurnProgress(from: newMessages),
            lastSceneSummary: newSummary.nonEmpty ?? session.lastSceneSummary.nonEmpty,
            unresolvedHooks: unresolvedHooks(world: world, scene: scene, previous: session.unresolvedHooks),
            storyState: nil
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
        if let statePatch = progressUpdate.storyState {
            session.storyState = statePatch.applying(to: session.storyState ?? StoryState(), characterIndex: charIndex)
        }
        try? await sessionRepo.saveSession(session)
        guard isGenerationActive(generationID) else { return }

        // 13) メモリー抽出。ユーザー事実は全体、出来事は物語内へ保存する。
        // ここを phase=.idle / activeGenerationID=nil より後に置くと、下の
        // isGenerationActive ガードが常に失敗してメモリーが一件も保存されない。
        // 本文の永続化は済んでいるため、抽出だけを完了させてからUIをidleへ戻す。
        let userVisibleAssistant = newMessages.map { (message: StoryMessage) in
            message.text
        }.joined(separator: "\n")
        var extractedStoryMemoryTexts = Set<String>()
        for member in activeCast {
            guard isGenerationActive(generationID) else { return }
            guard let profile = charIndex[member.characterId] else { continue }
            let mems = await memorySummarizer.extract(
                userText: userText,
                assistantText: userVisibleAssistant,
                character: profile
            )
            for memory in mems {
                guard isGenerationActive(generationID) else { return }
                if isGlobalMemoryCategory(memory.category) {
                    // ユーザーのプロフィール・好みは、別の物語でも使える全体メモリー。
                    try? await memoryRepo.saveMemory(memory)
                }
                if !isGlobalMemoryCategory(memory.category) {
                    let storyMemory = StoryMemory(
                        storyWorldId: world.id,
                        characterId: memory.characterId,
                        text: memory.text,
                        category: memory.category,
                        importance: memory.importance,
                        source: memory.source
                    )
                    try? await storyMemoryRepo.saveMemory(storyMemory)
                    extractedStoryMemoryTexts.insert(memory.text)
                }
            }
        }

        // 進行JSONの「今回の変化」も、次回以降に使える物語内の思い出にする。
        let progressText = progressUpdate.lastTurnProgress ?? ""
        if let progress = progressText
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            .nonEmpty,
           extractedStoryMemoryTexts.insert(progress).inserted {
            guard isGenerationActive(generationID) else { return }
            try? await storyMemoryRepo.saveMemory(
                StoryMemory(
                    storyWorldId: world.id,
                    text: progress,
                    category: .event,
                    importance: 0.6,
                    source: .summary
                )
            )
        }

        await MainActor.run {
            guard self.activeGenerationID == generationID else { return }
            self.latestSafetyConcern = safetyConcern
            self.streamingResponse = rawFinal
            self.streamingSpeakerName = newMessages.last?.speakerDisplayName
            self.streamingStatusText = ""
            self.savedTurnRevision += 1
            self.phase = .idle
            self.activeGenerationID = nil
        }
    }

    private func isGenerationActive(_ generationID: UUID) -> Bool {
        !Task.isCancelled && activeGenerationID == generationID
    }

    // 全体へ持ち越してよい情報だけを明示する。
    private func isGlobalMemoryCategory(_ category: MemoryCategory) -> Bool {
        switch category {
        case .userFact, .preference, .safety:
            return true
        case .relationship, .event, .world, .summary, .other:
            return false
        }
    }

    // StoryMemoryは軽量なキーワード重なり + 重要度 + 新しさで選ぶ。
    private func selectStoryMemories(
        query: String,
        candidates: [StoryMemory],
        topK: Int
    ) -> [StoryMemory] {
        let queryTokens = storyMemoryTokens(query)
        return candidates
            .map { memory -> (StoryMemory, Double) in
                let memoryTokens = storyMemoryTokens(memory.text)
                let overlap = queryTokens.intersection(memoryTokens).count
                let age = Date().timeIntervalSince(memory.lastUsedAt ?? memory.createdAt)
                let freshness = age < 60 * 60 * 24 * 7 ? 0.1 : 0.0
                return (memory, memory.importance * 0.5 + Double(overlap) * 0.4 + freshness)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(max(0, topK))
            .map(\.0)
    }

    private func storyMemoryTokens(_ text: String) -> Set<String> {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var tokens = Set(words)
        // 日本語は空白で区切られないため、2文字の重なりも関連度に使う。
        let characters = Array(text.lowercased())
        guard characters.count > 1 else { return tokens }
        for index in 0..<(characters.count - 1) {
            tokens.insert(String(characters[index...(index + 1)]))
        }
        return tokens
    }

    private func storyContentMessages(from messages: [StoryMessage]) -> [StoryMessage] {
        var result: [StoryMessage] = []
        for message in messages {
            if case .system = message.author { continue }
            if let previous = result.last, isSameSpeakerBurst(previous, message) {
                continue
            }
            result.append(message)
        }
        return result
    }

    /// 1回の生成で同じキャラの候補が複数保存された場合、後続プロンプトへ重複を持ち込まない。
    private func isSameSpeakerBurst(_ lhs: StoryMessage, _ rhs: StoryMessage) -> Bool {
        guard case let .cast(lhsID, _) = lhs.author,
              case let .cast(rhsID, _) = rhs.author,
              lhsID == rhsID else { return false }
        // 1ターンの出力はユーザー発言やナレーションで区切られるため、
        // 同じキャラが連続していれば候補の重複として扱う。
        return true
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
                // 物語本文は2〜7行で十分。過剰な上限は待ち時間と候補の連続出力を増やす。
                maxOutputTokens: 1024
            )
            await MainActor.run {
                guard self.activeGenerationID == generationID else { return }
                self.streamingResponse = text
                self.streamingStatusText = "発話を整形中"
                self.streamingSpeakerName = self.detectCurrentSpeakerName(in: text)
            }
            return text
        } catch let error as StoryGemma31BAPIError {
            // APIエラーをNPC本文として整形すると、空レスポンス時に
            // 同じキャラのフォールバック発話が追加されるためsystem通知にする。
            let message = gemmaRuntimeNotice(for: error)
            NSLog("[StoryGemma31B] generation failed: %@", error.localizedDescription)
            await MainActor.run {
                guard self.activeGenerationID == generationID else { return }
                self.streamingResponse = message
                self.streamingStatusText = ""
                self.streamingSpeakerName = nil
            }
            return message
        } catch {
            let message = "Gemma4 31B API の応答に失敗しました。もう一度試してください。"
            NSLog("[StoryGemma31B] generation failed: %@", error.localizedDescription)
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
                self.generationTask?.cancel()
                self.generationTask = nil
                LocalAssistantRuntimeBridge.shared.cancelActiveGeneration()
                let fallback = self.streamingResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "ナレーション: 応答が途切れ、場面はいったん止まった。もう一度話しかけてください。"
                    : self.streamingResponse
                Task { [weak self] in
                    guard let self else { return }
                    // 生成タスクが停止直前に保存した最新状態を基準にする。
                    // 初期スナップショットへ戻すと、直前の発言や進行状態を上書きする。
                    var next = ((try? await self.sessionRepo.fetchSessions(storyWorldId: session.storyWorldId)) ?? [])
                        .first(where: { $0.id == session.id }) ?? session
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
        characterIndex: [UUID: CharacterProfile],
        forbiddenCharacterID: UUID? = nil,
        forbiddenCharacterName: String? = nil
    ) -> [StoryMessage] {
        let castNames: [(UUID, String)] = cast.compactMap { member in
            guard member.characterId != forbiddenCharacterID else { return nil }
            if let p = characterIndex[member.characterId] {
                return (member.characterId, p.displayName.isEmpty ? p.name : p.displayName)
            }
            return nil
        }
        let forbiddenNames = Set(
            [forbiddenCharacterName]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var out: [StoryMessage] = []
        var emittedCastIDs = Set<UUID>()
        for line in lines where !line.isEmpty {
            // 「ナレーション:」
            if line.hasPrefix("ナレーション:") || line.hasPrefix("ナレーション：") || line.hasPrefix("ナレーター:") || line.hasPrefix("ナレーター：") {
                let body = textAfterSpeakerDelimiter(line)
                if !body.isEmpty {
                    out.append(StoryMessage(author: .narrator, text: body))
                }
                continue
            }
            // ユーザー操作キャラの発話は表示しない。AIが代弁した場合も、
            // そのままナレーションへ落とすとユーザーの台詞として見えてしまうため破棄する。
            if let delimiter = line.firstIndex(where: { $0 == ":" || $0 == "：" }) {
                let possibleSpeaker = String(line[..<delimiter]).trimmingCharacters(in: .whitespacesAndNewlines)
                if forbiddenNames.contains(possibleSpeaker) {
                    continue
                }
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
            if let (id, name, body) = matched,
               !body.isEmpty,
               emittedCastIDs.insert(id).inserted {
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

    private func gemmaRuntimeNotice(for error: StoryGemma31BAPIError) -> String {
        switch error {
        case .missingAPIKey:
            return "Gemma4 APIキーが未設定です。NAGIのモデル詳細からAPIキーを設定してください。"
        case .emptyResponse:
            return "Gemma4 31B API が空レスポンスを返しました。もう一度試してください。"
        case .emptyText:
            return "Gemma4 31B API の出力本文が空でした。もう一度試してください。"
        case .invalidURL, .httpStatus:
            return "Gemma4 31B API の応答に失敗しました。もう一度試してください。"
        }
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
            return "iori のモデルファイルは保存済みです。端末内の実行確認が自動で進行中です。"
        case .recentFailure:
            return "iori のローカル実行を確認できませんでした。モデルメニューからNAGIへ切り替えられます。"
        case .modelMissing:
            return "iori のローカルモデルが未導入です。モデルを保存すると端末内で自動確認します。"
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

    private func localStoryGenerationFailureMessage(runtimeError: String? = nil) -> String {
        if runtimeError?.contains("記号だけ") == true {
            return "ローカルモデルが「…」のような記号だけを返しました。これは本文ではないため保存していません。もう一度試すか、NAGIで続けられます。"
        }
        return "ローカルモデルが本文を生成できませんでした。会話は変更していません。もう一度試すか、NAGIで続けられます。"
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
        return removeStoryMetaLeakage(from: out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // モデルが本文の後ろに混ぜる「User is...」「the prompt says...」等の
    // 内部自己解説を、UIへ渡す前に落とす。通常の英語台詞を一律削除しない。
    private func removeStoryMetaLeakage(from text: String) -> String {
        let markers = [
            "Wait, User", "User is", "I shouldn't", "I should not",
            "the prompt says", "Usually, I", "as the NPC", "active characters center",
            "assistant should", "system prompt", "内部", "思考過程", "自己解説"
        ]
        let cleanedLines = text.components(separatedBy: .newlines).compactMap { rawLine -> String? in
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            let lower = line.localizedLowercase
            guard let marker = markers.first(where: { lower.contains($0.localizedLowercase) }) else {
                return line
            }

            // 「台詞」(Wait, User...) の形なら、台詞だけを残す。
            if let parenthesis = line.firstIndex(where: { $0 == "(" || $0 == "（" }) {
                line = String(line[..<parenthesis]).trimmingCharacters(in: .whitespacesAndNewlines)
                return line.isEmpty ? nil : line
            }
            // 行全体がメタ文なら表示しない。
            _ = marker
            return nil
        }
        return cleanedLines.joined(separator: "\n")
    }

    /// 休憩アラートへ渡す本文を短く整形し、依存・強制につながる出力を捨てる。
    private func normalizeRestSuggestion(_ text: String?) -> String? {
        guard var value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if let firstLine = value.components(separatedBy: .newlines).first?.nonEmpty {
            value = firstLine
        }
        for prefix in ["休憩提案:", "休憩の提案:", "ナレーション:", "提案:"] {
            if value.hasPrefix(prefix) {
                value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"『』「」*"))
        let forbiddenPhrases = [
            "必ず戻って", "戻ってきて", "待ってる", "待っています", "寂しい",
            "終わらせ", "終了して", "やめてはいけない", "離れないで"
        ]
        guard !forbiddenPhrases.contains(where: { value.contains($0) }) else { return nil }
        guard !value.isEmpty else { return nil }
        return String(value.prefix(120))
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

    private func isMeaningfulStoryText(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            scalar.properties.isAlphabetic || scalar.properties.numericType != nil
        }
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
        var seenSpeechKeys = Set<String>()
        var seenSpeakers = Set<UUID>()

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
                    let key = "\(name)\u{1F}\(normalizedSpeechKey(body))"
                    if !body.isEmpty,
                       speeches.count < 2,
                       !seenSpeakers.contains(id),
                       seenSpeechKeys.insert(key).inserted {
                        speeches.append("\(name): \(body)")
                        seenSpeakers.insert(id)
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

    private func normalizedSpeechKey(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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

    // CharacterProfile は既存データ互換のため専用フラグを持たない。
    // 「自分自身 / 本人」または主人公表記を優先してユーザー操作キャラを推定する。
    private func userControlledCharacterID(
        world: StoryWorld,
        cast: [CastMember],
        characterIndex: [UUID: CharacterProfile]
    ) -> UUID? {
        func isUserProfile(_ profile: CharacterProfile, castMember: CastMember?) -> Bool {
            let values = [
                profile.displayName,
                profile.name,
                profile.relationshipToUser,
                castMember?.relationshipToUser ?? ""
            ]
            .joined(separator: " ")
            .localizedLowercase
            return values.contains("自分自身")
                || values.contains("本人")
                || values.contains("ユーザー")
                || values.contains("user")
                || values.contains("主人公")
                || values.contains("protagonist")
        }

        if let mainID = world.mainCharacterId,
           let profile = characterIndex[mainID],
           let member = cast.first(where: { $0.characterId == mainID }),
           isUserProfile(profile, castMember: member) {
            return mainID
        }

        return cast.first { member in
            guard let profile = characterIndex[member.characterId] else { return false }
            return isUserProfile(profile, castMember: member)
        }?.characterId
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

    private func reconciledCast(
        _ existing: [CastMember],
        for world: StoryWorld,
        scene: StoryScene
    ) -> [CastMember] {
        guard !world.characterIds.isEmpty else { return [] }
        let defaults = defaultCastMembers(for: world, scene: scene)
        let existingByCharacterID = existing.reduce(into: [UUID: CastMember]()) { result, member in
            if result[member.characterId] == nil { result[member.characterId] = member }
        }
        return defaults.map { existingByCharacterID[$0.characterId] ?? $0 }
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
            unresolvedHooks: unresolvedHooks(world: world, scene: scene, previous: session.unresolvedHooks),
            storyState: nil
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
        storyState は今回変化した状態だけを入れる。変化がない項目は null にする。
        characterUpdates は会話に登場したキャラだけ。characterName は画面上の名前を使う。
        inventoryChanges は add / update / remove のいずれかを使う。
        storyState の current state を勝手に初期化せず、本文から確実に変化したものだけ更新する。
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

        現在のStoryState:
        場所: \(session.storyState?.location ?? "")
        時間: \(session.storyState?.timeOfDay ?? "")
        ムード: \(session.storyState?.mood ?? "")
        天候: \(session.storyState?.weather ?? "")
        関係段階: \(session.storyState?.relationshipStage ?? "")
        所持品: \((session.storyState?.inventory ?? []).map { $0.name }.joined(separator: " / "))

        今回のユーザー発言:
        \(userText)

        今回の返答:
        \(assistantMessages.map { messageLine($0) }.joined(separator: "\n"))

        JSON形式:
        {"progressLabel":"第1章 ...","currentObjective":"...","lastTurnProgress":"...","lastSceneSummary":"...","unresolvedHooks":["..."],"storyState":{"location":"...","timeOfDay":"...","mood":"...","weather":"...","relationshipStage":"...","characterUpdates":[{"characterName":"...","mood":"...","goal":"...","relationship":"...","innerThought":"..."}],"inventoryChanges":[{"action":"add","name":"...","detail":"...","owner":"..."}],"activeGoals":["..."]}}
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
            unresolvedHooks: normalizedHooks(parsed.unresolvedHooks, fallback: fallback.unresolvedHooks ?? []),
            storyState: parsed.storyState ?? fallback.storyState
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
