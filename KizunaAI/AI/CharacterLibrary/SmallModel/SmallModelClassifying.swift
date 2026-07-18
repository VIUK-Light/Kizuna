/*
仕様:
- 役割: 補助 LLM (Gemma 3 270M 想定) による軽量分類タスクの Protocol。
- 主な型: `SmallModelClassifying`, `SmallModelClassification`.
*/

import Foundation

struct SmallModelClassification: Equatable, Hashable {
    let label: String
    let confidence: Double   // 0.0...1.0
}

protocol SmallModelClassifying: AnyObject {
    /// 任意のテキストを与えられたラベル集合に分類する。
    func classify(text: String, labels: [String]) async -> SmallModelClassification
}
