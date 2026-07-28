/*
仕様:
- 役割: CharacterMemory の永続化。characterId でフィルタした取得をサポート。
- 主な型: `MemoryRepository` (protocol), `LocalJSONMemoryRepository`.
*/

import Foundation

protocol MemoryRepository: AnyObject {
    func fetchMemories(characterId: UUID) async throws -> [CharacterMemory]
    func saveMemory(_ memory: CharacterMemory) async throws
    func deleteMemory(id: UUID) async throws
    func deleteAllMemories(characterId: UUID) async throws
    func markUsed(ids: [UUID]) async throws
}

final class LocalJSONMemoryRepository: MemoryRepository {
    private let store = LocalJSONStore<CharacterMemory>(fileName: "memories.json")
    private let perCharacterLimit = 60   // キャラごとの上限

    func fetchMemories(characterId: UUID) async throws -> [CharacterMemory] {
        let all = try await store.load()
        return all
            .filter { $0.characterId == characterId }
            .sorted { lhs, rhs in
                let lhsKey = lhs.lastUsedAt ?? lhs.createdAt
                let rhsKey = rhs.lastUsedAt ?? rhs.createdAt
                if lhs.importance != rhs.importance { return lhs.importance > rhs.importance }
                return lhsKey > rhsKey
            }
    }

    func saveMemory(_ memory: CharacterMemory) async throws {
        // dedupe: 同じ characterId で text 正規化が一致するものは置き換え
        try await store.mutate { all in
            let normalized = normalize(memory.text)
            if let idx = all.firstIndex(where: { $0.characterId == memory.characterId && normalize($0.text) == normalized }) {
                var existing = all[idx]
                // importance は上書き (max を取る)、lastUsedAt は今に更新
                existing.importance = max(existing.importance, memory.importance)
                existing.lastUsedAt = Date()
                all[idx] = existing
            } else {
                all.append(memory)
            }
            // 上限超過時に古い lastUsedAt から削除
            let byCharacter = Dictionary(grouping: all, by: { $0.characterId })
            all = byCharacter.values.flatMap { items in
                let sorted = items.sorted { lhs, rhs in
                    let lhsKey = lhs.lastUsedAt ?? lhs.createdAt
                    let rhsKey = rhs.lastUsedAt ?? rhs.createdAt
                    if lhs.importance != rhs.importance { return lhs.importance > rhs.importance }
                    return lhsKey > rhsKey
                }
                return Array(sorted.prefix(perCharacterLimit))
            }
        }
    }

    func deleteMemory(id: UUID) async throws {
        try await store.delete(matching: { $0.id == id })
    }

    func deleteAllMemories(characterId: UUID) async throws {
        try await store.delete(matching: { $0.characterId == characterId })
    }

    func markUsed(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        try await store.mutate { all in
            let now = Date()
            for i in all.indices where ids.contains(all[i].id) {
                all[i].lastUsedAt = now
            }
        }
    }

    private func normalize(_ s: String) -> String {
        s.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
