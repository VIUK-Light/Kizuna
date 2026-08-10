/*
仕様:
- 役割: 安全性 Protocol の Mock 実装 (ルールベース + キーワード判定)。
  実モデル接続前の挙動確認や、軽量フォールバックとして使う。
- 主な型: MockCharacterSafetyChecker, MockInputSafetyChecker, MockOutputSafetyChecker.
*/

import Foundation

private func safetyCopy(japanese: String, english: String) -> String {
    KizunaCopy.text(japanese: japanese, english: english)
}

/// 危険キーワード辞書 (Mock 用)。本実装では SML/Gemma 3 270M に置き換える。
fileprivate enum SafetyKeywords {
    static let crimeHowTo = [
        "殺し方", "爆弾の作り方", "爆発物", "毒物の作り方", "詐欺の手口", "ハッキングの手順",
        "麻薬の作り方", "違法薬物"
    ]
    static let selfHarm = ["死にたい", "消えたい", "自殺", "自傷", "リストカット"]
    static let sexual = ["セックス", "性行為", "裸"]
    static let minorRomance = ["小学生", "幼児", "中学生"]
    static let personalInfo = ["住所", "電話番号", "本名", "口座", "パスワード"]
    static let harassment = ["殺す", "死ね", "クズ", "消えろ"]
}

// MARK: - Character

final class MockCharacterSafetyChecker: CharacterSafetyChecking {
    func evaluate(_ c: CharacterProfile) async -> SafetyDecision {
        var reasons: [String] = []
        var domains: [SafetyDomain] = []
        var severity: SafetySeverity = .info
        var action: SafetyAction = .allow
        var addedRules: [String] = []

        let combinedText = [
            c.name, c.displayName, c.shortDescription, c.personality, c.speakingStyle,
            c.background, c.relationshipToUser, c.scenario, c.firstMessage
        ].joined(separator: " ")

        // 犯罪手順系
        if SafetyKeywords.crimeHowTo.contains(where: combinedText.contains) {
            reasons.append(safetyCopy(japanese: "犯罪行為の具体的な手順が含まれている可能性があります。", english: "This profile may contain actionable instructions for criminal activity."))
            domains.append(.crime)
            severity = .block
            action = .block
        }

        // 未成年 × sexual の組み合わせは block
        let hasMinor = SafetyKeywords.minorRomance.contains(where: combinedText.contains)
        let hasSexual = SafetyKeywords.sexual.contains(where: combinedText.contains)
        if hasMinor && hasSexual {
            reasons.append(safetyCopy(japanese: "未成年と性的内容を組み合わせることはできません。", english: "A minor character cannot be combined with sexual content."))
            domains.append(contentsOf: [.minors, .sexual])
            severity = .block
            action = .block
        } else if hasSexual && c.safetyRating == .general {
            reasons.append(safetyCopy(japanese: "性的表現が含まれるため safetyRating の再検討を推奨します。", english: "Sexual content is present; consider reviewing the safety rating."))
            domains.append(.sexual)
            severity = .warning
            action = max(action, .warn)
        }

        // family/sibling 系 + 恋愛キーワード → requireEdit
        let isFamilyGroup = c.category.group == .family
        let isSiblingGenre = c.relationshipGenre == .sibling || c.relationshipGenre == .family
        let romanceWord = ["恋人", "恋愛", "キス", "好きすぎて", "デート"]
        let hasRomance = romanceWord.contains(where: combinedText.contains)
        if (isFamilyGroup || isSiblingGenre) && hasRomance {
            reasons.append(safetyCopy(japanese: "家族・兄弟姉妹的な関係性で恋愛表現が含まれています。", english: "Romantic content is present in a family or sibling relationship."))
            domains.append(contentsOf: [.family, .romance])
            severity = .warning
            action = max(action, .requireEdit)
            addedRules.append(safetyCopy(japanese: "家族関係を恋愛化しないでください。", english: "Do not turn a family relationship into a romance."))
        }

        // underworld 系 + 過激な犯罪手順 (再チェック)
        if c.category.group == .underworld {
            if SafetyKeywords.crimeHowTo.contains(where: combinedText.contains) {
                if action != .block {
                    action = .block
                    severity = .block
                    reasons.append(safetyCopy(japanese: "裏社会設定でも犯罪手順は禁止です。", english: "Criminal instructions are not allowed, even in an underworld setting."))
                    domains.append(.crime)
                }
            } else {
                addedRules.append(safetyCopy(japanese: "裏社会の雰囲気は雰囲気に留め、犯罪手順は出さない。", english: "Keep an underworld setting atmospheric; do not provide criminal instructions."))
            }
        }

        // yandere/secret_relationship 等の関係性に追加ルール
        if [.yandereLight, .secretRelationship, .arrangedRelationship, .fakeRelationship,
            .loveHate, .jealousPartner].contains(c.category) {
            addedRules.append(safetyCopy(japanese: "強制・脅迫・監禁・支配を肯定的に描かない。", english: "Do not portray coercion, threats, captivity, or control positively."))
        }

        if action == .allow && c.shortDescription.isEmpty && c.personality.isEmpty {
            // 内容が空すぎる場合は警告
            reasons.append(safetyCopy(japanese: "プロフィールがほぼ空です。性格や関係性を記述してください。", english: "The profile is nearly empty. Add a personality or relationship description."))
            severity = .warning
            action = .warn
        }

        return SafetyDecision(
            action: action,
            reasons: reasons,
            riskDomains: Array(Set(domains)),
            severity: severity,
            rewrittenText: nil,
            addedPromptRules: addedRules
        )
    }
}

// MARK: - Input

final class MockInputSafetyChecker: InputSafetyChecking {
    func evaluate(_ text: String, character: CharacterProfile) async -> SafetyDecision {
        var reasons: [String] = []
        var domains: [SafetyDomain] = []
        var severity: SafetySeverity = .info
        var action: SafetyAction = .allow
        var addedRules: [String] = []
        var rewritten: String? = nil

        // 自傷示唆 → 寄り添う応答に誘導
        if SafetyKeywords.selfHarm.contains(where: text.contains) {
            reasons.append(safetyCopy(japanese: "自傷の示唆を検知しました。", english: "The message may indicate self-harm."))
            domains.append(.selfHarm)
            severity = .warning
            action = .warn
            addedRules.append(safetyCopy(japanese: "つらい気持ちに共感し、安全と専門窓口 (例: いのちの電話) の存在をやさしく伝える。具体的な手段を示唆しない。", english: "Respond with empathy, gently mention safety and professional support, and never suggest specific methods."))
        }

        // 個人情報の要求 → 警告
        if SafetyKeywords.personalInfo.contains(where: text.contains) {
            reasons.append(safetyCopy(japanese: "個人情報のやり取りが含まれている可能性があります。", english: "The message may involve sharing personal information."))
            domains.append(.personalInfo)
            severity = .warning
            action = max(action, .warn)
            addedRules.append(safetyCopy(japanese: "個人情報は会話に残さない。具体的な住所や口座番号などを尋ねない/答えない。", english: "Do not retain personal information or ask for or provide specific addresses or account numbers."))
        }

        // 犯罪手順依頼 → block
        if SafetyKeywords.crimeHowTo.contains(where: text.contains) {
            reasons.append(safetyCopy(japanese: "犯罪行為の手順依頼を検知しました。", english: "The message requests instructions for criminal activity."))
            domains.append(.crime)
            severity = .block
            action = .block
            rewritten = safetyCopy(japanese: "ごめん、その話題には乗れないな。別の話、しよ?", english: "I can't help with that topic. Could we talk about something else?")
        }

        // ハラスメント → 軽い soften
        if SafetyKeywords.harassment.contains(where: text.contains) {
            reasons.append(safetyCopy(japanese: "攻撃的な表現が含まれています。", english: "The message contains aggressive language."))
            domains.append(.harassment)
            severity = .warning
            action = max(action, .soften)
        }

        return SafetyDecision(
            action: action,
            reasons: reasons,
            riskDomains: Array(Set(domains)),
            severity: severity,
            rewrittenText: rewritten,
            addedPromptRules: addedRules
        )
    }
}

// MARK: - Output

final class MockOutputSafetyChecker: OutputSafetyChecking {
    func evaluate(_ text: String, character: CharacterProfile) async -> SafetyDecision {
        var reasons: [String] = []
        var domains: [SafetyDomain] = []
        var severity: SafetySeverity = .info
        var action: SafetyAction = .allow
        var rewritten: String? = nil

        if SafetyKeywords.crimeHowTo.contains(where: text.contains) {
            reasons.append(safetyCopy(japanese: "出力に犯罪手順が含まれています。", english: "The response contains criminal instructions."))
            domains.append(.crime)
            severity = .block
            action = .block
            rewritten = safetyCopy(japanese: "うまく言えないけど、それは話したくないな。別の話にしよう?", english: "I can't continue with that. Let's talk about something else.")
        }

        if SafetyKeywords.sexual.contains(where: text.contains), character.safetyRating == .general {
            reasons.append(safetyCopy(japanese: "一般向け設定で性的表現が含まれています。", english: "Sexual content is not allowed for a general-audience character."))
            domains.append(.sexual)
            severity = .warning
            action = max(action, .soften)
        }

        return SafetyDecision(
            action: action,
            reasons: reasons,
            riskDomains: Array(Set(domains)),
            severity: severity,
            rewrittenText: rewritten,
            addedPromptRules: []
        )
    }
}

// MARK: - SafetyAction 大小比較 (deciding the strictest)

extension SafetyAction: Comparable {
    private var rank: Int {
        switch self {
        case .allow: return 0
        case .warn: return 1
        case .soften: return 2
        case .requireEdit: return 3
        case .block: return 4
        }
    }
    public static func < (lhs: SafetyAction, rhs: SafetyAction) -> Bool {
        lhs.rank < rhs.rank
    }
}
