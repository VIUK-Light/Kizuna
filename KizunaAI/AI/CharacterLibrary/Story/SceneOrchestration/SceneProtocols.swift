/*
仕様:
- 役割: Story モード用の 270M (Gemma 3 270M) 補助タスクを抽象化する Protocol。
  実モデル接続前は Mock で動作確認、後で実装差し替え。
- 主な型: SceneCharacterSelecting, SceneSummarizing, NextSceneSuggesting.
*/

import Foundation

/// 次のターンで「誰が喋るべきか/喋るのが自然か」を選ぶ。
/// 同時に最大 3 名まで。
protocol SceneCharacterSelecting: AnyObject {
    func select(
        userInput: String,
        currentScene: StoryScene,
        cast: [CastMember],
        characterIndex: [UUID: CharacterProfile],
        maxActive: Int
    ) async -> [UUID]
}

/// 直近の会話を踏まえて StoryScene.summary を更新する。
protocol SceneSummarizing: AnyObject {
    func updateSummary(
        currentSummary: String,
        recentMessages: [StoryMessage],
        characterIndex: [UUID: CharacterProfile]
    ) async -> String
}

/// 次のシーン候補を 1〜3 件提案する (タイトル + 場所 + ムードのみ)。
struct NextSceneSuggestion: Equatable, Hashable {
    var title: String
    var location: String
    var mood: String
    var sceneGoal: String
}

protocol NextSceneSuggesting: AnyObject {
    func suggestNext(
        world: StoryWorld,
        completedScene: StoryScene,
        cast: [CastMember]
    ) async -> [NextSceneSuggestion]
}
