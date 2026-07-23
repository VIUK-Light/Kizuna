/*
仕様:
- 役割: 3 つの安全 Protocol を統合した薄い Facade。
  キャラ作成/入力/出力の 3 経路で同じインタフェースで安全判定を呼べるようにする。
- 主な型: `SafetyPipeline`.
- 編集ポイント: 実装を Mock から本物 (Gemma 3 270M) に差し替える時、init のデフォルト値を変える。
*/

import Foundation

final class SafetyPipeline {
    private let characterChecker: CharacterSafetyChecking
    private let inputChecker: InputSafetyChecking
    private let outputChecker: OutputSafetyChecking
    private let concernClassifier: SafetyConcernClassifying

    init(
        characterChecker: CharacterSafetyChecking = MockCharacterSafetyChecker(),
        inputChecker: InputSafetyChecking = MockInputSafetyChecker(),
        outputChecker: OutputSafetyChecking = MockOutputSafetyChecker(),
        concernClassifier: SafetyConcernClassifying = ContextualSafetyConcernClassifier()
    ) {
        self.characterChecker = characterChecker
        self.inputChecker = inputChecker
        self.outputChecker = outputChecker
        self.concernClassifier = concernClassifier
    }

    func evaluateCharacter(_ c: CharacterProfile) async -> SafetyDecision {
        await characterChecker.evaluate(c)
    }
    func evaluateInput(_ text: String, character: CharacterProfile) async -> SafetyDecision {
        await inputChecker.evaluate(text, character: character)
    }
    func evaluateOutput(_ text: String, character: CharacterProfile) async -> SafetyDecision {
        await outputChecker.evaluate(text, character: character)
    }

    /// 危険な相談の可能性だけを分類する。会話の入力・出力を変更しない。
    func classifyConcern(_ text: String) async -> SafetyConcern? {
        await concernClassifier.classify(text)
    }

    /// 単一のデフォルトインスタンス (DI 不要なシンプルな呼び出し用)。
    static let shared = SafetyPipeline()
}

/// 単語1個のブラックリストではなく、相談意図・一人称・切迫性・文脈を組み合わせる初期分類器。
/// 将来 Gemma 3 270M などの専用分類モデルへ差し替える場合も、Protocolは変えない。
final class ContextualSafetyConcernClassifier: SafetyConcernClassifying {
    private struct Signal {
        let text: String
        let weight: Double
    }

    func classify(_ text: String) async -> SafetyConcern? {
        let normalized = text
            .lowercased()
            .replacingOccurrences(of: "\u{3000}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        // 物語・創作の話だけで誤検知しないため、個人的な相談の手がかりを別に見る。
        let personalContext = score(normalized, signals: [
            Signal(text: "私", weight: 1.0), Signal(text: "僕", weight: 1.0),
            Signal(text: "俺", weight: 1.0), Signal(text: "自分", weight: 0.8),
            Signal(text: "今", weight: 0.5), Signal(text: "現実", weight: 0.8),
            Signal(text: "i ", weight: 1.0), Signal(text: "i'm", weight: 1.0),
            Signal(text: "im ", weight: 1.0), Signal(text: "my ", weight: 0.8),
            Signal(text: "real life", weight: 0.8)
        ])
        let consultationContext = score(normalized, signals: [
            Signal(text: "相談", weight: 1.0), Signal(text: "悩み", weight: 1.0),
            Signal(text: "助けて", weight: 1.2), Signal(text: "聞いて", weight: 0.6),
            Signal(text: "どうすれば", weight: 0.8), Signal(text: "困って", weight: 0.8),
            Signal(text: "help", weight: 1.2), Signal(text: "advice", weight: 0.8),
            Signal(text: "what should i do", weight: 1.0), Signal(text: "worried", weight: 0.8)
        ])
        let urgency = score(normalized, signals: [
            Signal(text: "今すぐ", weight: 1.4), Signal(text: "もう", weight: 0.8),
            Signal(text: "これから", weight: 0.8), Signal(text: "止められない", weight: 1.2),
            Signal(text: "準備した", weight: 1.0), Signal(text: "手元に", weight: 0.8),
            Signal(text: "right now", weight: 1.4), Signal(text: "immediately", weight: 1.4),
            Signal(text: "can't stop", weight: 1.2)
        ])
        let fictionalContext = score(normalized, signals: [
            Signal(text: "物語", weight: 1.0), Signal(text: "キャラクター", weight: 1.0),
            Signal(text: "創作", weight: 1.0), Signal(text: "脚本", weight: 0.8),
            Signal(text: "設定", weight: 0.6), Signal(text: "ロールプレイ", weight: 1.0),
            Signal(text: "story", weight: 1.0), Signal(text: "character", weight: 1.0),
            Signal(text: "fiction", weight: 1.0), Signal(text: "script", weight: 0.8),
            Signal(text: "roleplay", weight: 1.0)
        ])

        let selfHarm = score(normalized, signals: [
            Signal(text: "死にたい", weight: 2.4), Signal(text: "消えたい", weight: 2.0),
            Signal(text: "自殺", weight: 2.6), Signal(text: "自傷", weight: 2.4),
            Signal(text: "自分を傷つけ", weight: 2.6), Signal(text: "いなくなりたい", weight: 1.8),
            Signal(text: "生きるのがつらい", weight: 1.8), Signal(text: "i want to die", weight: 2.4),
            Signal(text: "kill myself", weight: 2.6), Signal(text: "suicide", weight: 2.6),
            Signal(text: "self-harm", weight: 2.4), Signal(text: "self harm", weight: 2.4),
            Signal(text: "hurt myself", weight: 2.6), Signal(text: "don't want to live", weight: 2.2)
        ])
        // 「死にたい」「自殺したい」などの明示表現は、相談・一人称がなくても拾う。
        // ただし物語・脚本などの創作文脈だけは除外する。
        let explicitSelfHarm = normalized.contains("死にたい")
            || normalized.contains("自殺")
            || normalized.contains("自傷")
            || normalized.contains("自分を傷つけ")
            || normalized.contains("消えたい")
            || normalized.contains("いなくなりたい")
            || normalized.contains("i want to die")
            || normalized.contains("kill myself")
            || normalized.contains("suicide")
            || normalized.contains("self-harm")
            || normalized.contains("self harm")
            || normalized.contains("hurt myself")
        if selfHarm >= 2.0,
           (personalContext + consultationContext >= 1.0 || explicitSelfHarm),
           fictionalContext == 0 || personalContext >= 1.5 {
            return concern(
                category: .selfHarm,
                level: urgency >= 1.2 ? .urgent : .elevated,
                confidence: confidence(score: selfHarm + personalContext + consultationContext),
                message: "つらさや自分を傷つけたい気持ちがあるなら、ひとりで抱え込まず、身近な人や専門の相談先につながることも選べます。"
            )
        }

        let abuseOrViolence = score(normalized, signals: [
            Signal(text: "殴ら", weight: 1.8), Signal(text: "暴力", weight: 1.8),
            Signal(text: "脅され", weight: 1.8), Signal(text: "監禁", weight: 2.0),
            Signal(text: "逃げたい", weight: 1.4), Signal(text: "ストーカー", weight: 1.6),
            Signal(text: "怖い", weight: 0.8), Signal(text: "被害", weight: 1.0),
            Signal(text: "beaten", weight: 1.8), Signal(text: "violence", weight: 1.8),
            Signal(text: "threatened", weight: 1.8), Signal(text: "kidnapped", weight: 2.0),
            Signal(text: "stalker", weight: 1.6), Signal(text: "abused", weight: 1.8),
            Signal(text: "i'm scared", weight: 0.8), Signal(text: "im scared", weight: 0.8)
        ])
        let explicitSafetyThreat = normalized.contains("助けて")
            || normalized.contains("逃げたい")
            || normalized.contains("監禁")
            || normalized.contains("ストーカー")
        let abuseThreshold = explicitSafetyThreat ? 1.6 : 2.0
        if abuseOrViolence >= abuseThreshold,
           (personalContext + consultationContext >= 1.0 || explicitSafetyThreat),
           fictionalContext == 0 || personalContext >= 1.5 {
            return concern(
                category: .violenceOrAbuse,
                level: urgency >= 1.2 ? .urgent : .elevated,
                confidence: confidence(score: abuseOrViolence + personalContext + consultationContext),
                message: "身の安全に関わることなら、会話だけで抱えず、危険のない場所へ移動して、信頼できる人や公的な相談先につながってください。"
            )
        }

        let medicalUrgency = score(normalized, signals: [
            Signal(text: "息ができない", weight: 2.4), Signal(text: "意識がない", weight: 2.4),
            Signal(text: "大量出血", weight: 2.4), Signal(text: "胸が痛い", weight: 1.8),
            Signal(text: "救急", weight: 1.4), Signal(text: "倒れ", weight: 1.2),
            Signal(text: "can't breathe", weight: 2.4), Signal(text: "unconscious", weight: 2.4),
            Signal(text: "heavy bleeding", weight: 2.4), Signal(text: "chest pain", weight: 1.8),
            Signal(text: "emergency", weight: 1.4)
        ])
        let explicitMedicalEmergency = normalized.contains("息ができない")
            || normalized.contains("意識がない")
            || normalized.contains("大量出血")
        if medicalUrgency >= 2.0,
           (personalContext + consultationContext >= 0.8 || explicitMedicalEmergency) {
            return concern(
                category: .medicalUrgency,
                level: .urgent,
                confidence: confidence(score: medicalUrgency + personalContext + consultationContext),
                message: "緊急性のある体調の話なら、AIの返答を待たず、地域の救急窓口や医療機関へ連絡してください。"
            )
        }

        let distress = score(normalized, signals: [
            Signal(text: "つらい", weight: 1.0), Signal(text: "苦しい", weight: 1.0),
            Signal(text: "限界", weight: 1.2), Signal(text: "しんどい", weight: 1.0),
            Signal(text: "不安", weight: 0.7), Signal(text: "孤独", weight: 0.9),
            Signal(text: "眠れない", weight: 0.8), Signal(text: "overwhelmed", weight: 1.0),
            Signal(text: "depressed", weight: 1.0), Signal(text: "anxious", weight: 0.8),
            Signal(text: "lonely", weight: 0.9), Signal(text: "can't sleep", weight: 0.8)
        ])
        if distress >= 2.0, personalContext + consultationContext >= 1.0,
           fictionalContext == 0 || personalContext >= 1.5 {
            return concern(
                category: .emotionalDistress,
                level: .supportive,
                confidence: confidence(score: distress + personalContext + consultationContext),
                message: "悩みがあるなら、ここで話すだけでなく、信頼できる人や専門の相談先に話してみることもできます。"
            )
        }

        return nil
    }

    private func score(_ text: String, signals: [Signal]) -> Double {
        signals.reduce(0) { partial, signal in
            text.contains(signal.text) ? partial + signal.weight : partial
        }
    }

    private func confidence(score: Double) -> Double {
        min(0.99, max(0.55, 0.45 + score * 0.08))
    }

    private func concern(
        category: SafetyConcernCategory,
        level: SafetyConcernLevel,
        confidence: Double,
        message: String
    ) -> SafetyConcern {
        SafetyConcern(
            category: category,
            level: level,
            confidence: confidence,
            message: message,
            resources: SafetyConcern.defaultResources
        )
    }
}
