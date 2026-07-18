/*
仕様:
- 役割: キャラごとに保存される長期メモリー (ユーザーに関する事実、好み、関係性など)。
  characterId をキーに集約され、PromptBuilder に注入される。
- 主な型: CharacterMemory, MemoryCategory, MemorySource.
*/

import Foundation

enum MemoryCategory: String, Codable, CaseIterable, Hashable {
    case preference     // 好み・嗜好
    case relationship   // 関係性 (家族構成等)
    case event          // 出来事
    case world          // 世界観事実
    case userFact       // ユーザーの基本情報 (年齢、職業、所在地概略 等)
    case summary        // 会話要約
    case safety         // 安全関連メモ (例: ユーザーが触れてほしくない話題)
    case other

    var displayName: String {
        switch self {
        case .preference: return "好み"
        case .relationship: return "関係"
        case .event: return "出来事"
        case .world: return "世界"
        case .userFact: return "プロフィール"
        case .summary: return "要約"
        case .safety: return "配慮"
        case .other: return "その他"
        }
    }
}

enum MemorySource: String, Codable, CaseIterable, Hashable {
    case userInput   // ユーザー発話から抽出
    case aiOutput    // AI 応答から抽出
    case summary     // 要約パスから
    case manual      // 手動 (ユーザー追加)
    case system      // システム生成
}

struct CharacterMemory: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var characterId: UUID
    var text: String
    var category: MemoryCategory
    var importance: Double   // 0.0...1.0
    var source: MemorySource
    var createdAt: Date
    var lastUsedAt: Date?

    init(
        id: UUID = UUID(),
        characterId: UUID,
        text: String,
        category: MemoryCategory = .other,
        importance: Double = 0.5,
        source: MemorySource = .system,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.characterId = characterId
        self.text = text
        self.category = category
        self.importance = min(max(importance, 0.0), 1.0)
        self.source = source
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}
