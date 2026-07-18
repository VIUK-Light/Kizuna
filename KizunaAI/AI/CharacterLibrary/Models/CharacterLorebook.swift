/*
仕様:
- 役割: キャラの世界観・関係者・場所・出来事などを保持するロアブック。
  CharacterProfile とは 1:1 で紐付ける (characterId)。
- 主な型: `CharacterLorebook`.
*/

import Foundation

struct CharacterLorebook: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var characterId: UUID
    var worldSetting: String
    var importantPeople: [String]
    var importantPlaces: [String]
    var importantEvents: [String]
    var worldRules: [String]
    var forbiddenBreaks: [String]

    init(
        id: UUID = UUID(),
        characterId: UUID,
        worldSetting: String = "",
        importantPeople: [String] = [],
        importantPlaces: [String] = [],
        importantEvents: [String] = [],
        worldRules: [String] = [],
        forbiddenBreaks: [String] = []
    ) {
        self.id = id
        self.characterId = characterId
        self.worldSetting = worldSetting
        self.importantPeople = importantPeople
        self.importantPlaces = importantPlaces
        self.importantEvents = importantEvents
        self.worldRules = worldRules
        self.forbiddenBreaks = forbiddenBreaks
    }

    var isEmpty: Bool {
        worldSetting.isEmpty &&
        importantPeople.isEmpty &&
        importantPlaces.isEmpty &&
        importantEvents.isEmpty &&
        worldRules.isEmpty &&
        forbiddenBreaks.isEmpty
    }
}
