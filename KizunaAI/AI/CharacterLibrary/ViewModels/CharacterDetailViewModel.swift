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
            AppLog.error("[CharacterDetailVM] reload failed: %@", String(describing: error))
        }
    }

    func delete() async throws -> CharacterDeletionResult {
        do {
            deletionPhase = .deletingProfile
            PersonaChatService.shared.cancelGeneration(forCharacterID: character.id)
            let deletionResult = try await characterRepo.deleteCharacter(id: character.id)
            switch deletionResult {
            case .protected, .notFound:
                // A protected or unrelated missing profile must not be treated
                // as a successful deletion, and must not trigger cleanup of
                // another record's story references or memories.
                deletionPhase = .idle
                return deletionResult
            case .deleted, .needsCleanup:
                // `.needsCleanup` means the profile was removed by an earlier
                // attempt. Continue the same idempotent cleanup instead of
                // returning early with a misleading not-found state.
                break
            }

            // The profile is no longer readable even if a later related-data
            // cleanup step needs a retry. Invalidate every read-side cache now.
            CharacterLibraryChangeCenter.post()

            deletionPhase = .removingReferences
            try await StoryCharacterReferenceCleaner.remove(characterID: character.id)
            deletionPhase = .deletingMemories
            try await memoryRepo.deleteAllMemories(characterId: character.id)
            // プロフィール削除後も会話本文は保持し、関連スレッドだけを
            // personaSnapshotベースへ移行して継続可能にする。
            PersonaChatStore.shared.detachCharacterReferences(for: character.id)
            try await characterRepo.completeCharacterDeletionCleanup(id: character.id)
            deletionPhase = .completed
            return .deleted
        } catch {
            // 各Repositoryは個別のJSONを原子的に更新するが、複数ファイルを
            // 1トランザクションにはできない。再実行は冪等な掃除として扱い、
            // 部分完了を明示してユーザーに再試行を促す。
            deletionPhase = .partiallyCompleted
            throw error
        }
    }
}
