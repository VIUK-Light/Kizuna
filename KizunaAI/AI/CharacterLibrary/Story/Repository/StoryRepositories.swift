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
        let sessionRepo: StorySessionRepository = LocalJSONStorySessionRepository()
        let storyMemoryRepo: StoryMemoryRepository = LocalJSONStoryMemoryRepository()

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

            // セッション本文は過去ログとして残すが、現在状態にだけ残った
            // characterIdは削除する。次回プロンプトが削除済みキャラを復活させない。
            let sessions = try await sessionRepo.fetchSessions(storyWorldId: world.id)
            for var session in sessions {
                guard var storyState = session.storyState else { continue }
                let filteredStates = storyState.characterStates.filter {
                    $0.characterId != characterID
                }
                if filteredStates != storyState.characterStates {
                    storyState.characterStates = filteredStates
                    storyState.updatedAt = Date()
                    session.storyState = storyState
                    try await sessionRepo.saveSession(session)
                }
            }

            // キャラ固有の物語メモリーは参照先がなくなるため削除する。
            // characterId == nil の世界イベントは保持して、物語の流れを壊さない。
            let memories = try await storyMemoryRepo.fetchMemories(storyWorldId: world.id)
            for memory in memories where memory.characterId == characterID {
                try await storyMemoryRepo.deleteMemory(id: memory.id)
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
    /// Replace all members for a world in one read-modify-write transaction.
    func replaceCast(_ cast: [CastMember], storyWorldId: UUID) async throws
    func deleteCast(id: UUID) async throws
    func deleteAllCast(storyWorldId: UUID) async throws
}

protocol StorySceneRepository: AnyObject {
    func fetchScenes(storyWorldId: UUID) async throws -> [StoryScene]
    func saveScene(_ scene: StoryScene) async throws
    /// Fills a missing background key without replacing a concurrently edited
    /// scene. The local JSON implementation performs this condition check in
    /// the same read-modify-write transaction as the save.
    func repairMissingImageKey(storyWorldId: UUID, sceneId: UUID, imageKey: String) async throws -> Bool
    func deleteScene(id: UUID) async throws
    func deleteAllScenes(storyWorldId: UUID) async throws
}

protocol StorySessionRepository: AnyObject {
    func fetchSessions(storyWorldId: UUID) async throws -> [StorySession]
    func saveSession(_ session: StorySession) async throws
    func beginTurn(
        session: StorySession,
        userMessage: StoryMessage,
        turnID: UUID,
        attempt: Int,
        ownerID: UUID
    ) async throws -> StorySession
    func commitTurn(
        session: StorySession,
        scene: StoryScene,
        turnID: UUID,
        assistantMessageIDs: [UUID],
        memoryRetries: [StoryMemoryRetry]
    ) async throws -> StorySession
    func finishTurn(
        sessionID: UUID,
        turnID: UUID,
        attempt: Int,
        status: StoryTurnStatus,
        failureCode: String?
    ) async throws
    func recoverInterruptedTurns(
        storyWorldId: UUID,
        activeOwnerIDs: Set<UUID>
    ) async throws
    /// Discard an interrupted turn only when the caller still owns the exact
    /// persisted revision. The incomplete user message and any assistant IDs
    /// recorded by the checkpoint are removed together with the checkpoint.
    /// A late model callback must therefore fail the normal commit boundary.
    func discardInterruptedTurn(
        sessionID: UUID,
        turnID: UUID,
        attempt: Int,
        expectedRevision: UInt64
    ) async throws -> StorySession
    func deleteSession(id: UUID) async throws
}

// MARK: - Lorebook repository

/// Lorebookを別テーブルとして扱うことで、将来CloudKit/Supabaseへ差し替えやすくする。
protocol StoryLorebookRepository: AnyObject {
    func fetchEntries(storyWorldId: UUID) async throws -> [StoryLorebookEntry]
    func fetchAllEntries(storyWorldId: UUID) async throws -> [StoryLorebookEntry]
    /// Replace every entry belonging to a world in one read-modify-write operation.
    /// Callers must prepare/validate the complete replacement before invoking this
    /// method so a failed fetch cannot be mistaken for an intentional empty list.
    func replaceEntries(_ entries: [StoryLorebookEntry], storyWorldId: UUID) async throws
    func saveEntry(_ entry: StoryLorebookEntry) async throws
    func deleteEntry(id: UUID) async throws
}

/// 物語内メモリー。全体のCharacterMemoryとは保存先・取得条件を分ける。
protocol StoryMemoryRepository: AnyObject {
    func fetchMemories(storyWorldId: UUID) async throws -> [StoryMemory]
    /// Fetch only memories created in the specified StorySession. Legacy
    /// records without a session ID are intentionally excluded from prompts.
    func fetchMemories(storyWorldId: UUID, storySessionId: UUID) async throws -> [StoryMemory]
    func saveMemory(_ memory: StoryMemory) async throws
    /// Remove only the cancelled turn provenance. A merged memory created by
    /// another turn must remain available.
    func removeSourceTurnIds(_ sourceTurnIds: Set<UUID>) async throws
    func deleteMemory(id: UUID) async throws
    func deleteAllMemories(storyWorldId: UUID) async throws
    func markUsed(ids: [UUID]) async throws
}

/// Auxiliary memory saves are durable work items, not another user turn.
/// Keeping this queue behind its own repository lets a newly created
/// StorySessionService restore retries after an app restart without coupling
/// the queue to StoryMemory's read/query semantics.
protocol StoryMemoryRetryRepository: AnyObject {
    func fetchRetries() async throws -> [StoryMemoryRetry]
    func saveRetry(_ retry: StoryMemoryRetry) async throws
    func deleteRetry(turnID: UUID) async throws
}

/// Optional capability for local repositories that can commit the memory
/// payload and its session-liveness check under one shared file lock. Keeping
/// this separate from the queue repository preserves lightweight test/future
/// cloud implementations that only need the basic retry CRUD API.
protocol StoryMemoryRetryMemoryTransaction: AnyObject {
    func saveMemoryRetryRecords(_ retry: StoryMemoryRetry) async throws -> StoryMemoryRetry?
}

// MARK: - Local JSON impls

final class LocalJSONStoryWorldRepository: StoryWorldRepository {
    private let store = LocalJSONStore<StoryWorld>(fileName: "story_worlds.json")
    func fetchWorlds() async throws -> [StoryWorld] {
        try await store.loadRecoveringCorruptRecords()
            .map(\.normalizedForPersistence)
            .sorted { $0.updatedAt > $1.updatedAt }
    }
    func saveWorld(_ world: StoryWorld) async throws {
        // 保護フラグの読み込みと更新を同一ロックに置く。別々の
        // load→appendOrReplace では、同一IDをシード／修復が更新した直後に
        // 古い編集スナップショットで保護状態を上書きできてしまう。
        try await store.mutate { items in
            var updated = world.normalizedForPersistence
            if items.contains(where: { $0.id == world.id && $0.isSystemProtected == true }) {
                updated.isSystemProtected = true
            }
            updated.updatedAt = Date()
            items.removeAll { $0.id == updated.id }
            items.append(updated)
        }
    }
    func deleteWorld(id: UUID) async throws {
        // 保護判定と削除を同一トランザクションにして、判定後の並行変更で
        // system protected Worldが消えないようにする。読み込みエラーは
        // mutateから呼び出し元へ伝播し、未保護扱いで続行しない。
        try await store.mutate { items in
            guard !items.contains(where: { $0.id == id && $0.isSystemProtected == true }) else {
                return
            }
            items.removeAll { $0.id == id }
        }
    }

    /// 起動時の重複標準データ移行専用。通常のユーザー操作からは
    /// system protected Worldを削除できないが、canonical UUIDへ関連レコードを
    /// 移した後の余剰レコードだけは、移行処理から明示的に消せるようにする。
    func purgeSystemWorld(id: UUID) async throws {
        guard let world = try await store.loadRecoveringCorruptRecords().first(where: { $0.id == id }),
              world.isSystemProtected == true else {
            NSLog("[StoryWorldRepo] refused to purge non-system world: %@", id.uuidString)
            return
        }
        try await store.delete(matching: { $0.id == id })
    }
}

final class LocalJSONCastRepository: CastRepository {
    private let store = LocalJSONStore<CastMember>(fileName: "story_cast.json")
    func fetchCast(storyWorldId: UUID) async throws -> [CastMember] {
        try await store.loadRecoveringCorruptRecords().filter { $0.storyWorldId == storyWorldId }
    }
    func saveCast(_ cast: CastMember) async throws {
        try await store.appendOrReplace(cast, idEquals: { $0.id == $1.id })
    }
    func replaceCast(_ cast: [CastMember], storyWorldId: UUID) async throws {
        var replacement = cast
        replacement = replacement.map { member in
            var member = member
            member.storyWorldId = storyWorldId
            return member
        }
        try await store.mutate { values in
            values.removeAll { $0.storyWorldId == storyWorldId }
            values.append(contentsOf: replacement)
        }
    }
    func deleteCast(id: UUID) async throws {
        try await store.delete(matching: { $0.id == id })
    }
    func deleteAllCast(storyWorldId: UUID) async throws {
        try await store.delete(matching: { $0.storyWorldId == storyWorldId })
    }
}

final class LocalJSONStorySceneRepository: StorySceneRepository {
    private let store: LocalJSONStore<StoryScene>
    private let storageURL: URL

    init(storageURL: URL = KizunaDataMigration.characterLibraryURL) {
        self.storageURL = storageURL
        self.store = LocalJSONStore<StoryScene>(fileName: "story_scenes.json", baseURL: storageURL)
    }

    func fetchScenes(storyWorldId: UUID) async throws -> [StoryScene] {
        try await StoryTurnJournal.recoverIfNeededAsync(baseURL: storageURL)
        return try await store.loadRecoveringCorruptRecords()
            .filter { $0.storyWorldId == storyWorldId }
            .sorted { $0.createdAt < $1.createdAt }
    }
    func saveScene(_ scene: StoryScene) async throws {
        let storageURL = self.storageURL
        try await store.mutate { scenes in
            let tombstones = try StoryTurnJournal.loadTombstonesUnlocked(baseURL: storageURL)
            try StoryTurnJournal.ensureRecordIsNotDeletedUnlocked(
                recordID: scene.id,
                recordKind: .scene,
                tombstones: tombstones
            )
            var next = scene
            next.updatedAt = Date()
            // active キャラ数の上限を遵守
            next.activeCharacterIds = Array(next.activeCharacterIds.prefix(StoryConstants.maxActiveCharacters))
            if let index = scenes.firstIndex(where: { $0.id == next.id }) {
                next.persistenceRevision = scenes[index].effectivePersistenceRevision + 1
                scenes[index] = next
            } else {
                next.persistenceRevision = max(1, next.effectivePersistenceRevision)
                scenes.append(next)
            }
        }
    }

    func repairMissingImageKey(storyWorldId: UUID, sceneId: UUID, imageKey: String) async throws -> Bool {
        let trimmedKey = imageKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return false }
        var repaired = false
        let storageURL = self.storageURL
        try await store.mutate { scenes in
            let tombstones = try StoryTurnJournal.loadTombstonesUnlocked(baseURL: storageURL)
            try StoryTurnJournal.ensureRecordIsNotDeletedUnlocked(
                recordID: sceneId,
                recordKind: .scene,
                tombstones: tombstones
            )
            guard let index = scenes.firstIndex(where: {
                $0.id == sceneId && $0.storyWorldId == storyWorldId
            }), scenes[index].imageKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
                return
            }
            // Keep every user-edited field and update only the missing key.
            scenes[index].imageKey = trimmedKey
            scenes[index].persistenceRevision = scenes[index].effectivePersistenceRevision + 1
            repaired = true
        }
        return repaired
    }

    /// 重複Worldの移行専用。関連付けだけをcanonical Worldへ変更し、
    /// 元シーンのcreatedAt/updatedAtやactiveキャラの内容はそのまま保持する。
    /// 通常の編集経路（saveScene）はupdatedAtを更新するため、移行では使わない。
    func moveScene(id: UUID, toStoryWorldId: UUID) async throws {
        let storageURL = self.storageURL
        try await store.mutate { scenes in
            let tombstones = try StoryTurnJournal.loadTombstonesUnlocked(baseURL: storageURL)
            try StoryTurnJournal.ensureRecordIsNotDeletedUnlocked(
                recordID: id,
                recordKind: .scene,
                tombstones: tombstones
            )
            guard let index = scenes.firstIndex(where: { $0.id == id }) else { return }
            scenes[index].storyWorldId = toStoryWorldId
            scenes[index].persistenceRevision = scenes[index].effectivePersistenceRevision + 1
        }
    }

    func deleteScene(id: UUID) async throws {
        let storageURL = self.storageURL
        try await store.mutate { scenes in
            try StoryTurnJournal.recordDeletionUnlocked(
                recordID: id,
                recordKind: .scene,
                baseURL: storageURL
            )
            scenes.removeAll { $0.id == id }
        }
    }
    func deleteAllScenes(storyWorldId: UUID) async throws {
        let storageURL = self.storageURL
        try await store.mutate { scenes in
            let deletedIDs = scenes
                .filter { $0.storyWorldId == storyWorldId }
                .map(\.id)
            try StoryTurnJournal.recordDeletionsUnlocked(
                recordIDs: deletedIDs,
                recordKind: .scene,
                baseURL: storageURL
            )
            scenes.removeAll { $0.storyWorldId == storyWorldId }
        }
    }
}

final class LocalJSONStorySessionRepository: StorySessionRepository {
    private let store: LocalJSONStore<StorySession>
    private let storageURL: URL

    init(storageURL: URL = KizunaDataMigration.characterLibraryURL) {
        self.storageURL = storageURL
        self.store = LocalJSONStore<StorySession>(fileName: "story_sessions.json", baseURL: storageURL)
    }

    func fetchSessions(storyWorldId: UUID) async throws -> [StorySession] {
        try await StoryTurnJournal.recoverIfNeededAsync(baseURL: storageURL)
        let sessions = try await store.loadRecoveringCorruptRecords()
            .filter { $0.storyWorldId == storyWorldId }
            .sorted { $0.updatedAt > $1.updatedAt }
        var repairedSessions: [StorySession] = []
        for session in sessions {
            let repaired = StorySessionMessageRepair.repaired(session)
            var effectiveSession = repaired
            if repaired.messages != session.messages {
                do {
                    // 修復対象を読み込んだ後に別ターンが保存されている
                    // 可能性がある。ファイルロック内で同じスナップショットかを
                    // 確認し、変わっていれば新しいターンを上書きしない。
                    try await store.mutate { current in
                        guard let index = current.firstIndex(where: { $0.id == session.id }) else { return }
                        guard current[index].messages == session.messages,
                              current[index].updatedAt == session.updatedAt else {
                            effectiveSession = current[index]
                            return
                        }
                        current[index] = repaired
                    }
                    NSLog(
                        "[StorySession] repaired duplicate generated messages session=%@ removed=%ld",
                        session.id.uuidString,
                        session.messages.count - repaired.messages.count
                    )
                } catch {
                    // 読み込み自体は継続し、保存失敗はログで追跡できるようにする。
                    NSLog("[StorySession] duplicate repair save failed session=%@: %@", session.id.uuidString, error.localizedDescription)
                }
            }
            repairedSessions.append(effectiveSession)
        }
        return repairedSessions
    }
    func saveSession(_ session: StorySession) async throws {
        let storageURL = self.storageURL
        try await StoryTurnJournal.recoverIfNeededAsync(baseURL: storageURL)
        try await LocalJSONStoreTransaction.performOnFileIO {
            try LocalJSONStoreTransaction.withSharedLock {
                let tombstones = try StoryTurnJournal.loadTombstonesUnlocked(baseURL: storageURL)
                try StoryTurnJournal.ensureRecordIsNotDeletedUnlocked(
                    recordID: session.id,
                    recordKind: .session,
                    tombstones: tombstones
                )
                var sessions = try LocalJSONStoreTransaction.load(
                    StorySession.self,
                    fileName: "story_sessions.json",
                    baseURL: storageURL
                )
                if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                    let current = sessions[index]
                    guard current.effectivePersistenceRevision == session.effectivePersistenceRevision else {
                        throw StoryTurnPersistenceError.revisionConflict(
                            expected: session.effectivePersistenceRevision,
                            actual: current.effectivePersistenceRevision
                        )
                    }
                    var next = StorySessionMessageRepair.repaired(session)
                    // The checkpoint is owned by the persistence boundary, not by
                    // an auxiliary caller's possibly older snapshot. Preserve the
                    // current turn state so narration/rest saves cannot erase a
                    // pending or committed checkpoint.
                    next.latestTurnCheckpoint = current.latestTurnCheckpoint
                    next.persistenceRevision = current.effectivePersistenceRevision + 1
                    next.updatedAt = Date()
                    sessions[index] = next
                } else {
                    var next = StorySessionMessageRepair.repaired(session)
                    next.persistenceRevision = max(1, next.effectivePersistenceRevision)
                    next.updatedAt = Date()
                    sessions.append(next)
                }
                try LocalJSONStoreTransaction.save(sessions, fileName: "story_sessions.json", baseURL: storageURL)
            }
        }
    }

    func beginTurn(
        session: StorySession,
        userMessage: StoryMessage,
        turnID: UUID,
        attempt: Int,
        ownerID: UUID = StoryTurnOwner.currentID
    ) async throws -> StorySession {
        let storageURL = self.storageURL
        try await StoryTurnJournal.recoverIfNeededAsync(baseURL: storageURL)
        return try await LocalJSONStoreTransaction.performOnFileIO {
            try LocalJSONStoreTransaction.withSharedLock {
            let tombstones = try StoryTurnJournal.loadTombstonesUnlocked(baseURL: storageURL)
            try StoryTurnJournal.ensureRecordIsNotDeletedUnlocked(
                recordID: session.id,
                recordKind: .session,
                tombstones: tombstones
            )
            var sessions = try LocalJSONStoreTransaction.load(
                StorySession.self,
                fileName: "story_sessions.json",
                baseURL: storageURL
            )
            guard let index = sessions.firstIndex(where: { $0.id == session.id }) else {
                throw StoryTurnPersistenceError.sessionNotFound
            }
            let current = sessions[index]
            let actualRevision = current.effectivePersistenceRevision

            if let checkpoint = current.latestTurnCheckpoint {
                if checkpoint.status == .pending && checkpoint.turnID != turnID {
                    throw StoryTurnPersistenceError.turnInProgress
                }
                if checkpoint.turnID == turnID {
                    switch checkpoint.status {
                    case .committed:
                        // 同じターンの再適用は、現在の保存済み結果を返す。
                        return current
                    case .pending:
                        // 同じ生成処理の再入場はそのまま返す。失敗後の
                        // 再試行でattemptが進んだ場合だけcheckpointを更新し、
                        // 古いcancel/timeout cleanupが新しい試行を終了しないようにする。
                        guard attempt > checkpoint.attempt else { return current }
                    case .failed, .cancelled, .interrupted:
                        // 失敗・キャンセル後の再試行も、古い呼び出し元
                        // Snapshotのrevisionではなくcheckpointを正本にする。
                        guard attempt > checkpoint.attempt else { return current }
                    }

                    var retried = current
                    let now = Date()
                    retried.latestTurnCheckpoint = StoryTurnReducer.begin(
                        turnID: turnID,
                        userMessageID: checkpoint.userMessageID,
                        attempt: attempt,
                        ownerID: ownerID,
                        baseRevision: actualRevision,
                        startedAt: checkpoint.startedAt,
                        updatedAt: now
                    )
                    retried.persistenceRevision = actualRevision + 1
                    retried.updatedAt = now
                    sessions[index] = retried
                    try LocalJSONStoreTransaction.save(sessions, fileName: "story_sessions.json", baseURL: storageURL)
                    return retried
                }
            }

            let expectedRevision = session.effectivePersistenceRevision
            guard expectedRevision == actualRevision else {
                throw StoryTurnPersistenceError.revisionConflict(
                    expected: expectedRevision,
                    actual: actualRevision
                )
            }

            var next = current
            if next.storyState == nil {
                // runPipelineが現在Sceneから作った初期StoryStateだけは、
                // 同じrevisionの呼び出し元スナップショットから引き継ぐ。
                next.storyState = session.storyState
            }
            var normalizedMessage = userMessage
            normalizedMessage.turnID = turnID
            if let messageIndex = next.messages.firstIndex(where: { $0.id == userMessage.id }) {
                // 旧データから再試行する場合も、既存の本文を保持したまま
                // 新しいターン境界だけを付与する。
                next.messages[messageIndex].turnID = turnID
            } else {
                next.messages.append(normalizedMessage)
            }
            let now = Date()
            next.latestTurnCheckpoint = StoryTurnReducer.begin(
                turnID: turnID,
                userMessageID: userMessage.id,
                attempt: attempt,
                ownerID: ownerID,
                baseRevision: actualRevision,
                startedAt: current.latestTurnCheckpoint?.turnID == turnID
                    ? current.latestTurnCheckpoint?.startedAt ?? now
                    : now,
                updatedAt: now
            )
            next.persistenceRevision = actualRevision + 1
            next.updatedAt = now
            sessions[index] = next
            try LocalJSONStoreTransaction.save(sessions, fileName: "story_sessions.json", baseURL: storageURL)
            return next
            }
        }
    }

    func commitTurn(
        session: StorySession,
        scene: StoryScene,
        turnID: UUID,
        assistantMessageIDs: [UUID],
        memoryRetries: [StoryMemoryRetry]
    ) async throws -> StorySession {
        let storageURL = self.storageURL
        try await StoryTurnJournal.recoverIfNeededAsync(baseURL: storageURL)
        return try await LocalJSONStoreTransaction.performOnFileIO {
            try LocalJSONStoreTransaction.withSharedLock {
            let tombstones = try StoryTurnJournal.loadTombstonesUnlocked(baseURL: storageURL)
            try StoryTurnJournal.ensureRecordIsNotDeletedUnlocked(
                recordID: session.id,
                recordKind: .session,
                tombstones: tombstones
            )
            try StoryTurnJournal.ensureRecordIsNotDeletedUnlocked(
                recordID: scene.id,
                recordKind: .scene,
                tombstones: tombstones
            )
            var sessions = try LocalJSONStoreTransaction.load(
                StorySession.self,
                fileName: "story_sessions.json",
                baseURL: storageURL
            )
            var scenes = try LocalJSONStoreTransaction.load(
                StoryScene.self,
                fileName: "story_scenes.json",
                baseURL: storageURL
            )
            guard let sessionIndex = sessions.firstIndex(where: { $0.id == session.id }) else {
                throw StoryTurnPersistenceError.sessionNotFound
            }
            guard let sceneIndex = scenes.firstIndex(where: { $0.id == scene.id }) else {
                throw StoryTurnPersistenceError.worldMismatch
            }
            let currentScene = scenes[sceneIndex]
            guard currentScene.storyWorldId == session.storyWorldId,
                  scene.storyWorldId == session.storyWorldId else {
                throw StoryTurnPersistenceError.worldMismatch
            }
            guard session.currentSceneId == nil || session.currentSceneId == scene.id,
                  sessions[sessionIndex].currentSceneId == nil || sessions[sessionIndex].currentSceneId == scene.id else {
                throw StoryTurnPersistenceError.sceneConflict
            }

            let current = sessions[sessionIndex]
            guard let checkpoint = current.latestTurnCheckpoint,
                  checkpoint.turnID == turnID else {
                throw StoryTurnPersistenceError.turnNotPending
            }
            if checkpoint.status == .committed {
                if !memoryRetries.isEmpty {
                    // A prior attempt may have committed both records before
                    // reporting an error. Keep the exact auxiliary payload
                    // journaled until the caller finishes or queues it.
                    try StoryTurnJournal.prepareUnlocked(
                        StoryTurnJournalEntry(
                            turnID: turnID,
                            session: current,
                            scene: currentScene,
                            memoryRetries: memoryRetries
                        ),
                        baseURL: storageURL,
                        tombstones: tombstones
                    )
                }
                return current
            }
            guard checkpoint.status == .pending else {
                throw StoryTurnPersistenceError.turnNotPending
            }
            let expectedRevision = session.effectivePersistenceRevision
            let actualRevision = current.effectivePersistenceRevision
            guard expectedRevision == actualRevision else {
                throw StoryTurnPersistenceError.revisionConflict(
                    expected: expectedRevision,
                    actual: actualRevision
                )
            }

            var committed = StorySessionMessageRepair.repaired(session)
            let now = Date()
            var seenAssistantIDs = Set<UUID>()
            let assistantIDs = assistantMessageIDs.filter { seenAssistantIDs.insert($0).inserted }
            committed.messages = committed.messages.map { message in
                guard assistantIDs.contains(message.id) || message.id == checkpoint.userMessageID else {
                    return message
                }
                var message = message
                message.turnID = turnID
                return message
            }
            let retainedAssistantIDs = committed.messages
                .filter { assistantIDs.contains($0.id) }
                .map(\.id)
            committed.latestTurnCheckpoint = StoryTurnReducer.commit(
                pending: checkpoint,
                assistantMessageIDs: retainedAssistantIDs,
                updatedAt: now
            )
            committed.currentSceneId = sessions[sessionIndex].currentSceneId ?? scene.id
            committed.persistenceRevision = actualRevision + 1
            committed.updatedAt = now

            // Scene全体を古い呼び出し側スナップショットで置き換えない。
            // このターンが生成したsummary/activeキャラだけを、生成開始時点
            // から外部編集されていない場合に反映し、imageKey等の最新編集は残す。
            var committedScene = currentScene
            if currentScene.updatedAt == scene.updatedAt,
               currentScene.effectivePersistenceRevision == scene.effectivePersistenceRevision {
                committedScene.summary = scene.summary
                committedScene.activeCharacterIds = Array(
                    scene.activeCharacterIds.prefix(StoryConstants.maxActiveCharacters)
                )
                // StoryState is the runtime source of truth after the first
                // turn. Keep the scene strip and its fallback visual in sync
                // with that state, while retaining user edits made after the
                // turn started via the timestamp guard above.
                if let storyState = committed.storyState {
                    if !storyState.location.isEmpty {
                        committedScene.location = storyState.location
                    }
                    if !storyState.timeOfDay.isEmpty {
                        committedScene.timeOfDay = storyState.timeOfDay
                    }
                    if !storyState.mood.isEmpty {
                        committedScene.mood = storyState.mood
                    }
                }
                committedScene.updatedAt = now
                committedScene.persistenceRevision = currentScene.effectivePersistenceRevision + 1
            }

            // ジャーナルを先に置いてから2つのスナップショットを更新する。
            // 途中終了時は次回のfetchで両方を再適用する。
            try StoryTurnJournal.prepareUnlocked(
                StoryTurnJournalEntry(
                    turnID: turnID,
                    session: committed,
                    scene: committedScene,
                    memoryRetries: memoryRetries
                ),
                baseURL: storageURL,
                tombstones: tombstones
            )
            sessions[sessionIndex] = committed
            scenes[sceneIndex] = committedScene
            try LocalJSONStoreTransaction.save(sessions, fileName: "story_sessions.json", baseURL: storageURL)
            try LocalJSONStoreTransaction.save(scenes, fileName: "story_scenes.json", baseURL: storageURL)
            if memoryRetries.isEmpty {
                do {
                    try StoryTurnJournal.removeUnlocked(turnID: turnID, baseURL: storageURL)
                } catch {
                    // Session/Sceneが確定した後のjournal削除失敗は、ターン自体の
                    // 失敗ではない。次回recoveryで同じ確定snapshotを再適用する。
                    NSLog(
                        "[StoryTurnJournal] committed turn cleanup deferred turn=%@ error=%@",
                        turnID.uuidString,
                        error.localizedDescription
                    )
                }
            }
            return committed
            }
        }
    }

    func finishTurn(
        sessionID: UUID,
        turnID: UUID,
        attempt: Int,
        status: StoryTurnStatus,
        failureCode: String?
    ) async throws {
        guard status != .pending && status != .committed else { return }
        let storageURL = self.storageURL
        try await StoryTurnJournal.recoverIfNeededAsync(baseURL: storageURL)
        try await LocalJSONStoreTransaction.performOnFileIO {
            try LocalJSONStoreTransaction.withSharedLock {
            let tombstones = try StoryTurnJournal.loadTombstonesUnlocked(baseURL: storageURL)
            try StoryTurnJournal.ensureRecordIsNotDeletedUnlocked(
                recordID: sessionID,
                recordKind: .session,
                tombstones: tombstones
            )
            var sessions = try LocalJSONStoreTransaction.load(
                StorySession.self,
                fileName: "story_sessions.json",
                baseURL: storageURL
            )
            guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else {
                throw StoryTurnPersistenceError.sessionNotFound
            }
            var current = sessions[index]
            guard var checkpoint = current.latestTurnCheckpoint,
                  checkpoint.turnID == turnID,
                  checkpoint.attempt == attempt else {
                return
            }
            if checkpoint.status == .committed || checkpoint.status == status {
                return
            }
            guard checkpoint.status == .pending else { return }
            checkpoint = StoryTurnReducer.finish(
                pending: checkpoint,
                status: status,
                failureCode: failureCode,
                updatedAt: Date()
            )
            current.latestTurnCheckpoint = checkpoint
            current.persistenceRevision = current.effectivePersistenceRevision + 1
            current.updatedAt = checkpoint.updatedAt
            sessions[index] = current
            try LocalJSONStoreTransaction.save(sessions, fileName: "story_sessions.json", baseURL: storageURL)
            }
        }
    }

    func recoverInterruptedTurns(
        storyWorldId: UUID,
        activeOwnerIDs: Set<UUID> = StoryTurnOwnerRegistry.shared.activeOwnerIDs()
    ) async throws {
        let storageURL = self.storageURL
        try await StoryTurnJournal.recoverIfNeededAsync(baseURL: storageURL)
        try await LocalJSONStoreTransaction.performOnFileIO {
            try LocalJSONStoreTransaction.withSharedLock {
            var sessions = try LocalJSONStoreTransaction.load(
                StorySession.self,
                fileName: "story_sessions.json",
                baseURL: storageURL
            )
            var changed = false
            for index in sessions.indices where sessions[index].storyWorldId == storyWorldId {
                guard var checkpoint = sessions[index].latestTurnCheckpoint,
                      checkpoint.status == .pending else { continue }
                let isOwnedByLiveService = checkpoint.ownerID.map(activeOwnerIDs.contains) ?? false
                guard !isOwnedByLiveService else { continue }
                checkpoint = StoryTurnReducer.finish(
                    pending: checkpoint,
                    status: .interrupted,
                    failureCode: "app_relaunch",
                    updatedAt: Date()
                )
                sessions[index].latestTurnCheckpoint = checkpoint
                sessions[index].persistenceRevision = sessions[index].effectivePersistenceRevision + 1
                sessions[index].updatedAt = checkpoint.updatedAt
                changed = true
            }
            if changed {
                try LocalJSONStoreTransaction.save(sessions, fileName: "story_sessions.json", baseURL: storageURL)
            }
            }
        }
    }

    func discardInterruptedTurn(
        sessionID: UUID,
        turnID: UUID,
        attempt: Int,
        expectedRevision: UInt64
    ) async throws -> StorySession {
        let storageURL = self.storageURL
        try await StoryTurnJournal.recoverIfNeededAsync(baseURL: storageURL)
        return try await LocalJSONStoreTransaction.performOnFileIO {
            try LocalJSONStoreTransaction.withSharedLock {
                let tombstones = try StoryTurnJournal.loadTombstonesUnlocked(baseURL: storageURL)
                try StoryTurnJournal.ensureRecordIsNotDeletedUnlocked(
                    recordID: sessionID,
                    recordKind: .session,
                    tombstones: tombstones
                )
                var sessions = try LocalJSONStoreTransaction.load(
                    StorySession.self,
                    fileName: "story_sessions.json",
                    baseURL: storageURL
                )
                guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else {
                    throw StoryTurnPersistenceError.sessionNotFound
                }

                var current = sessions[index]
                guard current.effectivePersistenceRevision == expectedRevision else {
                    throw StoryTurnPersistenceError.revisionConflict(
                        expected: expectedRevision,
                        actual: current.effectivePersistenceRevision
                    )
                }
                guard let checkpoint = current.latestTurnCheckpoint,
                      checkpoint.turnID == turnID,
                      checkpoint.attempt == attempt,
                      checkpoint.status == .interrupted else {
                    throw StoryTurnPersistenceError.turnNotPending
                }

                let incompleteMessageIDs = Set(
                    [checkpoint.userMessageID] + checkpoint.assistantMessageIDs
                )
                current.messages.removeAll { incompleteMessageIDs.contains($0.id) }
                current.latestTurnCheckpoint = nil
                current.persistenceRevision = current.effectivePersistenceRevision + 1
                current.updatedAt = Date()
                sessions[index] = current
                try LocalJSONStoreTransaction.save(
                    sessions,
                    fileName: "story_sessions.json",
                    baseURL: storageURL
                )
                return current
            }
        }
    }

    /// 重複Worldの移行専用。セッションの所属Worldを変更し、
    /// 進行中turnの古いsnapshotが移行を巻き戻さないようrevisionを進める。
    /// 会話本文のcreatedAtは変更せず、updatedAtだけを移行時刻へ更新する。
    func moveSession(id: UUID, toStoryWorldId: UUID) async throws {
        let storageURL = self.storageURL
        try await StoryTurnJournal.recoverIfNeededAsync(baseURL: storageURL)
        try await LocalJSONStoreTransaction.performOnFileIO {
            try LocalJSONStoreTransaction.withSharedLock {
                let tombstones = try StoryTurnJournal.loadTombstonesUnlocked(baseURL: storageURL)
                try StoryTurnJournal.ensureRecordIsNotDeletedUnlocked(
                    recordID: id,
                    recordKind: .session,
                    tombstones: tombstones
                )
                var sessions = try LocalJSONStoreTransaction.load(
                    StorySession.self,
                    fileName: "story_sessions.json",
                    baseURL: storageURL
                )
                guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
                sessions[index].storyWorldId = toStoryWorldId
                sessions[index].persistenceRevision = sessions[index].effectivePersistenceRevision + 1
                sessions[index].updatedAt = Date()
                try LocalJSONStoreTransaction.save(
                    sessions,
                    fileName: "story_sessions.json",
                    baseURL: storageURL
                )
            }
        }
    }

    func deleteSession(id: UUID) async throws {
        let storageURL = self.storageURL
        try await LocalJSONStoreTransaction.performOnFileIO {
            try LocalJSONStoreTransaction.withSharedLock {
                var sessions = try LocalJSONStoreTransaction.load(
                    StorySession.self,
                    fileName: "story_sessions.json",
                    baseURL: storageURL
                )
                try StoryTurnJournal.recordDeletionUnlocked(
                    recordID: id,
                    recordKind: .session,
                    baseURL: storageURL
                )
                sessions.removeAll { $0.id == id }
                try StoryTurnJournal.removeStoryMemoriesForDeletedSessionsUnlocked(
                    Set([id]),
                    baseURL: storageURL
                )
                try LocalJSONStoreTransaction.save(
                    sessions,
                    fileName: "story_sessions.json",
                    baseURL: storageURL
                )
            }
        }
    }
}

/// 同じ生成結果が一つのセッションへ二重保存された場合の永続データ修復。
/// UI側で隠すのではなく、読み込み時に同一話者・同一本文・同一生成IDの
/// 隣接レコードだけを正規化する。旧データやユーザー発言/system通知には
/// 生成IDがないため、意図的な反復を壊さず本文をそのまま保持する。
private enum StorySessionMessageRepair {
    static func repaired(_ session: StorySession) -> StorySession {
        var repaired = session
        // 同一生成IDを持つ「同じ話者の同じ本文」が隣接している場合だけ修復する。
        // 生成IDのない旧レコードは重複を推測せず、意図的な反復を保持する。
        var previousGeneratedKey: String?
        repaired.messages = session.messages.filter { message in
            let key: String
            switch message.author {
            case .narrator:
                key = "narrator"
            case let .cast(characterID, _):
                key = "cast:\(characterID.uuidString)"
            case .user, .system:
                previousGeneratedKey = nil
                return true
            }

            let normalized = normalize(message.text)
            if isPlaceholder(message.text) {
                NSLog(
                    "[StorySession] removed placeholder generated message session=%@ message=%@",
                    session.id.uuidString,
                    message.id.uuidString
                )
                previousGeneratedKey = nil
                return false
            }
            guard normalized.count >= 4 else {
                previousGeneratedKey = nil
                return true
            }
            guard let generationID = message.generationID else {
                previousGeneratedKey = nil
                return true
            }
            let generatedKey = generationID.uuidString + "|" + key + "|" + normalized
            defer { previousGeneratedKey = generatedKey }
            return previousGeneratedKey != generatedKey
        }
        return repaired
    }

    private static func normalize(_ value: String) -> String {
        value
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .filter { scalar in
                !CharacterSet.whitespacesAndNewlines.contains(scalar)
                    && !CharacterSet.punctuationCharacters.contains(scalar)
            }
            .map(String.init)
            .joined()
    }

    private static func isPlaceholder(_ value: String) -> Bool {
        ["…", "・・・", "・・", "...", "..", "."].contains(
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

// MARK: - Local Lorebook implementation

/// 現在はローカルJSON。Repository境界はクラウド同期実装と共通にする。
final class LocalJSONStoryLorebookRepository: StoryLorebookRepository {
    private let store = LocalJSONStore<StoryLorebookEntry>(fileName: "story_lorebook.json")

    func fetchEntries(storyWorldId: UUID) async throws -> [StoryLorebookEntry] {
        try await store.loadRecoveringCorruptRecords()
            .filter { $0.storyWorldId == storyWorldId && $0.isEnabled }
            .sorted { $0.priority > $1.priority }
    }

    func fetchAllEntries(storyWorldId: UUID) async throws -> [StoryLorebookEntry] {
        try await store.loadRecoveringCorruptRecords()
            .filter { $0.storyWorldId == storyWorldId }
            .sorted { $0.priority > $1.priority }
    }

    func replaceEntries(_ entries: [StoryLorebookEntry], storyWorldId: UUID) async throws {
        let replacement = entries.map { entry in
            var entry = entry
            entry.storyWorldId = storyWorldId
            entry.updatedAt = Date()
            return entry
        }
        try await store.mutate { all in
            all.removeAll { $0.storyWorldId == storyWorldId }
            all.append(contentsOf: replacement)
        }
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
final class LocalJSONStoryMemoryRepository: StoryMemoryRepository, LocalJSONMemoryFileIdentityProviding {
    private struct MemoryScope: Hashable, Sendable {
        let storyWorldId: UUID
        let storySessionId: UUID?
    }

    private let store: LocalJSONStore<StoryMemory>
    let storageURL: URL
    let fileName: String
    private let perScopeLimit: Int

    init(
        fileName: String = "story_memories.json",
        storageURL: URL = KizunaDataMigration.characterLibraryURL,
        perScopeLimit: Int = 120
    ) {
        self.perScopeLimit = max(1, perScopeLimit)
        self.storageURL = storageURL
        self.fileName = fileName
        store = LocalJSONStore<StoryMemory>(fileName: fileName, baseURL: storageURL)
    }

    func fetchMemories(storyWorldId: UUID) async throws -> [StoryMemory] {
        try await store.loadRecoveringCorruptRecords()
            .filter { $0.storyWorldId == storyWorldId }
            .sorted { lhs, rhs in
                if lhs.importance != rhs.importance { return lhs.importance > rhs.importance }
                return (lhs.lastUsedAt ?? lhs.createdAt) > (rhs.lastUsedAt ?? rhs.createdAt)
            }
    }

    func fetchMemories(storyWorldId: UUID, storySessionId: UUID) async throws -> [StoryMemory] {
        let memories = try await store.loadRecoveringCorruptRecords()
            .filter { $0.storyWorldId == storyWorldId }
        return StoryMemory.scoped(to: storySessionId, from: memories)
            .sorted { lhs, rhs in
                if lhs.importance != rhs.importance { return lhs.importance > rhs.importance }
                return (lhs.lastUsedAt ?? lhs.createdAt) > (rhs.lastUsedAt ?? rhs.createdAt)
            }
    }

    func saveMemory(_ memory: StoryMemory) async throws {
        let storageURL = self.storageURL
        let perScopeLimit = self.perScopeLimit
        try await store.mutate { all in
            if let sessionID = memory.storySessionId {
                let tombstones = try StoryTurnJournal.loadTombstonesUnlocked(baseURL: storageURL)
                try StoryTurnJournal.ensureRecordIsNotDeletedUnlocked(
                    recordID: sessionID,
                    recordKind: .session,
                    tombstones: tombstones
                )
            }
            Self.mergeMemory(
                memory,
                &all,
                perScopeLimit: perScopeLimit
            )
        }
    }

    /// Applies one memory save to an already-loaded collection. The regular
    /// repository and the retry transaction share this implementation so a
    /// retry cannot silently change dedupe, provenance, or limit behavior.
    static func mergeMemory(
        _ memory: StoryMemory,
        _ all: inout [StoryMemory],
        perScopeLimit: Int = 120
    ) {
        let normalized = Self.normalize(memory.text)
        var incoming = memory
        let now = Date()
        for sourceTurnId in incoming.sourceTurnIds {
            var metadata = incoming.sourceTurnMetadata[sourceTurnId]
                ?? StoryMemorySourceMetadata(
                    importance: incoming.importance,
                    createdAt: incoming.createdAt,
                    lastUsedAt: incoming.lastUsedAt
                )
            metadata.lastUsedAt = now
            incoming.sourceTurnMetadata[sourceTurnId] = metadata
        }
        if let index = all.firstIndex(where: {
            // 同じ本文でもキャラクターごとの記憶は別レコードとして保持する。
            // world/textだけをキーにすると、別キャラの帰属・カテゴリ・出典が
            // 最初のレコードへ統合されてしまい、次回のプロンプト選択も壊れる。
            $0.storyWorldId == incoming.storyWorldId
                && $0.storySessionId == incoming.storySessionId
                && $0.characterId == incoming.characterId
                && $0.category == incoming.category
                && $0.source == incoming.source
                // A source-less legacy record is not interchangeable with a
                // record whose identity is tied to one or more turns. Keep
                // both records so removing provenance cannot delete the
                // legacy record indirectly.
                && $0.sourceTurnIds.isEmpty == incoming.sourceTurnIds.isEmpty
                && Self.normalize($0.text) == normalized
        }) {
            var existing = all[index]
            if incoming.sourceTurnIds.isEmpty {
                existing.importance = max(existing.importance, incoming.importance)
                existing.lastUsedAt = now
                // The identity check above guarantees that this branch only
                // handles source-less legacy records. Never fold a legacy
                // contribution into source metadata for a turn-attributed
                // record; that would make removeSourceTurnIds destructive.
            } else {
                existing.sourceTurnIds.formUnion(incoming.sourceTurnIds)
                existing.sourceTurnMetadata.merge(incoming.sourceTurnMetadata) { _, new in new }
                existing.recomputeAggregatesFromSourceMetadata()
            }
            all[index] = existing
        } else {
            if !incoming.sourceTurnIds.isEmpty {
                // New provenance receives a usage timestamp above. Keep
                // the aggregate fields in sync before the first write;
                // otherwise a newly-created memory would expose a nil
                // lastUsedAt until a later merge or cancellation.
                incoming.recomputeAggregatesFromSourceMetadata()
            }
            all.append(incoming)
        }

        // Sessionごとに上限を設ける。今回の保存対象以外のScopeまで
        // 切り詰めると、新しいSessionの保存が別Sessionやnilの
        // レガシー記録を削除してしまうため、対象Scopeだけを整理する。
        Self.trim(
            &all,
            to: [MemoryScope(
                storyWorldId: incoming.storyWorldId,
                storySessionId: incoming.storySessionId
            )],
            perScopeLimit: max(1, perScopeLimit)
        )
    }

    /// Move a memory without changing its UUID. `saveMemory` intentionally
    /// de-duplicates by world and normalized text, so saving a copy and then
    /// deleting the old UUID can delete the newly moved record as well.
    /// This operation keeps the move atomic inside the JSON store and merges
    /// an existing same-text memory in the destination world.
    func moveMemory(_ memory: StoryMemory, to storyWorldId: UUID) async throws {
        let perScopeLimit = self.perScopeLimit
        try await store.mutate { all in
            guard let sourceIndex = all.firstIndex(where: { $0.id == memory.id }) else { return }
            let normalized = Self.normalize(memory.text)
            if let targetIndex = all.indices.first(where: {
                    $0 != sourceIndex
                        && all[$0].storyWorldId == storyWorldId
                        && all[$0].storySessionId == memory.storySessionId
                        && all[$0].characterId == memory.characterId
                    && all[$0].category == memory.category
                    && all[$0].source == memory.source
                    && all[$0].sourceTurnIds.isEmpty == memory.sourceTurnIds.isEmpty
                    && Self.normalize(all[$0].text) == normalized
            }) {
                var target = all[targetIndex]
                if memory.sourceTurnIds.isEmpty {
                    target.importance = max(target.importance, memory.importance)
                    target.lastUsedAt = max(target.lastUsedAt ?? target.createdAt, memory.lastUsedAt ?? memory.createdAt)
                } else {
                    target.sourceTurnIds.formUnion(memory.sourceTurnIds)
                    target.sourceTurnMetadata.merge(memory.sourceTurnMetadata) { _, new in new }
                    target.recomputeAggregatesFromSourceMetadata()
                }
                all[targetIndex] = target
                all.remove(at: sourceIndex)
            } else {
                var moved = memory
                moved.storyWorldId = storyWorldId
                all[sourceIndex] = moved
            }

            // 移動元で空いた枠と移動先の上限だけを整理する。他のWorldや
            // Sessionの保持順序・件数には触れない。
            Self.trim(
                &all,
                to: [
                    MemoryScope(
                        storyWorldId: memory.storyWorldId,
                        storySessionId: memory.storySessionId
                    ),
                    MemoryScope(
                        storyWorldId: storyWorldId,
                        storySessionId: memory.storySessionId
                    )
                ],
                perScopeLimit: perScopeLimit
            )
        }
    }

    func removeSourceTurnIds(_ sourceTurnIds: Set<UUID>) async throws {
        guard !sourceTurnIds.isEmpty else { return }
        try await store.mutate { all in
            for index in all.indices.reversed() {
                guard !all[index].sourceTurnIds.isDisjoint(with: sourceTurnIds) else { continue }
                all[index].sourceTurnIds.subtract(sourceTurnIds)
                for sourceTurnId in sourceTurnIds {
                    all[index].sourceTurnMetadata.removeValue(forKey: sourceTurnId)
                }
                if all[index].sourceTurnIds.isEmpty {
                    all.remove(at: index)
                } else {
                    all[index].recomputeAggregatesFromSourceMetadata()
                }
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
                for sourceTurnId in all[index].sourceTurnIds {
                    var metadata = all[index].sourceTurnMetadata[sourceTurnId]
                        ?? StoryMemorySourceMetadata(
                            importance: all[index].importance,
                            createdAt: all[index].createdAt,
                            lastUsedAt: all[index].lastUsedAt
                        )
                    metadata.lastUsedAt = now
                    all[index].sourceTurnMetadata[sourceTurnId] = metadata
                }
                all[index].recomputeAggregatesFromSourceMetadata()
            }
        }
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func trim(
        _ all: inout [StoryMemory],
        to scopes: Set<MemoryScope>,
        perScopeLimit: Int
    ) {
        for scope in scopes {
            let scoped = all
                .filter { MemoryScope(storyWorldId: $0.storyWorldId, storySessionId: $0.storySessionId) == scope }
                .sorted {
                    if $0.importance != $1.importance { return $0.importance > $1.importance }
                    return ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt)
                }
            guard scoped.count > perScopeLimit else { continue }
            let keptIDs = Set(scoped.prefix(perScopeLimit).map(\.id))
            all.removeAll {
                MemoryScope(storyWorldId: $0.storyWorldId, storySessionId: $0.storySessionId) == scope
                    && !keptIDs.contains($0.id)
            }
        }
    }
}

/// Coordinates the two memory files with the session tombstone check. The
/// regular repositories intentionally remain independently replaceable, but a
/// retry is one logical write: if deletion wins the shared lock, neither
/// CharacterMemory nor StoryMemory may be recreated for that session.
private enum LocalJSONStoryMemoryRetryMemoryTransaction {
    static func save(
        _ retry: StoryMemoryRetry,
        storageURL: URL
    ) throws -> StoryMemoryRetry? {
        try LocalJSONStoreTransaction.withSharedLock {
            let tombstones = try StoryTurnJournal.loadTombstonesUnlocked(baseURL: storageURL)
            let ownedStoryMemories = retry.storyMemories.map { memory -> StoryMemory in
                var ownedMemory = memory
                if ownedMemory.storySessionId == nil {
                    ownedMemory.storySessionId = retry.storySessionID
                }
                return ownedMemory
            }

            // Validate the envelope and every embedded StoryMemory. Legacy
            // retries may have no envelope ID while still carrying a session
            // ID in the payload; skipping that case can resurrect memory after
            // the session was deleted.
            let sessionIDs = Set(
                [retry.storySessionID].compactMap { $0 }
                    + ownedStoryMemories.compactMap(\.storySessionId)
            )
            guard sessionIDs.count <= 1 else {
                // A single retry must never merge memories from multiple
                // sessions. Keep it durable for diagnosis instead of writing
                // a cross-session partial result.
                return retry
            }
            if sessionIDs.isEmpty, !ownedStoryMemories.isEmpty {
                // A world-scoped legacy StoryMemory has no safe owner. It may
                // not be guessed into whichever Session happens to retry it.
                return retry
            }
            if let sessionID = sessionIDs.first {
                if tombstones.contains(where: {
                    $0.recordID == sessionID && $0.recordKind == .session
                }) {
                    // The retry belongs to an intentionally deleted session.
                    // Returning nil lets the service remove the stale retry
                    // without attempting either memory repository.
                    return nil
                }

                let sessions = try LocalJSONStoreTransaction.load(
                    StorySession.self,
                    fileName: "story_sessions.json",
                    baseURL: storageURL
                )
                guard let session = sessions.first(where: { $0.id == sessionID }) else {
                    // A retry without a live owner is not safe to apply. This
                    // also covers a session removed before its tombstone was
                    // observed by the current process. Keep it durable until
                    // the owner is restored or an explicit tombstone makes it
                    // terminal; nil here would make the service delete a
                    // recoverable retry as if the write had succeeded.
                    return retry
                }
                if let worldID = retry.storyWorldID,
                   session.storyWorldId != worldID {
                    // Preserve the retry for diagnosis/recovery, but do not
                    // write a payload into a different StoryWorld.
                    return retry
                }
                guard ownedStoryMemories.allSatisfy({
                    $0.storyWorldId == session.storyWorldId
                }) else {
                    // The envelope cannot authorize a StoryMemory for another
                    // World. Keep the complete retry for diagnosis instead of
                    // writing a partial cross-World result.
                    return retry
                }
            }

            if !retry.characterMemories.isEmpty {
                var memories = try LocalJSONStoreTransaction.load(
                    CharacterMemory.self,
                    fileName: "memories.json",
                    baseURL: storageURL
                )
                for memory in retry.characterMemories {
                    LocalJSONMemoryRepository.mergeMemory(
                        memory,
                        into: &memories
                    )
                }
                try LocalJSONStoreTransaction.save(
                    memories,
                    fileName: "memories.json",
                    baseURL: storageURL
                )
            }

            if !ownedStoryMemories.isEmpty {
                var memories = try LocalJSONStoreTransaction.load(
                    StoryMemory.self,
                    fileName: "story_memories.json",
                    baseURL: storageURL
                )
                for memory in ownedStoryMemories {
                    LocalJSONStoryMemoryRepository.mergeMemory(
                        memory,
                        &memories
                    )
                }
                try LocalJSONStoreTransaction.save(
                    memories,
                    fileName: "story_memories.json",
                    baseURL: storageURL
                )
            }
            return nil
        }
    }
}

/// Persists memory-only retry work independently from the conversation and
/// memory stores. A failed retry must survive view dismissal and app restart,
/// while a successful retry can remove only its own turnID atomically.
final class LocalJSONStoryMemoryRetryRepository: StoryMemoryRetryRepository, StoryMemoryRetryMemoryTransaction, LocalJSONStorageIdentityProviding {
    private let store: LocalJSONStore<StoryMemoryRetry>
    let storageURL: URL

    init(
        fileName: String = "story_memory_retries.json",
        storageURL: URL = KizunaDataMigration.characterLibraryURL
    ) {
        self.storageURL = storageURL
        self.store = LocalJSONStore<StoryMemoryRetry>(
            fileName: fileName,
            baseURL: storageURL
        )
    }

    func saveMemoryRetryRecords(_ retry: StoryMemoryRetry) async throws -> StoryMemoryRetry? {
        let storageURL = self.storageURL
        return try await LocalJSONStoreTransaction.performOnFileIO {
            try LocalJSONStoryMemoryRetryMemoryTransaction.save(
                retry,
                storageURL: storageURL
            )
        }
    }

    func fetchRetries() async throws -> [StoryMemoryRetry] {
        // LocalJSONStore preserves insertion order. Sorting by UUID changes
        // the user's oldest-first retry order after an app restart.
        try await store.loadRecoveringCorruptRecords()
            .filter { !$0.isCompleted && !$0.isAbandoned }
    }

    func saveRetry(_ retry: StoryMemoryRetry) async throws {
        let storageURL = self.storageURL
        try await store.mutate { retries in
            let sessionIDs = Set(
                [retry.storySessionID].compactMap { $0 }
                    + retry.storyMemories.compactMap(\.storySessionId)
            )
            if !sessionIDs.isEmpty {
                let tombstones = try StoryTurnJournal.loadTombstonesUnlocked(baseURL: storageURL)
                for sessionID in sessionIDs {
                    try StoryTurnJournal.ensureRecordIsNotDeletedUnlocked(
                        recordID: sessionID,
                        recordKind: .session,
                        tombstones: tombstones
                    )
                }
            }
            if let index = retries.firstIndex(where: { $0.turnID == retry.turnID }) {
                retries[index] = retry
            } else {
                retries.append(retry)
            }
        }
    }

    func deleteRetry(turnID: UUID) async throws {
        try await store.delete(matching: { $0.turnID == turnID })
    }
}
