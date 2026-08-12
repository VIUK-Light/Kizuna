/*
  仕様:
  - 役割: StorySession の1ターン境界を、生成処理から分離して永続化する。
  - 方針: モデル生成中はファイルロックを保持しない。開始・確定・終了だけを
    短い read-modify-write として実行し、同じ turnID の再実行を冪等にする。
  - 互換性: 既存 StorySession は revision/checkpoint が nil のまま読み込み、
    最初の新しいターン開始時に世代を付与する。
*/

import Foundation

enum StoryTurnPersistenceError: Error, Equatable {
    case sessionNotFound
    case revisionConflict(expected: UInt64, actual: UInt64)
    case turnInProgress
    case turnNotPending
    case worldMismatch
    case sceneConflict
    case corruptJournal
}

enum StoryTurnOwner {
    /// アプリプロセス内で共有する所有者ID。プロセスが再起動すると変わる。
    static let currentID = UUID()
}

/// ターン状態の純粋な遷移部分。ファイルIOや時刻の取得を持たないため、
/// JSONリポジトリのテストとは独立してライフサイクルを検証できる。
enum StoryTurnReducer {
    static func begin(
        turnID: UUID,
        userMessageID: UUID,
        attempt: Int,
        ownerID: UUID? = StoryTurnOwner.currentID,
        baseRevision: UInt64,
        startedAt: Date,
        updatedAt: Date
    ) -> StoryTurnCheckpoint {
        StoryTurnCheckpoint(
            turnID: turnID,
            userMessageID: userMessageID,
            status: .pending,
            attempt: attempt,
            ownerID: ownerID,
            baseRevision: baseRevision,
            startedAt: startedAt,
            updatedAt: updatedAt
        )
    }

    static func commit(
        pending: StoryTurnCheckpoint,
        assistantMessageIDs: [UUID],
        updatedAt: Date
    ) -> StoryTurnCheckpoint {
        StoryTurnCheckpoint(
            turnID: pending.turnID,
            userMessageID: pending.userMessageID,
            status: .committed,
            attempt: pending.attempt,
            ownerID: pending.ownerID,
            baseRevision: pending.baseRevision,
            assistantMessageIDs: assistantMessageIDs,
            startedAt: pending.startedAt,
            updatedAt: updatedAt
        )
    }

    static func finish(
        pending: StoryTurnCheckpoint,
        status: StoryTurnStatus,
        failureCode: String?,
        updatedAt: Date
    ) -> StoryTurnCheckpoint {
        StoryTurnCheckpoint(
            turnID: pending.turnID,
            userMessageID: pending.userMessageID,
            status: status,
            attempt: pending.attempt,
            ownerID: pending.ownerID,
            baseRevision: pending.baseRevision,
            assistantMessageIDs: pending.assistantMessageIDs,
            startedAt: pending.startedAt,
            updatedAt: updatedAt,
            failureCode: failureCode
        )
    }
}

struct StoryTurnJournalEntry: Codable, Equatable {
    let turnID: UUID
    let session: StorySession
    let scene: StoryScene
}

/// 2つのJSONファイルへ確定結果を書き込む前に、同じディレクトリへ
/// 小さなジャーナルを原子的に置く。アプリ終了が session/scene の片方の
/// 書き込み直後に起きても、次回の読み込みで同じスナップショットを再適用する。
enum StoryTurnJournal {
    private static let fileName = "story_turn_journal.json"

    static func recoverIfNeeded(
        baseURL: URL = KizunaDataMigration.characterLibraryURL
    ) throws {
        try LocalJSONStoreTransaction.withSharedLock {
            let entries: [StoryTurnJournalEntry]
            do {
                entries = try LocalJSONStoreTransaction.load(
                    StoryTurnJournalEntry.self,
                    fileName: fileName,
                    baseURL: baseURL
                )
            } catch {
                // 壊れたjournalを残したままにすると、全てのStory read/writeが
                // 同じdecode errorで停止する。元ファイルを退避してから空journalへ
                // 戻し、部分コミットの調査材料を失わないようにする。
                let backupURL = try LocalJSONStoreTransaction.backup(fileName: fileName, baseURL: baseURL)
                try LocalJSONStoreTransaction.save(
                    [StoryTurnJournalEntry](),
                    fileName: fileName,
                    baseURL: baseURL
                )
                NSLog(
                    "[StoryTurnJournal] quarantined corrupt journal=%@ reason=%@",
                    backupURL.lastPathComponent,
                    error.localizedDescription
                )
                return
            }
            guard !entries.isEmpty else { return }

            guard entries.allSatisfy({ entry in
                guard entry.turnID == entry.session.latestTurnCheckpoint?.turnID,
                      entry.session.latestTurnCheckpoint?.status == .committed,
                      entry.session.storyWorldId == entry.scene.storyWorldId,
                      entry.session.currentSceneId == nil || entry.session.currentSceneId == entry.scene.id else {
                    return false
                }
                return true
            }) else {
                let backupURL = try LocalJSONStoreTransaction.backup(fileName: fileName, baseURL: baseURL)
                try LocalJSONStoreTransaction.save(
                    [StoryTurnJournalEntry](),
                    fileName: fileName,
                    baseURL: baseURL
                )
                NSLog(
                    "[StoryTurnJournal] quarantined semantically invalid journal=%@",
                    backupURL.lastPathComponent
                )
                return
            }

            var sessions = try LocalJSONStoreTransaction.load(
                StorySession.self,
                fileName: "story_sessions.json",
                baseURL: baseURL
            )
            var scenes = try LocalJSONStoreTransaction.load(
                StoryScene.self,
                fileName: "story_scenes.json",
                baseURL: baseURL
            )

            for entry in entries {
                guard let sessionIndex = sessions.firstIndex(where: { $0.id == entry.session.id }),
                      let sceneIndex = scenes.firstIndex(where: { $0.id == entry.scene.id }) else {
                    // A missing record may have been intentionally deleted
                    // after the commit. Do not resurrect it from a stale
                    // journal; the next normal save will create a fresh entry.
                    NSLog(
                        "[StoryTurnJournal] skipped replay for missing record turn=%@",
                        entry.turnID.uuidString
                    )
                    continue
                }
                let persistedSession = sessions[sessionIndex]
                if shouldApply(entry.session, over: persistedSession) {
                    sessions[sessionIndex] = entry.session
                }
                let persistedScene = scenes[sceneIndex]
                if shouldApply(entry.scene, over: persistedScene) {
                    scenes[sceneIndex] = entry.scene
                }
            }
            try LocalJSONStoreTransaction.save(sessions, fileName: "story_sessions.json", baseURL: baseURL)
            try LocalJSONStoreTransaction.save(scenes, fileName: "story_scenes.json", baseURL: baseURL)
            // journalを空配列としてatomic writeする。削除ではなく空配列に
            // することで、次回の保存先初期化と同じ形式を保つ。
            try LocalJSONStoreTransaction.save([StoryTurnJournalEntry](), fileName: fileName, baseURL: baseURL)
        }
    }

    private static func shouldApply(_ journal: StorySession, over persisted: StorySession) -> Bool {
        if journal.effectivePersistenceRevision != persisted.effectivePersistenceRevision {
            return journal.effectivePersistenceRevision > persisted.effectivePersistenceRevision
        }
        return journal.updatedAt > persisted.updatedAt
    }

    private static func shouldApply(_ journal: StoryScene, over persisted: StoryScene) -> Bool {
        journal.updatedAt > persisted.updatedAt
    }
}

extension StoryTurnJournal {
    /// Repository実装だけがジャーナルの全体を扱うための短い書き込みAPI。
    /// 同じファイルロックの中から呼び出す前提で、二重ロックはしない。
    static func prepareUnlocked(
        _ entry: StoryTurnJournalEntry,
        baseURL: URL = KizunaDataMigration.characterLibraryURL
    ) throws {
        var entries = try LocalJSONStoreTransaction.load(
            StoryTurnJournalEntry.self,
            fileName: fileName,
            baseURL: baseURL
        )
        entries.removeAll { $0.turnID == entry.turnID }
        entries.append(entry)
        try LocalJSONStoreTransaction.save(entries, fileName: fileName, baseURL: baseURL)
    }

    static func removeUnlocked(
        turnID: UUID,
        baseURL: URL = KizunaDataMigration.characterLibraryURL
    ) throws {
        var entries = try LocalJSONStoreTransaction.load(
            StoryTurnJournalEntry.self,
            fileName: fileName,
            baseURL: baseURL
        )
        entries.removeAll { $0.turnID == turnID }
        try LocalJSONStoreTransaction.save(entries, fileName: fileName, baseURL: baseURL)
    }
}
