/*
仕様:
- 役割: Story モード用 270M 補助 Protocol の Mock 実装。
  ルールベース + importance/registration 順 + キーワード照合。
- 主な型: MockSceneCharacterSelector, MockSceneSummarizer, MockNextSceneSuggester.
*/

import Foundation

// MARK: - Character Selector

final class MockSceneCharacterSelector: SceneCharacterSelecting {
    func select(
        userInput: String,
        currentScene: StoryScene,
        cast: [CastMember],
        characterIndex: [UUID: CharacterProfile],
        maxActive: Int
    ) async -> [UUID] {
        let cap = max(1, min(maxActive, StoryConstants.maxActiveCharacters))
        guard !cast.isEmpty else { return [] }

        // 既に scene に居るキャラは継続を優先 (会話の連続性のため)。
        let currentlyActiveSet = Set(currentScene.activeCharacterIds)
        let input = userInput.lowercased()

        // スコアリング: 1) ユーザー入力に名前が含まれる → 強ブースト
        //                2) currentlyActive なら継続ボーナス
        //                3) main/secondary/mentor/friend など物語役割で軽くボーナス
        //                4) importance
        var scored: [(id: UUID, score: Double)] = []
        for member in cast {
            guard let profile = characterIndex[member.characterId] else { continue }
            var s: Double = member.importance * 0.4
            let name = (profile.displayName.isEmpty ? profile.name : profile.displayName).lowercased()
            if !name.isEmpty, input.contains(name) { s += 0.8 }
            if currentlyActiveSet.contains(member.characterId) { s += 0.35 }
            switch member.roleInStory {
            case .main: s += 0.2
            case .secondary, .friend, .mentor, .rival, .antagonist: s += 0.1
            case .background: s += 0.0
            }
            scored.append((member.characterId, s))
        }
        let chosen = scored
            .sorted { $0.score > $1.score }
            .prefix(cap)
            .map { $0.id }
        // 最低 1 名は確保 (main or 先頭 cast)。
        if chosen.isEmpty, let first = cast.first {
            return [first.characterId]
        }
        return Array(chosen)
    }
}

// MARK: - Summarizer

final class MockSceneSummarizer: SceneSummarizing {
    func updateSummary(
        currentSummary: String,
        recentMessages: [StoryMessage],
        characterIndex: [UUID: CharacterProfile]
    ) async -> String {
        // 直近 6 メッセージから登場人物 + ユーザー意図っぽい単語を拾って 1〜2 文の要約に積む。
        let recent = Array(recentMessages.suffix(6))
        var speakers: Set<String> = []
        var topics: [String] = []
        for m in recent {
            switch m.author {
            case .user:
                topics.append(m.text.prefix(40).description)
            case .system:
                break
            case .narrator:
                break
            case .cast(_, let displayName):
                speakers.insert(displayName)
            }
        }
        var line = currentSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let speakerLine = speakers.isEmpty ? "" : speakers.sorted().joined(separator: "、") + " が会話に参加。"
        let topicLine = topics.last.map { "直近の話題: \($0)" } ?? ""
        let next = [speakerLine, topicLine].filter { !$0.isEmpty }.joined(separator: " ")
        if !next.isEmpty {
            if line.isEmpty { line = next } else { line = (line + " " + next).prefix(280).description }
        }
        return line
    }
}

// MARK: - Next Scene Suggester

final class MockNextSceneSuggester: NextSceneSuggesting {
    func suggestNext(
        world: StoryWorld,
        completedScene: StoryScene,
        cast: [CastMember]
    ) async -> [NextSceneSuggestion] {
        // 雰囲気を反転させた 3 候補を返す。実 270M 接続で本物にする想定。
        let moodPalette: [String]
        switch world.genre.group {
        case .romance: moodPalette = ["少し気まずい朝", "二人だけの静かな夕方", "騒がしいお祭り"]
        case .school:  moodPalette = ["昼休みの教室", "放課後の校舎裏", "翌朝の登校時"]
        case .fantasy: moodPalette = ["森を抜けた平原", "夜の宿屋", "古びた遺跡の前"]
        case .mysteryHorror: moodPalette = ["雨の止んだ路地", "古い書庫", "夜の駅"]
        case .underworld: moodPalette = ["薄暗いビルの屋上", "深夜の倉庫街", "明け方のカフェ"]
        case .sciFi:   moodPalette = ["宇宙港のラウンジ", "ハッキング後の地下", "AI 都市の中央広場"]
        default:       moodPalette = ["翌日の同じ場所", "別の街に移って", "夜が更けた頃"]
        }
        return moodPalette.prefix(3).map { mood in
            NextSceneSuggestion(
                title: completedScene.title.isEmpty ? "次の場面" : completedScene.title + " の続き",
                location: mood,
                mood: mood,
                sceneGoal: world.storyGoal.isEmpty ? "" : "目標: " + world.storyGoal
            )
        }
    }
}
