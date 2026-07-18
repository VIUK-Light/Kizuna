/*
仕様:
- 役割: MemorySelecting / MemorySummarizing の Mock 実装。
  Selector はキーワード重なり + LRU + importance、Summarizer は単純なパターン抽出。
- 主な型: MockMemorySelector, MockMemorySummarizer.
*/

import Foundation

// MARK: - Selecting

final class MockMemorySelector: MemorySelecting {
    func select(query: String, candidates: [CharacterMemory], topK: Int) async -> [CharacterMemory] {
        guard !candidates.isEmpty else { return [] }
        let qTokens = tokenize(query)
        let scored: [(memory: CharacterMemory, score: Double)] = candidates.map { mem in
            var score = mem.importance * 0.5
            let memTokens = tokenize(mem.text)
            let overlap = qTokens.intersection(memTokens).count
            score += Double(overlap) * 0.4
            // 最近使った/作ったものに小さなブースト
            let key = mem.lastUsedAt ?? mem.createdAt
            let age = Date().timeIntervalSince(key)
            if age < 60 * 60 * 24 * 7 { score += 0.1 }
            return (mem, score)
        }
        return scored
            .sorted { $0.score > $1.score }
            .prefix(topK)
            .map { $0.memory }
    }

    private func tokenize(_ s: String) -> Set<String> {
        let normalized = s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && $0.count >= 2 }
        return Set(normalized)
    }
}

// MARK: - Summarizing

final class MockMemorySummarizer: MemorySummarizing {
    /// 「私は〇〇」「僕は〇〇」「俺は〇〇」「うちは〇〇」のような自己紹介パターンを 1 件だけ拾う。
    func extract(userText: String, assistantText: String, character: CharacterProfile) async -> [CharacterMemory] {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return [] }

        let firstPersonMarkers = ["私は", "わたしは", "僕は", "ぼくは", "俺は", "おれは", "うちは"]
        for marker in firstPersonMarkers {
            if let r = trimmed.range(of: marker) {
                // marker 以降を 30 文字程度抜き出して fact 化
                let after = trimmed[r.upperBound...]
                let snippet = String(after.prefix(30)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !snippet.isEmpty else { continue }
                let fact = "ユーザーは" + snippet
                return [
                    CharacterMemory(
                        characterId: character.id,
                        text: fact,
                        category: .userFact,
                        importance: 0.7,
                        source: .userInput
                    )
                ]
            }
        }

        // 「好き」「嫌い」が含まれるなら preference として 1 件
        if trimmed.contains("好き") || trimmed.contains("嫌い") {
            return [
                CharacterMemory(
                    characterId: character.id,
                    text: trimmed.prefix(40).description,
                    category: .preference,
                    importance: 0.55,
                    source: .userInput
                )
            ]
        }
        return []
    }
}
