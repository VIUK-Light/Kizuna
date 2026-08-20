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
            let name = profile.visibleName.lowercased()
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

final class RuntimeSceneCharacterSelector: SceneCharacterSelecting {
    private let fallback: SceneCharacterSelecting

    init(fallback: SceneCharacterSelecting = MockSceneCharacterSelector()) {
        self.fallback = fallback
    }

    func select(
        userInput: String,
        currentScene: StoryScene,
        cast: [CastMember],
        characterIndex: [UUID: CharacterProfile],
        maxActive: Int
    ) async -> [UUID] {
        guard !cast.isEmpty else { return [] }
        let candidates = cast.compactMap { member -> String? in
            guard let profile = characterIndex[member.characterId] else { return nil }
            return "(member.characterId.uuidString)|(profile.visibleName)|(member.roleInStory.rawValue)"
        }.joined(separator: "\n")
        let prompt = """
        Choose up to (max(1, maxActive)) character UUIDs who should be active in this scene.
        Return only comma-separated UUIDs.
        User input: (userInput)
        Scene: (currentScene.title) / (currentScene.mood)
        Cast:
        (candidates)
        """
        guard let raw = await LocalAuxiliaryAI.generate(prompt: prompt, maxOutputTokens: max(64, maxActive * 48)) else {
            return await fallback.select(
                userInput: userInput,
                currentScene: currentScene,
                cast: cast,
                characterIndex: characterIndex,
                maxActive: maxActive
            )
        }
        let ids = LocalAuxiliaryAI.normalized(raw)
            .split { $0 == "," || $0 == " " || $0 == "\n" }
            .compactMap { UUID(uuidString: String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
        let allowed = Set(cast.map(\.characterId))
        let selected = ids.filter { allowed.contains($0) }
        guard !selected.isEmpty else {
            return await fallback.select(
                userInput: userInput,
                currentScene: currentScene,
                cast: cast,
                characterIndex: characterIndex,
                maxActive: maxActive
            )
        }
        return Array(selected.prefix(max(1, min(maxActive, StoryConstants.maxActiveCharacters))))
    }
}

final class RuntimeSceneSummarizer: SceneSummarizing {
    private let fallback: SceneSummarizing

    init(fallback: SceneSummarizing = MockSceneSummarizer()) {
        self.fallback = fallback
    }

    func updateSummary(
        currentSummary: String,
        recentMessages: [StoryMessage],
        characterIndex: [UUID: CharacterProfile]
    ) async -> String {
        let transcript = recentMessages.suffix(8).map { message in
            let author: String
            switch message.author {
            case .user: author = "User"
            case .narrator: author = "Narration"
            case .system: author = "System"
            case .cast(_, let name): author = name
            }
            return "(author): (message.text)"
        }.joined(separator: "\n")
        let prompt = """
        Write one concise factual summary of the current story state.
        Return only the summary, no label or explanation. Keep under 280 characters.
        Existing summary: (currentSummary)
        Recent transcript:
        (transcript)
        """
        guard let raw = await LocalAuxiliaryAI.generate(prompt: prompt, maxOutputTokens: 96) else {
            return await fallback.updateSummary(
                currentSummary: currentSummary,
                recentMessages: recentMessages,
                characterIndex: characterIndex
            )
        }
        let summary = LocalAuxiliaryAI.normalized(raw)
        return summary.isEmpty ? await fallback.updateSummary(
            currentSummary: currentSummary,
            recentMessages: recentMessages,
            characterIndex: characterIndex
        ) : String(summary.prefix(280))
    }
}

final class RuntimeNextSceneSuggester: NextSceneSuggesting {
    private let fallback: NextSceneSuggesting

    init(fallback: NextSceneSuggesting = MockNextSceneSuggester()) {
        self.fallback = fallback
    }

    func suggestNext(
        world: StoryWorld,
        completedScene: StoryScene,
        cast: [CastMember]
    ) async -> [NextSceneSuggestion] {
        let prompt = """
        Suggest up to three next story scenes.
        Return one per line as TITLE|LOCATION|MOOD|GOAL, with no extra text.
        World: (world.title) / (world.genre.displayName)
        Story goal: (world.storyGoal)
        Completed scene: (completedScene.title) / (completedScene.mood)
        """
        guard let raw = await LocalAuxiliaryAI.generate(prompt: prompt, maxOutputTokens: 256) else {
            return await fallback.suggestNext(world: world, completedScene: completedScene, cast: cast)
        }
        let suggestions = LocalAuxiliaryAI.normalized(raw).split(separator: "\n").compactMap { line -> NextSceneSuggestion? in
            let parts = line.split(separator: "|", maxSplits: 3).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
            return NextSceneSuggestion(title: parts[0], location: parts[1], mood: parts[2], sceneGoal: parts[3])
        }
        return suggestions.isEmpty
            ? await fallback.suggestNext(world: world, completedScene: completedScene, cast: cast)
            : Array(suggestions.prefix(3))
    }
}
