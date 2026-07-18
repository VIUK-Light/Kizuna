/*
仕様:
- 役割: Story モードの 4 画面用 ViewModel (Library/Create/Detail/Session)。
- 主な型: StoryWorldLibraryViewModel, StoryWorldCreateViewModel, StoryWorldDetailViewModel,
         StorySessionViewModel.
*/

import Foundation
import Combine

// MARK: - Library

@MainActor
final class StoryWorldLibraryViewModel: ObservableObject {
    @Published private(set) var worlds: [StoryWorld] = []
    @Published private(set) var charactersById: [UUID: CharacterProfile] = [:]
    @Published var searchText: String = ""
    @Published var groupFilter: CategoryGroup? = nil

    private let worldRepo: StoryWorldRepository = LocalJSONStoryWorldRepository()
    private let characterRepo: CharacterRepository = LocalJSONCharacterRepository()

    func bootstrap() async {
        await CharacterLibrarySeed.seedIfNeeded(characterRepo: characterRepo, worldRepo: worldRepo)
        await reload()
    }

    func reload() async {
        do {
            self.worlds = try await worldRepo.fetchWorlds()
            let characters = try await characterRepo.fetchCharacters()
            self.charactersById = characters.reduce(into: [:]) { result, character in
                guard result[character.id] == nil else { return }
                result[character.id] = character
            }
        } catch {
            NSLog("[StoryLibraryVM] reload failed: %@", String(describing: error))
        }
    }

    func delete(id: UUID) async {
        do {
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
                w.title.lowercased().contains(needle)
                    || w.shortDescription.lowercased().contains(needle)
                    || w.tags.contains(where: { $0.lowercased().contains(needle) })
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
    @Published private(set) var availableCharacters: [CharacterProfile] = []
    @Published var saveError: String? = nil
    @Published var generationBrief: String = ""
    @Published private(set) var isGeneratingTemplate: Bool = false
    @Published private(set) var generationStatus: String? = nil

    private let worldRepo: StoryWorldRepository = LocalJSONStoryWorldRepository()
    private let castRepo: CastRepository = LocalJSONCastRepository()
    private let characterRepo: CharacterRepository = LocalJSONCharacterRepository()
    private let sceneRepo: StorySceneRepository = LocalJSONStorySceneRepository()
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

        let systemPrompt = Self.storyTemplateSystemPrompt
        let reply: String
        do {
            reply = try await StoryGemma31BAPIService.shared.generate(
                systemPrompt: systemPrompt,
                userPrompt: brief,
                temperature: 0.45,
                maxOutputTokens: 8192,
                responseMIMEType: "application/json"
            )
        } catch {
            generationStatus = "JSON生成を再試行中..."
            do {
                reply = try await StoryGemma31BAPIService.shared.generate(
                    systemPrompt: systemPrompt,
                    userPrompt: brief,
                    temperature: 0.35,
                    maxOutputTokens: 8192
                )
            } catch {
                saveError = error.localizedDescription
                generationStatus = nil
                return
            }
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
                opening.activeCharacterIds = Array(castDrafts.prefix(StoryConstants.maxActiveCharacters).map(\.characterId))
            }
            opening.activeCharacterIds = Array(opening.activeCharacterIds.prefix(StoryConstants.maxActiveCharacters))
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

        for generated in template.characters.prefix(4) {
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

    2〜4人のキャラを作る。初期シーンで同席している主要キャラは activeInInitialScene=true にしてよい。
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
    @Published private(set) var characterIndex: [UUID: CharacterProfile] = [:]

    private let worldRepo: StoryWorldRepository = LocalJSONStoryWorldRepository()
    private let castRepo: CastRepository = LocalJSONCastRepository()
    private let sceneRepo: StorySceneRepository = LocalJSONStorySceneRepository()
    private let sessionRepo: StorySessionRepository = LocalJSONStorySessionRepository()
    private let characterRepo: CharacterRepository = LocalJSONCharacterRepository()

    init(world: StoryWorld) {
        self.world = world
    }

    func reload() async {
        async let castFetch = (try? await castRepo.fetchCast(storyWorldId: world.id)) ?? []
        async let scenesFetch = (try? await sceneRepo.fetchScenes(storyWorldId: world.id)) ?? []
        async let sessionsFetch = (try? await sessionRepo.fetchSessions(storyWorldId: world.id)) ?? []
        async let charsFetch = (try? await characterRepo.fetchCharacters()) ?? []
        let (cast, scenes, sessions, chars) = await (castFetch, scenesFetch, sessionsFetch, charsFetch)
        if cast.isEmpty, !world.characterIds.isEmpty {
            let repaired = defaultCastMembers(for: world, existingScenes: scenes)
            for member in repaired { try? await castRepo.saveCast(member) }
            self.cast = repaired
        } else {
            self.cast = cast
        }
        self.scenes = scenes
        self.sessions = sessions
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
        if let last = sessions.first,
           let sceneId = last.currentSceneId,
           let scene = scenes.first(where: { $0.id == sceneId }) {
            return (last, scene)
        }
        // 新規セッション + 先頭シーン
        guard let firstScene = scenes.first else { return nil }
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
        do {
            try await worldRepo.deleteWorld(id: world.id)
            try await castRepo.deleteAllCast(storyWorldId: world.id)
            try await sceneRepo.deleteAllScenes(storyWorldId: world.id)
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
}

// MARK: - Session (Scene chat)

@MainActor
final class StorySessionViewModel: ObservableObject {
    @Published private(set) var session: StorySession
    @Published private(set) var scene: StoryScene
    @Published private(set) var world: StoryWorld
    @Published private(set) var cast: [CastMember] = []
    @Published private(set) var characterIndex: [UUID: CharacterProfile] = [:]
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

    init(world: StoryWorld, session: StorySession, scene: StoryScene) {
        self.world = world
        self.session = session
        self.scene = scene
        self.generationModelKey = "storySessionGenerationModel.\(world.id.uuidString)"
        let stored = UserDefaults.standard.string(forKey: generationModelKey)
        let savedModel = stored.flatMap(StoryGenerationModel.init(rawValue:)) ?? .e4b
        self.generationModel = savedModel
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
    }

    func send(_ userText: String) {
        service.send(userText, session: session, world: world, scene: scene, generationModel: generationModel)
        // Service 内で session/scene が永続化されるので、こちらは UI 更新のため
        // 軽くポーリングで再取得する (将来 Combine pipeline 化)。
        Task { [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                await self?.refreshAfterTurn()
                if self?.service.phase == .idle {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    await self?.refreshAfterTurn()
                    break
                }
            }
            await self?.refreshAfterTurn()
        }
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

    var activeCharacters: [CharacterProfile] {
        scene.activeCharacterIds.compactMap { characterIndex[$0] }
    }
}
