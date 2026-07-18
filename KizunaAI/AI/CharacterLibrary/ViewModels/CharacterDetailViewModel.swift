/*
仕様:
- 役割: CharacterDetailView の表示用データ (キャラ + Lorebook + 最近メモリー) を取りまとめる。
- 主な型: `CharacterDetailViewModel`.
*/

import Foundation
import Combine

@MainActor
final class CharacterDetailViewModel: ObservableObject {
    @Published private(set) var character: CharacterProfile
    @Published private(set) var lorebook: CharacterLorebook?
    @Published private(set) var memories: [CharacterMemory] = []

    private let characterRepo: CharacterRepository
    private let memoryRepo: MemoryRepository

    init(
        character: CharacterProfile,
        characterRepo: CharacterRepository? = nil,
        memoryRepo: MemoryRepository? = nil
    ) {
        self.character = character
        self.characterRepo = characterRepo ?? LocalJSONCharacterRepository()
        self.memoryRepo = memoryRepo ?? LocalJSONMemoryRepository()
    }

    func reload() async {
        do {
            self.lorebook = try await characterRepo.fetchLorebook(characterId: character.id)
            self.memories = try await memoryRepo.fetchMemories(characterId: character.id)
        } catch {
            NSLog("[CharacterDetailVM] reload failed: %@", String(describing: error))
        }
    }

    func delete() async {
        do {
            try await characterRepo.deleteCharacter(id: character.id)
            try await memoryRepo.deleteAllMemories(characterId: character.id)
        } catch {
            NSLog("[CharacterDetailVM] delete failed: %@", String(describing: error))
        }
    }
}
