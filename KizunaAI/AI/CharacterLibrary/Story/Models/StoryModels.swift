/*
仕様:
- 役割: 「複数キャラが同じ世界観で関係性を進める」絆モードのデータモデル一式。
  CharacterProfile (1キャラ) はそのまま利用しつつ、上位概念として StoryWorld / CastMember /
  StoryScene を導入する。CharacterProfile に直接依存させず、参照は characterId (UUID) で行う。
- 主な型:
    StoryWorld, CastMember, CastRole, IntroductionTiming,
    CharacterRelationship, RelationshipType, StoryScene,
    StorySession, StoryMessage, StoryMessageAuthor.
- 編集ポイント: 物語進行に関する状態 (active 制限、シーン遷移、関係性 enum 拡張)。
- 制約: activeCharacterIds は 1 シーンあたり最大 3 名に制限する (UI/Service 側で enforced)。
*/

import Foundation

// Fallback for App Group identifier. If your project defines this elsewhere, 
// this local definition is harmless as long as the names match; otherwise it
// enables compilation by defaulting to nil (no shared container).

private enum AppGroupIdentifiers {
    /// Set your App Group ID here (e.g., "group.com.example.app") or leave nil to disable.
    static let defaultGroup: String? = nil
}

enum StoryGenerationModel: String, Codable, CaseIterable, Identifiable, Hashable {
    case e4b
    case b31

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .e4b:
            return LocalAssistantModelManager.shared.selectedModelChoice?.shortDisplayName ?? "iori"
        case .b31: return "NAGI"
        }
    }

    var detailLabel: String {
        switch self {
        case .e4b:
            return LocalAssistantModelManager.shared.selectedModelChoice?.displayName ?? "iori"
        case .b31: return "NAGI"
        }
    }

    var promptHint: String {
        switch self {
        case .e4b:
            if LocalAssistantModelManager.shared.selectedModelChoice == .viukStoryV25Q4KM {
                return "VIUK Story v2.5の4bitモデル。\n端末内で日本語の物語と会話を生成します。"
            }
            return "軽く自然な会話を楽しめるスマホ向け標準モデル。"
        case .b31:
            return "Gemma4 31B APIで長めの文脈を読み、場面・関係性・描写を丁寧に保つモデル"
        }
    }

    var storageFolderName: String {
        switch self {
        case .e4b: return LocalAssistantModelProfile.storageFolderName
        case .b31: return "Gemma4-31B-API"
        }
    }

    var installedModelURL: URL? {
        switch self {
        case .e4b:
            return LocalAssistantModelManager.shared.installedModelURL
        case .b31:
            return nil
        }
    }

    private static func firstGGUF(inFolderNamed folderName: String) -> URL? {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let localURL = baseURL
            .appendingPathComponent(AppBrand.displayName, isDirectory: true)
            .appendingPathComponent("LocalModels", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)

        // On iOS, homeDirectoryForCurrentUser is unavailable. As an alternative,
        // also check an optional app group container (if configured) to allow
        // sharing models across builds/targets. Replace the identifier if your app
        // defines one; otherwise this will be nil and simply skipped.

        var candidateDirectories: [URL] = [localURL]

        if let group = AppGroupIdentifiers.defaultGroup,
           let sharedContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
            let sharedURL = sharedContainer
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent(AppBrand.displayName, isDirectory: true)
                .appendingPathComponent("LocalModels", isDirectory: true)
                .appendingPathComponent(folderName, isDirectory: true)
            candidateDirectories.append(sharedURL)
        }

        for directory in candidateDirectories {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            if let model = files.first(where: { $0.pathExtension.lowercased() == "gguf" }) {
                return model
            }
        }
        return nil
    }
}

// MARK: - StoryWorld

struct StoryWorld: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var title: String
    var shortDescription: String
    var genre: CharacterCategory
    var relationshipGenre: RelationshipGenre
    var tags: [String]
    var worldSetting: String
    /// ユーザーが物語上でどんな役を演じるか (例: 転校生、捜査の依頼人、ギルドの新入り)。
    var userRole: String
    var openingScene: String
    var storyGoal: String
    var mood: String
    /// この世界に登場しうる CharacterProfile.id の一覧。
    /// CastMember を介して役割と詳細を持つが、ここは「世界に存在する全キャラ」の一覧として保持。
    var characterIds: [UUID]
    /// メインキャラ (主人公的・カバー画像扱い)。
    var mainCharacterId: UUID?
    /// 標準搭載データ。ユーザーが削除・編集できない。
    var isSystemProtected: Bool?
    var safetyRules: [String]
    var visibility: CharacterVisibility
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        shortDescription: String = "",
        genre: CharacterCategory = .originalFreeform,
        relationshipGenre: RelationshipGenre = .none,
        tags: [String] = [],
        worldSetting: String = "",
        userRole: String = "",
        openingScene: String = "",
        storyGoal: String = "",
        mood: String = "",
        characterIds: [UUID] = [],
        mainCharacterId: UUID? = nil,
        isSystemProtected: Bool? = false,
        safetyRules: [String] = [],
        visibility: CharacterVisibility = .private,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.shortDescription = shortDescription
        self.genre = genre
        self.relationshipGenre = relationshipGenre
        self.tags = tags
        self.worldSetting = worldSetting
        self.userRole = userRole
        self.openingScene = openingScene
        self.storyGoal = storyGoal
        self.mood = mood
        self.characterIds = characterIds
        self.mainCharacterId = mainCharacterId
        self.isSystemProtected = isSystemProtected
        self.safetyRules = safetyRules
        self.visibility = visibility
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - CastMember

enum CastRole: String, Codable, CaseIterable, Hashable {
    case main
    case secondary
    case rival
    case friend
    case mentor
    case antagonist
    case background

    var displayName: String {
        switch self {
        case .main: return "主役"
        case .secondary: return "準主役"
        case .rival: return "ライバル"
        case .friend: return "味方"
        case .mentor: return "師・先輩"
        case .antagonist: return "敵対"
        case .background: return "脇役"
        }
    }

    var iconName: String {
        switch self {
        case .main: return "star.fill"
        case .secondary: return "star.leadinghalf.filled"
        case .rival: return "flame.fill"
        case .friend: return "person.2.fill"
        case .mentor: return "graduationcap.fill"
        case .antagonist: return "exclamationmark.triangle.fill"
        case .background: return "person.fill"
        }
    }
}

enum IntroductionTiming: String, Codable, CaseIterable, Hashable {
    case opening
    case early
    case middle
    case late
    case optional

    var displayName: String {
        switch self {
        case .opening: return "オープニング"
        case .early: return "序盤"
        case .middle: return "中盤"
        case .late: return "終盤"
        case .optional: return "条件付き"
        }
    }
}

struct CastMember: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var storyWorldId: UUID
    var characterId: UUID
    var roleInStory: CastRole
    /// 物語内での重要度 (0.0...1.0)。プロンプトでの詳細度の重み付けに使う。
    var importance: Double
    var introductionTiming: IntroductionTiming
    /// この物語の文脈での「ユーザーとの関係」(CharacterProfile.relationshipToUser とは別)。
    var relationshipToUser: String
    /// 他キャラとの関係性 (この CastMember 視点からの edge 集合)。
    var relationshipToOtherCharacters: [CharacterRelationship]
    /// 現在のシーンに居るか。Scene 切替時に Service が更新。
    var isActiveInCurrentScene: Bool

    init(
        id: UUID = UUID(),
        storyWorldId: UUID,
        characterId: UUID,
        roleInStory: CastRole = .secondary,
        importance: Double = 0.5,
        introductionTiming: IntroductionTiming = .early,
        relationshipToUser: String = "",
        relationshipToOtherCharacters: [CharacterRelationship] = [],
        isActiveInCurrentScene: Bool = false
    ) {
        self.id = id
        self.storyWorldId = storyWorldId
        self.characterId = characterId
        self.roleInStory = roleInStory
        self.importance = min(max(importance, 0), 1)
        self.introductionTiming = introductionTiming
        self.relationshipToUser = relationshipToUser
        self.relationshipToOtherCharacters = relationshipToOtherCharacters
        self.isActiveInCurrentScene = isActiveInCurrentScene
    }
}

// MARK: - CharacterRelationship

enum RelationshipType: String, Codable, CaseIterable, Hashable {
    case friend
    case rival
    case sibling
    case seniorJunior      = "senior_junior"
    case classmate
    case coworker
    case masterServant     = "master_servant"
    case protectorProtected = "protector_protected"
    case enemy
    case unknown

    var displayName: String {
        switch self {
        case .friend: return "友達"
        case .rival: return "ライバル"
        case .sibling: return "兄弟姉妹"
        case .seniorJunior: return "先輩後輩"
        case .classmate: return "同級"
        case .coworker: return "同僚"
        case .masterServant: return "主従"
        case .protectorProtected: return "守護"
        case .enemy: return "敵対"
        case .unknown: return "不明"
        }
    }
}

struct CharacterRelationship: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var fromCharacterId: UUID
    var toCharacterId: UUID
    var relationshipType: RelationshipType
    var description: String
    /// 緊張度 (0.0 平穏 ... 1.0 一触即発)。
    var tension: Double
    /// 信頼度 (0.0 不信 ... 1.0 完全信頼)。
    var trust: Double

    init(
        id: UUID = UUID(),
        fromCharacterId: UUID,
        toCharacterId: UUID,
        relationshipType: RelationshipType = .unknown,
        description: String = "",
        tension: Double = 0.0,
        trust: Double = 0.5
    ) {
        self.id = id
        self.fromCharacterId = fromCharacterId
        self.toCharacterId = toCharacterId
        self.relationshipType = relationshipType
        self.description = description
        self.tension = min(max(tension, 0), 1)
        self.trust = min(max(trust, 0), 1)
    }
}

// MARK: - StoryScene

struct StoryScene: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var storyWorldId: UUID
    var title: String
    var location: String
    var timeOfDay: String
    var mood: String
    /// このシーンで active な CharacterProfile.id (最大 3 件まで Service で enforce)。
    var activeCharacterIds: [UUID]
    var sceneGoal: String
    var conflict: String?
    /// 270M が更新する短い要約。次の Scene へのコンテキストにも使う。
    var summary: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        storyWorldId: UUID,
        title: String = "",
        location: String = "",
        timeOfDay: String = "",
        mood: String = "",
        activeCharacterIds: [UUID] = [],
        sceneGoal: String = "",
        conflict: String? = nil,
        summary: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.storyWorldId = storyWorldId
        self.title = title
        self.location = location
        self.timeOfDay = timeOfDay
        self.mood = mood
        self.activeCharacterIds = Array(activeCharacterIds.prefix(StoryConstants.maxActiveCharacters))
        self.sceneGoal = sceneGoal
        self.conflict = conflict
        self.summary = summary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum StoryConstants {
    /// 1 シーンで同時に登場できるキャラの上限。プロンプト肥大化と
    /// レイテンシ悪化を防ぐためにハードキャップする。
    static let maxActiveCharacters: Int = 3
}

// MARK: - StorySession (会話セッション本体)

enum StoryMessageAuthor: Codable, Equatable, Hashable {
    case user
    /// モデル未起動・API失敗など、物語本文ではない実行状態通知。
    case system
    /// 場面描写や関係ログとして表示するナレーション。
    case narrator
    /// キャラ発話。表示名と characterId を持つ。
    case cast(characterId: UUID, displayName: String)

    var isUser: Bool { if case .user = self { return true } else { return false } }
}

struct StoryMessage: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var author: StoryMessageAuthor
    var text: String
    var createdAt: Date

    init(id: UUID = UUID(), author: StoryMessageAuthor, text: String, createdAt: Date = Date()) {
        self.id = id
        self.author = author
        self.text = text
        self.createdAt = createdAt
    }
}

/// 1 つの StoryWorld に対して進行中の物語セッション。
/// Scene を順に進めていく状態を持ち、メッセージはすべてここに記録される。
struct StorySession: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var storyWorldId: UUID
    var currentSceneId: UUID?
    var messages: [StoryMessage]
    var progressLabel: String?
    var currentObjective: String?
    var relationshipStage: String?
    /// 直近ターンで物語上なにが変わったか。進行カードの「今回」に表示する。
    var lastTurnProgress: String?
    var lastSceneSummary: String?
    var unresolvedHooks: [String]?
    /// 直近ターンでユーザーが選んだモデル名。実行結果の透明性表示に使う。
    var lastSelectedModelName: String?
    /// 直近ターンで実際に使ったバックエンド、または未起動/失敗理由の短い状態。
    var lastUsedBackendName: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        storyWorldId: UUID,
        currentSceneId: UUID? = nil,
        messages: [StoryMessage] = [],
        progressLabel: String? = nil,
        currentObjective: String? = nil,
        relationshipStage: String? = nil,
        lastTurnProgress: String? = nil,
        lastSceneSummary: String? = nil,
        unresolvedHooks: [String]? = nil,
        lastSelectedModelName: String? = nil,
        lastUsedBackendName: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.storyWorldId = storyWorldId
        self.currentSceneId = currentSceneId
        self.messages = messages
        self.progressLabel = progressLabel
        self.currentObjective = currentObjective
        self.relationshipStage = relationshipStage
        self.lastTurnProgress = lastTurnProgress
        self.lastSceneSummary = lastSceneSummary
        self.unresolvedHooks = unresolvedHooks
        self.lastSelectedModelName = lastSelectedModelName
        self.lastUsedBackendName = lastUsedBackendName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
