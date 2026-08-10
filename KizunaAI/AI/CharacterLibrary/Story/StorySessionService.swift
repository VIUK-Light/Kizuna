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

/// Runtime error cards carry their retry target inside the persisted message text.
/// StoryMessage is shared by older stores and cannot gain a new field here, so use
/// invisible variation selectors instead of exposing implementation metadata in UI.
/// The parser deliberately tolerates missing metadata and callers can fall back to
/// the closest preceding user message for records written by older versions.
enum StoryRetryMetadata {
    private static let startMarker = "\u{2063}\u{2060}"
    private static let endMarker = "\u{2060}\u{2063}"

    static func attachingUserMessageID(_ id: UUID, to text: String) -> String {
        let hex = id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var encoded = ""
        for character in hex {
            guard let nibble = Int(String(character), radix: 16),
                  let scalar = UnicodeScalar(0xFE00 + nibble) else { continue }
            encoded.unicodeScalars.append(scalar)
        }
        return text + startMarker + encoded + endMarker
    }

    static func userMessageID(in text: String) -> UUID? {
        guard let start = text.range(of: startMarker),
              let end = text.range(of: endMarker, range: start.upperBound..<text.endIndex) else {
            return nil
        }
        var hex = ""
        for scalar in text[start.upperBound..<end.lowerBound].unicodeScalars {
            let value = Int(scalar.value)
            guard (0xFE00...0xFE0F).contains(value) else { return nil }
            hex.append(String(format: "%x", value - 0xFE00))
        }
        guard hex.count == 32 else { return nil }
        let part1 = String(hex.prefix(8))
        let part2 = String(hex.dropFirst(8).prefix(4))
        let part3 = String(hex.dropFirst(12).prefix(4))
        let part4 = String(hex.dropFirst(16).prefix(4))
        let part5 = String(hex.dropFirst(20).prefix(12))
        let uuidText = "\(part1)-\(part2)-\(part3)-\(part4)-\(part5)"
        return UUID(uuidString: uuidText)
    }

    /// Removes metadata for presentation/debug output. The marker is invisible,
    /// but stripping it keeps exports and future UI surfaces clean as well.
    static func removingMetadata(from text: String) -> String {
        var result = text
        while let start = result.range(of: startMarker),
              let end = result.range(of: endMarker, range: start.upperBound..<result.endIndex) {
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return result
    }
}

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
    /// Timeout notice persistence has its own validity token. A watchdog may
    /// suspend at a repository await; cancellation or a newer turn must then
    /// invalidate the pending save before it can write a stale snapshot.
    private var timeoutSaveToken: UUID?
    private var generationWatchdogDeadline: Date?
    private static let generationWatchdogDuration: TimeInterval = 75
    private static let localRuntimeSystemPromptLimit = 1_250
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
    /// `existingUserMessageID` が指定された場合は保存済みターンを再利用し、
    /// ユーザー発話を再 append せず生成だけを再実行する。
    @discardableResult
    func send(
        _ userText: String,
        session: StorySession,
        world: StoryWorld,
        scene: StoryScene,
        generationModel: StoryGenerationModel = .e4b,
        existingUserMessageID: UUID? = nil
    ) -> UUID? {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, phase != .thinking else { return nil }
        phase = .thinking
        streamingResponse = ""
        streamingSpeakerName = nil
        streamingStatusText = statusText("準備中", "Preparing")
        latestSafetyConcern = nil
        lastVisibleText = ""
        let generationID = UUID()
        activeGenerationID = generationID
        timeoutSaveToken = nil
        let userMessageID = existingUserMessageID ?? UUID()

        generationTask = Task { [weak self] in
            await self?.runPipeline(
                userText: trimmed,
                session: session,
                world: world,
                scene: scene,
                generationModel: generationModel,
                generationID: generationID,
                userMessageID: userMessageID,
                existingUserMessageID: existingUserMessageID
            )
        }
        return userMessageID
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
                text: localizedNotice("了解。続けよう。", "Okay. Let's continue.")
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
        // Invalidate an in-flight timeout persistence task before cancelling
        // the backend. Repository calls may already be suspended at await and
        // cannot be assumed to observe Task cancellation immediately.
        timeoutSaveToken = nil
        generationTask?.cancel()
        generationTask = nil
        LocalAssistantRuntimeBridge.shared.cancelActiveGeneration()
        activeGenerationID = nil
        generationWatchdogDeadline = nil
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
        generationID: UUID,
        userMessageID: UUID,
        existingUserMessageID: UUID?
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

        // user メッセージ append + 空 narration ストリーム先を確保。
        // 再試行では既存の保存済み入力を再利用し、同じIDの発話を重複保存しない。
        streamingStatusText = statusText("会話を保存中", "Saving conversation")
        if let existingUserMessageID {
            guard session.messages.contains(where: { message in
                message.id == existingUserMessageID && message.author.isUser
            }) else {
                NSLog("[StorySession] retry target user message not found: %@", existingUserMessageID.uuidString)
                await finishGenerationWithoutSaving(
                    generationID: generationID,
                    notice: "再試行対象の発言を復元できませんでした。新しいメッセージを送信してください。"
                )
                return
            }
        } else {
            let userMsg = StoryMessage(id: userMessageID, author: .user, text: userText)
            session.messages.append(userMsg)
            try? await sessionRepo.saveSession(session)
        }
        guard isGenerationActive(generationID) else { return }

        // 1) キャラ index / cast 取得
        streamingStatusText = statusText("登場キャラを確認中", "Checking characters")
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
        streamingStatusText = statusText("入力を確認中", "Checking input")
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
        streamingStatusText = statusText("場面のキャラを選定中", "Selecting scene characters")
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
        streamingStatusText = statusText("記憶を読み込み中", "Loading memories")
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
        streamingStatusText = statusText("Lorebookを選択中", "Selecting lorebook entries")
        var lorebookEntries = (try? await lorebookRepo.fetchEntries(storyWorldId: world.id)) ?? []
        guard isGenerationActive(generationID) else { return }
        // 既存のCharacterLorebookも移行期間は同じ選択器に流し込む。
        for member in cast {
            guard let legacy = try? await characterRepo.fetchLorebook(characterId: member.characterId),
                  !legacy.isEmpty else { continue }
            let keywords = (legacy.importantPeople + legacy.importantPlaces + legacy.importantEvents)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            var contentParts: [String] = [legacy.worldSetting]
            if !legacy.importantPeople.isEmpty {
                contentParts.append("重要人物: " + legacy.importantPeople.joined(separator: " / "))
            }
            if !legacy.importantPlaces.isEmpty {
                contentParts.append("重要な場所: " + legacy.importantPlaces.joined(separator: " / "))
            }
            if !legacy.importantEvents.isEmpty {
                contentParts.append("重要な出来事: " + legacy.importantEvents.joined(separator: " / "))
            }
            if !legacy.worldRules.isEmpty {
                contentParts.append("世界のルール: " + legacy.worldRules.joined(separator: " / "))
            }
            if !legacy.forbiddenBreaks.isEmpty {
                contentParts.append("壊してはいけない設定: " + legacy.forbiddenBreaks.joined(separator: " / "))
            }
            let content = contentParts.filter { !$0.isEmpty }.joined(separator: "\n")
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
        streamingStatusText = statusText("物語コンテキストを構築中", "Building story context")
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
                selectedMemories: selectedMemories,
                selectedStoryMemories: selectedStoryMemories,
                userCharacterName: userCharacterName
            )
        }
        guard isGenerationActive(generationID) else { return }

        // 8) Story model 生成。31B を明示選択した時だけ Gemma4 API を使う。
        // 端末内モデルは、保存直後の自動 self-check が終わるまで同じターンを待つ。
        // 「保存済みだが未確認」を会話失敗として即保存しない。
        // リポジトリ読込・安全確認・シーン選定・プロンプト構築は生成予算に含めない。
        // ここからAPI呼び出しまたは端末内モデルの実行確認を監視する。
        generationWatchdogDeadline = Date().addingTimeInterval(Self.generationWatchdogDuration)
        startWatchdog(
            session: session,
            generationID: generationID,
            generationModel: generationModel,
            userMessageID: userMessageID
        )
        streamingStatusText = generationModel == .b31
            ? statusText("Gemma4 31Bで発話生成中", "Generating with Gemma4 31B")
            : statusText("ローカルモデルで発話生成中", "Generating on device")
        let localModelManager = LocalAssistantModelManager.shared
        let selectedModelURL = generationModel.installedModelURL ?? localModelManager.installedModelURL

        func generateStoryReply(systemPrompt: String) async -> (reply: String?, runtimeNotice: Bool, backend: String) {
            if generationModel == .b31 {
                if StoryGemma31BAPIService.shared.hasAPIKey {
                    let reply = await generateWithGemma31BAPI(
                        systemPrompt: systemPrompt,
                        userPrompt: effectiveUserText,
                        generationID: generationID
                    )
                    let isNotice = isGemma31BRuntimeNotice(reply)
                    return (
                        reply: reply,
                        runtimeNotice: isNotice,
                        backend: isNotice ? "Gemma4 31B API失敗" : "Gemma4 31B API"
                    )
                }

                streamingStatusText = statusText("NAGI APIキー未設定", "NAGI API key is not set")
                return (
                    reply: localizedNotice(
                        "NAGI の Gemma4 31B APIキーが未設定です。モデル詳細からAPIキーを設定してから続けてください。",
                        "NAGI's Gemma4 31B API key is not set. Add it in Model details before continuing."
                    ),
                    runtimeNotice: true,
                    backend: "Gemma4 31B API未設定"
                )
            }

            let availability = await waitForLocalRuntime(
                manager: localModelManager,
                selectedModelURL: selectedModelURL,
                generationID: generationID
            )
            // self-checkもユーザーの送信ターンに含める。待機時間を
            // watchdogへ足し戻すと、60秒の起動確認 + 75秒の生成で
            // 1ターンが最大135秒まで伸びてしまう。
            guard isGenerationActive(generationID) else {
                return (reply: nil, runtimeNotice: true, backend: "iori 生成キャンセル")
            }

            // self-check が保存状態を復元した後のURLを再取得する。起動直後に
            // manager の非同期更新が間に合わなくても、保存済みモデルを未導入扱いにしない。
            let availableModelURL = selectedModelURL ?? localModelManager.installedModelURL

            if let localUnavailableMessage = localStoryRuntimeUnavailableMessage(
                availability: availability,
                selectedModelURL: availableModelURL
            ) {
                streamingStatusText = statusText("ローカル未起動", "On-device model is not ready")
                return (
                    reply: localUnavailableMessage,
                    runtimeNotice: true,
                    backend: localStoryBackendStatusName(
                        availability: availability,
                        selectedModelURL: availableModelURL
                    )
                )
            }

            let advanced = voiceOptimizedAdvancedSettings()
            let backend = localStoryBackendStatusName(
                availability: availability,
                selectedModelURL: availableModelURL
            )
            let reply = await LocalAssistantRuntimeBridge.shared.generateReply(
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
                initialMessages: localConversationHistory,
                overrideModelURL: availableModelURL,
                onUpdate: { @MainActor [weak self] update in
                    self?.handleStreamUpdate(update, generationID: generationID)
                }
            )
            guard let reply else {
                let runtimeError = LocalAssistantRuntimeBridge.shared.latestDebugSnapshot().errorMessage
                streamingStatusText = runtimeError?.contains("記号だけ") == true
                    ? statusText("ローカル出力が無効", "On-device output was invalid")
                    : statusText("ローカル起動失敗", "On-device generation failed")
                return (
                    reply: localStoryGenerationFailureMessage(runtimeError: runtimeError),
                    runtimeNotice: true,
                    backend: "iori ローカル生成失敗"
                )
            }
            return (reply: reply, runtimeNotice: false, backend: backend)
        }

        var generationPrompt = prompt
        var generated = await generateStoryReply(systemPrompt: generationPrompt)
        var reply = generated.reply
        var isRuntimeNotice = generated.runtimeNotice
        var usedBackendName = generated.backend

        // キャンセルやウォッチドッグ後に、古い生成結果を後段へ保存しない。
        guard isGenerationActive(generationID) else { return }

        // 9) 出力 safety
        streamingStatusText = statusText("発話を整形中", "Formatting response")
        var rawFinal = sanitizedFinalText(
            (reply?.isEmpty == false ? reply! : streamingResponse)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )

        // 前ターンと同じ本文を保存しない。最初の重複は一度だけ再生成し、
        // それでも同じなら原因を隠さず system 通知として保存する。
        if !isRuntimeNotice,
           isMeaningfulStoryText(rawFinal) {
            let firstMessages = parseSpeakerLines(
                rawFinal,
                cast: aiCastForTurn,
                characterIndex: charIndex,
                forbiddenCharacterID: userCharacterID,
                forbiddenCharacterName: userCharacterName
            )
            if isDuplicateStoryOutput(firstMessages, in: session) {
                NSLog(
                    "[StorySession] duplicate output rejected attempt=1 chars=%ld messages=%ld",
                    rawFinal.count,
                    firstMessages.count
                )
                let retryInstruction = "再生成指示: 直前のNPCやナレーションと同じ本文を返さない。今回のユーザー発言へ直接反応し、別の短い台詞を1行で返す。場面が変わっていない限りナレーションは追加しない。"
                generationPrompt = generationModel == .e4b
                    ? localRetrySystemPrompt(base: prompt, instruction: retryInstruction)
                    : "\(retryInstruction)\n\n\(prompt)"
                lastVisibleText = ""
                streamingResponse = ""
                streamingStatusText = statusText("重複を避けて再生成中", "Regenerating to avoid duplicate output")
                generated = await generateStoryReply(systemPrompt: generationPrompt)
                reply = generated.reply
                isRuntimeNotice = generated.runtimeNotice
                usedBackendName = generated.backend + "・重複再試行"
                rawFinal = sanitizedFinalText(
                    (reply?.isEmpty == false ? reply! : streamingResponse)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                )

                if !isRuntimeNotice,
                   isMeaningfulStoryText(rawFinal) {
                    let retriedMessages = parseSpeakerLines(
                        rawFinal,
                        cast: aiCastForTurn,
                        characterIndex: charIndex,
                        forbiddenCharacterID: userCharacterID,
                        forbiddenCharacterName: userCharacterName
                    )
                    if isDuplicateStoryOutput(retriedMessages, in: session) {
                        NSLog(
                            "[StorySession] duplicate output rejected attempt=2 chars=%ld messages=%ld",
                            rawFinal.count,
                            retriedMessages.count
                        )
                        isRuntimeNotice = true
                        usedBackendName += "・重複失敗"
                        rawFinal = localizedNotice(
                            "直前と同じ本文が続いたため、重複した発話は保存していません。もう一度送信してください。",
                            "The response repeated the previous text, so it was not saved. Send your message again."
                        )
                    }
                }
            }
        }

        if !isMeaningfulStoryText(rawFinal) {
            isRuntimeNotice = true
            usedBackendName += "・無効出力"
            rawFinal = generationModel == .b31
                ? "Gemma4 31B API が有効な本文を返しませんでした。もう一度試してください。"
                : localStoryGenerationFailureMessage(runtimeError: "記号だけの本文")
        }
        if isRuntimeNotice {
            guard isGenerationActive(generationID) else { return }
            let noticeText = textAfterSpeakerDelimiter(rawFinal)
            let notice = retryableSystemMessage(noticeText, userMessageID: userMessageID)
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
            // 安全ブロックを物語内の沈黙や台詞に偽装しない。モデル本文は保存せず、
            // 明示的なsystem通知として返す。
            let notice = localizedNotice(
                "安全上の理由でこの応答は保存しませんでした。別の表現で続けてください。",
                "This response was not saved for safety reasons. Try a different way to continue."
            )
            session.messages.append(retryableSystemMessage(notice, userMessageID: userMessageID))
            session.lastSelectedModelName = generationModel.displayName
            session.lastUsedBackendName = usedBackendName + "・安全ブロック"
            try? await sessionRepo.saveSession(session)
            await MainActor.run {
                guard self.activeGenerationID == generationID else { return }
                self.latestSafetyConcern = safetyConcern
                self.streamingResponse = notice
                self.streamingSpeakerName = "システム"
                self.streamingStatusText = ""
                self.savedTurnRevision += 1
                self.phase = .idle
                self.activeGenerationID = nil
            }
            return
        case .soften, .requireEdit:
            if let rewritten = outSafety.rewrittenText, !rewritten.isEmpty { rawFinal = rewritten }
        case .warn, .allow:
            break
        }
        rawFinal = sanitize(rawFinal)
        guard isMeaningfulStoryText(rawFinal) else {
            let notice = localizedNotice(
                "整形後の本文が空になったため保存していません。もう一度試すか、NAGIで続けられます。",
                "The formatted response was empty, so it was not saved. Try again or continue with NAGI."
            )
            session.messages.append(retryableSystemMessage(notice, userMessageID: userMessageID))
            session.lastSelectedModelName = generationModel.displayName
            session.lastUsedBackendName = usedBackendName + "・無効出力"
            try? await sessionRepo.saveSession(session)
            await MainActor.run {
                guard self.activeGenerationID == generationID else { return }
                self.streamingResponse = notice
                self.streamingSpeakerName = "システム"
                self.streamingStatusText = ""
                self.savedTurnRevision += 1
                self.phase = .idle
                self.activeGenerationID = nil
            }
            return
        }

        // 10) 「名前: 本文」行ごとに StoryMessage 化
        streamingStatusText = statusText("発話を保存中", "Saving response")
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
        let savedMessageIDs = newMessages.map(\.id.uuidString).joined(separator: ",")
        NSLog(
            "[StorySession] saved generated messages count=%ld ids=%@ backend=%@",
            newMessages.count,
            savedMessageIDs,
            usedBackendName
        )
        session.lastSelectedModelName = generationModel.displayName
        session.lastUsedBackendName = usedBackendName
        try? await sessionRepo.saveSession(session)
        guard isGenerationActive(generationID) else { return }

        // 11) Scene summary 更新 (270M)
        streamingStatusText = statusText("場面要約を更新中", "Updating scene summary")
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

    private func retryableSystemMessage(_ text: String, userMessageID: UUID) -> StoryMessage {
        StoryMessage(
            author: .system,
            text: StoryRetryMetadata.attachingUserMessageID(userMessageID, to: text)
        )
    }

    /// A stale/corrupt retry target must not create a new user turn. Surface a
    /// clear transient error while leaving the persisted conversation untouched.
    private func finishGenerationWithoutSaving(generationID: UUID, notice: String) async {
        guard isGenerationActive(generationID) else { return }
        await MainActor.run {
            guard self.activeGenerationID == generationID else { return }
            self.streamingResponse = notice
            self.streamingSpeakerName = "システム"
            self.streamingStatusText = ""
            self.savedTurnRevision += 1
            self.generationWatchdogDeadline = nil
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
            self.streamingStatusText = self.statusText("Gemma4 31Bで発話生成中", "Generating with Gemma4 31B")
            self.streamingResponse = self.localizedNotice(
                "ナレーション: NAGIが場面と会話履歴を読み込んでいます。",
                "Narration: NAGI is reading the scene and conversation history."
            )
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
                self.streamingStatusText = self.statusText("発話を整形中", "Formatting response")
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
        streamingStatusText = statusText("発話生成中", "Generating response")
        if stripped.count >= lastVisibleText.count {
            lastVisibleText = stripped
            streamingResponse = stripped
        } else {
            lastVisibleText = stripped
            streamingResponse = stripped
        }
    }

    private func startWatchdog(
        session: StorySession,
        generationID: UUID,
        generationModel: StoryGenerationModel,
        userMessageID: UUID
    ) {
        Task { @MainActor [weak self] in
            while true {
                guard let self,
                      self.activeGenerationID == generationID,
                      self.phase == .thinking,
                      let deadline = self.generationWatchdogDeadline else { return }
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { break }
                do {
                    let nanoseconds = UInt64(min(remaining, 1.0) * 1_000_000_000)
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
            }

            guard let self,
                  self.activeGenerationID == generationID,
                  self.phase == .thinking else { return }
            let timeoutToken = UUID()
            self.timeoutSaveToken = timeoutToken
            // Invalidate the pipeline before cancelling it. Some native/API
            // backends do not observe cancellation immediately; keeping the
            // generation ID valid would let a late result pass the guards and
            // append a story turn after the timeout card was saved.
            self.generationTask?.cancel()
            self.generationTask = nil
            self.activeGenerationID = nil
            self.generationWatchdogDeadline = nil
            if generationModel == .e4b {
                LocalAssistantRuntimeBridge.shared.cancelActiveGeneration()
            }
            let notice: String
            let backendName: String
            switch generationModel {
            case .e4b:
                notice = self.localizedNotice(
                    "iori ローカル生成の待機上限を超えたため停止しました。モデル本文は保存していません。もう一度試すか、NAGIで続けられます。",
                    "iori reached its wait limit and stopped. The model response was not saved. Try again or continue with NAGI."
                )
                backendName = "iori ローカル・タイムアウト"
            case .b31:
                notice = self.localizedNotice(
                    "Gemma4 31B APIの生成が時間内に完了しませんでした。本文は保存していません。もう一度試してください。",
                    "Gemma4 31B API did not finish in time. The response was not saved. Try again."
                )
                backendName = "Gemma4 31B API・タイムアウト"
            }
            self.streamingResponse = notice
            self.streamingSpeakerName = "システム"
            self.streamingStatusText = self.statusText("タイムアウト通知を保存中", "Saving timeout notice")

            // 通知保存が終わるまで phase は thinking のままにする。
            // activeGenerationID は先に無効化済みなので、遅れて返る本文は
            // pipeline側のguardで破棄され、次のsendも保存完了まで受付しない。
            guard self.timeoutSaveToken == timeoutToken,
                  self.phase == .thinking else { return }
            var next: StorySession?
            do {
                next = (try await self.sessionRepo.fetchSessions(storyWorldId: session.storyWorldId))
                    .first(where: { $0.id == session.id }) ?? session
            } catch {
                NSLog("[StorySession] timeout notice fetch failed: %@", error.localizedDescription)
                // 最新セッションを取得できない場合は、古いスナップショットを
                // saveSessionして新しいターンを上書きしない。UI通知だけで終了する。
                next = nil
            }
            // The user may have cancelled while fetchSessions was suspended.
            // Never append/save the timeout card after that point.
            guard self.timeoutSaveToken == timeoutToken,
                  self.phase == .thinking else { return }
            if var next {
                next.messages.append(self.retryableSystemMessage(notice, userMessageID: userMessageID))
                next.lastSelectedModelName = generationModel.displayName
                next.lastUsedBackendName = backendName
                guard self.timeoutSaveToken == timeoutToken,
                      self.phase == .thinking else { return }
                do {
                    try await self.sessionRepo.saveSession(next)
                } catch {
                    NSLog("[StorySession] timeout notice save failed: %@", error.localizedDescription)
                }
            }
            guard self.timeoutSaveToken == timeoutToken,
                  self.phase == .thinking else { return }
            self.streamingStatusText = ""
            self.savedTurnRevision += 1
            self.timeoutSaveToken = nil
            self.phase = .idle
            self.activeGenerationID = nil
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
        var emittedCastLines = Set<String>()
        for line in lines where !line.isEmpty {
            // 生成中のプレースホルダーを物語本文へ昇格させない。
            // これを通さないと「・・・」だけのキャラ発話が保存され、
            // 再試行のたびに同じ空バブルが増えてしまう。
            guard isMeaningfulStoryText(line) else { continue }
            // 日本語・英語どちらの生成ラベルも受け付ける。英語モードで
            // "Narration:" が出ても、本文をキャスト発話へ誤分類しない。
            let narrationPrefixes = [
                "ナレーション:", "ナレーション：", "ナレーター:", "ナレーター：",
                "Narration:", "Narration：", "Narrator:", "Narrator：",
                "Scene:", "Scene："
            ]
            let lowercasedLine = line.localizedLowercase
            if narrationPrefixes.contains(where: { lowercasedLine.hasPrefix($0.localizedLowercase) }) {
                let body = textAfterSpeakerDelimiter(line)
                if isMeaningfulStoryText(body) {
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
            if let (id, name, body) = matched {
                guard isMeaningfulStoryText(body) else { continue }
                guard emittedCastLines.insert(id.uuidString + "|" + normalizedDuplicateText(body)).inserted else {
                    continue
                }
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

    private func normalizedDuplicateText(_ text: String) -> String {
        text
            .precomposedStringWithCanonicalMapping
            .localizedLowercase
            .split(whereSeparator: { $0.isWhitespace })
            .joined()
    }

    private func detectCurrentSpeakerName(in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let last = lines.last else { return nil }
        let narrationPrefixes = [
            "ナレーション:", "ナレーション：", "ナレーター:", "ナレーター：",
            "Narration:", "Narration：", "Narrator:", "Narrator：",
            "Scene:", "Scene："
        ]
        let lowercasedLast = last.localizedLowercase
        if narrationPrefixes.contains(where: { lowercasedLast.hasPrefix($0.localizedLowercase) }) {
            return KizunaCopy.text(japanese: "ナレーション", english: "Narration")
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
            return localizedNotice("Gemma4 APIキーが未設定です。NAGIのモデル詳細からAPIキーを設定してください。", "The Gemma4 API key is not set. Add it in NAGI's Model details.")
        case .emptyResponse:
            return localizedNotice("Gemma4 31B API が空レスポンスを返しました。もう一度試してください。", "Gemma4 31B API returned an empty response. Try again.")
        case .emptyText:
            return localizedNotice("Gemma4 31B API の出力本文が空でした。もう一度試してください。", "Gemma4 31B API returned no response text. Try again.")
        case .invalidURL, .httpStatus:
            return localizedNotice("Gemma4 31B API の応答に失敗しました。もう一度試してください。", "Gemma4 31B API failed to respond. Try again.")
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
            return localizedNotice("iori はまだ端末内で起動確認中です。確認が終わるまで、この場面のローカル生成は開始しません。", "iori is still being checked on this device. Local generation will start after the check finishes.")
        case .savedOnly:
            return localizedNotice("iori のモデルファイルは保存済みです。端末内の実行確認が自動で進行中です。", "iori is saved. The automatic on-device check is in progress.")
        case .recentFailure:
            return localizedNotice("iori のローカル実行を確認できませんでした。モデルメニューからNAGIへ切り替えられます。", "iori could not run on this device. Choose NAGI from the model menu to continue.")
        case .modelMissing:
            return localizedNotice("iori のローカルモデルが未導入です。モデルを保存すると端末内で自動確認します。", "The iori model is not installed. Save a model to start the automatic on-device check.")
        }
    }

    /// 保存直後のモデルは自動 self-check が進行中のため、会話側で即時失敗にしない。
    /// 既存の75秒 watchdogを越えないよう、最大60秒だけ状態を待ってから
    /// 実行不可の診断を表示する。待機中にユーザーがキャンセルした場合は保存しない。
    private func waitForLocalRuntime(
        manager: LocalAssistantModelManager,
        selectedModelURL: URL?,
        generationID: UUID
    ) async -> LocalAssistantRuntimeAvailability {
        // 起動直後は manager のURL復元も非同期なため、URLがまだnilでも
        // 一度だけ同期的な再確認入口を呼び、保存済みファイルを再発見させる。
        var didRequestRecheck = selectedModelURL == nil
        if didRequestRecheck {
            manager.recheckRuntimeAvailability()
        }
        var lastReportedSecond = -1
        for attempt in 0..<60 {
            guard isGenerationActive(generationID) else { return .recentFailure }
            let availability = manager.runtimeAvailability
            switch availability {
            case .executable, .recentFailure, .modelMissing:
                return availability
            case .savedOnly:
                // 自動確認がまだ起動していない古い状態でも、会話開始時に再確認を依頼する。
                if !didRequestRecheck {
                    didRequestRecheck = true
                    manager.recheckRuntimeAvailability()
                }
            case .checking:
                break
            }

            let elapsed = attempt + 1
            if elapsed != lastReportedSecond {
                lastReportedSecond = elapsed
                streamingStatusText = statusText("端末内モデルを確認中（\(elapsed)秒）", "Checking on-device model (\(elapsed)s)")
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return manager.runtimeAvailability
    }

    /// LiteRT-LMはsystem promptを1,250 UTF-8 bytesへ切り詰めるため、
    /// 再生成指示を先頭へ置き、指示そのものが消えないようにベースを後ろから短くする。
    private func localRetrySystemPrompt(base: String, instruction: String) -> String {
        let prefix = instruction + "\n\n"
        let remainingBytes = max(
            0,
            Self.localRuntimeSystemPromptLimit - prefix.lengthOfBytes(using: .utf8)
        )
        return prefix + utf8Prefix(base, byteLimit: remainingBytes)
    }

    private func utf8Prefix(_ value: String, byteLimit: Int) -> String {
        guard byteLimit > 0 else { return "" }
        guard value.lengthOfBytes(using: .utf8) > byteLimit else { return value }
        var result = ""
        var usedBytes = 0
        for character in value {
            let piece = String(character)
            let pieceBytes = piece.lengthOfBytes(using: .utf8)
            guard usedBytes + pieceBytes <= byteLimit else { break }
            result.append(contentsOf: piece)
            usedBytes += pieceBytes
        }
        return result
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
            return localizedNotice("iori モデルパス不明", "iori model path unavailable")
        case .checking:
            return localizedNotice("iori 起動確認中", "iori check in progress")
        case .savedOnly:
            return localizedNotice("iori 保存済み・未起動", "iori saved · not started")
        case .recentFailure:
            return localizedNotice("iori 起動失敗", "iori failed to start")
        case .modelMissing:
            return localizedNotice("iori 未導入", "iori not installed")
        }
    }

    private func localStoryGenerationFailureMessage(runtimeError: String? = nil) -> String {
        if runtimeError?.contains("記号だけ") == true {
            return localizedNotice(
                "ローカルモデルが「…」のような記号だけを返しました。これは本文ではないため保存していません。もう一度試すか、NAGIで続けられます。",
                "The local model returned only symbols such as an ellipsis. It was not saved because it is not story text. Try again or continue with NAGI."
            )
        }
        return localizedNotice(
            "ローカルモデルが本文を生成できませんでした。会話は変更していません。もう一度試すか、NAGIで続けられます。",
            "The local model could not generate story text. The conversation was not changed. Try again or continue with NAGI."
        )
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
        for prefix in [
            "休憩提案:", "休憩の提案:", "ナレーション:", "提案:",
            "Rest suggestion:", "Narration:", "Suggestion:"
        ] {
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
        // 整形は記法の除去だけに留める。空・記号だけの応答を物語本文へ
        // 差し替えると、障害を隠したまま存在しない会話を保存してしまう。
        sanitize(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 話者ラベルや句読点を外した比較用テキスト。本文そのものはログへ出さない。
    private func normalizedStoryComparisonText(_ text: String) -> String {
        text.localizedLowercase.unicodeScalars
            .filter { scalar in
                scalar.properties.isAlphabetic || scalar.properties.numericType != nil
            }
            .map(String.init)
            .joined()
    }

    /// 直近の物語本文と同じ応答、または一つの応答内で同じ本文を繰り返す場合を検出する。
    /// 「うん」など極端に短い相づちは意図的な反復もあり得るため、4文字以上だけを比較する。
    private func isDuplicateStoryOutput(_ candidates: [StoryMessage], in session: StorySession) -> Bool {
        let candidateTexts = candidates
            .map { normalizedStoryComparisonText($0.text) }
            .filter { $0.count >= 4 }
        guard !candidateTexts.isEmpty else { return false }

        if Set(candidateTexts).count != candidateTexts.count {
            return true
        }

        let previousTexts = Set(
            storyContentMessages(from: session.messages)
                .suffix(12)
                .map { normalizedStoryComparisonText($0.text) }
                .filter { $0.count >= 4 }
        )
        guard !previousTexts.isEmpty else { return false }

        // ナレーションと台詞が揃って同じ場合は同一応答とみなす。
        // 1メッセージ構成のローカル応答も同じ判定で再生成する。
        if candidateTexts.allSatisfy({ previousTexts.contains($0) }) {
            return true
        }

        // 台詞が新しくても、ナレーションだけが直近と同じなら場面描写の反復である。
        let previousNarrations = Set(
            storyContentMessages(from: session.messages)
                .suffix(12)
                .filter { message in
                    if case .narrator = message.author { return true }
                    return false
                }
                .map { normalizedStoryComparisonText($0.text) }
                .filter { $0.count >= 4 }
        )
        return candidates.contains { message in
            guard case .narrator = message.author else { return false }
            let text = normalizedStoryComparisonText(message.text)
            return text.count >= 4 && previousNarrations.contains(text)
        }
    }

    private func isMeaningfulStoryText(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            scalar.properties.isAlphabetic || scalar.properties.numericType != nil
        }
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
        let userLabel = KizunaCopy.text(japanese: "ユーザー", english: "User")
        let narrationLabel = KizunaCopy.text(japanese: "ナレーション", english: "Narration")
        switch message.author {
        case .user:
            return "\(userLabel): \(message.text)"
        case .system:
            return ""
        case .narrator:
            return "\(narrationLabel): \(message.text)"
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

    private func statusText(_ japanese: String, _ english: String) -> String {
        KizunaCopy.text(japanese: japanese, english: english)
    }

    private func localizedNotice(_ japanese: String, _ english: String) -> String {
        KizunaCopy.text(japanese: japanese, english: english)
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
