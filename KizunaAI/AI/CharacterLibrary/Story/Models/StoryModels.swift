/*
仕様:
- 役割: 「複数キャラが同じ世界観で関係性を進める」絆モードのデータモデル一式。
  CharacterProfile (1キャラ) はそのまま利用しつつ、上位概念として StoryWorld / CastMember /
  StoryScene を導入する。CharacterProfile に直接依存させず、参照は characterId (UUID) で行う。
- 主な型:
    StoryWorld, CastMember, CastRole, IntroductionTiming,
    CharacterRelationship, RelationshipType, StoryScene,
    StorySession, StoryMessage, StoryMessageAuthor, StoryState, StoryLorebookEntry, StoryMemory.
- 編集ポイント: 物語進行に関する状態 (active 制限、シーン遷移、関係性 enum 拡張)。
- 制約: 群像劇の activeCharacterIds は最大 3 名、単体物語は主役1名に制限する (UI/Service 側で enforced)。
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
        case .e4b: return "iori"
        case .b31: return "NAGI"
        }
    }

    var detailLabel: String {
        switch self {
        case .e4b: return "iori"
        case .b31: return "NAGI"
        }
    }

    var promptHint: String {
        switch self {
        case .e4b:
            return "VIUK AIによる独自のファインチューニングモデル。\n軽く自然な会話を楽しめる標準モデル。"
        case .b31:
            return "Gemma4 31B APIで長めの文脈を読み、場面・関係性・描写を丁寧に保つモデル"
        }
    }

    var localizedPromptHint: String {
        switch self {
        case .e4b:
            return KizunaCopy.text(
                japanese: promptHint,
                english: "A VIUK fine-tuned model for light, natural conversation."
            )
        case .b31:
            return KizunaCopy.text(
                japanese: promptHint,
                english: "Gemma4 31B API. Preserves longer context, scene atmosphere, and relationship nuance."
            )
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

/// 実行失敗の再試行先を表示文言から切り離すためのバックエンド識別子。
/// 文面は日本語/英語で切り替わるため、UIのフォールバック判定に使ってはいけない。
enum StoryGenerationBackend: String, Codable, Equatable, Hashable {
    case local
    case gemmaAPI
    case persistence
    case safety
    case unknown
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
    /// 物語の基本形式。nil は旧データ互換のため単体物語として扱う。
    var castMode: StoryCastMode?
    /// 標準搭載データ。ユーザーが削除・編集できない。
    var isSystemProtected: Bool?
    var safetyRules: [String]
    var visibility: CharacterVisibility
    var createdAt: Date
    var updatedAt: Date
    /// 表示用の言語別コンテンツ。nil は旧保存データまたは未翻訳のユーザー作成物語。
    var localizations: [String: StoryWorldLocalization]?

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
        castMode: StoryCastMode? = nil,
        isSystemProtected: Bool? = false,
        safetyRules: [String] = [],
        visibility: CharacterVisibility = .private,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        localizations: [String: StoryWorldLocalization]? = nil
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
        self.castMode = castMode
        self.isSystemProtected = isSystemProtected
        self.safetyRules = safetyRules
        self.visibility = visibility
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.localizations = localizations
    }

    /// Zeta型の「ユーザー + 主役1人」を既定にする。
    var resolvedCastMode: StoryCastMode {
        castMode ?? .solo
    }

    var isSoloStory: Bool {
        resolvedCastMode == .solo
    }

    func localized(for language: KizunaLanguage) -> StoryWorld {
        guard language == .english else { return self }
        // ユーザー作成Storyは、標準Storyと同じタイトルでも英語カタログへ
        // フォールバックしない。明示的に保存されたlocalizationだけを使い、
        // 標準カタログはsystem-protectedデータに限定する。
        let localization: StoryWorldLocalization?
        if let stored = localizations?[language.rawValue] {
            localization = stored
        } else {
            guard isSystemProtected == true else { return self }
            localization = StoryEnglishCatalog.localization(for: self)
        }
        guard let localization else {
            return self
        }

        var copy = self
        if let value = localization.title?.nonEmpty { copy.title = value }
        if let value = localization.shortDescription?.nonEmpty { copy.shortDescription = value }
        if let value = localization.worldSetting?.nonEmpty { copy.worldSetting = value }
        if let value = localization.userRole?.nonEmpty { copy.userRole = value }
        if let value = localization.openingScene?.nonEmpty { copy.openingScene = value }
        if let value = localization.storyGoal?.nonEmpty { copy.storyGoal = value }
        if let value = localization.mood?.nonEmpty { copy.mood = value }
        if let value = localization.tags, !value.isEmpty {
            copy.tags = Self.normalizedUniqueValues(value)
        }
        if let value = localization.safetyRules, !value.isEmpty {
            // An explicit localization wins, including for user-created
            // worlds.  This is presentation-only and never writes back to the
            // Japanese source values.
            copy.safetyRules = Self.normalizedUniqueValues(value)
        } else if isSystemProtected == true {
            // Bundled worlds predate the localization payload and keep their
            // safety/output rules in Japanese.  Translate only the stable
            // bundled catalog; unknown text remains visible rather than being
            // discarded or replaced with a misleading placeholder.
            copy.safetyRules = Self.normalizedUniqueValues(
                safetyRules.map(StoryEnglishCatalog.localizedSafetyRule)
            )
        }
        return copy
    }

    var localizedForCurrentLanguage: StoryWorld {
        localized(for: KizunaCopy.language)
    }

    /// Normalize user- and model-authored metadata at the persistence boundary.
    ///
    /// Tags and safety rules are rendered with their value as a SwiftUI key in
    /// Story Detail.  Keeping a trimmed, non-empty, first-seen list here means
    /// generated JSON, hand-edited drafts, and legacy files all follow the same
    /// invariant before they reach the repository or a view.
    var normalizedForPersistence: StoryWorld {
        var copy = self
        copy.tags = Self.normalizedUniqueValues(tags)
        copy.safetyRules = Self.normalizedUniqueValues(safetyRules)
        return copy
    }

    private static func normalizedUniqueValues(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { rawValue in
            let value = rawValue
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
                .joined(separator: " ")
            guard !value.isEmpty else { return nil }
            let key = value.localizedLowercase
            guard seen.insert(key).inserted else { return nil }
            return value
        }
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum StoryCastMode: String, Codable, CaseIterable, Identifiable, Hashable {
    case solo
    case ensemble

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .solo: return "単体物語"
        case .ensemble: return "群像劇"
        }
    }

    var localizedDisplayName: String {
        KizunaCopy.text(japanese: displayName, english: self == .solo ? "Solo story" : "Ensemble story")
    }

    var detail: String {
        switch self {
        case .solo: return "ユーザーと主役NPC1人を中心に進める"
        case .ensemble: return "複数のキャラクターが場面に参加する"
        }
    }

    var localizedDetail: String {
        KizunaCopy.text(
            japanese: detail,
            english: self == .solo
                ? "You and one main NPC share the focus."
                : "Several characters can take part in each scene."
        )
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

    var localizedDisplayName: String {
        let english: String
        switch self {
        case .main: english = "Main"
        case .secondary: english = "Supporting"
        case .rival: english = "Rival"
        case .friend: english = "Friend"
        case .mentor: english = "Mentor"
        case .antagonist: english = "Antagonist"
        case .background: english = "Background"
        }
        return KizunaCopy.text(japanese: displayName, english: english)
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

    var localizedDisplayName: String {
        let english: String
        switch self {
        case .opening: english = "Opening"
        case .early: english = "Early"
        case .middle: english = "Middle"
        case .late: english = "Late"
        case .optional: english = "Conditional"
        }
        return KizunaCopy.text(japanese: displayName, english: english)
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
    /// 旧データではnil。新しい作成フローでは文字列推測を避けるため明示できる。
    var isUserControlled: Bool?
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
        isUserControlled: Bool? = nil,
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
        self.isUserControlled = isUserControlled
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

    /// UI専用の表示名。保存するraw valueと日本語のdisplayNameは変更しない。
    var localizedDisplayName: String {
        let english: String
        switch self {
        case .friend: english = "Friend"
        case .rival: english = "Rival"
        case .sibling: english = "Siblings"
        case .seniorJunior: english = "Senior / junior"
        case .classmate: english = "Classmates"
        case .coworker: english = "Coworkers"
        case .masterServant: english = "Master / servant"
        case .protectorProtected: english = "Protector / protected"
        case .enemy: english = "Enemies"
        case .unknown: english = "Unknown"
        }
        return KizunaCopy.text(japanese: displayName, english: english)
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
    /// シーン背景のアセットキー。旧保存データでは nil のまま読み込める。
    var imageKey: String?
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
        imageKey: String? = nil,
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
        self.imageKey = imageKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - StoryState (AIが更新する構造化コンテキスト)

/// 会話本文とは別に保持する、現在の物語状態。
/// UIのInfo Box、次回プロンプト、将来のクラウド同期で同じ値を使う。
struct StoryState: Codable, Equatable, Hashable {
    var location: String
    var timeOfDay: String
    var mood: String
    var weather: String
    var relationshipStage: String
    var characterStates: [StoryCharacterState]
    var inventory: [StoryInventoryItem]
    var activeGoals: [String]
    var updatedAt: Date

    init(
        location: String = "",
        timeOfDay: String = "",
        mood: String = "",
        weather: String = "",
        relationshipStage: String = "",
        characterStates: [StoryCharacterState] = [],
        inventory: [StoryInventoryItem] = [],
        activeGoals: [String] = [],
        updatedAt: Date = Date()
    ) {
        self.location = location
        self.timeOfDay = timeOfDay
        self.mood = mood
        self.weather = weather
        self.relationshipStage = relationshipStage
        self.characterStates = characterStates
        self.inventory = inventory
        self.activeGoals = activeGoals
        self.updatedAt = updatedAt
    }
}

/// シーンに登場しているキャラクターの可変状態。
struct StoryCharacterState: Codable, Equatable, Hashable, Identifiable {
    var id: UUID
    var characterId: UUID?
    var characterName: String
    var mood: String
    var goal: String
    var relationship: String
    var innerThought: String

    init(
        id: UUID = UUID(),
        characterId: UUID? = nil,
        characterName: String,
        mood: String = "",
        goal: String = "",
        relationship: String = "",
        innerThought: String = ""
    ) {
        self.id = id
        self.characterId = characterId
        self.characterName = characterName
        self.mood = mood
        self.goal = goal
        self.relationship = relationship
        self.innerThought = innerThought
    }
}

/// 物語中の所持品・重要オブジェクト。
struct StoryInventoryItem: Codable, Equatable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var detail: String
    var owner: String

    init(id: UUID = UUID(), name: String, detail: String = "", owner: String = "") {
        self.id = id
        self.name = name
        self.detail = detail
        self.owner = owner
    }
}

// MARK: - StoryStatePatch (AIレスポンス専用の差分)

/// AIには全文状態ではなく、今回変化したフィールドだけをJSONで返させる。
struct StoryStatePatch: Codable, Equatable, Hashable {
    var location: String?
    var timeOfDay: String?
    var mood: String?
    var weather: String?
    var relationshipStage: String?
    var characterUpdates: [StoryCharacterStatePatch]?
    var inventoryChanges: [StoryInventoryChange]?
    var activeGoals: [String]?

    /// 既存値を保ちつつ、空文字の更新は無視する。
    func applying(
        to state: StoryState,
        characterIndex: [UUID: CharacterProfile],
        validCharacterIDs: Set<UUID>? = nil
    ) -> StoryState {
        var next = state
        if let location, !location.isEmpty { next.location = location }
        if let timeOfDay, !timeOfDay.isEmpty { next.timeOfDay = timeOfDay }
        if let mood, !mood.isEmpty { next.mood = mood }
        if let weather, !weather.isEmpty { next.weather = weather }
        if let relationshipStage, !relationshipStage.isEmpty { next.relationshipStage = relationshipStage }
        if let activeGoals { next.activeGoals = Array(activeGoals.filter { !$0.isEmpty }.prefix(6)) }

        // 新形式は characterId を主キーにする。旧形式の名前だけのJSONは
        // 後方互換で受け付けるが、同名キャラが複数いる場合は曖昧なまま
        // 適用しない。辞書の走査順をIDの代わりに使ってはいけない。
        for update in characterUpdates ?? [] {
            let normalizedName = update.characterName.trimmingCharacters(in: .whitespacesAndNewlines)
            let requestedID = update.characterId
            let matchedID: UUID
            let resolvedName: String
            if let requestedID {
                // IDが存在しない／今回のキャストに含まれない更新は、別の
                // キャラへ名前フォールバックしない。生成結果の古いIDや
                // 別WorldのIDを現在状態へ混入させないためである。
                guard characterIndex[requestedID] != nil,
                      validCharacterIDs?.contains(requestedID) ?? true else { continue }
                matchedID = requestedID
                resolvedName = characterIndex[requestedID]?.visibleName.nonEmpty ?? normalizedName
            } else {
                // 旧データ／旧モデルの名前だけの更新は、一意に解決できる
                // 場合だけUUIDへ昇格する。同名なら今回の更新を保留する。
                guard !normalizedName.isEmpty else { continue }
                let matchingIDs = characterIndex.compactMap { id, profile -> UUID? in
                    guard validCharacterIDs?.contains(id) ?? true else { return nil }
                    let displayName = profile.visibleName
                    return displayName == normalizedName || profile.name == normalizedName ? id : nil
                }
                guard matchingIDs.count == 1, let onlyID = matchingIDs.first else { continue }
                matchedID = onlyID
                resolvedName = characterIndex[onlyID]?.visibleName ?? normalizedName
            }
            let matchingByID = next.characterStates.indices.filter { index in
                let current = next.characterStates[index]
                return current.characterId == matchedID
            }
            // 旧保存データでは characterId が nil の状態が残っていることがある。
            // 新しいID付き更新と表示名が一致し、かつ候補が一件だけならその状態を
            // UUID付きへ移行する。同名・重複状態は曖昧なまま更新しない。
            if matchingByID.count > 1 {
                continue
            }
            let index: Int?
            if let onlyIDIndex = matchingByID.first {
                index = onlyIDIndex
            } else {
                let legacyNameIndices = next.characterStates.indices.filter { index in
                    let current = next.characterStates[index]
                    guard current.characterId == nil else { return false }
                    return current.characterName == resolvedName
                        || characterIndex[matchedID]?.name == current.characterName
                }
                if legacyNameIndices.count > 1 {
                    continue
                }
                index = legacyNameIndices.count == 1 ? legacyNameIndices.first : nil
            }
            if let index {
                // 今回JSONに含まれなかった項目は、前回値をそのまま保持する。
                var value = next.characterStates[index]
                value.characterId = matchedID
                value.characterName = resolvedName
                value.mood = update.mood ?? value.mood
                value.goal = update.goal ?? value.goal
                value.relationship = update.relationship ?? value.relationship
                value.innerThought = update.innerThought ?? value.innerThought
                next.characterStates[index] = value
            } else {
                next.characterStates.append(
                    StoryCharacterState(
                        characterId: matchedID,
                        characterName: resolvedName,
                        mood: update.mood ?? "",
                        goal: update.goal ?? "",
                        relationship: update.relationship ?? "",
                        innerThought: update.innerThought ?? ""
                    )
                )
            }
        }

        // 所持品は add/update/remove を小さな差分として適用する。
        for change in inventoryChanges ?? [] {
            let name = change.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            if change.action == .remove {
                next.inventory.removeAll { $0.name == name }
            } else {
                let value = StoryInventoryItem(name: name, detail: change.detail ?? "", owner: change.owner ?? "")
                if let index = next.inventory.firstIndex(where: { $0.name == name }) {
                    next.inventory[index] = value
                } else {
                    next.inventory.append(value)
                }
            }
        }
        next.updatedAt = Date()
        return next
    }
}

struct StoryCharacterStatePatch: Codable, Equatable, Hashable {
    /// 新形式の主キー。旧モデルは名前だけを返すため optional のまま
    /// 後方互換にし、`StoryStatePatch.applying` で一意名だけを昇格する。
    var characterId: UUID?
    var characterName: String
    var mood: String?
    var goal: String?
    var relationship: String?
    var innerThought: String?

    init(
        characterId: UUID? = nil,
        characterName: String = "",
        mood: String? = nil,
        goal: String? = nil,
        relationship: String? = nil,
        innerThought: String? = nil
    ) {
        self.characterId = characterId
        self.characterName = characterName
        self.mood = mood
        self.goal = goal
        self.relationship = relationship
        self.innerThought = innerThought
    }

    private enum CodingKeys: String, CodingKey {
        case characterId
        case characterID
        case characterName
        case mood
        case goal
        case relationship
        case innerThought
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A malformed ID should not discard the rest of a progress update.
        // Models sometimes emit a placeholder or a copied display name here;
        // treat only that field as unavailable and keep the other state fields.
        characterId = Self.decodeLenientUUID(container, forKey: .characterId)
            ?? Self.decodeLenientUUID(container, forKey: .characterID)
        characterName = try container.decodeIfPresent(String.self, forKey: .characterName) ?? ""
        mood = try container.decodeIfPresent(String.self, forKey: .mood)
        goal = try container.decodeIfPresent(String.self, forKey: .goal)
        relationship = try container.decodeIfPresent(String.self, forKey: .relationship)
        innerThought = try container.decodeIfPresent(String.self, forKey: .innerThought)
    }

    private static func decodeLenientUUID(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> UUID? {
        // Decode as a string first so UUID(uuidString:) can fail locally. The
        // keyed container may still contain other valid fields in this patch.
        let raw: String?
        do {
            raw = try container.decodeIfPresent(String.self, forKey: key)
        } catch {
            return nil
        }
        guard let raw else { return nil }
        return UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(characterId, forKey: .characterId)
        try container.encode(characterName, forKey: .characterName)
        try container.encodeIfPresent(mood, forKey: .mood)
        try container.encodeIfPresent(goal, forKey: .goal)
        try container.encodeIfPresent(relationship, forKey: .relationship)
        try container.encodeIfPresent(innerThought, forKey: .innerThought)
    }
}

enum StoryInventoryChangeAction: String, Codable, Hashable {
    case add
    case update
    case remove
}

struct StoryInventoryChange: Codable, Equatable, Hashable {
    var action: StoryInventoryChangeAction
    var name: String
    var detail: String?
    var owner: String?
}

// MARK: - StoryLorebookEntry (キーワード連動の設定)

/// ZetaのLorebookに相当する、世界・キャスト共通の設定カード。
/// キーワードが会話やシーンに現れた時だけプロンプトへ投入する。
struct StoryLorebookEntry: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var storyWorldId: UUID
    var characterId: UUID?
    var title: String
    var keywords: [String]
    var content: String
    var priority: Int
    var isEnabled: Bool
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        storyWorldId: UUID,
        characterId: UUID? = nil,
        title: String,
        keywords: [String] = [],
        content: String,
        priority: Int = 50,
        isEnabled: Bool = true,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.storyWorldId = storyWorldId
        self.characterId = characterId
        self.title = title
        self.keywords = keywords
        self.content = content
        self.priority = priority
        self.isEnabled = isEnabled
        self.updatedAt = updatedAt
    }
}

// MARK: - StoryMemory (この物語だけの思い出)

/// 全体メモリー(CharacterMemory)とは分離して、StoryWorld内の出来事だけを保持する。
/// 別の物語へ持ち越さないため、storyWorldIdを必須にする。
struct StoryMemory: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var storyWorldId: UUID
    var characterId: UUID?
    var text: String
    var category: MemoryCategory
    var importance: Double
    var source: MemorySource
    var createdAt: Date
    var lastUsedAt: Date?

    init(
        id: UUID = UUID(),
        storyWorldId: UUID,
        characterId: UUID? = nil,
        text: String,
        category: MemoryCategory = .event,
        importance: Double = 0.5,
        source: MemorySource = .system,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.storyWorldId = storyWorldId
        self.characterId = characterId
        self.text = text
        self.category = category
        self.importance = min(max(importance, 0.0), 1.0)
        self.source = source
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

enum StoryConstants {
    /// 1 シーンで同時に登場できるキャラの上限。プロンプト肥大化と
    /// レイテンシ悪化を防ぐためにハードキャップする。
    static let maxActiveCharacters: Int = 3

    /// 単体物語ではAI発話候補を1人に固定する。
    static let soloActiveCharacters: Int = 1
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
    /// この発話を生成したターンのID。旧データではnilのまま読み込む。
    /// 同一生成内の重複修復にだけ使い、別ターンの正当な反復は保持する。
    var generationID: UUID?
    /// このメッセージが属する永続ターン。旧データではnilのまま読み込む。
    /// generationIDは実行ごとに変わるため、再試行・復旧の冪等キーには
    /// turnIDを使う。
    var turnID: UUID?
    /// system通知をどのバックエンドで再試行できるか。旧ストアには
    /// このキーがないため optional のまま後方互換にする。
    var retryBackend: StoryGenerationBackend?

    init(
        id: UUID = UUID(),
        author: StoryMessageAuthor,
        text: String,
        createdAt: Date = Date(),
        generationID: UUID? = nil,
        turnID: UUID? = nil,
        retryBackend: StoryGenerationBackend? = nil
    ) {
        self.id = id
        self.author = author
        self.text = text
        self.createdAt = createdAt
        self.generationID = generationID
        self.turnID = turnID
        self.retryBackend = retryBackend
    }
}

/// Storyの1ユーザー入力を、生成・保存・再試行まで同じ単位で追跡する状態。
/// Codableのraw valueは将来のリポジトリ差し替えでも安定させる。
enum StoryTurnStatus: String, Codable, Hashable {
    case pending
    case committed
    case failed
    case cancelled
    case interrupted
}

struct StoryTurnCheckpoint: Codable, Equatable, Hashable {
    var turnID: UUID
    var userMessageID: UUID
    var status: StoryTurnStatus
    var attempt: Int
    /// 同一プロセス内の別ViewModelが、まだ実行中のターンを
    /// 「前回起動の残骸」として終了しないための所有者ID。
    /// 旧保存データではnilのまま読み込む。
    var ownerID: UUID?
    var baseRevision: UInt64
    var assistantMessageIDs: [UUID]
    var startedAt: Date
    var updatedAt: Date
    var failureCode: String?

    init(
        turnID: UUID,
        userMessageID: UUID,
        status: StoryTurnStatus = .pending,
        attempt: Int = 1,
        ownerID: UUID? = nil,
        baseRevision: UInt64 = 0,
        assistantMessageIDs: [UUID] = [],
        startedAt: Date = Date(),
        updatedAt: Date = Date(),
        failureCode: String? = nil
    ) {
        self.turnID = turnID
        self.userMessageID = userMessageID
        self.status = status
        self.attempt = max(1, attempt)
        self.ownerID = ownerID
        self.baseRevision = baseRevision
        self.assistantMessageIDs = assistantMessageIDs
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.failureCode = failureCode
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
    /// 本文とは独立して保存する、AI更新可能な現在状態。
    var storyState: StoryState?
    /// 直近ターンでユーザーが選んだモデル名。実行結果の透明性表示に使う。
    var lastSelectedModelName: String?
    /// 直近ターンで実際に使ったバックエンド、または未起動/失敗理由の短い状態。
    var lastUsedBackendName: String?
    /// 保存成功ごとに単調増加する世代。旧データはnilを0として扱う。
    var persistenceRevision: UInt64?
    /// 生成中・直近ターンの復旧境界。本文とは別に保存して、再起動後に
    /// pendingを放置したり、同じユーザー入力を二重追加したりしない。
    var latestTurnCheckpoint: StoryTurnCheckpoint?
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
        storyState: StoryState? = nil,
        lastSelectedModelName: String? = nil,
        lastUsedBackendName: String? = nil,
        persistenceRevision: UInt64? = nil,
        latestTurnCheckpoint: StoryTurnCheckpoint? = nil,
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
        self.storyState = storyState
        self.lastSelectedModelName = lastSelectedModelName
        self.lastUsedBackendName = lastUsedBackendName
        self.persistenceRevision = persistenceRevision
        self.latestTurnCheckpoint = latestTurnCheckpoint
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension StorySession {
    var effectivePersistenceRevision: UInt64 {
        persistenceRevision ?? 0
    }
}
