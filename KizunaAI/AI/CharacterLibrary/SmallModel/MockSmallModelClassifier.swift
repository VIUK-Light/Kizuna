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

/// Runs auxiliary prompts through the currently selected local runtime. When
/// no validated artifact is executable this returns nil; production callers do
/// not convert that absence into a fabricated 270M result.
enum LocalAuxiliaryAI {
    @MainActor
    static func generate(
        prompt: String,
        maxOutputTokens: Int = 192,
        role: AIModelRole = .classifier
    ) async -> String? {
        let modelManager = LocalAssistantModelManager.shared
        let registry = AIModelRegistry.shared
        let configurations = registry.configurations(for: role)
        let tuningStore = AIModelTuningStore.shared
        let dedicatedAuxiliaryModelID = modelManager.auxiliaryModelID
        let preferred: AIModelConfiguration? = {
            if let auxiliaryID = dedicatedAuxiliaryModelID {
                guard let model = modelManager.installedModels.first(where: { $0.id == auxiliaryID }) else {
                    AppLog.error(
                        "[LocalAuxiliaryAI] dedicated local artifact is missing id=%@",
                        auxiliaryID
                    )
                    return nil
                }
                return registry.localArtifactConfiguration(
                    artifactID: model.id,
                    displayName: model.displayName,
                    roles: [role]
                )
            } else {
                if tuningStore.preferences.mode == .advanced,
                   let configuredID = tuningStore.preferredConfigurationID(for: role),
                   !configurations.contains(where: { $0.id == configuredID }) {
                    AppLog.error(
                        "[LocalAuxiliaryAI] configured model is not registered for role=%@ id=%@",
                        role.rawValue,
                        configuredID.uuidString
                    )
                    return nil
                }
                return tuningStore.configurationIDForCurrentMode(
                    for: role,
                    configurations: configurations,
                    fallbackProviderID: nil
                ).flatMap { preferredID in
                    configurations.first(where: { $0.id == preferredID })
                }
            }
        }()
        let request = AIGenerationRequest(
            systemPrompt: "Return only the requested compact result. Do not add explanations.",
            userPrompt: prompt,
            temperature: 0.1,
            maxOutputTokens: maxOutputTokens
        )
        guard let result = try? await AIModelRouter.shared.generate(
            request: request,
            role: role,
            preferredConfigurationID: preferred?.id,
            allowsFallback: dedicatedAuxiliaryModelID == nil
                && tuningStore.allowsFallbackForCurrentMode
        ) else {
            return nil
        }
        let text = result.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
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
    /// A fallback is injectable for previews/tests, but production defaults to
    /// nil so an unavailable 270M artifact never masquerades as a model result.
    private let fallback: SmallModelClassifying?

    init(fallback: SmallModelClassifying? = nil) {
        self.fallback = fallback
    }

    func classify(text: String, labels: [String]) async -> SmallModelClassification {
        guard !labels.isEmpty else { return SmallModelClassification(label: "", confidence: 0) }
        let prompt = [
            "Choose exactly one label from: " + labels.joined(separator: ", "),
            "Return exactly LABEL|CONFIDENCE where CONFIDENCE is 0 to 1.",
            "Text: " + text
        ].joined(separator: "\n")
        guard let raw = await LocalAuxiliaryAI.generate(prompt: prompt, maxOutputTokens: 48, role: .classifier) else {
            if let fallbackResult = await fallback?.classify(text: text, labels: labels) {
                return SmallModelClassification(
                    label: fallbackResult.label,
                    confidence: fallbackResult.confidence,
                    status: .fallback,
                    failureReason: "The local auxiliary model was unavailable."
                )
            }
            return SmallModelClassification(
                label: "",
                confidence: 0,
                status: .unavailable,
                failureReason: "The local auxiliary model was unavailable."
            )
        }
        let parts = LocalAuxiliaryAI.normalized(raw).split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let label = labels.first(where: { $0.caseInsensitiveCompare(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }),
              let confidence = Double(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)),
              confidence.isFinite else {
            if let fallbackResult = await fallback?.classify(text: text, labels: labels) {
                return SmallModelClassification(
                    label: fallbackResult.label,
                    confidence: fallbackResult.confidence,
                    status: .fallback,
                    failureReason: "The local auxiliary model returned an invalid contract."
                )
            }
            return SmallModelClassification(
                label: "",
                confidence: 0,
                status: .invalidResponse,
                failureReason: "The local auxiliary model returned an invalid contract."
            )
        }
        return SmallModelClassification(
            label: label,
            confidence: min(max(confidence, 0), 1),
            status: .success
        )
    }
}
