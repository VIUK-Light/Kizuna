/*
仕様:
- 役割: CharacterDetailView の表示用データ (キャラ + Lorebook + 最近メモリー) を取りまとめる。
- 主な型: `CharacterDetailViewModel`.
*/

import Foundation
import Combine

enum CharacterDeletionPhase: Equatable {
    case idle
    case removingReferences
    case deletingMemories
    case deletingProfile
    case partiallyCompleted
    case completed
}

@MainActor
final class CharacterDetailViewModel: ObservableObject {
    @Published private(set) var character: CharacterProfile
    @Published private(set) var lorebook: CharacterLorebook?
    @Published private(set) var memories: [CharacterMemory] = []
    /// Local JSON repositories cannot commit all related files atomically.
    /// Expose the resumable phase so the UI never promises a rollback that is
    /// not available.
    @Published private(set) var deletionPhase: CharacterDeletionPhase = .idle

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

    func delete() async throws {
        let latest = try await characterRepo.fetchCharacters().first(where: { $0.id == character.id })
        guard latest?.isSystemProtected != true else { return }
        deletionPhase = .removingReferences
        do {
            try await StoryCharacterReferenceCleaner.remove(characterID: character.id)
            deletionPhase = .deletingMemories
            try await memoryRepo.deleteAllMemories(characterId: character.id)
            deletionPhase = .deletingProfile
            try await characterRepo.deleteCharacter(id: character.id)
            deletionPhase = .completed
        } catch {
            // 各Repositoryは個別のJSONを原子的に更新するが、複数ファイルを
            // 1トランザクションにはできない。再実行は冪等な掃除として扱い、
            // 部分完了を明示してユーザーに再試行を促す。
            deletionPhase = .partiallyCompleted
            throw error
        }
    }
}
