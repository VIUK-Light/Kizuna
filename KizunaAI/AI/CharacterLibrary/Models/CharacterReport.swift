/*
仕様:
- 役割: ユーザーがキャラを通報する時に保存するレコード。
- 主な型: `CharacterReport`, `ReportReason`.
*/

import Foundation

enum ReportReason: String, Codable, CaseIterable, Identifiable, Hashable {
    case inappropriate
    case sexualMinor   = "sexual_minor"
    case harassment
    case violence
    case crime
    case spam
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .inappropriate: return "不適切な内容"
        case .sexualMinor: return "未成年への性的内容"
        case .harassment: return "嫌がらせ・差別"
        case .violence: return "過度な暴力"
        case .crime: return "犯罪を助長"
        case .spam: return "スパム / 無関係"
        case .other: return "その他"
        }
    }
}

struct CharacterReport: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var characterId: UUID
    var reason: ReportReason
    var detail: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        characterId: UUID,
        reason: ReportReason,
        detail: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.characterId = characterId
        self.reason = reason
        self.detail = detail
        self.createdAt = createdAt
    }
}
