/*
仕様:
- 役割: Story モードの 4 画面用 ViewModel (Library/Create/Detail/Session)。
- 主な型: StoryWorldLibraryViewModel, StoryWorldCreateViewModel, StoryWorldDetailViewModel,
         StorySessionViewModel.
*/

import Foundation
import Combine

/// デバッグ設定から休憩提案カードの表示テストを依頼するための共有窓口。
enum KizunaDebugOptions {
    static let restSuggestionEnabledKey = "kizuna.debug.restSuggestion.enabled"
    static let restSuggestionRequestKey = "kizuna.debug.restSuggestion.requestedAt"
    static let restSuggestionRequestNotification = Notification.Name("kizuna.debug.restSuggestion.requested")
    static let safetyConcernRequestKey = "kizuna.debug.safetyConcern.requestedAt"
    static let safetyConcernRequestNotification = Notification.Name("kizuna.debug.safetyConcern.requested")

    static func requestRestSuggestionUI() {
        let timestamp = Date().timeIntervalSince1970
        UserDefaults.standard.set(timestamp, forKey: restSuggestionRequestKey)
        NSLog("[KizunaDebug] rest suggestion requested: %.3f", timestamp)
        NotificationCenter.default.post(name: restSuggestionRequestNotification, object: nil)
    }

    static func requestSafetyConcernUI() {
        let timestamp = Date().timeIntervalSince1970
        UserDefaults.standard.set(timestamp, forKey: safetyConcernRequestKey)
        NSLog("[KizunaDebug] safety concern requested: %.3f", timestamp)
        NotificationCenter.default.post(name: safetyConcernRequestNotification, object: nil)
    }
}

// MARK: - Library

enum StoryLibraryLoadIssue: String, Equatable, Sendable {
    case storageFailure

    var messageKey: String { "ストーリーの保存データを読み込めません" }
}

@MainActor
final class StoryWorldLibraryViewModel: ObservableObject {
    @Published private(set) var worlds: [StoryWorld] = []
    @Published private(set) var charactersById: [UUID: CharacterProfile] = [:]
    @Published private(set) var isBootstrapping = false
    @Published private(set) var loadError: StoryLibraryLoadIssue?
    @Published private(set) var seedError: CharacterLibrarySeed.SeedIssue?
    @Published var searchText: String = ""
    @Published var groupFilter: CategoryGroup? = nil

    private let worldRepo: StoryWorldRepository = LocalJSONStoryWorldRepository()
    private let characterRepo: CharacterRepository = LocalJSONCharacterRepository()
    private let castRepo: CastRepository = LocalJSONCastRepository()
    private let sceneRepo: StorySceneRepository = LocalJSONStorySceneRepository()
    private let sessionRepo: StorySessionRepository = LocalJSONStorySessionRepository()
    private let lorebookRepo: StoryLorebookRepository = LocalJSONStoryLorebookRepository()
    private let storyMemoryRepo: StoryMemoryRepository = LocalJSONStoryMemoryRepository()

    func bootstrap() async {
        guard !isBootstrapping else { return }
        isBootstrapping = true
        loadError = nil
        seedError = nil

        // 既存データは初期シードを待たずに表示する。大きなJSONを持つMacでも
        // 一覧が空のまま固まったように見えないようにする。
        await reload()

        let error = await CharacterLibrarySeed.seedIfNeeded(characterRepo: characterRepo, worldRepo: worldRepo)
        seedError = error
        await reload()
        isBootstrapping = false
    }

    func reload() async {
        do {
            let fetchedWorlds = try await worldRepo.fetchWorlds()
            self.worlds = deduplicatedSystemWorlds(fetchedWorlds)
            let characters = try await characterRepo.fetchCharacters()
            self.charactersById = characters.reduce(into: [:]) { result, character in
                guard result[character.id] == nil else { return }
                result[character.id] = character
            }
            loadError = nil
        } catch {
            let message = String(describing: error)
            loadError = .storageFailure
            NSLog("[StoryLibraryVM] reload failed: %@", message)
        }
    }

    func retryBootstrap() async {
        await bootstrap()
    }

    private func deduplicatedSystemWorlds(_ fetchedWorlds: [StoryWorld]) -> [StoryWorld] {
        var seenSystemWorlds = Set<String>()
        return fetchedWorlds.filter { world in
            guard world.isSystemProtected == true else { return true }
            // 以前のシードはタイトルの大文字・空白・Unicode正規化だけが違う
            // 複製を残すことがあった。標準ストーリーのタイトルは一意なので、
            // 説明文が少し変わっていても同じタイトルを1件に畳む。
            let key = normalizedSystemWorldKey(world)
            guard seenSystemWorlds.insert(key).inserted else {
                NSLog("[StoryLibraryVM] hiding duplicate system world title: %@ (%@)", world.title, world.id.uuidString)
                return false
            }
            return true
        }
    }

    private func normalizedSystemWorldKey(_ world: StoryWorld) -> String {
        func normalize(_ value: String) -> String {
            value
                .precomposedStringWithCanonicalMapping
                .lowercased()
                .filter { !$0.isWhitespace && !$0.isPunctuation && $0 != "\u{200B}" }
        }
        return normalize(world.title)
    }

    func delete(id: UUID) async {
        guard let world = worlds.first(where: { $0.id == id }), world.isSystemProtected != true else { return }
        do {
            // 一覧画面からの削除も詳細画面と同じく関連データを掃除する。
            let sessions = try await sessionRepo.fetchSessions(storyWorldId: id)
            for session in sessions {
                try await sessionRepo.deleteSession(id: session.id)
            }
            let lorebookEntries = try await lorebookRepo.fetchAllEntries(storyWorldId: id)
            for entry in lorebookEntries {
                try await lorebookRepo.deleteEntry(id: entry.id)
            }
            try await castRepo.deleteAllCast(storyWorldId: id)
            try await sceneRepo.deleteAllScenes(storyWorldId: id)
            try await storyMemoryRepo.deleteAllMemories(storyWorldId: id)
            try await worldRepo.deleteWorld(id: id)
            await reload()
        } catch {
            NSLog("[StoryLibraryVM] delete failed: %@", String(describing: error))
        }
    }

    var filtered: [StoryWorld] {
        var result = worlds
        if let g = groupFilter { result = result.filter { $0.genre.group == g } }
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !needle.isEmpty {
            result = result.filter { w in
                let displayed = w.localizedForCurrentLanguage
                return displayed.title.lowercased().contains(needle)
                    || displayed.shortDescription.lowercased().contains(needle)
                    || displayed.tags.contains(where: { $0.lowercased().contains(needle) })
            }
        }
        return result
    }

    func coverCharacter(for world: StoryWorld) -> CharacterProfile? {
        if let mainCharacterId = world.mainCharacterId,
           let character = charactersById[mainCharacterId] {
            return character
        }
        return world.characterIds.compactMap { charactersById[$0] }.first
    }
}

// MARK: - Create

@MainActor
final class StoryWorldCreateViewModel: ObservableObject {
    @Published var draft: StoryWorld
    @Published var sceneDraft: StoryScene
    @Published private(set) var castDrafts: [CastMember] = []
    // StoryWorld内で使うLorebook。キャラ欄ではなく物語編集画面から管理する。
    @Published private(set) var lorebookDrafts: [StoryLorebookEntry] = []
    @Published private(set) var availableCharacters: [CharacterProfile] = []
    @Published var saveError: String? = nil
    @Published var generationBrief: String = ""
    @Published private(set) var isGeneratingTemplate: Bool = false
    @Published private(set) var generationStatus: String? = nil

    private let worldRepo: StoryWorldRepository = LocalJSONStoryWorldRepository()
    private let castRepo: CastRepository = LocalJSONCastRepository()
    private let characterRepo: CharacterRepository = LocalJSONCharacterRepository()
    private let sceneRepo: StorySceneRepository = LocalJSONStorySceneRepository()
    private let lorebookRepo: StoryLorebookRepository = LocalJSONStoryLorebookRepository()
    private let safetyPipeline = SafetyPipeline.shared

    init(existing: StoryWorld? = nil) {
        if let existing {
            self.draft = existing
            self.sceneDraft = StoryScene(
                storyWorldId: existing.id,
                title: existing.title + " - 第 1 場面",
                mood: existing.mood,
                sceneGoal: existing.storyGoal,
                summary: existing.openingScene
            )
        } else {
            let world = StoryWorld(
                title: "",
                genre: .originalFreeform,
                relationshipGenre: .none
            )
            self.draft = world
            self.sceneDraft = StoryScene(storyWorldId: world.id)
        }
    }

    func load() async {
        do {
            self.availableCharacters = try await characterRepo.fetchCharacters()
            self.castDrafts = (try? await castRepo.fetchCast(storyWorldId: draft.id)) ?? []
            self.lorebookDrafts = (try? await lorebookRepo.fetchEntries(storyWorldId: draft.id)) ?? []
            if let firstScene = ((try? await sceneRepo.fetchScenes(storyWorldId: draft.id)) ?? []).first {
                self.sceneDraft = firstScene
            } else if sceneDraft.title.isEmpty {
                sceneDraft.title = draft.title.isEmpty ? "第 1 場面" : draft.title + " - 第 1 場面"
                sceneDraft.mood = draft.mood
                sceneDraft.sceneGoal = draft.storyGoal
                sceneDraft.summary = draft.openingScene
            }
        } catch {
            NSLog("[StoryWorldCreateVM] load failed: %@", String(describing: error))
        }
    }

    func addCharacter(_ profile: CharacterProfile) {
        guard !castDrafts.contains(where: { $0.characterId == profile.id }) else { return }
        if !availableCharacters.contains(where: { $0.id == profile.id }) {
            availableCharacters.append(profile)
        }
        let cast = CastMember(
            storyWorldId: draft.id,
            characterId: profile.id,
            roleInStory: castDrafts.isEmpty ? .main : .secondary,
            importance: castDrafts.isEmpty ? 0.9 : 0.5,
            introductionTiming: castDrafts.isEmpty ? .opening : .early,
            relationshipToUser: profile.relationshipToUser
        )
        castDrafts.append(cast)
        if !draft.characterIds.contains(profile.id) { draft.characterIds.append(profile.id) }
        if draft.mainCharacterId == nil { draft.mainCharacterId = profile.id }
    }

    // Lorebookカードを1件追加する。キーワードは空白・読点区切りで受け取る。
    func addLorebookEntry(title: String, keywordsText: String, content: String) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, !cleanContent.isEmpty else { return }
        let keywords = keywordsText
            .split(whereSeparator: { $0 == "," || $0 == "、" || $0 == " " || $0 == "\n" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        lorebookDrafts.append(
            StoryLorebookEntry(
                storyWorldId: draft.id,
                title: cleanTitle,
                keywords: keywords,
                content: cleanContent
            )
        )
    }

    func removeLorebookEntry(id: UUID) {
        lorebookDrafts.removeAll { $0.id == id }
    }

    func generateTemplateWith31BThinking() async {
        let brief = generationBrief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brief.isEmpty else {
            saveError = "作りたいストーリーの方向性を入力してください。"
            return
        }

        guard StoryGemma31BAPIService.shared.hasAPIKey else {
            saveError = "Gemma4 APIキーが未設定です。絆アプリ右上の設定からNAGI APIキーを登録してください。"
            return
        }

        isGeneratingTemplate = true
        generationStatus = "Gemma4 31B APIで雛形を作成中..."
        saveError = nil
        defer { isGeneratingTemplate = false }

        let systemPrompt = Self.storyTemplateSystemPrompt + "\n\n" + (KizunaCopy.language == .english
            ? "All human-readable string values in the JSON (title, descriptions, settings, scenes, character text, tags, and rules) must be written in English. Keep enum values exactly as specified."
            : "JSON内のタイトル、説明、設定、シーン、キャラクター本文、タグ、ルールは日本語で書いてください。enum値はschemaの表記をそのまま使ってください。")
        let reply: String
        do {
            reply = try await StoryGemma31BAPIService.shared.generate(
                systemPrompt: systemPrompt,
                userPrompt: brief,
                temperature: 0.45,
                maxOutputTokens: 8192
            )
        } catch {
            saveError = error.localizedDescription
            generationStatus = nil
            return
        }

        guard let data = Self.extractJSONObjectData(from: reply) else {
            saveError = "雛形の生成に失敗しました。JSONとして読める出力がありません。"
            generationStatus = nil
            return
        }

        do {
            let template = try JSONDecoder().decode(GeneratedStoryTemplate.self, from: data)
            try await applyGeneratedTemplate(template)
            generationStatus = "雛形をフォームへ反映しました。"
        } catch {
            saveError = "雛形の読み込みに失敗しました: \(error.localizedDescription)"
            generationStatus = nil
        }
    }

    func removeCharacter(characterID: UUID) {
        castDrafts.removeAll { $0.characterId == characterID }
        for idx in castDrafts.indices {
            castDrafts[idx].relationshipToOtherCharacters.removeAll {
                $0.fromCharacterId == characterID || $0.toCharacterId == characterID
            }
        }
        draft.characterIds.removeAll { $0 == characterID }
        sceneDraft.activeCharacterIds.removeAll { $0 == characterID }
        if draft.mainCharacterId == characterID {
            draft.mainCharacterId = castDrafts.first?.characterId
        }
    }

    func setRole(_ role: CastRole, for characterID: UUID) {
        guard let idx = castDrafts.firstIndex(where: { $0.characterId == characterID }) else { return }
        castDrafts[idx].roleInStory = role
    }

    func setImportance(_ value: Double, for characterID: UUID) {
        guard let idx = castDrafts.firstIndex(where: { $0.characterId == characterID }) else { return }
        castDrafts[idx].importance = min(max(value, 0), 1)
    }

    func setIntroductionTiming(_ timing: IntroductionTiming, for characterID: UUID) {
        guard let idx = castDrafts.firstIndex(where: { $0.characterId == characterID }) else { return }
        castDrafts[idx].introductionTiming = timing
    }

    func setStoryRelationshipToUser(_ text: String, for characterID: UUID) {
        guard let idx = castDrafts.firstIndex(where: { $0.characterId == characterID }) else { return }
        castDrafts[idx].relationshipToUser = text
    }

    func setActiveInOpeningScene(_ isActive: Bool, for characterID: UUID) {
        if isActive {
            // 単体物語の開始シーンは主役NPCだけ。別キャラを選ぶと前の選択を置き換える。
            if draft.isSoloStory {
                sceneDraft.activeCharacterIds = [characterID]
                return
            }
            guard !sceneDraft.activeCharacterIds.contains(characterID),
                  sceneDraft.activeCharacterIds.count < StoryConstants.maxActiveCharacters else { return }
            sceneDraft.activeCharacterIds.append(characterID)
        } else {
            sceneDraft.activeCharacterIds.removeAll { $0 == characterID }
        }
    }

    func relationship(from fromID: UUID, to toID: UUID) -> CharacterRelationship {
        castDrafts
            .first(where: { $0.characterId == fromID })?
            .relationshipToOtherCharacters
            .first(where: { $0.toCharacterId == toID })
        ?? CharacterRelationship(fromCharacterId: fromID, toCharacterId: toID)
    }

    func updateRelationship(
        from fromID: UUID,
        to toID: UUID,
        type: RelationshipType? = nil,
        description: String? = nil,
        tension: Double? = nil,
        trust: Double? = nil
    ) {
        guard fromID != toID,
              let idx = castDrafts.firstIndex(where: { $0.characterId == fromID }) else { return }
        var relation = relationship(from: fromID, to: toID)
        if let type { relation.relationshipType = type }
        if let description { relation.description = description }
        if let tension { relation.tension = min(max(tension, 0), 1) }
        if let trust { relation.trust = min(max(trust, 0), 1) }
        if let relIdx = castDrafts[idx].relationshipToOtherCharacters.firstIndex(where: { $0.toCharacterId == toID }) {
            castDrafts[idx].relationshipToOtherCharacters[relIdx] = relation
        } else {
            castDrafts[idx].relationshipToOtherCharacters.append(relation)
        }
    }

    func save() async -> StoryWorld? {
        saveError = nil
        guard !draft.title.trimmingCharacters(in: .whitespaces).isEmpty else {
            saveError = "タイトルを入力してください。"
            return nil
        }
        do {
            // World 保存
            var world = draft
            world.updatedAt = Date()
            try await worldRepo.saveWorld(world)
            // Cast 保存
            try? await castRepo.deleteAllCast(storyWorldId: world.id)
            for member in castDrafts {
                var m = member
                m.storyWorldId = world.id
                try await castRepo.saveCast(m)
            }
            // LorebookもWorld単位で置き換え、削除されたカードを残さない。
            // 無効化済みエントリも編集保存時に置き換える。enabled のみ取得すると
            // UIから見えない古いカードが story_lorebook.json に残り続ける。
            let existingLorebook = (try? await lorebookRepo.fetchAllEntries(storyWorldId: world.id)) ?? []
            for entry in existingLorebook {
                try? await lorebookRepo.deleteEntry(id: entry.id)
            }
            for entry in lorebookDrafts {
                var value = entry
                value.storyWorldId = world.id
                try await lorebookRepo.saveEntry(value)
            }
            // Opening Scene を 1 件 seed / update
            let existingScenes = (try? await sceneRepo.fetchScenes(storyWorldId: world.id)) ?? []
            var opening = sceneDraft
            opening.storyWorldId = world.id
            if opening.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                opening.title = world.title + " - 第 1 場面"
            }
            if opening.mood.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                opening.mood = world.mood
            }
            if opening.sceneGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                opening.sceneGoal = world.storyGoal
            }
            if opening.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                opening.summary = world.openingScene
            }
            if opening.activeCharacterIds.isEmpty {
                let limit = world.isSoloStory ? StoryConstants.soloActiveCharacters : StoryConstants.maxActiveCharacters
                opening.activeCharacterIds = Array(castDrafts.prefix(limit).map(\.characterId))
            }
            let activeLimit = world.isSoloStory ? StoryConstants.soloActiveCharacters : StoryConstants.maxActiveCharacters
            opening.activeCharacterIds = Array(opening.activeCharacterIds.prefix(activeLimit))
            if existingScenes.isEmpty {
                try await sceneRepo.saveScene(opening)
            } else {
                opening.id = existingScenes[0].id
                opening.createdAt = existingScenes[0].createdAt
                opening.updatedAt = Date()
                try await sceneRepo.saveScene(opening)
            }
            return world
        } catch {
            saveError = "保存に失敗しました: " + String(describing: error)
            return nil
        }
    }

    private func applyGeneratedTemplate(_ template: GeneratedStoryTemplate) async throws {
        let story = template.story
        draft.title = story.title
        draft.shortDescription = story.shortDescription
        draft.genre = Self.category(from: story.genre)
        draft.relationshipGenre = Self.relationship(from: story.relationshipGenre)
        draft.tags = story.tags
        draft.worldSetting = story.worldSetting
        draft.userRole = story.userRole
        draft.openingScene = story.openingScene
        draft.storyGoal = story.storyGoal
        draft.mood = story.mood
        draft.safetyRules = template.generationRules

        let scene = template.initialScene
        sceneDraft.title = scene.title
        sceneDraft.location = scene.location
        sceneDraft.timeOfDay = scene.timeOfDay
        sceneDraft.mood = scene.mood
        sceneDraft.sceneGoal = scene.sceneGoal
        sceneDraft.conflict = scene.conflict
        sceneDraft.summary = scene.summary
        sceneDraft.activeCharacterIds = []

        castDrafts.removeAll()
        draft.characterIds.removeAll()
        draft.mainCharacterId = nil

        // 指定がなければ、ユーザーと主役NPC1人だけの単体物語にする。
        // 「群像」「複数人」などを明示した時だけ補助キャラも取り込む。
        let wantsEnsemble = generationBrief.localizedCaseInsensitiveContains("群像")
            || generationBrief.localizedCaseInsensitiveContains("複数人")
            || generationBrief.localizedCaseInsensitiveContains("複数")
            || generationBrief.localizedCaseInsensitiveContains("チーム")
            || generationBrief.localizedCaseInsensitiveContains("仲間たち")
        draft.castMode = wantsEnsemble ? .ensemble : .solo
        let generatedCharacters = template.characters.prefix(wantsEnsemble ? 4 : 1)
        for generated in generatedCharacters {
            let profile = CharacterProfile(
                name: generated.name,
                displayName: generated.displayName.isEmpty ? generated.name : generated.displayName,
                shortDescription: generated.shortDescription,
                imageKey: generated.imageKey,
                category: Self.category(from: generated.category),
                relationshipGenre: Self.relationship(from: generated.relationshipGenre),
                personality: generated.personality,
                speakingStyle: generated.speakingStyle,
                background: generated.background,
                relationshipToUser: generated.relationshipToUser,
                scenario: generated.scenario,
                firstMessage: generated.firstMessage,
                tags: generated.tags,
                rules: generated.rules,
                safetyRules: generated.safetyRules,
                visibility: .private,
                safetyRating: .general
            )
            try await characterRepo.saveCharacter(profile)
            addCharacter(profile)
            setRole(Self.castRole(from: generated.storyRole), for: profile.id)
            setIntroductionTiming(generated.activeInInitialScene ? .opening : Self.introductionTiming(from: generated.introductionTiming), for: profile.id)
            setImportance(generated.importance, for: profile.id)
            setStoryRelationshipToUser(generated.storyRelationshipToUser, for: profile.id)
            setActiveInOpeningScene(generated.activeInInitialScene, for: profile.id)
        }

        var charactersByName: [String: UUID] = [:]
        for character in availableCharacters {
            charactersByName[character.displayName] = character.id
            charactersByName[character.name] = character.id
        }
        for relationship in template.relationships {
            guard let fromID = charactersByName[relationship.from],
                  let toID = charactersByName[relationship.to] else { continue }
            updateRelationship(
                from: fromID,
                to: toID,
                type: Self.relationshipType(from: relationship.relationshipType),
                description: relationship.description,
                tension: relationship.tension,
                trust: relationship.trust
            )
        }
    }

    private static let storyTemplateSystemPrompt = """
    あなたはVIUK 絆のストーリー作成エンジンです。
    ユーザーの短い説明から、カスタムGPTのように動く物語テンプレートを1つ作ります。
    出力はJSONオブジェクトのみ。Markdown、説明文、コードフェンスは禁止。

    必須JSON schema:
    {
      "story": {
        "title": "string",
        "shortDescription": "string",
        "genre": "school_romance | slice_of_life | detective | fantasy_rpg | sci_fi | club_activity | original_freeform",
        "relationshipGenre": "none | friendship | bl | gl | senpai_kouhai | mentor_student | rival | freeform",
        "worldSetting": "string",
        "userRole": "string",
        "openingScene": "string",
        "storyGoal": "string",
        "mood": "string",
        "tags": ["string"]
      },
      "initialScene": {
        "title": "string",
        "location": "string",
        "timeOfDay": "string",
        "mood": "string",
        "sceneGoal": "string",
        "conflict": "string",
        "summary": "string"
      },
      "characters": [
        {
          "name": "string",
          "displayName": "string",
          "shortDescription": "string",
          "category": "school_romance | classmate | senpai_kouhai | best_friend | detective | fantasy_rpg | sci_fi | club_activity | original_freeform",
          "relationshipGenre": "friendship | bl | gl | senpai_kouhai | mentor_student | rival | freeform",
          "personality": "string",
          "speakingStyle": "string",
          "background": "string",
          "relationshipToUser": "string",
          "scenario": "string",
          "firstMessage": "名前: 本文",
          "tags": ["string"],
          "rules": ["string"],
          "safetyRules": ["string"],
          "storyRole": "main | friend | mentor | rival | secondary",
          "introductionTiming": "opening | early | middle | late | optional",
          "activeInInitialScene": true,
          "importance": 1.0,
          "storyRelationshipToUser": "string",
          "imageKey": "optional_string"
        }
      ],
      "relationships": [
        {
          "from": "displayName",
          "to": "displayName",
          "relationshipType": "friend | classmate | senior_junior | rival | mentor",
          "description": "string",
          "trust": 0.5,
          "tension": 0.2
        }
      ],
      "generationRules": [
        "最初の行は必ず「ナレーション: 本文」",
        "場面が自然なら1ターンで複数キャラが話してよい",
        "キャラ発話は「名前: 本文」",
        "複数キャラを出す時は発話ごとに名前を分ける",
        "active以外のキャラは同じ場にいて自然に反応する時だけ短く喋る",
        "会話だけで終わらせず、場面・表情・沈黙・空気を少し描写する",
        "思考過程、案、選択肢、メタ発言は出さない"
      ]
    }

    原則はユーザーと主役NPC1人の物語にする。ユーザーが複数人・群像劇を明示した時だけ、補助キャラを最大3人追加する。
    初期シーンで同席させるのは原則として主役NPC1人だけにする。
    恋愛や対立は段階的に進める。安全ルールは物語ジャンルに合わせる。
    """

    private static func extractJSONObjectData(from text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}") else { return nil }
        let json = String(trimmed[start...end])
        guard let data = json.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else { return nil }
        return data
    }

    private static func category(from raw: String) -> CharacterCategory {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let category = CharacterCategory(rawValue: normalized) { return category }
        if normalized.contains("ミステリー") || normalized.localizedCaseInsensitiveContains("detective") { return .detective }
        if normalized.contains("SF") || normalized.contains("未来") || normalized.localizedCaseInsensitiveContains("sci") { return .sciFi }
        if normalized.contains("ファンタジー") || normalized.contains("冒険") { return .fantasyRpg }
        if normalized.contains("部活") || normalized.contains("ロボット") { return .clubActivity }
        if normalized.contains("日常") || normalized.contains("喫茶") { return .sliceOfLife }
        if normalized.contains("先輩") { return .senpaiKouhai }
        if normalized.contains("同級") { return .classmate }
        return .originalFreeform
    }

    private static func relationship(from raw: String) -> RelationshipGenre {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let genre = RelationshipGenre(rawValue: normalized) { return genre }
        if normalized.localizedCaseInsensitiveContains("BL") { return .bl }
        if normalized.localizedCaseInsensitiveContains("GL") { return .gl }
        if normalized.contains("先輩") || normalized.contains("後輩") { return .senpaiKouhai }
        if normalized.contains("ライバル") { return .rival }
        if normalized.contains("師") || normalized.contains("先生") { return .mentorStudent }
        if normalized.contains("友") || normalized.contains("仲間") || normalized.contains("相棒") { return .friendship }
        return .freeform
    }

    private static func castRole(from raw: String) -> CastRole {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let role = CastRole(rawValue: normalized) { return role }
        if normalized.contains("メイン") || normalized.contains("主") { return .main }
        if normalized.contains("友") || normalized.contains("仲間") { return .friend }
        if normalized.contains("先輩") || normalized.contains("指導") { return .mentor }
        if normalized.contains("ライバル") { return .rival }
        return .secondary
    }

    private static func introductionTiming(from raw: String) -> IntroductionTiming {
        if let timing = IntroductionTiming(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) { return timing }
        if raw.contains("初") || raw.contains("opening") { return .opening }
        if raw.contains("中") || raw.contains("middle") { return .middle }
        if raw.contains("後") || raw.contains("late") { return .late }
        return .early
    }

    private static func relationshipType(from raw: String) -> RelationshipType {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let type = RelationshipType(rawValue: normalized) { return type }
        if normalized.contains("同級") { return .classmate }
        if normalized.contains("先輩") || normalized.contains("後輩") || normalized.contains("先生") || normalized.contains("mentor") { return .seniorJunior }
        if normalized.contains("ライバル") { return .rival }
        return .friend
    }
}

private struct GeneratedStoryTemplate: Decodable {
    struct Story: Decodable {
        var title: String
        var shortDescription: String
        var genre: String
        var relationshipGenre: String
        var worldSetting: String
        var userRole: String
        var openingScene: String
        var storyGoal: String
        var mood: String
        var tags: [String]
    }

    struct InitialScene: Decodable {
        var title: String
        var location: String
        var timeOfDay: String
        var mood: String
        var sceneGoal: String
        var conflict: String?
        var summary: String
    }

    struct Character: Decodable {
        var name: String
        var displayName: String
        var shortDescription: String
        var category: String
        var relationshipGenre: String
        var personality: String
        var speakingStyle: String
        var background: String
        var relationshipToUser: String
        var scenario: String
        var firstMessage: String
        var tags: [String]
        var rules: [String]
        var safetyRules: [String]
        var storyRole: String
        var introductionTiming: String
        var activeInInitialScene: Bool
        var importance: Double
        var storyRelationshipToUser: String
        var imageKey: String?
    }

    struct Relationship: Decodable {
        var from: String
        var to: String
        var relationshipType: String
        var description: String
        var trust: Double
        var tension: Double
    }

    var story: Story
    var initialScene: InitialScene
    var characters: [Character]
    var relationships: [Relationship]
    var generationRules: [String]
}

// MARK: - Detail

@MainActor
final class StoryWorldDetailViewModel: ObservableObject {
    @Published private(set) var world: StoryWorld
    @Published private(set) var cast: [CastMember] = []
    @Published private(set) var scenes: [StoryScene] = []
    @Published private(set) var sessions: [StorySession] = []
    // この物語だけに属する思い出。全体メモリーとは分けて表示・取得する。
    @Published private(set) var storyMemories: [StoryMemory] = []
    @Published private(set) var characterIndex: [UUID: CharacterProfile] = [:]

    private let worldRepo: StoryWorldRepository = LocalJSONStoryWorldRepository()
    private let castRepo: CastRepository = LocalJSONCastRepository()
    private let sceneRepo: StorySceneRepository = LocalJSONStorySceneRepository()
    private let sessionRepo: StorySessionRepository = LocalJSONStorySessionRepository()
    private let lorebookRepo: StoryLorebookRepository = LocalJSONStoryLorebookRepository()
    private let storyMemoryRepo: StoryMemoryRepository = LocalJSONStoryMemoryRepository()
    private let characterRepo: CharacterRepository = LocalJSONCharacterRepository()

    init(world: StoryWorld) {
        self.world = world
    }

    func reload() async {
        async let castFetch = (try? await castRepo.fetchCast(storyWorldId: world.id)) ?? []
        async let scenesFetch = (try? await sceneRepo.fetchScenes(storyWorldId: world.id)) ?? []
        async let sessionsFetch = (try? await sessionRepo.fetchSessions(storyWorldId: world.id)) ?? []
        async let memoriesFetch = (try? await storyMemoryRepo.fetchMemories(storyWorldId: world.id)) ?? []
        async let charsFetch = (try? await characterRepo.fetchCharacters()) ?? []
        let (cast, scenes, sessions, memories, chars) = await (castFetch, scenesFetch, sessionsFetch, memoriesFetch, charsFetch)
        let repairedCast = reconciledCast(cast, for: world, existingScenes: scenes)
        if Set(cast.map(\.characterId)) != Set(repairedCast.map(\.characterId)) || cast.count != repairedCast.count {
            // 部分的に欠けたキャストや、削除済みキャラの孤児参照を一度だけ整理する。
            try? await castRepo.deleteAllCast(storyWorldId: world.id)
            for member in repairedCast { try? await castRepo.saveCast(member) }
        }
        self.cast = repairedCast
        self.scenes = scenes
        self.sessions = sessions
        self.storyMemories = memories
        self.characterIndex = chars.reduce(into: [:]) { result, character in
            guard result[character.id] == nil else { return }
            result[character.id] = character
        }
    }

    @discardableResult
    func createOrResumeSession(preferredSessionID: UUID? = nil) async -> (StorySession, StoryScene)? {
        if let preferredSessionID,
           let session = sessions.first(where: { $0.id == preferredSessionID }),
           let sceneId = session.currentSceneId,
           let scene = scenes.first(where: { $0.id == sceneId }) {
            return (session, scene)
        }
        if preferredSessionID == nil,
           let last = sessions.first,
           let sceneId = last.currentSceneId,
           let scene = scenes.first(where: { $0.id == sceneId }) {
            return (last, scene)
        }
        // 新規セッション + 先頭シーン
        guard let firstScene = scenes.first else { return nil }

        // セッション保存中にシーンが削除・置換されると currentSceneId だけが
        // 無効になる。ここで既存セッションを先頭シーンへ修復しないと、画面を
        // 開くたびに同じセッションが新規作成され、会話履歴が分裂する。
        if let brokenIndex = sessions.firstIndex(where: { session in
            if let preferredSessionID { return session.id == preferredSessionID }
            return session.id == sessions.first?.id
        }) {
            var repaired = sessions[brokenIndex]
            repaired.currentSceneId = firstScene.id
            if repaired.progressLabel?.isEmpty != false { repaired.progressLabel = "第1章 きっかけ" }
            if repaired.currentObjective?.isEmpty != false { repaired.currentObjective = firstScene.sceneGoal.isEmpty ? world.storyGoal : firstScene.sceneGoal }
            if repaired.lastSceneSummary?.isEmpty != false {
                repaired.lastSceneSummary = firstScene.summary.isEmpty ? world.openingScene : firstScene.summary
            }
            try? await sessionRepo.saveSession(repaired)
            await reload()
            return (repaired, firstScene)
        }

        var session = StorySession(
            storyWorldId: world.id,
            currentSceneId: firstScene.id,
            progressLabel: "第1章 きっかけ",
            currentObjective: firstScene.sceneGoal.isEmpty ? world.storyGoal : firstScene.sceneGoal,
            relationshipStage: "出会い",
            lastTurnProgress: nil,
            lastSceneSummary: firstScene.summary.isEmpty ? world.openingScene : firstScene.summary,
            unresolvedHooks: [firstScene.conflict, world.storyGoal].compactMap { $0 }.filter { !$0.isEmpty }
        )
        // opening を narration として 1 件投入 (見やすさのため)
        if !world.openingScene.isEmpty {
            session.messages.append(StoryMessage(author: .narrator, text: world.openingScene))
        }
        try? await sessionRepo.saveSession(session)
        await reload()
        return (session, firstScene)
    }

    func delete() async {
        // 標準ストーリーはUI以外からこのメソッドが呼ばれても削除しない。
        guard world.isSystemProtected != true else { return }
        do {
            // セッションとLorebookは別ファイルのため、世界だけ消すと孤児データが残る。
            let sessions = try await sessionRepo.fetchSessions(storyWorldId: world.id)
            for session in sessions {
                try await sessionRepo.deleteSession(id: session.id)
            }
            let lorebookEntries = try await lorebookRepo.fetchAllEntries(storyWorldId: world.id)
            for entry in lorebookEntries {
                try await lorebookRepo.deleteEntry(id: entry.id)
            }
            try await castRepo.deleteAllCast(storyWorldId: world.id)
            try await sceneRepo.deleteAllScenes(storyWorldId: world.id)
            // 物語を削除する時は、その世界だけの思い出も一緒に削除する。
            try await storyMemoryRepo.deleteAllMemories(storyWorldId: world.id)
            try await worldRepo.deleteWorld(id: world.id)
        } catch {
            NSLog("[StoryDetailVM] delete failed: %@", String(describing: error))
        }
    }

    private func defaultCastMembers(for world: StoryWorld, existingScenes: [StoryScene]) -> [CastMember] {
        let activeIDs = Set(existingScenes.first?.activeCharacterIds ?? Array(world.characterIds.prefix(StoryConstants.maxActiveCharacters)))
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
        existingScenes: [StoryScene]
    ) -> [CastMember] {
        guard !world.characterIds.isEmpty else { return [] }
        let defaults = defaultCastMembers(for: world, existingScenes: existingScenes)
        let existingByCharacterID = existing.reduce(into: [UUID: CastMember]()) { result, member in
            // 重複行がある場合は、最初の1件を正として安定させる。
            if result[member.characterId] == nil { result[member.characterId] = member }
        }
        return defaults.map { existingByCharacterID[$0.characterId] ?? $0 }
    }
}

// MARK: - Session (Scene chat)

/// 休憩提案を表示するための UI 用データ。
/// 生成済みの本文を保持し、同じ発動条件でモデルを二重実行しない。
struct StoryRestSuggestion: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let characterID: UUID?
    let characterName: String
}

@MainActor
final class StorySessionViewModel: ObservableObject {
    @Published private(set) var session: StorySession
    @Published private(set) var scene: StoryScene
    @Published private(set) var world: StoryWorld
    @Published private(set) var cast: [CastMember] = []
    @Published private(set) var characterIndex: [UUID: CharacterProfile] = [:]
    /// アプリ側で判定した休憩提案。nil の間は提案カードを表示しない。
    @Published var restSuggestion: StoryRestSuggestion?
    @Published var generationModel: StoryGenerationModel {
        didSet {
            defaults.set(generationModel.rawValue, forKey: generationModelKey)
        }
    }

    let service = StorySessionService()

    private let defaults = UserDefaults.standard
    private let castRepo: CastRepository = LocalJSONCastRepository()
    private let sceneRepo: StorySceneRepository = LocalJSONStorySceneRepository()
    private let sessionRepo: StorySessionRepository = LocalJSONStorySessionRepository()
    private let characterRepo: CharacterRepository = LocalJSONCharacterRepository()
    private let generationModelKey: String

    // 休憩提案の時計はアプリ側だけが管理する。モデルには判定を任せない。
    private var continuousUseStartedAt = Date()
    private var restSuggestionSuppressedUntil: Date?
    private var isGeneratingRestSuggestion = false
    // 同じ60分窓で専用生成を繰り返さないためのアプリ側フラグ。
    private var restSuggestionAttempted = false
    // アプリ内デバッグモードで、UI確認用に30秒後の提案カードを予約する。
    private var debugRestSuggestionTask: Task<Void, Never>?
    private var debugRestSuggestionObserver: NSObjectProtocol?
    private var debugSafetyConcernTask: Task<Void, Never>?
    private var debugSafetyConcernObserver: NSObjectProtocol?
    private var debugRequestPollingTask: Task<Void, Never>?
    private var lastSubmittedText: String?
    private var sendPreparationTask: Task<Void, Never>?
    private var sendPreparationID: UUID?

    init(world: StoryWorld, session: StorySession, scene: StoryScene) {
        self.world = world
        self.session = session
        self.scene = scene
        self.generationModelKey = "storySessionGenerationModel.\(world.id.uuidString)"
        let stored = UserDefaults.standard.string(forKey: generationModelKey)
        let savedModel = stored.flatMap(StoryGenerationModel.init(rawValue:)) ?? .e4b
        self.generationModel = savedModel
        registerDebugRestSuggestionObserver()
        registerDebugSafetyConcernObserver()
        startDebugRequestPolling()
    }

    deinit {
        debugRestSuggestionTask?.cancel()
        debugSafetyConcernTask?.cancel()
        debugRequestPollingTask?.cancel()
        sendPreparationTask?.cancel()
        if let debugRestSuggestionObserver {
            NotificationCenter.default.removeObserver(debugRestSuggestionObserver)
        }
        if let debugSafetyConcernObserver {
            NotificationCenter.default.removeObserver(debugSafetyConcernObserver)
        }
    }

    func bootstrap() async {
        async let castFetch = (try? await castRepo.fetchCast(storyWorldId: world.id)) ?? []
        async let charsFetch = (try? await characterRepo.fetchCharacters()) ?? []
        let (cast, chars) = await (castFetch, charsFetch)
        self.cast = cast
        self.characterIndex = chars.reduce(into: [:]) { result, character in
            guard result[character.id] == nil else { return }
            result[character.id] = character
        }
        consumePendingDebugRestSuggestionRequest()
        consumePendingDebugSafetyConcernRequest()
    }

    /// 通知を取り逃しても、Story画面が生きている間は予約キーを拾えるようにする。
    private func startDebugRequestPolling() {
        guard debugRequestPollingTask == nil else { return }
        debugRequestPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.consumePendingDebugRestSuggestionRequest()
                self.consumePendingDebugSafetyConcernRequest()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func registerDebugRestSuggestionObserver() {
        debugRestSuggestionObserver = NotificationCenter.default.addObserver(
            forName: KizunaDebugOptions.restSuggestionRequestNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.startDebugRestSuggestionTimer()
            }
        }
    }

    private func consumePendingDebugRestSuggestionRequest() {
        guard UserDefaults.standard.bool(forKey: KizunaDebugOptions.restSuggestionEnabledKey) else { return }
        let requestedAt = UserDefaults.standard.double(forKey: KizunaDebugOptions.restSuggestionRequestKey)
        // Storyを開くまでの時間を制限しない。設定画面から先に予約しても失わない。
        guard requestedAt > 0, Date().timeIntervalSince1970 - requestedAt < 24 * 60 * 60 else { return }
        UserDefaults.standard.removeObject(forKey: KizunaDebugOptions.restSuggestionRequestKey)
        NSLog("[KizunaDebug] rest suggestion request consumed")
        startDebugRestSuggestionTimer()
    }

    /// 設定画面のボタン押下後だけ、休憩提案カードと選択肢UIを確認する。
    private func startDebugRestSuggestionTimer() {
        guard UserDefaults.standard.bool(forKey: KizunaDebugOptions.restSuggestionEnabledKey) else { return }
        guard debugRestSuggestionTask == nil else { return }
        debugRestSuggestionTask = Task { [weak self] in
            defer { self?.debugRestSuggestionTask = nil }
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self, self.restSuggestion == nil else { return }
            UserDefaults.standard.removeObject(forKey: KizunaDebugOptions.restSuggestionRequestKey)
            let character = self.lastSpeakingCharacter() ?? self.activeCharacters.first
            let characterName = character.map { $0.displayName.isEmpty ? $0.name : $0.displayName } ?? "相手"
            self.restSuggestion = StoryRestSuggestion(
                text: "【DEBUG】休憩提案カードの表示テストです。",
                characterID: self.characterID(for: character),
                characterName: characterName
            )
            NSLog("[KizunaDebug] rest suggestion card published")
        }
    }

    private func registerDebugSafetyConcernObserver() {
        debugSafetyConcernObserver = NotificationCenter.default.addObserver(
            forName: KizunaDebugOptions.safetyConcernRequestNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.startDebugSafetyConcernTimer()
            }
        }
    }

    private func consumePendingDebugSafetyConcernRequest() {
        guard UserDefaults.standard.bool(forKey: KizunaDebugOptions.restSuggestionEnabledKey) else { return }
        let requestedAt = UserDefaults.standard.double(forKey: KizunaDebugOptions.safetyConcernRequestKey)
        // Storyを開くまでの時間を制限しない。設定画面から先に予約しても失わない。
        guard requestedAt > 0, Date().timeIntervalSince1970 - requestedAt < 24 * 60 * 60 else { return }
        UserDefaults.standard.removeObject(forKey: KizunaDebugOptions.safetyConcernRequestKey)
        NSLog("[KizunaDebug] safety concern request consumed")
        startDebugSafetyConcernTimer()
    }

    /// 設定画面のボタン押下後だけ、相談サポートカードを30秒後に表示する。
    private func startDebugSafetyConcernTimer() {
        guard UserDefaults.standard.bool(forKey: KizunaDebugOptions.restSuggestionEnabledKey) else { return }
        guard debugSafetyConcernTask == nil else { return }
        debugSafetyConcernTask = Task { [weak self] in
            defer { self?.debugSafetyConcernTask = nil }
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            UserDefaults.standard.removeObject(forKey: KizunaDebugOptions.safetyConcernRequestKey)
            self.service.showDebugSafetyConcern()
            NSLog("[KizunaDebug] safety concern card published")
        }
    }

    @discardableResult
    func send(_ userText: String) -> Bool {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              service.phase != .thinking,
              sendPreparationTask == nil else { return false }
        lastSubmittedText = userText
        // 直前ターンの保存完了通知と送信タップが競合すると、古い session スナップショットで
        // 次のターンを開始して新しい発言を上書きする。送信前に最新状態を一度だけ読み直す。
        let preparationID = UUID()
        sendPreparationID = preparationID
        sendPreparationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.sendPreparationID == preparationID {
                    self.sendPreparationTask = nil
                    self.sendPreparationID = nil
                }
            }
            guard !Task.isCancelled, self.sendPreparationID == preparationID else { return }
            await self.refreshAfterTurn()
            // キャンセルと再送が近接すると、古い準備タスクが最新の送信を
            // 横取りしないよう、IDとTask.isCancelledの両方を確認する。
            guard !Task.isCancelled,
                  self.sendPreparationID == preparationID,
                  self.service.phase != .thinking else { return }
            self.service.send(trimmed, session: self.session, world: self.world, scene: self.scene, generationModel: self.generationModel)

            // Service 内で session/scene が永続化されるので、こちらは UI 更新のため
            // 軽くポーリングで再取得する (将来 Combine pipeline 化)。
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, self.sendPreparationID == preparationID else { return }
                await self.refreshAfterTurn()
                if self.service.phase == .idle {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard !Task.isCancelled, self.sendPreparationID == preparationID else { return }
                    await self.refreshAfterTurn()
                    break
                }
            }
            guard !Task.isCancelled, self.sendPreparationID == preparationID else { return }
            await self.refreshAfterTurn()
        }
        return true
    }

    func retryLastMessage() {
        guard let lastSubmittedText, service.phase != .thinking else { return }
        send(lastSubmittedText)
    }

    /// 生成停止時は、サービス本体だけでなく送信前の状態再読込も止める。
    /// これを残すと停止直後の再送が一時的に弾かれる。
    func cancelGeneration() {
        sendPreparationID = nil
        sendPreparationTask?.cancel()
        sendPreparationTask = nil
        service.cancel()
    }

    func addNarration(_ text: String) {
        service.addNarration(text, session: session)
        Task { [weak self] in
            await self?.refreshAfterTurn()
        }
    }

    func refreshAfterTurn() async {
        let sessions = (try? await sessionRepo.fetchSessions(storyWorldId: world.id)) ?? []
        if let updated = sessions.first(where: { $0.id == session.id }) {
            self.session = updated
        }
        let scenes = (try? await sceneRepo.fetchScenes(storyWorldId: world.id)) ?? []
        if let updated = scenes.first(where: { $0.id == scene.id }) {
            self.scene = updated
        }
    }

    /// キャラクター発話が保存された直後だけ、60 分条件をアプリ側で判定する。
    /// 条件を満たしても、専用生成はこのメソッドから 1 回だけ呼び出す。
    func evaluateRestSuggestionAfterTurn() async {
        guard service.phase == .idle,
              restSuggestion == nil,
              !isGeneratingRestSuggestion,
              let lastMessage = session.messages.last,
              case .cast = lastMessage.author else { return }

        let now = Date()
        guard now.timeIntervalSince(continuousUseStartedAt) >= 60 * 60 else { return }
        if let suppressedUntil = restSuggestionSuppressedUntil, now < suppressedUntil { return }
        if restSuggestionSuppressedUntil != nil {
            // 120分の抑制が終わったら、次の提案窓を開始できる。
            restSuggestionSuppressedUntil = nil
            restSuggestionAttempted = false
        }
        guard !restSuggestionAttempted else { return }

        restSuggestionAttempted = true
        isGeneratingRestSuggestion = true
        defer { isGeneratingRestSuggestion = false }

        let character = lastSpeakingCharacter() ?? activeCharacters.first
        let characterName = character.map { $0.displayName.isEmpty ? $0.name : $0.displayName } ?? "相手"
        guard let generatedText = await service.generateRestSuggestion(
            character: character,
            world: world,
            scene: scene,
            generationModel: generationModel
        ) else {
            // モデルが生成できない場合は固定文を出さず、休憩提案を表示しない。
            // 時計を再スタートし、次の60分窓までは再生成しない。
            continuousUseStartedAt = now
            restSuggestionAttempted = false
            return
        }
        let text = generatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        restSuggestion = StoryRestSuggestion(
            text: text,
            characterID: characterID(for: character),
            characterName: characterName
        )
    }

    /// 「少し休む」は強制終了せず、次の連続利用の時計だけを再スタートする。
    func chooseRestSuggestionBreak() {
        restSuggestion = nil
        continuousUseStartedAt = Date()
        restSuggestionSuppressedUntil = nil
        restSuggestionAttempted = false
    }

    /// 「このまま続ける」は短い了承を 1 回だけ記録し、その後 120 分は抑制する。
    func chooseRestSuggestionContinue() {
        guard restSuggestion != nil else { return }
        restSuggestion = nil
        restSuggestionSuppressedUntil = Date().addingTimeInterval(120 * 60)
        restSuggestionAttempted = true

        guard let character = lastSpeakingCharacter() ?? activeCharacters.first,
              let characterID = characterID(for: character) else { return }
        let name = character.displayName.isEmpty ? character.name : character.displayName
        Task { [weak self] in
            guard let self else { return }
            await self.service.addRestAcknowledgement(
                characterID: characterID,
                characterName: name,
                session: self.session
            )
            await self.refreshAfterTurn()
        }
    }

    private func lastSpeakingCharacter() -> CharacterProfile? {
        for message in session.messages.reversed() {
            guard case let .cast(characterID, _) = message.author else { continue }
            if let character = characterIndex[characterID] { return character }
        }
        return nil
    }

    private func characterID(for character: CharacterProfile?) -> UUID? {
        guard let character else { return nil }
        return characterIndex.first(where: { $0.value.id == character.id })?.key
    }

    var activeCharacters: [CharacterProfile] {
        scene.activeCharacterIds.compactMap { characterIndex[$0] }
    }
}
