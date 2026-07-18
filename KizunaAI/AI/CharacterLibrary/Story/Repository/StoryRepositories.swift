/*
仕様:
- 役割: Story 系 (StoryWorld / CastMember / StoryScene / StorySession) の保存・取得。
  既存 LocalJSONStore<T> を使った Local JSON 実装。将来 CloudKit/SQLite に差し替え可能。
- 主な型: StoryWorldRepository, CastRepository, StorySceneRepository, StorySessionRepository
         + それぞれの LocalJSON 実装。
- 編集ポイント: ファイル名、フィルタ、上限管理。
*/

import Foundation

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
