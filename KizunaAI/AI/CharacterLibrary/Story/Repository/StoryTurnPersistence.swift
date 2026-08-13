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
    nonisolated static let currentID = UUID()
}

/// ターン状態の純粋な遷移部分。ファイルIOや時刻の取得を持たないため、
/// JSONリポジトリのテストとは独立してライフサイクルを検証できる。
enum StoryTurnReducer {
    nonisolated static func begin(
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

    nonisolated static func commit(
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

    nonisolated static func finish(
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
    /// Memory candidates are written with the same journal entry as the
    /// session/scene snapshot. Recovery can therefore preserve the auxiliary
    /// work even if the process exits before the post-commit memory writes.
    let memoryRetries: [StoryMemoryRetry]

    init(
        turnID: UUID,
        session: StorySession,
        scene: StoryScene,
        memoryRetries: [StoryMemoryRetry] = []
    ) {
        self.turnID = turnID
        self.session = session
        self.scene = scene
        self.memoryRetries = memoryRetries
    }

    private enum CodingKeys: String, CodingKey {
        case turnID
        case session
        case scene
        case memoryRetries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        turnID = try container.decode(UUID.self, forKey: .turnID)
        session = try container.decode(StorySession.self, forKey: .session)
        scene = try container.decode(StoryScene.self, forKey: .scene)
        // Existing journal files predate durable auxiliary retries.
        memoryRetries = try container.decodeIfPresent(
            [StoryMemoryRetry].self,
            forKey: .memoryRetries
        ) ?? []
    }
}

/// 2つのJSONファイルへ確定結果を書き込む前に、同じディレクトリへ
/// 小さなジャーナルを原子的に置く。アプリ終了が session/scene の片方の
/// 書き込み直後に起きても、次回の読み込みで同じスナップショットを再適用する。
enum StoryTurnJournal {
    nonisolated private static let fileName = "story_turn_journal.json"
    nonisolated private static let memoryRetryFileName = "story_memory_retries.json"

    private struct RecoverableEntries {
        let entries: [StoryTurnJournalEntry]
        let containsInvalidEntries: Bool
    }

    /// Async repositories use the dedicated file-I/O executor. The original
    /// synchronous entry point remains available for low-level recovery tests.
    /// Do not call this method from inside `performOnFileIO`: that method uses
    /// the same serial queue, so a nested call would wait for itself forever.
    nonisolated static func recoverIfNeededAsync(
        baseURL: URL = KizunaDataMigration.characterLibraryURL
    ) async throws {
        try await LocalJSONStoreTransaction.performOnFileIO {
            try recoverIfNeeded(baseURL: baseURL)
        }
    }

    nonisolated static func recoverIfNeeded(
        baseURL: URL = KizunaDataMigration.characterLibraryURL
    ) throws {
        try LocalJSONStoreTransaction.withSharedLock {
            let decoded: RecoverableEntries
            do {
                decoded = try loadRecoverableEntries(baseURL: baseURL)
            } catch let error as LocalJSONStoreError {
                switch error {
                case .ioFailure:
                    // 読み取り不能は破損と断定できない。active journalも
                    // backupも変更せず、呼び出し元へ返して保存処理を止める。
                    throw error
                case .decode:
                    // ルートJSON自体が配列として復元できない場合だけ、元の
                    // ファイルを退避してactive journalを初期化する。元データ
                    // は必ず同じディレクトリに残るため、復旧材料を失わない。
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
                case .encode:
                    throw error
                }
            }
            let entries = decoded.entries
            guard !entries.isEmpty else {
                if decoded.containsInvalidEntries {
                    let backupURL = try LocalJSONStoreTransaction.backup(fileName: fileName, baseURL: baseURL)
                    try LocalJSONStoreTransaction.save(
                        [StoryTurnJournalEntry](),
                        fileName: fileName,
                        baseURL: baseURL
                    )
                    NSLog(
                        "[StoryTurnJournal] quarantined journal with no decodable entries=%@",
                        backupURL.lastPathComponent
                    )
                }
                return
            }

            let validEntries = entries.filter(isValid)

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

            // 片側recordの欠落は意図的削除か未完了保存かをjournalだけでは
            // 判別できない。欠落した側だけでなく、残っている側も復旧せず、
            // entryをactive journalへ残して後続の復旧機会を維持する。
            var unresolvedEntries: [StoryTurnJournalEntry] = []
            var sessionsChanged = false
            var scenesChanged = false

            for entry in validEntries {
                guard let sessionIndex = sessions.firstIndex(where: { $0.id == entry.session.id }),
                      let sceneIndex = scenes.firstIndex(where: { $0.id == entry.scene.id }) else {
                    unresolvedEntries.append(entry)
                    NSLog(
                        "[StoryTurnJournal] retained journal entry with missing record turn=%@",
                        entry.turnID.uuidString
                    )
                    continue
                }

                if !entry.memoryRetries.isEmpty {
                    do {
                        try mergeMemoryRetriesUnlocked(
                            entry.memoryRetries,
                            baseURL: baseURL
                        )
                    } catch {
                        // Do not consume a journal entry while its auxiliary
                        // retry store is unreadable. The conversation
                        // snapshot and its memory candidates must remain
                        // recoverable on the next launch.
                        unresolvedEntries.append(entry)
                        NSLog(
                            "[StoryTurnJournal] retained entry while merging memory retries turn=%@: %@",
                            entry.turnID.uuidString,
                            error.localizedDescription
                        )
                        continue
                    }
                }

                let persistedSession = sessions[sessionIndex]
                if shouldApply(entry.session, over: persistedSession) {
                    sessions[sessionIndex] = entry.session
                    sessionsChanged = true
                }
                let persistedScene = scenes[sceneIndex]
                if shouldApply(entry.scene, over: persistedScene) {
                    scenes[sceneIndex] = entry.scene
                    scenesChanged = true
                }
            }

            // 壊れたentryや意味的に不正なentryを含む元journalは、正常entryの
            // 復旧前に調査用backupへ保存する。壊れたentryはactive journalから
            // 除外するが、欠落recordのentryは下でactive journalへ保持する。
            let invalidEntries = entries.filter { !isValid($0) }
            let requiresQuarantine = decoded.containsInvalidEntries || !invalidEntries.isEmpty
            if requiresQuarantine {
                let backupURL = try LocalJSONStoreTransaction.backup(fileName: fileName, baseURL: baseURL)
                NSLog(
                    "[StoryTurnJournal] quarantined journal=%@ invalid=%ld unresolved=%ld",
                    backupURL.lastPathComponent,
                    invalidEntries.count,
                    unresolvedEntries.count
                )
            }

            if sessionsChanged {
                try LocalJSONStoreTransaction.save(sessions, fileName: "story_sessions.json", baseURL: baseURL)
            }
            if scenesChanged {
                try LocalJSONStoreTransaction.save(scenes, fileName: "story_scenes.json", baseURL: baseURL)
            }
            // 欠落recordには削除意図を示すtombstoneがないため、entryを
            // active journalへ残す。後でrecordが復元された時にsessionとsceneを
            // 一緒に再適用でき、片側だけの状態を確定させない。
            try LocalJSONStoreTransaction.save(
                unresolvedEntries,
                fileName: fileName,
                baseURL: baseURL
            )
        }
    }

    /// Removes one already-recovered journal entry. This is intentionally a
    /// separate operation from recovery: auxiliary memory work keeps the
    /// journal until it is either persisted in the retry queue or completed.
    nonisolated static func remove(
        turnID: UUID,
        baseURL: URL = KizunaDataMigration.characterLibraryURL
    ) throws {
        try LocalJSONStoreTransaction.withSharedLock {
            try removeUnlocked(turnID: turnID, baseURL: baseURL)
        }
    }

    /// Async callers must use the dedicated file-I/O executor so journal
    /// cleanup cannot block the MainActor. Do not call this from inside
    /// `performOnFileIO`, whose serial queue would otherwise self-deadlock.
    nonisolated static func removeAsync(
        turnID: UUID,
        baseURL: URL = KizunaDataMigration.characterLibraryURL
    ) async throws {
        try await LocalJSONStoreTransaction.performOnFileIO {
            try removeUnlocked(turnID: turnID, baseURL: baseURL)
        }
    }

    /// ルートJSONが配列として読める場合はentry単位でdecodeする。
    /// 配列の一部が壊れていても、正常entryを同じ復旧処理へ渡す。
    /// ファイル読み取り失敗は `ioFailure` のまま呼び出し元へ返し、
    /// 壊れたと断定してjournalを上書きしない。
    private static func loadRecoverableEntries(
        baseURL: URL
    ) throws -> RecoverableEntries {
        let url = baseURL.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return RecoverableEntries(entries: [], containsInvalidEntries: false)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LocalJSONStoreError.ioFailure(underlying: error)
        }

        do {
            guard let rawItems = try JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            ) as? [Any] else {
                throw LocalJSONStoreError.decode(
                    underlying: JournalDecodeError.rootIsNotArray
                )
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var entries: [StoryTurnJournalEntry] = []
            var containsInvalidEntries = false
            for (index, rawItem) in rawItems.enumerated() {
                do {
                    let itemData = try JSONSerialization.data(
                        withJSONObject: rawItem,
                        options: [.fragmentsAllowed]
                    )
                    entries.append(try decoder.decode(StoryTurnJournalEntry.self, from: itemData))
                } catch {
                    containsInvalidEntries = true
                    NSLog(
                        "[StoryTurnJournal] skipped malformed entry index=%ld reason=%@",
                        index,
                        error.localizedDescription
                    )
                }
            }
            return RecoverableEntries(
                entries: entries,
                containsInvalidEntries: containsInvalidEntries
            )
        } catch let error as LocalJSONStoreError {
            throw error
        } catch {
            throw LocalJSONStoreError.decode(underlying: error)
        }
    }

    private enum JournalDecodeError: Error {
        case rootIsNotArray
    }

    nonisolated private static func shouldApply(_ journal: StorySession, over persisted: StorySession) -> Bool {
        if journal.effectivePersistenceRevision != persisted.effectivePersistenceRevision {
            return journal.effectivePersistenceRevision > persisted.effectivePersistenceRevision
        }
        return journal.updatedAt > persisted.updatedAt
    }

    nonisolated private static func isValid(_ entry: StoryTurnJournalEntry) -> Bool {
        guard entry.turnID == entry.session.latestTurnCheckpoint?.turnID,
              entry.session.latestTurnCheckpoint?.status == .committed,
              entry.session.storyWorldId == entry.scene.storyWorldId,
              entry.session.currentSceneId == nil || entry.session.currentSceneId == entry.scene.id else {
            return false
        }
        return true
    }

    nonisolated private static func shouldApply(_ journal: StoryScene, over persisted: StoryScene) -> Bool {
        if journal.effectivePersistenceRevision != persisted.effectivePersistenceRevision {
            return journal.effectivePersistenceRevision > persisted.effectivePersistenceRevision
        }
        return journal.updatedAt > persisted.updatedAt
    }

    /// Merge journal-owned auxiliary work into the durable retry queue while
    /// the same shared lock is held. This is idempotent by turnID and keeps
    /// retries from a newer journal snapshot instead of duplicating them.
    private static func mergeMemoryRetriesUnlocked(
        _ retries: [StoryMemoryRetry],
        baseURL: URL
    ) throws {
        guard !retries.isEmpty else { return }
        var existing = try loadMemoryRetriesUnlocked(baseURL: baseURL)
        for retry in retries {
            if let index = existing.firstIndex(where: { $0.turnID == retry.turnID }) {
                existing[index] = retry
            } else {
                existing.append(retry)
            }
        }
        try LocalJSONStoreTransaction.save(
            existing,
            fileName: memoryRetryFileName,
            baseURL: baseURL
        )
    }

    /// The normal repository can salvage malformed array members through its
    /// actor-backed store. Journal recovery runs synchronously under the
    /// shared lock, so it needs the same behavior without awaiting an actor.
    /// A successful repair keeps valid records, backs up the original, and
    /// lets the caller merge the new journal-owned candidates atomically.
    private static func loadMemoryRetriesUnlocked(
        baseURL: URL
    ) throws -> [StoryMemoryRetry] {
        do {
            return try LocalJSONStoreTransaction.load(
                StoryMemoryRetry.self,
                fileName: memoryRetryFileName,
                baseURL: baseURL
            )
        } catch let error as LocalJSONStoreError {
            guard case .decode = error else { throw error }
            let url = baseURL.appendingPathComponent(memoryRetryFileName)
            guard FileManager.default.fileExists(atPath: url.path) else { throw error }
            let data = try Data(contentsOf: url)
            guard let rawItems = try JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            ) as? [Any] else {
                let backupURL = try LocalJSONStoreTransaction.backup(
                    fileName: memoryRetryFileName,
                    baseURL: baseURL
                )
                try LocalJSONStoreTransaction.save(
                    [StoryMemoryRetry](),
                    fileName: memoryRetryFileName,
                    baseURL: baseURL
                )
                NSLog(
                    "[StoryTurnJournal] quarantined malformed memory retry file=%@",
                    backupURL.lastPathComponent
                )
                return []
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var validItems: [StoryMemoryRetry] = []
            var invalidCount = 0
            for rawItem in rawItems {
                do {
                    let itemData = try JSONSerialization.data(
                        withJSONObject: rawItem,
                        options: [.fragmentsAllowed]
                    )
                    validItems.append(try decoder.decode(StoryMemoryRetry.self, from: itemData))
                } catch {
                    invalidCount += 1
                }
            }
            guard invalidCount > 0 else { throw error }

            let backupURL = try LocalJSONStoreTransaction.backup(
                fileName: memoryRetryFileName,
                baseURL: baseURL
            )
            try LocalJSONStoreTransaction.save(
                validItems,
                fileName: memoryRetryFileName,
                baseURL: baseURL
            )
            NSLog(
                "[StoryTurnJournal] repaired memory retry file=%@ valid=%ld invalid=%ld",
                backupURL.lastPathComponent,
                validItems.count,
                invalidCount
            )
            return validItems
        }
    }
}

extension StoryTurnJournal {
    /// Repository実装だけがジャーナルの全体を扱うための短い書き込みAPI。
    /// 同じファイルロックの中から呼び出す前提で、二重ロックはしない。
    nonisolated static func prepareUnlocked(
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

    nonisolated static func removeUnlocked(
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
