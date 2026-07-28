/*
仕様:
- 役割: Story 系 (StoryWorld / CastMember / StoryScene / StorySession) の保存・取得。
  既存 LocalJSONStore<T> を使った Local JSON 実装。将来 CloudKit/SQLite に差し替え可能。
- 主な型: StoryWorldRepository, CastRepository, StorySceneRepository, StorySessionRepository
         + それぞれの LocalJSON 実装。
- 編集ポイント: ファイル名、フィルタ、上限管理。
*/

import Foundation

/// キャラクター削除時に、StoryWorld側へ残るUUID参照を掃除する。
/// 会話履歴の本文は表示名を持っているため削除せず、過去ログとして保持する。
enum StoryCharacterReferenceCleaner {
    static func remove(characterID: UUID) async throws {
        let worldRepo: StoryWorldRepository = LocalJSONStoryWorldRepository()
        let castRepo: CastRepository = LocalJSONCastRepository()
        let sceneRepo: StorySceneRepository = LocalJSONStorySceneRepository()

        let worlds = try await worldRepo.fetchWorlds()
        for var world in worlds {
            var worldChanged = false
            let filteredIDs = world.characterIds.filter { $0 != characterID }
            if filteredIDs != world.characterIds {
                world.characterIds = filteredIDs
                worldChanged = true
            }
            if world.mainCharacterId == characterID {
                world.mainCharacterId = filteredIDs.first
                worldChanged = true
            }
            if worldChanged {
                try await worldRepo.saveWorld(world)
            }

            let cast = try await castRepo.fetchCast(storyWorldId: world.id)
            for var member in cast {
                if member.characterId == characterID {
                    try await castRepo.deleteCast(id: member.id)
                    continue
                }

                let filteredRelationships = member.relationshipToOtherCharacters.filter {
                    $0.fromCharacterId != characterID && $0.toCharacterId != characterID
                }
                if filteredRelationships != member.relationshipToOtherCharacters {
                    member.relationshipToOtherCharacters = filteredRelationships
                    try await castRepo.saveCast(member)
                }
            }

            let scenes = try await sceneRepo.fetchScenes(storyWorldId: world.id)
            for var scene in scenes {
                let filteredActiveIDs = scene.activeCharacterIds.filter { $0 != characterID }
                if filteredActiveIDs != scene.activeCharacterIds {
                    scene.activeCharacterIds = filteredActiveIDs
                    try await sceneRepo.saveScene(scene)
                }
            }
        }
    }
}

// MARK: - Protocols

protocol StoryWorldRepository: AnyObject {
    func fetchWorlds() async throws -> [StoryWorld]
    func saveWorld(_ world: StoryWorld) async throws
    func deleteWorld(id: UUID) async throws
}

protocol CastRepository: AnyObject {
    func fetchCast(storyWorldId: UUID) async throws -> [CastMember]
    func saveCast(_ cast: CastMember) async throws
    func deleteCast(id: UUID) async throws
    func deleteAllCast(storyWorldId: UUID) async throws
}

protocol StorySceneRepository: AnyObject {
    func fetchScenes(storyWorldId: UUID) async throws -> [StoryScene]
    func saveScene(_ scene: StoryScene) async throws
    func deleteScene(id: UUID) async throws
    func deleteAllScenes(storyWorldId: UUID) async throws
}

protocol StorySessionRepository: AnyObject {
    func fetchSessions(storyWorldId: UUID) async throws -> [StorySession]
    func saveSession(_ session: StorySession) async throws
    func deleteSession(id: UUID) async throws
}

// MARK: - Lorebook repository

/// Lorebookを別テーブルとして扱うことで、将来CloudKit/Supabaseへ差し替えやすくする。
protocol StoryLorebookRepository: AnyObject {
    func fetchEntries(storyWorldId: UUID) async throws -> [StoryLorebookEntry]
    func fetchAllEntries(storyWorldId: UUID) async throws -> [StoryLorebookEntry]
    func saveEntry(_ entry: StoryLorebookEntry) async throws
    func deleteEntry(id: UUID) async throws
}

/// 物語内メモリー。全体のCharacterMemoryとは保存先・取得条件を分ける。
protocol StoryMemoryRepository: AnyObject {
    func fetchMemories(storyWorldId: UUID) async throws -> [StoryMemory]
    func saveMemory(_ memory: StoryMemory) async throws
    func deleteMemory(id: UUID) async throws
    func deleteAllMemories(storyWorldId: UUID) async throws
    func markUsed(ids: [UUID]) async throws
}

// MARK: - Local JSON impls

final class LocalJSONStoryWorldRepository: StoryWorldRepository {
    private let store = LocalJSONStore<StoryWorld>(fileName: "story_worlds.json")
    func fetchWorlds() async throws -> [StoryWorld] {
        try await store.load().sorted { $0.updatedAt > $1.updatedAt }
    }
    func saveWorld(_ world: StoryWorld) async throws {
        var w = world
        if let existing = (try? await store.load().first(where: { $0.id == world.id })),
           existing.isSystemProtected == true {
            w.isSystemProtected = true
        }
        w.updatedAt = Date()
        try await store.appendOrReplace(w, idEquals: { $0.id == $1.id })
    }
    func deleteWorld(id: UUID) async throws {
        if let existing = (try? await store.load().first(where: { $0.id == id })),
           existing.isSystemProtected == true {
            return
        }
        try await store.delete(matching: { $0.id == id })
    }
}

final class LocalJSONCastRepository: CastRepository {
    private let store = LocalJSONStore<CastMember>(fileName: "story_cast.json")
    func fetchCast(storyWorldId: UUID) async throws -> [CastMember] {
        try await store.load().filter { $0.storyWorldId == storyWorldId }
    }
    func saveCast(_ cast: CastMember) async throws {
        try await store.appendOrReplace(cast, idEquals: { $0.id == $1.id })
    }
    func deleteCast(id: UUID) async throws {
        try await store.delete(matching: { $0.id == id })
    }
    func deleteAllCast(storyWorldId: UUID) async throws {
        try await store.delete(matching: { $0.storyWorldId == storyWorldId })
    }
}

final class LocalJSONStorySceneRepository: StorySceneRepository {
    private let store = LocalJSONStore<StoryScene>(fileName: "story_scenes.json")
    func fetchScenes(storyWorldId: UUID) async throws -> [StoryScene] {
        try await store.load()
            .filter { $0.storyWorldId == storyWorldId }
            .sorted { $0.createdAt < $1.createdAt }
    }
    func saveScene(_ scene: StoryScene) async throws {
        var s = scene
        s.updatedAt = Date()
        // active キャラ数の上限を遵守
        s.activeCharacterIds = Array(s.activeCharacterIds.prefix(StoryConstants.maxActiveCharacters))
        try await store.appendOrReplace(s, idEquals: { $0.id == $1.id })
    }
    func deleteScene(id: UUID) async throws {
        try await store.delete(matching: { $0.id == id })
    }
    func deleteAllScenes(storyWorldId: UUID) async throws {
        try await store.delete(matching: { $0.storyWorldId == storyWorldId })
    }
}

final class LocalJSONStorySessionRepository: StorySessionRepository {
    private let store = LocalJSONStore<StorySession>(fileName: "story_sessions.json")
    func fetchSessions(storyWorldId: UUID) async throws -> [StorySession] {
        try await store.load()
            .filter { $0.storyWorldId == storyWorldId }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
    func saveSession(_ session: StorySession) async throws {
        var s = session
        s.updatedAt = Date()
        try await store.appendOrReplace(s, idEquals: { $0.id == $1.id })
    }
    func deleteSession(id: UUID) async throws {
        try await store.delete(matching: { $0.id == id })
    }
}

// MARK: - Local Lorebook implementation

/// 現在はローカルJSON。Repository境界はクラウド同期実装と共通にする。
final class LocalJSONStoryLorebookRepository: StoryLorebookRepository {
    private let store = LocalJSONStore<StoryLorebookEntry>(fileName: "story_lorebook.json")

    func fetchEntries(storyWorldId: UUID) async throws -> [StoryLorebookEntry] {
        try await store.load()
            .filter { $0.storyWorldId == storyWorldId && $0.isEnabled }
            .sorted { $0.priority > $1.priority }
    }

    func fetchAllEntries(storyWorldId: UUID) async throws -> [StoryLorebookEntry] {
        try await store.load()
            .filter { $0.storyWorldId == storyWorldId }
            .sorted { $0.priority > $1.priority }
    }

    func saveEntry(_ entry: StoryLorebookEntry) async throws {
        var value = entry
        value.updatedAt = Date()
        try await store.appendOrReplace(value, idEquals: { $0.id == $1.id })
    }

    func deleteEntry(id: UUID) async throws {
        try await store.delete(matching: { $0.id == id })
    }
}

// MARK: - Local Story Memory implementation

/// 現在はローカルJSON。将来クラウド同期へ差し替えてもService側の呼び出しは変えない。
final class LocalJSONStoryMemoryRepository: StoryMemoryRepository {
    private let store = LocalJSONStore<StoryMemory>(fileName: "story_memories.json")
    private let perWorldLimit = 120

    func fetchMemories(storyWorldId: UUID) async throws -> [StoryMemory] {
        try await store.load()
            .filter { $0.storyWorldId == storyWorldId }
            .sorted { lhs, rhs in
                if lhs.importance != rhs.importance { return lhs.importance > rhs.importance }
                return (lhs.lastUsedAt ?? lhs.createdAt) > (rhs.lastUsedAt ?? rhs.createdAt)
            }
    }

    func saveMemory(_ memory: StoryMemory) async throws {
        try await store.mutate { all in
            let normalized = normalize(memory.text)
            if let index = all.firstIndex(where: {
                $0.storyWorldId == memory.storyWorldId && normalize($0.text) == normalized
            }) {
                var existing = all[index]
                existing.importance = max(existing.importance, memory.importance)
                existing.lastUsedAt = Date()
                all[index] = existing
            } else {
                all.append(memory)
            }

            // 物語ごとの上限を設け、古く重要度の低いものから自然に整理する。
            let grouped = Dictionary(grouping: all, by: { $0.storyWorldId })
            all = grouped.values.flatMap { values in
                values.sorted {
                    if $0.importance != $1.importance { return $0.importance > $1.importance }
                    return ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt)
                }.prefix(perWorldLimit)
            }
        }
    }

    func deleteMemory(id: UUID) async throws {
        try await store.delete(matching: { $0.id == id })
    }

    func deleteAllMemories(storyWorldId: UUID) async throws {
        try await store.delete(matching: { $0.storyWorldId == storyWorldId })
    }

    func markUsed(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        try await store.mutate { all in
            let now = Date()
            for index in all.indices where ids.contains(all[index].id) {
                all[index].lastUsedAt = now
            }
        }
    }

    private func normalize(_ text: String) -> String {
        text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
