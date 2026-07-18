/*
仕様:
- 役割: CharacterProfile + Lorebook + 選別メモリー + 直近会話 + ユーザー入力 + SafetyDecision を
  組み立てて Gemma 4 E4B に渡す system prompt 文字列を作る。
- 主な型: `PromptBuilder` (struct).
- 編集ポイント: セクション構造、注入順、メモリーの整形、末尾のキャラ名プライム。
- 重要: 末尾を `\(character.name):` でプライムすることで、思考漏れ (構造化テキストや「(案)」) を抑止する。
*/

import Foundation

struct PromptBuilder {
    /// 直近会話に渡す既存メッセージ型は PersonaMessage を再利用する。
    func build(
        character: CharacterProfile,
        lorebook: CharacterLorebook?,
        selectedMemories: [CharacterMemory],
        recentMessages: [PersonaMessage],
        userInput: String,
        safetyDecision: SafetyDecision?
    ) -> String {
        var sections: [String] = []

        // 冒頭
        sections.append(
            """
            今、LINE で会話しています。あなたは AI ではなく、下記の人物そのものです。
            頭で考えたことは出力に書きません。最初の1文字目から、その人物が LINE で送信する短い本文を返します。
            """
        )

        // あなた
        var youLines: [String] = []
        youLines.append("名前: \(character.displayName.isEmpty ? character.name : character.displayName)")
        if !character.shortDescription.isEmpty { youLines.append("ひとこと: \(character.shortDescription)") }
        if !character.personality.isEmpty { youLines.append("性格: \(character.personality)") }
        if !character.speakingStyle.isEmpty { youLines.append("口調: \(character.speakingStyle)") }
        if !character.background.isEmpty { youLines.append("背景: \(character.background)") }
        if !character.relationshipToUser.isEmpty { youLines.append("相手との関係: \(character.relationshipToUser)") }
        if !character.scenario.isEmpty { youLines.append("今のシーン: \(character.scenario)") }
        sections.append("## あなた\n" + youLines.joined(separator: "\n"))

        // ジャンル / 関係性
        var hintLines: [String] = []
        let categoryHint = character.category.promptHint
        if !categoryHint.isEmpty { hintLines.append(categoryHint) }
        let genreHint = character.relationshipGenre.promptHint
        if !genreHint.isEmpty { hintLines.append(genreHint) }
        if !hintLines.isEmpty {
            sections.append("## ジャンル・関係性\n" + hintLines.joined(separator: "\n"))
        }

        // 世界観 (Lorebook)
        if let lb = lorebook, !lb.isEmpty {
            var loreLines: [String] = []
            if !lb.worldSetting.isEmpty { loreLines.append("世界観: \(lb.worldSetting)") }
            if !lb.importantPeople.isEmpty { loreLines.append("登場人物: " + lb.importantPeople.joined(separator: ", ")) }
            if !lb.importantPlaces.isEmpty { loreLines.append("場所: " + lb.importantPlaces.joined(separator: ", ")) }
            if !lb.importantEvents.isEmpty { loreLines.append("出来事: " + lb.importantEvents.joined(separator: ", ")) }
            if !lb.worldRules.isEmpty { loreLines.append("世界のルール:\n" + lb.worldRules.map { "- " + $0 }.joined(separator: "\n")) }
            if !lb.forbiddenBreaks.isEmpty { loreLines.append("壊さない約束:\n" + lb.forbiddenBreaks.map { "- " + $0 }.joined(separator: "\n")) }
            sections.append("## 世界観\n" + loreLines.joined(separator: "\n"))
        }

        // メモリー (相手について覚えていること)
        if !selectedMemories.isEmpty {
            let lines = selectedMemories.prefix(5).map { "- " + $0.text }.joined(separator: "\n")
            sections.append(
                """
                ## あなたが相手について覚えていること
                \(lines)
                (これらを明示的に「覚えてるよ」と言わず、自然な会話の中で活かす)
                """
            )
        }

        // 直近会話
        if !recentMessages.isEmpty {
            let convo = recentMessages.map { msg -> String in
                switch msg.role {
                case .user:
                    return "相手: " + msg.text

                case .assistant:
                    return "\(character.displayName.isEmpty ? character.name : character.displayName): " + msg.text

                case .narrator:
                    return "ナレーション: " + msg.text
                }
            }.joined(separator: "\n")
            sections.append("## 直近の会話\n" + convo)
        }

        // ルール (キャラ固有 + Genre + Category + SafetyDecision)
        var rules: [String] = []
        var seen = Set<String>()
        func push(_ r: String) {
            let t = r.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, seen.insert(t).inserted { rules.append(t) }
        }
        character.resolvedSafetyRules.forEach(push)
        character.rules.forEach(push)
        safetyDecision?.addedPromptRules.forEach(push)
        // 共通の出力形式ルール
        push("LINE で送る短い本文のみ。1〜2 文、長くて 3 文まで。改行 0〜1 個。")
        push("記号・箇条書き・見出し・コードブロック・Markdown・引用符での囲みは禁止。")
        push("「私は AI / 言語モデル / アシスタント」のような自己言及や、キャラを破る発言をしない。")
        push("思考・計画・分析・(案)・選択肢の列挙・前置きを書かない。最初の1文字目から本文を始める。")

        if !rules.isEmpty {
            sections.append("## 守ること\n" + rules.map { "- " + $0 }.joined(separator: "\n"))
        }

        // 今回の相手の発言 + プライム。旧 PersonaSettings 経路の system prompt だけを作る場合は空で渡せる。
        let trimmedUserInput = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedUserInput.isEmpty {
            sections.append("## 今回の相手の発言\n" + trimmedUserInput)
        }
        sections.append("\(character.displayName.isEmpty ? character.name : character.displayName):")

        return sections.joined(separator: "\n\n")
    }
}
