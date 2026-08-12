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
        assistantMessageIDs: [UUID]
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
    func saveMemory(_ memory: StoryMemory) async throws
    func deleteMemory(id: UUID) async throws
    func deleteAllMemories(storyWorldId: UUID) async throws
    func markUsed(ids: [UUID]) async throws
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
        try await store.mutate { scenes in
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
        try await store.mutate { scenes in
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
        try await store.mutate { scenes in
            guard let index = scenes.firstIndex(where: { $0.id == id }) else { return }
            scenes[index].storyWorldId = toStoryWorldId
            scenes[index].persistenceRevision = scenes[index].effectivePersistenceRevision + 1
        }
    }

    func deleteScene(id: UUID) async throws {
        try await store.delete(matching: { $0.id == id })
    }
    func deleteAllScenes(storyWorldId: UUID) async throws {
        try await store.delete(matching: { $0.storyWorldId == storyWorldId })
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
        assistantMessageIDs: [UUID]
    ) async throws -> StorySession {
        let storageURL = self.storageURL
        try await StoryTurnJournal.recoverIfNeededAsync(baseURL: storageURL)
        return try await LocalJSONStoreTransaction.performOnFileIO {
            try LocalJSONStoreTransaction.withSharedLock {
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
                committedScene.updatedAt = now
                committedScene.persistenceRevision = currentScene.effectivePersistenceRevision + 1
            }

            // ジャーナルを先に置いてから2つのスナップショットを更新する。
            // 途中終了時は次回のfetchで両方を再適用する。
            try StoryTurnJournal.prepareUnlocked(
                StoryTurnJournalEntry(turnID: turnID, session: committed, scene: committedScene),
                baseURL: storageURL
            )
            sessions[sessionIndex] = committed
            scenes[sceneIndex] = committedScene
            try LocalJSONStoreTransaction.save(sessions, fileName: "story_sessions.json", baseURL: storageURL)
            try LocalJSONStoreTransaction.save(scenes, fileName: "story_scenes.json", baseURL: storageURL)
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

    /// 重複Worldの移行専用。セッションの所属Worldを変更し、
    /// 進行中turnの古いsnapshotが移行を巻き戻さないようrevisionを進める。
    /// 会話本文のcreatedAtは変更せず、updatedAtだけを移行時刻へ更新する。
    func moveSession(id: UUID, toStoryWorldId: UUID) async throws {
        let storageURL = self.storageURL
        try await StoryTurnJournal.recoverIfNeededAsync(baseURL: storageURL)
        try await LocalJSONStoreTransaction.performOnFileIO {
            try LocalJSONStoreTransaction.withSharedLock {
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
        try await store.delete(matching: { $0.id == id })
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
final class LocalJSONStoryMemoryRepository: StoryMemoryRepository {
    private let store = LocalJSONStore<StoryMemory>(fileName: "story_memories.json")
    private let perWorldLimit = 120

    func fetchMemories(storyWorldId: UUID) async throws -> [StoryMemory] {
        try await store.loadRecoveringCorruptRecords()
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
                // 同じ本文でもキャラクターごとの記憶は別レコードとして保持する。
                // world/textだけをキーにすると、別キャラの帰属・カテゴリ・出典が
                // 最初のレコードへ統合されてしまい、次回のプロンプト選択も壊れる。
                $0.storyWorldId == memory.storyWorldId
                    && $0.characterId == memory.characterId
                    && $0.category == memory.category
                    && $0.source == memory.source
                    && normalize($0.text) == normalized
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

    /// Move a memory without changing its UUID. `saveMemory` intentionally
    /// de-duplicates by world and normalized text, so saving a copy and then
    /// deleting the old UUID can delete the newly moved record as well.
    /// This operation keeps the move atomic inside the JSON store and merges
    /// an existing same-text memory in the destination world.
    func moveMemory(_ memory: StoryMemory, to storyWorldId: UUID) async throws {
        try await store.mutate { all in
            guard let sourceIndex = all.firstIndex(where: { $0.id == memory.id }) else { return }
            let normalized = normalize(memory.text)
            if let targetIndex = all.indices.first(where: {
                $0 != sourceIndex
                    && all[$0].storyWorldId == storyWorldId
                    && all[$0].characterId == memory.characterId
                    && all[$0].category == memory.category
                    && all[$0].source == memory.source
                    && normalize(all[$0].text) == normalized
            }) {
                var target = all[targetIndex]
                target.importance = max(target.importance, memory.importance)
                target.lastUsedAt = max(target.lastUsedAt ?? target.createdAt, memory.lastUsedAt ?? memory.createdAt)
                all[targetIndex] = target
                all.remove(at: sourceIndex)
            } else {
                var moved = memory
                moved.storyWorldId = storyWorldId
                all[sourceIndex] = moved
            }

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
