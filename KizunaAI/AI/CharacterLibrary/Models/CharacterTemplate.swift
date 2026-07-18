/*
仕様:
- 役割: 「テンプレ」= キャラ作成画面の初期値プリセット。
  ライブラリーに seed され、UI のテンプレ選択で defaults 一括反映する。
- 主な型: `CharacterTemplate`.
*/

import Foundation

struct CharacterTemplate: Codable, Identifiable, Equatable, Hashable {
    let id: String   // human-readable, e.g. "childhood_friend_v1"
    var displayName: String
    var category: CharacterCategory
    var relationshipGenre: RelationshipGenre
    var defaultPersonality: String
    var defaultSpeakingStyle: String
    var defaultRelationshipToUser: String
    var defaultScenario: String
    var defaultFirstMessage: String
    var defaultTags: [String]
    var defaultRules: [String]
    var defaultSafetyRules: [String]

    init(
        id: String,
        displayName: String,
        category: CharacterCategory,
        relationshipGenre: RelationshipGenre,
        defaultPersonality: String,
        defaultSpeakingStyle: String,
        defaultRelationshipToUser: String,
        defaultScenario: String,
        defaultFirstMessage: String,
        defaultTags: [String],
        defaultRules: [String] = [],
        defaultSafetyRules: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.category = category
        self.relationshipGenre = relationshipGenre
        self.defaultPersonality = defaultPersonality
        self.defaultSpeakingStyle = defaultSpeakingStyle
        self.defaultRelationshipToUser = defaultRelationshipToUser
        self.defaultScenario = defaultScenario
        self.defaultFirstMessage = defaultFirstMessage
        self.defaultTags = defaultTags
        self.defaultRules = defaultRules
        self.defaultSafetyRules = defaultSafetyRules
    }

    /// テンプレを CharacterProfile の draft に展開する。
    func makeDraft() -> CharacterProfile {
        CharacterProfile(
            name: displayName,
            displayName: displayName,
            shortDescription: "",
            category: category,
            relationshipGenre: relationshipGenre,
            personality: defaultPersonality,
            speakingStyle: defaultSpeakingStyle,
            background: "",
            relationshipToUser: defaultRelationshipToUser,
            scenario: defaultScenario,
            firstMessage: defaultFirstMessage,
            tags: defaultTags,
            rules: defaultRules,
            safetyRules: defaultSafetyRules
        )
    }
}
