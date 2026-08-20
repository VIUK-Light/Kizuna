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

/// Identifies the JSON file used by a memory repository. The story retry
/// transaction may only combine repositories that expose matching identities.
protocol LocalJSONStorageIdentityProviding: AnyObject {
    var storageURL: URL { get }
}

protocol LocalJSONMemoryFileIdentityProviding: LocalJSONStorageIdentityProviding {
    var fileName: String { get }
}

final class LocalJSONMemoryRepository: MemoryRepository, LocalJSONMemoryFileIdentityProviding {
    let storageURL: URL
    let fileName: String
    private let store: LocalJSONStore<CharacterMemory>
    private let perCharacterLimit = 60   // キャラごとの上限

    init(
        fileName: String = "memories.json",
        storageURL: URL = KizunaDataMigration.characterLibraryURL
    ) {
        self.fileName = fileName
        self.storageURL = storageURL
        self.store = LocalJSONStore<CharacterMemory>(
            fileName: fileName,
            baseURL: storageURL
        )
    }

    func fetchMemories(characterId: UUID) async throws -> [CharacterMemory] {
        // 1件の旧形式/破損レコードで全メモリーを空に見せない。
        // 読み取り時は救出した有効レコードを使い、元ファイルの書き戻しは
        // mutate/save が成功した時だけ行う。
        let all = try await store.loadRecoveringCorruptRecords()
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
        guard !LocalJSONCharacterRepository.isCharacterDeletionPending(memory.characterId) else {
            throw CharacterRepositoryError.deletionInProgress(memory.characterId)
        }
        let perCharacterLimit = self.perCharacterLimit
        try await store.mutate { all in
            // The deletion marker can be written while this save is waiting
            // for the memory-file lock. Re-check inside the transaction so a
            // late in-flight Persona/Story extraction cannot recreate a
            // character-owned memory after deletion starts.
            guard !LocalJSONCharacterRepository.isCharacterDeletionPending(memory.characterId) else {
                throw CharacterRepositoryError.deletionInProgress(memory.characterId)
            }
            Self.mergeMemory(
                memory,
                into: &all,
                perCharacterLimit: perCharacterLimit
            )
        }
    }

    /// Applies one memory save to an already-loaded collection. The helper is
    /// shared with the cross-file Story memory retry transaction so the
    /// regular repository and the retry path keep identical dedupe and limit
    /// semantics.
    static func mergeMemory(
        _ memory: CharacterMemory,
        into all: inout [CharacterMemory],
        perCharacterLimit: Int = 60
    ) {
        // dedupe: 同じ characterId で text 正規化が一致するものは置き換え
        let normalized = Self.normalize(memory.text)
        if let idx = all.firstIndex(where: {
            $0.characterId == memory.characterId
                && Self.normalize($0.text) == normalized
        }) {
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
            return Array(sorted.prefix(max(1, perCharacterLimit)))
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

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
