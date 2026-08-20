/*
仕様:
- 役割: SmallModelClassifying の Mock 実装。各ラベルとテキストの部分一致をスコアにする雑実装。
  実モデル接続前の挙動確認用。
- 主な型: `MockSmallModelClassifier`.
*/

import Foundation

final class MockSmallModelClassifier: SmallModelClassifying {
    func classify(text: String, labels: [String]) async -> SmallModelClassification {
        guard !labels.isEmpty else {
            return SmallModelClassification(label: "", confidence: 0.0)
        }
        let lower = text.lowercased()
        var best: (label: String, score: Double) = (labels[0], 0.0)
        for label in labels {
            let words = label.lowercased().split(separator: "_")
            var hits = 0
            for w in words where lower.contains(String(w)) { hits += 1 }
            let score = Double(hits) / Double(max(words.count, 1))
            if score > best.score { best = (label, score) }
        }
        // 一致が無い時は最初のラベルを低信頼で返す。
        return SmallModelClassification(
            label: best.label,
            confidence: best.score == 0 ? 0.25 : min(1.0, 0.4 + best.score * 0.6)
        )
    }
}

/// Runs auxiliary prompts through the currently selected local runtime. The
/// existing Mock remains an explicit fallback when no validated local model is
/// executable; production composition no longer pretends that the fallback
/// is a 270M model.
enum LocalAuxiliaryAI {
    static func generate(prompt: String, maxOutputTokens: Int = 192) async -> String? {
        guard LocalAssistantModelManager.shared.runtimeAvailability == .executable else {
            return nil
        }
        let result = await LocalAssistantRuntimeBridge.shared.generateReply(
            prompt: prompt,
            contextPrompt: nil,
            coachMode: .studio,
            reasoningMode: .fast,
            researchMode: .off,
            childAge: 12,
            pageInfo: nil,
            safetySnapshot: nil,
            advancedSettings: GemmaAdvancedSettings.default,
            overrideSystemPrompt: "Return only the requested compact result. Do not add explanations.",
            onUpdate: nil
        )
        let text = result.text?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : String(text.prefix(maxOutputTokens * 4))
    }

    static func normalized(_ text: String) -> String {
        text
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Production composition for lightweight classification. It asks the real
/// local runtime for a label and confidence, then falls back explicitly when
/// the runtime is unavailable or returns an invalid contract.
final class RuntimeSmallModelClassifier: SmallModelClassifying {
    private let fallback: SmallModelClassifying

    init(fallback: SmallModelClassifying = MockSmallModelClassifier()) {
        self.fallback = fallback
    }

    func classify(text: String, labels: [String]) async -> SmallModelClassification {
        guard !labels.isEmpty else { return SmallModelClassification(label: "", confidence: 0) }
        let prompt = [
            "Choose exactly one label from: " + labels.joined(separator: ", "),
            "Return exactly LABEL|CONFIDENCE where CONFIDENCE is 0 to 1.",
            "Text: " + text
        ].joined(separator: "\n")
        guard let raw = await LocalAuxiliaryAI.generate(prompt: prompt, maxOutputTokens: 48) else {
            return await fallback.classify(text: text, labels: labels)
        }
        let parts = LocalAuxiliaryAI.normalized(raw).split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let label = labels.first(where: { $0.caseInsensitiveCompare(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }),
              let confidence = Double(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)),
              confidence.isFinite else {
            return await fallback.classify(text: text, labels: labels)
        }
        return SmallModelClassification(label: label, confidence: min(max(confidence, 0), 1))
    }
}
