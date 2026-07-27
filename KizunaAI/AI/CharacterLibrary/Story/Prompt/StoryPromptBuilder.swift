/*
仕様:
- 役割: 複数キャラが同居する Story モードの system prompt を組み立てる。
  active なキャラだけを詳細に出し、active でないキャラは「居る」程度の短い背景として 1 行ずつ。
- 主な型: `StoryPromptBuilder` (struct).
- 編集ポイント: セクション順、active/inactive のバランス、関係性の整形、末尾プライム。
- 重要:
    1) active は最大 3 名でハードキャップ。
    2) 関係性 (CharacterRelationship) は active キャラ間のものだけ展開する。
    3) 全キャラ詳細を毎回入れない — 上限はそれぞれ短文に保つ。
*/

import Foundation

struct StoryPromptBuilder {
    /// マルチキャラ Scene 用プロンプト。
    /// activeCast に渡すのは「現在のシーンで喋ってよいキャラ」だけにする (≤ 3 名)。
    func build(
        world: StoryWorld,
        scene: StoryScene,
        activeCast: [CastMember],
        inactiveCast: [CastMember],
        characterIndex: [UUID: CharacterProfile],
        selectedMemories: [CharacterMemory],
        session: StorySession,
        recentMessages: [StoryMessage],
        userInput: String,
        generationModel: StoryGenerationModel,
        safetyDecision: SafetyDecision?,
        storyState: StoryState? = nil,
        selectedLorebookEntries: [StoryLorebookEntry] = [],
        selectedStoryMemories: [StoryMemory] = [],
        userCharacterName: String? = nil
    ) -> String {
        var sections: [String] = []

        // ── 冒頭 ──
        sections.append(
            """
            あなたは下記の物語世界を進める語り手です。ユーザーは物語内の相手役です。
            返答は絆チャットとして、今の場面から自然に続く本文だけを書きます。
            出力言語は日本語です。英語、翻訳、内部メモ、思考過程、計画、候補、前置き、自己説明は出しません。
            ユーザーが操作する主人公の行動・感情・台詞は、ユーザーの入力に書かれたものだけです。AIは主人公を代弁しません。
            基本は現在の相手役であるNPC 1人が返します。場面上の反応が必要な時だけ、NPCを最大2人まで短く返します。
            場面描写は必要に応じて「ナレーション: 本文」として添えます。
            """
        )

        if let userCharacterName {
            sections.append(
                """
                ## ユーザー操作キャラ
                (userCharacterName)
                このキャラはユーザー本人です。AIは「(userCharacterName):」という発話行を絶対に生成しません。
                ユーザーの返答が必要な場面では、ナレーションで間を残して止めます。
                """
            )
        }

        // ── 世界観 ──
        var worldLines: [String] = []
        worldLines.append("タイトル: \(world.title)")
        if !world.shortDescription.isEmpty { worldLines.append("概要: \(world.shortDescription)") }
        if !world.worldSetting.isEmpty { worldLines.append("世界観: \(world.worldSetting)") }
        if !world.userRole.isEmpty { worldLines.append("あなた (相手 = ユーザー) の役: \(world.userRole)") }
        if !world.storyGoal.isEmpty { worldLines.append("物語の目標: \(world.storyGoal)") }
        if !world.mood.isEmpty { worldLines.append("ムード: \(world.mood)") }
        worldLines.append("ジャンル: \(world.genre.displayName) ・ 関係性: \(world.relationshipGenre.displayName)")
        worldLines.append(generationModel.promptHint)
        sections.append("## 世界\n" + worldLines.joined(separator: "\n"))

        // ── シーン ──
        var sceneLines: [String] = []
        if !scene.title.isEmpty { sceneLines.append("シーン名: \(scene.title)") }
        if !scene.location.isEmpty { sceneLines.append("場所: \(scene.location)") }
        if !scene.timeOfDay.isEmpty { sceneLines.append("時間: \(scene.timeOfDay)") }
        if !scene.mood.isEmpty { sceneLines.append("空気: \(scene.mood)") }
        if !scene.sceneGoal.isEmpty { sceneLines.append("このシーンの目的: \(scene.sceneGoal)") }
        if let conflict = scene.conflict, !conflict.isEmpty { sceneLines.append("葛藤: \(conflict)") }
        if !scene.summary.isEmpty { sceneLines.append("ここまでの要約: \(scene.summary)") }
        sections.append("## 現在のシーン\n" + sceneLines.joined(separator: "\n"))

        var sessionLines: [String] = []
        if let progress = session.progressLabel, !progress.isEmpty { sessionLines.append("進行: \(progress)") }
        if let objective = session.currentObjective, !objective.isEmpty { sessionLines.append("現在の目的: \(objective)") }
        if let turnProgress = session.lastTurnProgress, !turnProgress.isEmpty { sessionLines.append("前回動いたこと: \(turnProgress)") }
        if let summary = session.lastSceneSummary, !summary.isEmpty { sessionLines.append("前回までの要約: \(summary)") }
        if let hooks = session.unresolvedHooks, !hooks.isEmpty {
            sessionLines.append("未回収の要素: " + hooks.prefix(6).joined(separator: " / "))
        }
        sessionLines.append("累計メッセージ数: \(session.messages.count)")
        sections.append("## 物語の進行状態\n" + sessionLines.joined(separator: "\n"))

        // ── 構造化されたStoryState ──
        // 会話全文ではなく、今の状態だけを短く渡して長期整合性を保つ。
        if let storyState {
            var stateLines: [String] = []
            if !storyState.location.isEmpty { stateLines.append("場所: \(storyState.location)") }
            if !storyState.timeOfDay.isEmpty { stateLines.append("時間: \(storyState.timeOfDay)") }
            if !storyState.mood.isEmpty { stateLines.append("ムード: \(storyState.mood)") }
            if !storyState.weather.isEmpty { stateLines.append("天候: \(storyState.weather)") }
            if !storyState.relationshipStage.isEmpty { stateLines.append("関係段階: \(storyState.relationshipStage)") }
            if !storyState.activeGoals.isEmpty { stateLines.append("進行中の目的: \(storyState.activeGoals.joined(separator: " / "))") }
            for character in storyState.characterStates.prefix(StoryConstants.maxActiveCharacters) {
                let values = [character.mood, character.goal, character.relationship, character.innerThought]
                    .filter { !$0.isEmpty }
                    .joined(separator: " / ")
                if !values.isEmpty { stateLines.append("\(character.characterName): \(values)") }
            }
            for item in storyState.inventory.prefix(8) {
                let owner = item.owner.isEmpty ? "" : " [\(item.owner)]"
                stateLines.append("所持品: \(item.name)\(owner) \(item.detail)".trimmingCharacters(in: .whitespaces))
            }
            if !stateLines.isEmpty { sections.append("## 現在のStoryState\n" + stateLines.joined(separator: "\n")) }
        }

        // ── キーワードに一致したLorebookだけを投入 ──
        // 全Lorebookを毎回送らないことで、トークンと無関係な設定の混入を抑える。
        if !selectedLorebookEntries.isEmpty {
            let loreLines = selectedLorebookEntries.prefix(6).map { entry in
                "- [\(entry.title)] \(entry.content.prefix(600))"
            }
            sections.append("## 今回有効なLorebook\n" + loreLines.joined(separator: "\n"))
        }

        // ── active キャラ (詳細) ──
        if !activeCast.isEmpty {
            var blocks: [String] = []
            for member in activeCast.prefix(StoryConstants.maxActiveCharacters) {
                guard let profile = characterIndex[member.characterId] else { continue }
                let name = profile.displayName.isEmpty ? profile.name : profile.displayName
                var lines: [String] = []
                lines.append("◆ \(name) (\(member.roleInStory.displayName))")
                if !profile.shortDescription.isEmpty { lines.append("  紹介: \(profile.shortDescription)") }
                if !profile.personality.isEmpty { lines.append("  性格: \(profile.personality)") }
                if !profile.speakingStyle.isEmpty { lines.append("  口調: \(profile.speakingStyle)") }
                if !profile.background.isEmpty { lines.append("  背景: \(profile.background)") }
                if !profile.scenario.isEmpty { lines.append("  この物語での役割: \(profile.scenario)") }
                if !profile.firstMessage.isEmpty { lines.append("  初回の空気: \(profile.firstMessage)") }
                if !member.relationshipToUser.isEmpty {
                    lines.append("  あなたとの関係: \(member.relationshipToUser)")
                } else if !profile.relationshipToUser.isEmpty {
                    lines.append("  あなたとの関係: \(profile.relationshipToUser)")
                }
                blocks.append(lines.joined(separator: "\n"))
            }
            sections.append("## 今このシーンに居るキャラ (active)\n" + blocks.joined(separator: "\n\n"))
        }

        // ── inactive キャラ (短い背景情報のみ) ──
        if !inactiveCast.isEmpty {
            let lines = inactiveCast.compactMap { member -> String? in
                guard let profile = characterIndex[member.characterId] else { return nil }
                let name = profile.displayName.isEmpty ? profile.name : profile.displayName
                let oneLiner = [
                    profile.shortDescription,
                    profile.personality,
                    member.relationshipToUser.isEmpty ? profile.relationshipToUser : member.relationshipToUser
                ]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " / ")
                return "- \(name) (\(member.roleInStory.displayName), \(member.introductionTiming.displayName)): \(oneLiner.prefix(130))"
            }
            if !lines.isEmpty {
                sections.append(
                    """
                    ## このシーンに居ないが世界には存在するキャラ
                    \(lines.joined(separator: "\n"))
                    (上のキャラは今は登場しません。明示的に呼ばれた時だけ言及します。)
                    """
                )
            }
        }

        // ── active キャラ同士の関係性 ──
        let activeIDs = Set(activeCast.map(\.characterId))
        var relationLines: [String] = []
        for member in activeCast {
            for rel in member.relationshipToOtherCharacters where activeIDs.contains(rel.toCharacterId) {
                let from = characterIndex[rel.fromCharacterId].map { $0.displayName.isEmpty ? $0.name : $0.displayName } ?? "??"
                let to = characterIndex[rel.toCharacterId].map { $0.displayName.isEmpty ? $0.name : $0.displayName } ?? "??"
                var l = "- \(from) → \(to): \(rel.relationshipType.displayName)"
                if !rel.description.isEmpty { l += " (" + rel.description + ")" }
                l += " / 信頼 \(String(format: "%.1f", rel.trust)) / 緊張 \(String(format: "%.1f", rel.tension))"
                relationLines.append(l)
            }
        }
        if !relationLines.isEmpty {
            sections.append("## キャラ同士の関係 (active のみ)\n" + relationLines.joined(separator: "\n"))
        }

        // ── 全体メモリー ──
        // CharacterMemoryはキャラクターをまたいで次の物語でも使う長期記憶。
        if !selectedMemories.isEmpty {
            let mems = selectedMemories
                .sorted { $0.importance > $1.importance }
                .prefix(12)
                .map { "- [\($0.category.displayName) / \(String(format: "%.1f", $0.importance))] " + $0.text }
                .joined(separator: "\n")
            sections.append(
                """
                ## 全体メモリー (物語をまたいで使う)
                \(mems)
                (明示的に「覚えてるよ」と言わず、自然に活かす)
                """
            )
        }

        // ── 物語内メモリー ──
        // StoryMemoryはこのStoryWorldの出来事だけ。別の物語には注入しない。
        if !selectedStoryMemories.isEmpty {
            let mems = selectedStoryMemories
                .sorted { $0.importance > $1.importance }
                .prefix(12)
                .map { "- [\($0.category.displayName) / \(String(format: "%.1f", $0.importance))] " + $0.text }
                .joined(separator: "\n")
            sections.append(
                """
                ## 物語内メモリー (この世界だけ)
                \(mems)
                (この物語の過去として自然に活かす。別の世界の出来事として扱わない)
                """
            )
        }

        // ── 直近の会話 (話者名つき) ──
        // Runtime/model status notices are shown in the UI, but must not become story context.
        let storyRecentMessages = recentMessages.filter { message in
            if case .system = message.author { return false }
            return true
        }
        if !storyRecentMessages.isEmpty {
            let olderAnchor = conversationAnchors(from: storyRecentMessages)
            if !olderAnchor.isEmpty {
                sections.append("## これまでの流れの目印\n" + olderAnchor)
            }

            // 直近48メッセージをそのまま渡す。24件で切ると、ローカルモデルでも
            // 会話の連続性を早く失ってしまう。
            let convo = storyRecentMessages.suffix(48).compactMap { msg -> String? in
                switch msg.author {
                case .user: return "ユーザー: " + msg.text
                case .system: return nil
                case .narrator: return "ナレーション: " + msg.text
                case .cast(_, let name): return name + ": " + msg.text
                }
            }.joined(separator: "\n")
            sections.append("## 直近の会話 (重要。ここから自然に続ける)\n" + convo)
        }

        // ── ルール ──
        var rules: [String] = []
        var seen = Set<String>()
        func push(_ r: String) {
            let t = r.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, seen.insert(t).inserted { rules.append(t) }
        }
        world.safetyRules.filter { !isStoredOutputRule($0) }.forEach(push)
        world.genre.defaultSafetyRules.forEach(push)
        world.relationshipGenre.safetyRules.forEach(push)
        // active キャラ固有のルールも積む
        for member in activeCast {
            guard let profile = characterIndex[member.characterId] else { continue }
            profile.resolvedSafetyRules.forEach(push)
            profile.rules.forEach(push)
        }
        safetyDecision?.addedPromptRules.forEach(push)
        push("出力は2〜7行。基本形は「ナレーション: 短い場面描写」→「NPC名: 発話」。通常はNPC 1人だけが返す。")
        if world.isSoloStory {
            push("これは単体物語。active NPCは必ず1人だけにし、inactiveのキャラを勝手に登場させない。")
        } else {
            push("これは群像劇。掛け合いが場面上不可欠な時だけ、active のNPCを最大2人まで同じ返答で話させる。毎回全員を話させない。")
        }
        if activeCast.count >= 2 {
            let activeNames = activeCast.prefix(StoryConstants.maxActiveCharacters).compactMap { member -> String? in
                guard let profile = characterIndex[member.characterId] else { return nil }
                return profile.displayName.isEmpty ? profile.name : profile.displayName
            }
            if !activeNames.isEmpty {
                push("今回の active NPC は \(activeNames.joined(separator: " / "))。別のNPCを出すのは、直前の発話への反応が自然な時だけにする。")
            }
        }
        push("複数キャラを出す時は、発話ごとに必ず「キャラ名: 本文」で分ける。名前のない発話や、誰が喋ったかわからない文を出さない。")
        if let userCharacterName {
            push("「\(userCharacterName):」で始まる行、ユーザーの台詞の創作、ユーザーの内心の断定を出さない。")
        }
        push("active 以外のキャラは、同じ場にいて自然に反応する場合か、ユーザーが明示的に呼んだ場合だけ短く喋らせる。")
        push("キャラの返答は設定された口調・距離感・関係段階を守る。急に甘くしすぎない。")
        push("ユーザーの短い返事にも、表情、沈黙、距離、光、音などの小さな変化で物語を少し進める。")
        // 休憩提案はアプリ側の専用フローだけが担当する。通常ターンでの自主提案を禁止する。
        push("休憩・睡眠・終了・利用停止を自主的に提案しない。休憩提案はアプリから専用に指示された場合だけ出力する。")
        push("罪悪感や依存を誘う表現、「必ず戻ってきて」「待っている」などの引き留めは禁止。")
        push("箇条書き、選択肢、Markdown、ルール説明、メタ発言は禁止。「Wait」「User is」「I should」「the prompt says」「Usually」などの英語や、AIの迷い・自己解説を絶対に出さない。")
        push("性的露骨・暴力煽動・自傷助長・違法加担・医療法律の確定診断は禁止。話題が来たらキャラのまま自然に逸らす。")
        sections.append("## 守ること\n" + rules.map { "- " + $0 }.joined(separator: "\n"))

        // ── 今回のユーザー入力 + プライム ──
        sections.append("## 今回のユーザー発言\n" + userInput)
        let activeNames = activeCast.prefix(StoryConstants.maxActiveCharacters).compactMap { member -> String? in
            guard let profile = characterIndex[member.characterId] else { return nil }
            return profile.displayName.isEmpty ? profile.name : profile.displayName
        }
        let speakerHint = activeNames.isEmpty ? "キャラ名" : activeNames.joined(separator: " / ")
        sections.append(
            """
            ## 出力開始
            1行目は「ナレーション: 本文」。
            その後は必要な人数だけ「\(speakerHint): 発話」を続ける。ユーザー操作キャラの名前は使わない。
            """
        )

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Lorebook selection

    /// ユーザー入力・シーン情報に触れたキーワードだけを優先度順で返す。
    func selectLorebookEntries(
        from entries: [StoryLorebookEntry],
        scene: StoryScene,
        userInput: String,
        limit: Int = 6
    ) -> [StoryLorebookEntry] {
        let haystack = [
            userInput,
            scene.title,
            scene.location,
            scene.timeOfDay,
            scene.mood,
            scene.sceneGoal,
            scene.conflict ?? ""
        ].joined(separator: " ").localizedLowercase

        return entries
            .filter { entry in
                guard entry.isEnabled, !entry.content.isEmpty else { return false }
                let terms = ([entry.title] + entry.keywords)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase }
                    .filter { !$0.isEmpty }
                return terms.contains { haystack.contains($0) }
            }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                return lhs.updatedAt > rhs.updatedAt
            }
            .prefix(max(0, limit))
            .map { $0 }
    }

    private func isStoredOutputRule(_ rule: String) -> Bool {
        [
            "ナレーション",
            "1ターン",
            "キャラ発話",
            "複数キャラ",
            "active",
            "会話だけ",
            "思考過程",
            "メタ発言",
            "場面",
            "描写",
            "段階的"
        ].contains { rule.localizedCaseInsensitiveContains($0) }
    }

    private func conversationAnchors(from messages: [StoryMessage]) -> String {
        let older = Array(messages.dropLast(48))
        guard !older.isEmpty else { return "" }
        let anchors = older.enumerated().compactMap { index, message -> String? in
            guard index % 6 == 0 || index == older.count - 1 else { return nil }
            let speaker: String
            switch message.author {
            case .user: speaker = "ユーザー"
            case .system: return nil
            case .narrator: speaker = "ナレーション"
            case .cast(_, let name): speaker = name
            }
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return "- \(speaker): \(text.prefix(90))"
        }
        return anchors.prefix(12).joined(separator: "\n")
    }
}
