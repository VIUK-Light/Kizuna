/*
仕様:
- 役割: ライブラリーに保存されるキャラクターの主プロファイル。
- 主な型: `CharacterProfile`.
- 編集ポイント: フィールド追加時、編集ロジックや表示順を変える時。
*/

import Foundation

struct CharacterProfile: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var name: String
    var displayName: String
    var shortDescription: String
    var avatarImageData: Data?
    var imageKey: String?
    var isSystemProtected: Bool?

    var category: CharacterCategory
    var relationshipGenre: RelationshipGenre

    var personality: String
    var speakingStyle: String
    var background: String
    var relationshipToUser: String
    var scenario: String
    var firstMessage: String

    var tags: [String]
    var rules: [String]
    var safetyRules: [String]

    var visibility: CharacterVisibility
    var safetyRating: SafetyRating

    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        displayName: String,
        shortDescription: String = "",
        avatarImageData: Data? = nil,
        imageKey: String? = nil,
        isSystemProtected: Bool? = false,
        category: CharacterCategory,
        relationshipGenre: RelationshipGenre,
        personality: String = "",
        speakingStyle: String = "",
        background: String = "",
        relationshipToUser: String = "",
        scenario: String = "",
        firstMessage: String = "",
        tags: [String] = [],
        rules: [String] = [],
        safetyRules: [String] = [],
        visibility: CharacterVisibility = .private,
        safetyRating: SafetyRating = .general,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName.isEmpty ? name : displayName
        self.shortDescription = shortDescription
        self.avatarImageData = avatarImageData
        self.imageKey = imageKey
        self.isSystemProtected = isSystemProtected
        self.category = category
        self.relationshipGenre = relationshipGenre
        self.personality = personality
        self.speakingStyle = speakingStyle
        self.background = background
        self.relationshipToUser = relationshipToUser
        self.scenario = scenario
        self.firstMessage = firstMessage
        self.tags = tags
        self.rules = rules
        self.safetyRules = safetyRules
        self.visibility = visibility
        self.safetyRating = safetyRating
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// CategoryGroup / Category / RelationshipGenre の各 defaultSafetyRules をマージした結果。
    /// 作成時の初期値や、保存時の最終的な安全ルールセット計算に使う。
    var resolvedSafetyRules: [String] {
        var set: [String] = []
        var seen = Set<String>()
        func push(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            if seen.insert(t).inserted { set.append(t) }
        }
        category.defaultSafetyRules.forEach(push)
        relationshipGenre.safetyRules.forEach(push)
        safetyRules.forEach(push)
        return set
    }
}
