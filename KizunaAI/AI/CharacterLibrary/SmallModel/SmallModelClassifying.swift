/*
仕様:
- 役割: 補助 LLM (Gemma 3 270M 想定) による軽量分類タスクの Protocol。
  本番のRuntimeSmallModelClassifierは、選択されたlocal auxiliary modelへ接続する。
- 主な型: `SmallModelClassifying`, `SmallModelClassification`.
*/

import Foundation

enum SmallModelClassificationStatus: String, Equatable, Hashable, Sendable {
    case success
    case unavailable
    case invalidResponse
    case fallback
}

struct SmallModelClassification: Equatable, Hashable, Sendable {
    let label: String
    let confidence: Double   // 0.0...1.0
    let status: SmallModelClassificationStatus
    let failureReason: String?

    init(
        label: String,
        confidence: Double,
        status: SmallModelClassificationStatus = .success,
        failureReason: String? = nil
    ) {
        self.label = label
        self.confidence = confidence
        self.status = status
        self.failureReason = failureReason
    }
}

protocol SmallModelClassifying: AnyObject {
    /// 任意のテキストを与えられたラベル集合に分類する。
    func classify(text: String, labels: [String]) async -> SmallModelClassification
}
