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
