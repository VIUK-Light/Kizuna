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

final class LocalJSONCharacterRepository: CharacterRepository {
    private let charStore = LocalJSONStore<CharacterProfile>(fileName: "characters.json")
    private let loreStore = LocalJSONStore<CharacterLorebook>(fileName: "lorebooks.json")

    func fetchCharacters() async throws -> [CharacterProfile] {
        let all = try await charStore.load()
        return all.sorted { $0.updatedAt > $1.updatedAt }
    }

    func saveCharacter(_ character: CharacterProfile) async throws {
        var updated = character
        if let existing = (try? await charStore.load().first(where: { $0.id == character.id })),
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

    func deleteCharacter(id: UUID) async throws {
        if let existing = (try? await charStore.load().first(where: { $0.id == id })),
           existing.isSystemProtected == true {
            return
        }
        try await charStore.delete(matching: { $0.id == id })
        try await loreStore.delete(matching: { $0.characterId == id })
    }

    func fetchLorebook(characterId: UUID) async throws -> CharacterLorebook? {
        let all = try await loreStore.load()
        return all.first { $0.characterId == characterId }
    }

    func saveLorebook(_ lorebook: CharacterLorebook) async throws {
        try await loreStore.appendOrReplace(lorebook, idEquals: { $0.characterId == $1.characterId })
    }
}
