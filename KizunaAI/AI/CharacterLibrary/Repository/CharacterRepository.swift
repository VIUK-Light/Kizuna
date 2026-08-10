/*
仕様:
- 役割: CharacterProfile の保存・取得・削除を抽象化する。Local JSON 実装をデフォルトに、
  将来は CloudKit/SQLite 等へ差し替え可能にする。
- 主な型: `CharacterRepository` (protocol), `LocalJSONCharacterRepository`.
*/

import Foundation

/// Result of the serialized character deletion check.
///
/// The repository decides whether the current record is protected while it
/// holds the same file lock used by saves.  Callers must only remove related
/// story/memory data after receiving `.deleted`.
enum CharacterDeletionResult: Equatable {
    case deleted
    case protected
    case notFound
}

protocol CharacterRepository: AnyObject {
    func fetchCharacters() async throws -> [CharacterProfile]
    func saveCharacter(_ character: CharacterProfile) async throws
    func deleteCharacter(id: UUID) async throws -> CharacterDeletionResult

    // Lorebook (1:1)。CharacterProfile と一緒に管理した方が呼び出し側が楽なのでここに置く。
    func fetchLorebook(characterId: UUID) async throws -> CharacterLorebook?
    func saveLorebook(_ lorebook: CharacterLorebook) async throws
}

/// 複数キャラクターを一度の read-modify-write で保存できるリポジトリ。
///
/// Story の初期シードでは、既存の `characters.json` が大きい環境でも
/// 1件ずつファイル全体を書き戻さないようにする。旧来の実装やテスト用
/// リポジトリは `CharacterRepository` のままでも動作するよう、呼び出し側
/// ではこのプロトコルを任意機能として扱う。
protocol BatchCharacterRepository: CharacterRepository {
    func saveCharacters(_ characters: [CharacterProfile]) async throws
}

final class LocalJSONCharacterRepository: BatchCharacterRepository {
    private let charStore = LocalJSONStore<CharacterProfile>(fileName: "characters.json")
    private let loreStore = LocalJSONStore<CharacterLorebook>(fileName: "lorebooks.json")

    func fetchCharacters() async throws -> [CharacterProfile] {
        let all = try await charStore.loadRecoveringCorruptRecords()
        return deduplicatedCharacters(all).sorted { $0.updatedAt > $1.updatedAt }
    }

    func saveCharacter(_ character: CharacterProfile) async throws {
        try await charStore.mutate { items in
            var updated = character.normalizedForPersistence
            let existing = items.filter { $0.id == character.id }
            if let protected = existing.first(where: { $0.isSystemProtected == true }) {
                updated.isSystemProtected = true
                if updated.avatarImageData == nil, let imageData = protected.avatarImageData {
                    updated.avatarImageData = imageData
                    updated.imageKey = protected.imageKey
                }
            }
            updated.updatedAt = Date()
            // appendOrReplaceは最初の1件だけを置き換えるため、旧データに
            // 残った同UUIDレコードを一緒に除去して保存層を一意に保つ。
            items.removeAll { $0.id == updated.id }
            items.append(updated)
        }
    }

    func saveCharacters(_ characters: [CharacterProfile]) async throws {
        guard !characters.isEmpty else { return }

        // charStore.mutate はファイルの読み込み・変更・保存を同じロック内で
        // 完了させる。初期シードで数百回発生していた全量I/Oを1回にまとめる。
        try await charStore.mutate { items in
            let timestamp = Date()

            // 先に既存ファイル全体をUUID単位へ正規化し、バッチ入力にも同じ
            // IDが複数ある場合は最後の入力を採用する。
            var normalized = deduplicatedCharacters(items)
            for character in characters {
                var updated = character.normalizedForPersistence
                let existing = normalized.filter { $0.id == character.id }
                if let protected = existing.first(where: { $0.isSystemProtected == true }) {
                    updated.isSystemProtected = true
                    if updated.avatarImageData == nil, let imageData = protected.avatarImageData {
                        updated.avatarImageData = imageData
                        updated.imageKey = protected.imageKey
                    }
                }
                updated.updatedAt = timestamp
                normalized.removeAll { $0.id == updated.id }
                normalized.append(updated)
            }
            items = normalized
        }
    }

    /// 旧バージョンや中断したシードで残った同一UUIDを1件へ統合する。
    /// 保護済みフラグと画像は失わず、本文は更新日時が新しいレコードを優先する。
    private func deduplicatedCharacters(_ characters: [CharacterProfile]) -> [CharacterProfile] {
        var result: [CharacterProfile] = []
        var indexByID: [UUID: Int] = [:]
        for character in characters {
            guard let existingIndex = indexByID[character.id] else {
                indexByID[character.id] = result.count
                result.append(character)
                continue
            }
            let existing = result[existingIndex]
            let protected = existing.isSystemProtected == true || character.isSystemProtected == true
            var preferred = character.updatedAt >= existing.updatedAt ? character : existing
            preferred.isSystemProtected = protected
            if preferred.avatarImageData == nil {
                let fallback = character.avatarImageData ?? existing.avatarImageData
                preferred.avatarImageData = fallback
                if preferred.imageKey == nil { preferred.imageKey = character.imageKey ?? existing.imageKey }
            }
            result[existingIndex] = preferred
        }
        return result
    }

    func deleteCharacter(id: UUID) async throws -> CharacterDeletionResult {
        var result: CharacterDeletionResult = .notFound
        // Protection and removal share the charStore read-modify-write lock.
        // A concurrent seed/save can therefore not turn a protected character
        // into a successful deletion after a caller has already cleaned refs.
        try await charStore.mutate { items in
            guard items.contains(where: { $0.id == id }) else {
                result = .notFound
                return
            }
            guard !items.contains(where: { $0.id == id && $0.isSystemProtected == true }) else {
                result = .protected
                return
            }
            items.removeAll { $0.id == id }
            result = .deleted
        }

        guard result == .deleted else { return result }
        // Lorebook cleanup belongs to the character repository, but story and
        // memory cleanup is intentionally left to callers after `.deleted`.
        try await loreStore.delete(matching: { $0.characterId == id })
        return result
    }

    func fetchLorebook(characterId: UUID) async throws -> CharacterLorebook? {
        let all = try await loreStore.loadRecoveringCorruptRecords()
        return all.first { $0.characterId == characterId }
    }

    func saveLorebook(_ lorebook: CharacterLorebook) async throws {
        try await loreStore.appendOrReplace(lorebook, idEquals: { $0.characterId == $1.characterId })
    }
}
