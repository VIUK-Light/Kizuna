/*
仕様:
- 役割: CharacterProfile の保存・取得・削除を抽象化する。Local JSON 実装をデフォルトに、
  将来は CloudKit/SQLite 等へ差し替え可能にする。
- 主な型: `CharacterRepository` (protocol), `LocalJSONCharacterRepository`.
*/

import Foundation

protocol CharacterRepository: AnyObject {
    func fetchCharacters() async throws -> [CharacterProfile]
    func saveCharacter(_ character: CharacterProfile) async throws
    func deleteCharacter(id: UUID) async throws

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
        return all.sorted { $0.updatedAt > $1.updatedAt }
    }

    func saveCharacter(_ character: CharacterProfile) async throws {
        var updated = character
        if let existing = (try? await charStore.loadRecoveringCorruptRecords().first(where: { $0.id == character.id })),
           existing.isSystemProtected == true {
            updated.isSystemProtected = true
            if existing.avatarImageData != nil, updated.avatarImageData == nil {
                updated.avatarImageData = existing.avatarImageData
                updated.imageKey = existing.imageKey
            }
        }
        updated.updatedAt = Date()
        try await charStore.appendOrReplace(updated, idEquals: { $0.id == $1.id })
    }

    func saveCharacters(_ characters: [CharacterProfile]) async throws {
        guard !characters.isEmpty else { return }

        // charStore.mutate はファイルの読み込み・変更・保存を同じロック内で
        // 完了させる。初期シードで数百回発生していた全量I/Oを1回にまとめる。
        try await charStore.mutate { items in
            var indexByID: [UUID: Int] = [:]
            for (index, item) in items.enumerated() {
                // 旧データに同じUUIDが残っていてもクラッシュせず、最後の
                // レコードを置換対象にする。
                indexByID[item.id] = index
            }
            let timestamp = Date()

            for character in characters {
                var updated = character
                if let index = indexByID[character.id] {
                    let existing = items[index]
                    if existing.isSystemProtected == true {
                        updated.isSystemProtected = true
                        if existing.avatarImageData != nil, updated.avatarImageData == nil {
                            updated.avatarImageData = existing.avatarImageData
                            updated.imageKey = existing.imageKey
                        }
                    }
                    updated.updatedAt = timestamp
                    items[index] = updated
                } else {
                    updated.updatedAt = timestamp
                    indexByID[updated.id] = items.count
                    items.append(updated)
                }
            }
        }
    }

    func deleteCharacter(id: UUID) async throws {
        if let existing = (try? await charStore.loadRecoveringCorruptRecords().first(where: { $0.id == id })),
           existing.isSystemProtected == true {
            return
        }
        try await charStore.delete(matching: { $0.id == id })
        try await loreStore.delete(matching: { $0.characterId == id })
    }

    func fetchLorebook(characterId: UUID) async throws -> CharacterLorebook? {
        let all = try await loreStore.loadRecoveringCorruptRecords()
        return all.first { $0.characterId == characterId }
    }

    func saveLorebook(_ lorebook: CharacterLorebook) async throws {
        try await loreStore.appendOrReplace(lorebook, idEquals: { $0.characterId == $1.characterId })
    }
}
