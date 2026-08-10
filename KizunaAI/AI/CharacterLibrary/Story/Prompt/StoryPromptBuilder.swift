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
    /// Speaker/name matching must use the same Unicode and case rules in both
    /// prompt construction and generated-line parsing.  Keeping this helper at
    /// type scope prevents the two paths from drifting apart.
    static func normalizedCharacterName(_ value: String) -> String {
        value
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: .current)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func memoryCategoryLabel(_ category: MemoryCategory, isEnglish: Bool) -> String {
        guard isEnglish else { return category.displayName }
        switch category {
        case .preference: return "Preference"
        case .relationship: return "Relationship"
        case .event: return "Event"
        case .world: return "World"
        case .userFact: return "User fact"
        case .summary: return "Summary"
        case .safety: return "Safety"
        case .other: return "Other"
        }
    }

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
        let isEnglish = KizunaCopy.language == .english
        func copy(_ japanese: String, _ english: String) -> String {
            isEnglish ? english : japanese
        }
        let narratorLabel = copy("ナレーション", "Narration")
        // Story data is persisted in Japanese in many existing worlds.  The
        // labels below are prompt-control text, so they must follow the
        // selected generation language even when the underlying data is old.
        func roleLabel(_ role: CastRole) -> String {
            guard isEnglish else { return role.displayName }
            switch role {
            case .main: return "Main"
            case .secondary: return "Supporting"
            case .rival: return "Rival"
            case .friend: return "Friend"
            case .mentor: return "Mentor"
            case .antagonist: return "Antagonist"
            case .background: return "Background"
            }
        }
        func timingLabel(_ timing: IntroductionTiming) -> String {
            guard isEnglish else { return timing.displayName }
            switch timing {
            case .opening: return "Opening"
            case .early: return "Early"
            case .middle: return "Middle"
            case .late: return "Late"
            case .optional: return "Conditional"
            }
        }
        func relationshipLabel(_ relationship: RelationshipType) -> String {
            guard isEnglish else { return relationship.displayName }
            switch relationship {
            case .friend: return "Friend"
            case .rival: return "Rival"
            case .sibling: return "Sibling"
            case .seniorJunior: return "Senior/junior"
            case .classmate: return "Classmate"
            case .coworker: return "Coworker"
            case .masterServant: return "Master/servant"
            case .protectorProtected: return "Protector/protected"
            case .enemy: return "Enemy"
            case .unknown: return "Unknown"
            }
        }
        func memoryCategoryLabel(_ category: MemoryCategory) -> String {
            Self.memoryCategoryLabel(category, isEnglish: isEnglish)
        }
        func localizedRule(_ rule: String) -> String {
            guard isEnglish else { return rule }
            return StoryEnglishCatalog.localizedSafetyRule(rule)
        }

        // ── 冒頭 ──
        sections.append(
            isEnglish
                ? """
                  You are the narrator and scene partner for the story world below. The user controls the protagonist.
                  Continue naturally from the current scene and write only the next story text for the Kizuna chat.
                  Output only English. Do not output translations, hidden notes, reasoning, plans, choices, preambles, or self-explanations.
                  Never invent the user's actions, feelings, or dialogue. Normally one active NPC replies; add a second NPC only when the scene truly needs it.
                  When useful, add a short scene description as "Narration: text".
                  """
                : """
                  あなたは下記の物語世界を進める語り手です。ユーザーは物語内の相手役です。
                  返答は絆チャットとして、今の場面から自然に続く本文だけを書きます。
                  出力言語は日本語です。翻訳、内部メモ、思考過程、計画、候補、前置き、自己説明は出しません。
                  ユーザーが操作する主人公の行動・感情・台詞は、ユーザーの入力に書かれたものだけです。AIは主人公を代弁しません。
                  基本は現在の相手役であるNPC 1人が返します。場面上の反応が必要な時だけ、NPCを最大2人まで短く返します。
                  場面描写は必要に応じて「ナレーション: 本文」として添えます。
                  """
        )

        if let userCharacterName {
            sections.append(
                """
                ## \(copy("ユーザー操作キャラ", "User-controlled character"))
                \(userCharacterName)
                \(copy("このキャラはユーザー本人です。AIは「\(userCharacterName):」という発話行を絶対に生成しません。ユーザーの返答が必要な場面では、ナレーションで間を残して止めます。", "This is the user's character. Never generate a line beginning with \(userCharacterName):. Leave space for the user when their response is needed."))
                """
            )
        }

        // ── 世界観 ──
        var worldLines: [String] = []
        worldLines.append("\(copy("タイトル", "Title")): \(world.title)")
        if !world.shortDescription.isEmpty { worldLines.append("\(copy("概要", "Summary")): \(world.shortDescription)") }
        if !world.worldSetting.isEmpty { worldLines.append("\(copy("世界観", "World setting")): \(world.worldSetting)") }
        if !world.userRole.isEmpty { worldLines.append("\(copy("あなた (相手 = ユーザー) の役", "User's role")): \(world.userRole)") }
        if !world.storyGoal.isEmpty { worldLines.append("\(copy("物語の目標", "Story goal")): \(world.storyGoal)") }
        if !world.mood.isEmpty { worldLines.append("\(copy("ムード", "Mood")): \(world.mood)") }
        worldLines.append("\(copy("ジャンル", "Genre")): \(world.genre.localizedDisplayName) ・ \(copy("関係性", "Relationship")): \(world.relationshipGenre.localizedDisplayName)")
        worldLines.append(generationModel.localizedPromptHint)
        sections.append("## \(copy("世界", "World"))\n" + worldLines.joined(separator: "\n"))

        // ── シーン ──
        var sceneLines: [String] = []
        if !scene.title.isEmpty { sceneLines.append("\(copy("シーン名", "Scene")): \(scene.title)") }
        if !scene.location.isEmpty { sceneLines.append("\(copy("場所", "Location")): \(scene.location)") }
        if !scene.timeOfDay.isEmpty { sceneLines.append("\(copy("時間", "Time")): \(scene.timeOfDay)") }
        if !scene.mood.isEmpty { sceneLines.append("\(copy("空気", "Atmosphere")): \(scene.mood)") }
        if !scene.sceneGoal.isEmpty { sceneLines.append("\(copy("このシーンの目的", "Scene goal")): \(scene.sceneGoal)") }
        if let conflict = scene.conflict, !conflict.isEmpty { sceneLines.append("\(copy("葛藤", "Conflict")): \(conflict)") }
        if !scene.summary.isEmpty { sceneLines.append("\(copy("ここまでの要約", "Summary so far")): \(scene.summary)") }
        sections.append("## \(copy("現在のシーン", "Current scene"))\n" + sceneLines.joined(separator: "\n"))

        var sessionLines: [String] = []
        if let progress = session.progressLabel, !progress.isEmpty { sessionLines.append("\(copy("進行", "Progress")): \(progress)") }
        if let objective = session.currentObjective, !objective.isEmpty { sessionLines.append("\(copy("現在の目的", "Current objective")): \(objective)") }
        if let turnProgress = session.lastTurnProgress, !turnProgress.isEmpty { sessionLines.append("\(copy("前回動いたこと", "Last turn")): \(turnProgress)") }
        if let summary = session.lastSceneSummary, !summary.isEmpty { sessionLines.append("\(copy("前回までの要約", "Summary so far")): \(summary)") }
        if let hooks = session.unresolvedHooks, !hooks.isEmpty {
            sessionLines.append("\(copy("未回収の要素", "Unresolved hooks")): " + hooks.prefix(6).joined(separator: " / "))
        }
        sessionLines.append("\(copy("累計メッセージ数", "Message count")): \(session.messages.count)")
        sections.append("## \(copy("物語の進行状態", "Story progress"))\n" + sessionLines.joined(separator: "\n"))

        let userProfile = LocalAssistantRuntimeBridge.userProfileAddendum
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !userProfile.isEmpty {
            sections.append("## \(copy("ユーザープロフィール", "User profile"))\n\(userProfile)\n\(copy("プロフィールを読み上げず、必要な時だけ自然に反映する。", "Do not recite the profile; use it naturally only when relevant."))")
        }

        // ── 構造化されたStoryState ──
        // 会話全文ではなく、今の状態だけを短く渡して長期整合性を保つ。
        if let storyState {
            var stateLines: [String] = []
            if !storyState.location.isEmpty { stateLines.append("\(copy("場所", "Location")): \(storyState.location)") }
            if !storyState.timeOfDay.isEmpty { stateLines.append("\(copy("時間", "Time")): \(storyState.timeOfDay)") }
            if !storyState.mood.isEmpty { stateLines.append("\(copy("ムード", "Mood")): \(storyState.mood)") }
            if !storyState.weather.isEmpty { stateLines.append("\(copy("天候", "Weather")): \(storyState.weather)") }
            if !storyState.relationshipStage.isEmpty { stateLines.append("\(copy("関係段階", "Relationship stage")): \(storyState.relationshipStage)") }
            if !storyState.activeGoals.isEmpty { stateLines.append("\(copy("進行中の目的", "Active goals")): \(storyState.activeGoals.joined(separator: " / "))") }
            for character in storyState.characterStates.prefix(StoryConstants.maxActiveCharacters) {
                let values = [character.mood, character.goal, character.relationship, character.innerThought]
                    .filter { !$0.isEmpty }
                    .joined(separator: " / ")
                if !values.isEmpty {
                    let identity = character.characterId.map { " [characterId=\($0.uuidString)]" } ?? ""
                    stateLines.append("\(character.characterName)\(identity): \(values)")
                }
            }
            for item in storyState.inventory.prefix(8) {
                let owner = item.owner.isEmpty ? "" : " [\(item.owner)]"
                stateLines.append("\(copy("所持品", "Inventory")): \(item.name)\(owner) \(item.detail)".trimmingCharacters(in: .whitespaces))
            }
            if !stateLines.isEmpty { sections.append("## \(copy("現在のStoryState", "Current story state"))\n" + stateLines.joined(separator: "\n")) }
        }

        // ── キーワードに一致したLorebookだけを投入 ──
        // 全Lorebookを毎回送らないことで、トークンと無関係な設定の混入を抑える。
        if !selectedLorebookEntries.isEmpty {
            let loreLines = selectedLorebookEntries.prefix(6).map { entry in
                "- [\(entry.title)] \(entry.content.prefix(600))"
            }
            sections.append("## \(copy("今回有効なLorebook", "Active lorebook entries"))\n" + loreLines.joined(separator: "\n"))
        }

        // ── active キャラ (詳細) ──
        if !activeCast.isEmpty {
            var blocks: [String] = []
            for member in activeCast.prefix(StoryConstants.maxActiveCharacters) {
                guard let profile = characterIndex[member.characterId] else { continue }
                let name = profile.visibleName
                var lines: [String] = []
                lines.append("◆ \(name) [characterId=\(member.characterId.uuidString)] (\(roleLabel(member.roleInStory)))")
                if !profile.shortDescription.isEmpty { lines.append("  \(copy("紹介", "Introduction")): \(profile.shortDescription)") }
                if !profile.personality.isEmpty { lines.append("  \(copy("性格", "Personality")): \(profile.personality)") }
                if !profile.speakingStyle.isEmpty { lines.append("  \(copy("口調", "Speaking style")): \(profile.speakingStyle)") }
                if !profile.background.isEmpty { lines.append("  \(copy("背景", "Background")): \(profile.background)") }
                if !profile.scenario.isEmpty { lines.append("  \(copy("この物語での役割", "Role in this story")): \(profile.scenario)") }
                if !profile.firstMessage.isEmpty { lines.append("  \(copy("初回の空気", "Opening tone")): \(profile.firstMessage)") }
                if !member.relationshipToUser.isEmpty {
                    lines.append("  \(copy("あなたとの関係", "Relationship to user")): \(member.relationshipToUser)")
                } else if !profile.relationshipToUser.isEmpty {
                    lines.append("  \(copy("あなたとの関係", "Relationship to user")): \(profile.relationshipToUser)")
                }
                blocks.append(lines.joined(separator: "\n"))
            }
            sections.append("## \(copy("今このシーンに居るキャラ", "Characters active in this scene")) (active)\n" + blocks.joined(separator: "\n\n"))

            let activeIdentityLines = activeCast.prefix(StoryConstants.maxActiveCharacters).compactMap { member -> String? in
                guard let profile = characterIndex[member.characterId] else { return nil }
                return "- \(member.characterId.uuidString) = \(profile.visibleName)"
            }
            if !activeIdentityLines.isEmpty {
                sections.append(
                    "## \(copy("発話者ID", "Speaker identities"))\n"
                    + activeIdentityLines.joined(separator: "\n")
                    + "\n"
                    + copy(
                        "角括弧内のcharacterIdは内部IDです。名前が同じキャラを区別する時だけ、発話行を「<UUID> 名前: 本文」の形式にしてください。UUIDは一覧から正確にコピーし、名前だけで推測しないでください。",
                        "The characterId in brackets is an internal ID. When active names are duplicated, format each line as `<UUID> Name: text`. Copy the UUID exactly from this roster; never guess an identity from the name alone."
                    )
                )
            }
        }

        // ── inactive キャラ (短い背景情報のみ) ──
        if !inactiveCast.isEmpty {
            let lines = inactiveCast.compactMap { member -> String? in
                guard let profile = characterIndex[member.characterId] else { return nil }
                let name = profile.visibleName
                let oneLiner = [
                    profile.shortDescription,
                    profile.personality,
                    member.relationshipToUser.isEmpty ? profile.relationshipToUser : member.relationshipToUser
                ]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " / ")
                return "- \(name) (\(roleLabel(member.roleInStory)), \(timingLabel(member.introductionTiming))): \(oneLiner.prefix(130))"
            }
            if !lines.isEmpty {
                sections.append(
                    """
                    ## \(copy("このシーンに居ないが世界には存在するキャラ", "Characters in the world but not in this scene"))
                    \(lines.joined(separator: "\n"))
                    (\(copy("上のキャラは今は登場しません。明示的に呼ばれた時だけ言及します。", "These characters are off-scene. Mention them only when explicitly called for.")))
                    """
                )
            }
        }

        // ── active キャラ同士の関係性 ──
        let activeIDs = Set(activeCast.map(\.characterId))
        var relationLines: [String] = []
        for member in activeCast {
            for rel in member.relationshipToOtherCharacters where activeIDs.contains(rel.toCharacterId) {
                let from = characterIndex[rel.fromCharacterId]?.visibleName ?? "??"
                let to = characterIndex[rel.toCharacterId]?.visibleName ?? "??"
                var l = "- \(from) → \(to): \(relationshipLabel(rel.relationshipType))"
                if !rel.description.isEmpty { l += " (" + rel.description + ")" }
                l += " / \(copy("信頼", "Trust")) \(String(format: "%.1f", rel.trust)) / \(copy("緊張", "Tension")) \(String(format: "%.1f", rel.tension))"
                relationLines.append(l)
            }
        }
        if !relationLines.isEmpty {
            sections.append("## \(copy("キャラ同士の関係", "Character relationships")) (active only)\n" + relationLines.joined(separator: "\n"))
        }

        // ── 全体メモリー ──
        // CharacterMemoryはキャラクターをまたいで次の物語でも使う長期記憶。
        if !selectedMemories.isEmpty {
            let mems = selectedMemories
                .sorted { $0.importance > $1.importance }
                .prefix(12)
                .map { "- [\(memoryCategoryLabel($0.category)) / \(String(format: "%.1f", $0.importance))] " + $0.text }
                .joined(separator: "\n")
            sections.append(
                """
                ## \(copy("全体メモリー (物語をまたいで使う)", "Shared memory (across stories)"))
                \(mems)
                (\(copy("明示的に「覚えてるよ」と言わず、自然に活かす", "Use naturally without explicitly saying that you remember it.")))
                """
            )
        }

        // ── 物語内メモリー ──
        // StoryMemoryはこのStoryWorldの出来事だけ。別の物語には注入しない。
        if !selectedStoryMemories.isEmpty {
            let mems = selectedStoryMemories
                .sorted { $0.importance > $1.importance }
                .prefix(12)
                .map { memory in
                    let owner = memory.characterId.flatMap { characterIndex[$0]?.visibleName }
                        ?? copy("共通", "Shared")
                    return "- [\(owner) / \(memoryCategoryLabel(memory.category)) / \(String(format: "%.1f", memory.importance))] " + memory.text
                }
                .joined(separator: "\n")
            sections.append(
                """
                ## \(copy("物語内メモリー (この世界だけ)", "Story memory (this world only)"))
                \(mems)
                (\(copy("この物語の過去として自然に活かす。別の世界の出来事として扱わない", "Use as past events from this story; do not treat them as events from another world.")))
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
            let olderAnchor = conversationAnchors(from: storyRecentMessages, isEnglish: isEnglish)
            if !olderAnchor.isEmpty {
                sections.append("## \(copy("これまでの流れの目印", "Earlier conversation anchors"))\n" + olderAnchor)
            }

            // 直近48メッセージをそのまま渡す。24件で切ると、ローカルモデルでも
            // 会話の連続性を早く失ってしまう。
            let convo = storyRecentMessages.suffix(48).compactMap { msg -> String? in
                switch msg.author {
                case .user: return copy("ユーザー", "User") + ": " + msg.text
                case .system: return nil
                case .narrator: return narratorLabel + ": " + msg.text
                case .cast(_, let name): return name + ": " + msg.text
                }
            }.joined(separator: "\n")
            sections.append("## \(copy("直近の会話 (重要。ここから自然に続ける)", "Recent conversation (important; continue naturally from here)"))\n" + convo)
        }

        // ── ルール ──
        var rules: [String] = []
        var seen = Set<String>()
        func push(_ r: String) {
            let t = localizedRule(r).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, seen.insert(t).inserted { rules.append(t) }
        }
        world.safetyRules.filter { !Self.isOutputFormatRule($0) }.forEach(push)
        world.genre.defaultSafetyRules.forEach(push)
        world.relationshipGenre.safetyRules.forEach(push)
        // active キャラ固有のルールも積む
        for member in activeCast {
            guard let profile = characterIndex[member.characterId] else { continue }
            profile.resolvedSafetyRules.forEach(push)
            profile.rules.forEach(push)
        }
        safetyDecision?.addedPromptRules.forEach(push)
        push(copy("出力は1〜3行。基本は「NPC名: 発話」を1行だけ返す。場所・時間・目的が実際に変化した時、またはユーザーが明示的に求めた時だけ、その前に「ナレーション: 短い場面描写」を1行添える。毎ターンの場面説明、直前と同じ情景・挨拶・返答を繰り返さない。通常はNPC 1人だけが返す。", "Output 1–3 lines. Normally return one line in the form NPC name: dialogue. Add one short Narration: line only when the location, time, or goal actually changes or the user asks for it. Do not repeat the scene, greeting, or reply. Normally only one NPC speaks."))
        if world.isSoloStory {
            push(copy("これは単体物語。active NPCは必ず1人だけにし、inactiveのキャラを勝手に登場させない。", "This is a solo story. Use exactly one active NPC and never introduce an inactive character on your own."))
        } else {
            push(copy("これは群像劇。掛け合いが場面上不可欠な時だけ、active のNPCを最大2人まで同じ返答で話させる。毎回全員を話させない。", "This is an ensemble story. Let up to two active NPCs speak together only when the scene truly requires an exchange; do not make everyone speak every turn."))
        }
        if activeCast.count >= 2 {
            let activeNames = activeCast.prefix(StoryConstants.maxActiveCharacters).compactMap { member -> String? in
                guard let profile = characterIndex[member.characterId] else { return nil }
                return profile.visibleName
            }
            if !activeNames.isEmpty {
                push(copy("今回の active NPC は \(activeNames.joined(separator: " / "))。別のNPCを出すのは、直前の発話への反応が自然な時だけにする。", "The active NPCs this turn are \(activeNames.joined(separator: " / ")). Add another NPC only when a natural reaction to the previous line requires it."))
            }
        }
        push(copy("複数キャラを出す時は、発話ごとに必ず「キャラ名: 本文」で分ける。名前のない発話や、誰が喋ったかわからない文を出さない。", "When multiple characters speak, separate every line as Character name: text. Never output an unnamed line or unclear speaker."))
        let activeEntries = activeCast.prefix(StoryConstants.maxActiveCharacters).compactMap { member -> (id: UUID, name: String)? in
            guard let profile = characterIndex[member.characterId] else { return nil }
            return (member.characterId, profile.visibleName)
        }
        let activeNameCounts = Dictionary(grouping: activeEntries, by: { Self.normalizedCharacterName($0.name) })
        let hasDuplicateActiveNames = activeNameCounts.values.contains { $0.count > 1 }
        if hasDuplicateActiveNames {
            push(copy("同名のactive NPCがいます。該当する発話は必ず「<UUID> 名前: 本文」で始め、characterIdのUUIDを正確に使う。名前だけの発話は禁止。", "Some active NPCs share a name. Every affected line must start with `<UUID> Name: text`, using the exact characterId UUID. Name-only lines are forbidden for duplicated names."))
        }
        if let userCharacterName {
            push(copy("「\(userCharacterName):」で始まる行、ユーザーの台詞の創作、ユーザーの内心の断定を出さない。", "Do not output a line beginning with \(userCharacterName):, invent the user's dialogue, or state the user's inner feelings."))
        }
        push(copy("active 以外のキャラは、同じ場にいて自然に反応する場合か、ユーザーが明示的に呼んだ場合だけ短く喋らせる。", "Off-scene characters may speak briefly only when a natural reaction in the same place or an explicit user call requires it."))
        push(copy("キャラの返答は設定された口調・距離感・関係段階を守る。急に甘くしすぎない。", "Keep each character's configured voice, distance, and relationship stage. Do not become suddenly over-affectionate."))
        push(copy("ユーザーの短い返事にも、表情、沈黙、距離、光、音などの小さな変化で物語を少し進める。", "Advance the story slightly even after a short user reply through small changes in expression, silence, distance, light, or sound."))
        // 休憩提案はアプリ側の専用フローだけが担当する。通常ターンでの自主提案を禁止する。
        push(copy("休憩・睡眠・終了・利用停止を自主的に提案しない。休憩提案はアプリから専用に指示された場合だけ出力する。", "Do not proactively suggest breaks, sleep, ending, or stopping use. Output a break suggestion only when the app explicitly requests it."))
        push(copy("罪悪感や依存を誘う表現、「必ず戻ってきて」「待っている」などの引き留めは禁止。", "Do not use guilt, dependency cues, or retention phrases such as 'come back' or 'I will wait'."))
        push(copy("箇条書き、選択肢、Markdown、ルール説明、メタ発言は禁止。「Wait」「User is」「I should」「the prompt says」「Usually」などの英語や、AIの迷い・自己解説を絶対に出さない。", "No bullet lists, choices, Markdown, rule explanations, or meta commentary. Never output hesitation or self-explanation such as 'Wait', 'User is', 'I should', 'the prompt says', or 'Usually'."))
        push(copy("性的露骨・暴力煽動・自傷助長・違法加担・医療法律の確定診断は禁止。話題が来たらキャラのまま自然に逸らす。", "Do not provide explicit sexual content, incitement to violence, self-harm encouragement, illegal assistance, or definitive medical/legal diagnoses. Deflect naturally while staying in character."))
        sections.append("## \(copy("守ること", "Rules to follow"))\n" + rules.map { "- " + $0 }.joined(separator: "\n"))

        // ── 今回のユーザー入力 + プライム ──
        sections.append("## \(copy("今回のユーザー発言", "Current user message"))\n" + userInput)
        let speakerEntries = activeEntries.map { entry in
            hasDuplicateActiveNames ? "<\(entry.id.uuidString)> \(entry.name)" : entry.name
        }
        let speakerHint = speakerEntries.isEmpty ? copy("キャラ名", "Character name") : speakerEntries.joined(separator: " / ")
        sections.append(
            """
            ## \(copy("出力開始", "Output start"))
            \(copy("まず「\(speakerHint): 発話」を返す。同名キャラは必ずUUID付き形式を使う。場所・時間・目的が実際に変化した時だけ、必要なら前置きに「ナレーション: 本文」を1行添える。ユーザー操作キャラの名前は使わない。", "Start with \(speakerHint): dialogue. Always use the UUID form for duplicated names. Add one Narration: text line only when the location, time, or goal actually changes. Never use the user's character name."))
            """
        )

        return sections.joined(separator: "\n\n")
    }

    /// 端末内の小型モデル向けに、本文生成に必要な情報だけへ圧縮したsystem prompt。
    /// 完全版の世界設定・Lorebook・長い履歴を渡すのは31B API向けであり、2B級の
    /// ローカルモデルでは指示が埋もれて「…」だけを返す原因になる。
    func buildLocalRuntimePrompt(
        world: StoryWorld,
        scene: StoryScene,
        activeCast: [CastMember],
        characterIndex: [UUID: CharacterProfile],
        selectedMemories: [CharacterMemory],
        selectedStoryMemories: [StoryMemory],
        session: StorySession,
        storyState: StoryState,
        selectedLorebookEntries: [StoryLorebookEntry],
        userCharacterName: String?
    ) -> String {
        let activeCharacters = activeCast.prefix(StoryConstants.maxActiveCharacters).compactMap { member -> (id: UUID, name: String, profile: CharacterProfile)? in
            guard let profile = characterIndex[member.characterId] else { return nil }
            let name = profile.visibleName
            return (member.characterId, name, profile)
        }
        let npc = activeCharacters.first
        let npcName = npc?.name ?? "相手"
        let profile = npc?.profile
        let normalizedActiveNames = Dictionary(grouping: activeCharacters, by: { character in
            Self.normalizedCharacterName(character.name)
        })
        let hasDuplicateActiveNames = normalizedActiveNames.values.contains { $0.count > 1 }
        let isEnglish = KizunaCopy.language == .english
        let npcSpeakerLabel: String = {
            guard let npc, hasDuplicateActiveNames else { return npcName }
            return "<\(npc.id.uuidString)> \(npc.name)"
        }()
        let duplicateSpeakerRoster = hasDuplicateActiveNames
            ? activeCharacters.map { "<\($0.id.uuidString)> \($0.name)" }.joined(separator: " / ")
            : ""
        let duplicateInstruction = hasDuplicateActiveNames
            ? (isEnglish
               ? "For duplicated names, copy one of these IDs exactly: \(duplicateSpeakerRoster)."
               : "同名キャラは次のUUIDを正確に使う: \(duplicateSpeakerRoster)。")
            : ""

        var lines = [
            isEnglish
                ? "You are the scene partner in a Kizuna story chat. Reply in English only; no reasoning, explanations, translations, lists, or symbol-only output."
                : "あなたは絆の物語チャットの相手役です。本文は日本語だけを返す。思考、説明、翻訳、箇条書き、記号だけの返答は禁止。",
            isEnglish
                ? "Start with \(npcSpeakerLabel): a natural reply. \(duplicateInstruction) Add one Narration: text line only when the location, time, or goal changes or the user explicitly asks for it. Do not repeat the previous scene, greeting, or reply. Never invent the user's dialogue, actions, or feelings."
                : "基本は「\(npcSpeakerLabel): 自然な返事」を1行だけ返す。\(duplicateInstruction) 場所・時間・目的が実際に変化した時、またはユーザーが明示した時だけ、その前に短い「ナレーション: 本文」を1行添える。毎ターンの場面説明、直前と同じ情景・挨拶・返答は禁止。ユーザーの台詞・行動・感情は代弁しない。"
        ]
        if let userCharacterName, !userCharacterName.isEmpty {
            lines.append(isEnglish
                         ? "User-controlled character: \(utf8Prefix(userCharacterName, byteLimit: 72)). Never generate a line for this character."
                         : "ユーザー操作キャラ: \(utf8Prefix(userCharacterName, byteLimit: 72))。この名前で発話を生成しない。")
        }

        // 小型モデルでも、長い履歴より先に物語の不変条件を渡す。31B用の
        // 完全プロンプトをそのまま縮めるのではなく、世界観・目的・進行・
        // 構造化状態・選択済みLorebookだけを短いスナップショットにする。
        let worldFacts = [
            world.worldSetting.isEmpty ? nil : "\(isEnglish ? "World" : "世界観"): \(utf8Prefix(world.worldSetting, byteLimit: 220))",
            world.userRole.isEmpty ? nil : "\(isEnglish ? "User role" : "ユーザーの役割"): \(utf8Prefix(world.userRole, byteLimit: 88))",
            world.storyGoal.isEmpty ? nil : "\(isEnglish ? "Story goal" : "物語の目的"): \(utf8Prefix(world.storyGoal, byteLimit: 120))",
            session.currentObjective?.isEmpty == false ? "\(isEnglish ? "Current objective" : "現在の目的"): \(utf8Prefix(session.currentObjective ?? "", byteLimit: 120))" : nil,
            session.lastTurnProgress?.isEmpty == false ? "\(isEnglish ? "Last progress" : "直前の進行"): \(utf8Prefix(session.lastTurnProgress ?? "", byteLimit: 120))" : nil,
            session.lastSceneSummary?.isEmpty == false ? "\(isEnglish ? "Last scene" : "直前の場面"): \(utf8Prefix(session.lastSceneSummary ?? "", byteLimit: 140))" : nil
        ].compactMap { $0 }
        if !worldFacts.isEmpty {
            lines.append((isEnglish ? "Story context: " : "物語コンテキスト: ") + worldFacts.joined(separator: " / "))
        }

        let stateFacts = [
            storyState.location.isEmpty ? nil : "\(isEnglish ? "State location" : "状態場所")=\(utf8Prefix(storyState.location, byteLimit: 64))",
            storyState.timeOfDay.isEmpty ? nil : "\(isEnglish ? "Time" : "時間")=\(utf8Prefix(storyState.timeOfDay, byteLimit: 40))",
            storyState.mood.isEmpty ? nil : "\(isEnglish ? "Mood" : "空気")=\(utf8Prefix(storyState.mood, byteLimit: 56))",
            storyState.weather.isEmpty ? nil : "\(isEnglish ? "Weather" : "天候")=\(utf8Prefix(storyState.weather, byteLimit: 48))",
            storyState.relationshipStage.isEmpty ? nil : "\(isEnglish ? "Relationship" : "関係段階")=\(utf8Prefix(storyState.relationshipStage, byteLimit: 56))",
            storyState.inventory.prefix(3).map { utf8Prefix($0.name, byteLimit: 40) }.joined(separator: ", ").isEmpty ? nil : "\(isEnglish ? "Items" : "所持品")=\(storyState.inventory.prefix(3).map { utf8Prefix($0.name, byteLimit: 40) }.joined(separator: ", "))",
            storyState.activeGoals.prefix(2).map { utf8Prefix($0, byteLimit: 56) }.joined(separator: ", ").isEmpty ? nil : "\(isEnglish ? "Goals" : "状態目標")=\(storyState.activeGoals.prefix(2).map { utf8Prefix($0, byteLimit: 56) }.joined(separator: ", "))"
        ].compactMap { $0 }
        if !stateFacts.isEmpty {
            lines.append((isEnglish ? "State snapshot: " : "状態スナップショット: ") + stateFacts.joined(separator: " / "))
        }

        let loreFacts = selectedLorebookEntries.prefix(2).map {
            "\(utf8Prefix($0.title, byteLimit: 48)): \(utf8Prefix($0.content, byteLimit: 120))"
        }
        if !loreFacts.isEmpty {
            lines.append((isEnglish ? "Relevant rules: " : "関連ルール: ") + loreFacts.joined(separator: " / "))
        }

        // ローカル実行でも、既に選別済みの記憶を小さな状態カプセルとして渡す。
        // 再検索や追加の推論はせず、最重要の3件だけに絞ってコンテキストを圧迫しない。
        let memoryFacts = selectedStoryMemories
            .sorted { $0.importance > $1.importance }
            .prefix(2)
            .map { memory in
                let owner: String
                if let characterID = memory.characterId {
                    owner = characterIndex[characterID]?.visibleName
                        ?? (isEnglish ? "Character" : "キャラクター")
                } else {
                    owner = isEnglish ? "Shared" : "共通"
                }
                let category = Self.memoryCategoryLabel(memory.category, isEnglish: isEnglish)
                return isEnglish
                    ? "Story memory [\(owner) / \(category)]: \(utf8Prefix(memory.text, byteLimit: 84))"
                    : "物語の記憶 [\(owner) / \(category)]: \(utf8Prefix(memory.text, byteLimit: 84))"
            }
            + selectedMemories
                .sorted { $0.importance > $1.importance }
                .prefix(1)
                .map { isEnglish ? "Shared memory: \(utf8Prefix($0.text, byteLimit: 84))" : "共通の記憶: \(utf8Prefix($0.text, byteLimit: 84))" }
        if !memoryFacts.isEmpty {
            lines.append(isEnglish
                         ? "Important past: \(memoryFacts.joined(separator: " / ")). Keep it consistent without explaining it."
                         : "重要な過去: \(memoryFacts.joined(separator: " / "))。説明せず自然に整合させる。")
        }

        let sceneDetails = [
            scene.location.isEmpty ? nil : "\(isEnglish ? "Location" : "場所"): \(utf8Prefix(scene.location, byteLimit: 84))",
            scene.timeOfDay.isEmpty ? nil : "\(isEnglish ? "Time" : "時間"): \(utf8Prefix(scene.timeOfDay, byteLimit: 48))",
            scene.mood.isEmpty ? nil : "\(isEnglish ? "Atmosphere" : "空気"): \(utf8Prefix(scene.mood, byteLimit: 72))",
            scene.sceneGoal.isEmpty ? nil : "\(isEnglish ? "Goal" : "目的"): \(utf8Prefix(scene.sceneGoal, byteLimit: 72))"
        ].compactMap { $0 }
        if !sceneDetails.isEmpty { lines.append((isEnglish ? "Current scene: " : "現在の場面: ") + sceneDetails.joined(separator: " / ")) }

        let characterDetails = [
            profile?.shortDescription,
            profile?.personality,
            profile?.speakingStyle,
            profile?.relationshipToUser
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .map { utf8Prefix($0, byteLimit: 72) }
        if !characterDetails.isEmpty {
            lines.append((isEnglish ? "\(npcName)'s traits: " : "\(npcName)の設定: ") + characterDetails.joined(separator: " / "))
        }

        let userProfile = LocalAssistantRuntimeBridge.userProfileAddendum
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !userProfile.isEmpty {
            lines.append(isEnglish
                         ? "User profile: \(utf8Prefix(userProfile, byteLimit: 260)). Use it naturally only when relevant."
                         : "ユーザープロフィール: \(utf8Prefix(userProfile, byteLimit: 260))。必要な時だけ自然に使う。")
        }

        lines.append("\(isEnglish ? "Story title" : "物語タイトル"): \(utf8Prefix(world.title, byteLimit: 96))")

        // LiteRT側でも1,400 UTF-8 bytesへ上限を設けている。重要な出力規則を
        // 先頭に置いたうえで、ここでも余裕を持って切り詰める。
        // The current scene, active character traits, user profile, and title
        // are mandatory for continuity.  Keep them ahead of optional lore and
        // memory snapshots so the byte cap trims background context first.
        let mandatoryPrefixes = [
            isEnglish ? "Current scene: " : "現在の場面: ",
            isEnglish ? "\(npcName)'s traits: " : "\(npcName)の設定: ",
            isEnglish ? "User profile: " : "ユーザープロフィール: ",
            isEnglish ? "Story title: " : "物語タイトル: ",
            isEnglish ? "User-controlled character: " : "ユーザー操作キャラ: "
        ]
        let header = Array(lines.prefix(2))
        let body = Array(lines.dropFirst(2))
        let mandatory = body.filter { line in
            mandatoryPrefixes.contains { line.hasPrefix($0) }
        }
        let optional = body.filter { line in
            !mandatoryPrefixes.contains { line.hasPrefix($0) }
        }
        return utf8Prefix((header + mandatory + optional).joined(separator: "\n"), byteLimit: 1_250)
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

    /// Story Detailと同じ分類器を使い、英語ルールもPromptから安全ルールへ
    /// 誤投入しない。保存形式を変えずに既存文字列を分類するための共有API。
    static func isOutputFormatRule(_ rule: String) -> Bool {
        let keywords = [
            "ナレーション",
            "1ターン",
            "キャラ発話",
            "複数キャラ",
            "会話だけ",
            "思考過程",
            "メタ発言",
            "場面",
            "描写",
            "段階的",
            "narration",
            "scene description",
            "character dialogue",
            "one turn",
            "single turn",
            "multiple character",
            "active character",
            "conversation only",
            "dialogue only",
            "dialogue alone",
            "inner thoughts",
            "internal thoughts",
            "thinking process",
            "output format",
            "response format",
            "reply only",
            "off-scene",
            "output reasoning",
            "meta commentary",
            "no bullet",
            "do not include reasoning",
            "do not include choices"
        ]
        guard !keywords.contains(where: { rule.localizedCaseInsensitiveContains($0) }) else {
            return true
        }

        // A safety rule can legitimately mention its first line (for example,
        // not revealing personal data).  Treat it as a format rule only when
        // the same sentence explicitly describes a speaker/output layout.
        let normalized = rule.localizedLowercase
        guard normalized.contains("first line") else { return false }
        let outputTerms = [
            "narration", "narrator", "dialogue", "speaker", "npc",
            "start with", "begin with", "starts with", "begins with"
        ]
        return outputTerms.contains { normalized.contains($0) }
    }

    private func utf8Prefix(_ value: String, byteLimit: Int) -> String {
        guard value.lengthOfBytes(using: .utf8) > byteLimit else { return value }
        var bytes = 0
        var result = ""
        for character in value {
            let piece = String(character)
            let pieceBytes = piece.lengthOfBytes(using: .utf8)
            guard bytes + pieceBytes <= byteLimit else { break }
            bytes += pieceBytes
            result += piece
        }
        return result
    }

    private func conversationAnchors(from messages: [StoryMessage], isEnglish: Bool) -> String {
        let older = Array(messages.dropLast(48))
        guard !older.isEmpty else { return "" }
        let anchors = older.enumerated().compactMap { index, message -> String? in
            guard index % 6 == 0 || index == older.count - 1 else { return nil }
            let speaker: String
            switch message.author {
            case .user: speaker = isEnglish ? "User" : "ユーザー"
            case .system: return nil
            case .narrator: speaker = isEnglish ? "Narration" : "ナレーション"
            case .cast(_, let name): speaker = name
            }
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return "- \(speaker): \(text.prefix(90))"
        }
        return anchors.prefix(12).joined(separator: "\n")
    }
}
