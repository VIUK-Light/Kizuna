/*
仕様:
- 役割: Persona / Story の専用画面へ遷移するルートと継続カードの共通モデル。
- 方針: チャット本文・生成処理・保存モデルは統合しない。遷移先だけを型安全に
  共通化し、カード上でモードを明示する。
*/

import Foundation

enum KizunaConversationKind: String, CaseIterable, Hashable, Identifiable {
    case persona
    case story

    var id: String { rawValue }
}

enum KizunaConversationRoute: Hashable, Identifiable {
    case persona(threadID: UUID)
    case story(worldID: UUID, sessionID: UUID)

    var id: String {
        switch self {
        case .persona(let threadID):
            return "persona:\(threadID.uuidString)"
        case .story(let worldID, let sessionID):
            return "story:\(worldID.uuidString):\(sessionID.uuidString)"
        }
    }

    var kind: KizunaConversationKind {
        switch self {
        case .persona: return .persona
        case .story: return .story
        }
    }
}

/// 既存のPersonaThread / StorySessionから導出する表示用の継続カード。
/// メッセージ本文を別の共通モデルへコピーせず、遷移先のIDだけを保持する。
struct KizunaContinuationItem: Identifiable, Hashable {
    let route: KizunaConversationRoute
    let kind: KizunaConversationKind
    let title: String
    let preview: String
    let updatedAt: Date
    let personaProfile: PersonaProfile?
    let storyWorld: StoryWorld?

    var id: String { route.id }
}
