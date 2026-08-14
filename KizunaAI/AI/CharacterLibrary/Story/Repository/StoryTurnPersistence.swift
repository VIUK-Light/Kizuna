/*
  仕様:
  - 役割: StorySession の1ターン境界を、生成処理から分離して永続化する。
  - 方針: モデル生成中はファイルロックを保持しない。開始・確定・終了だけを
    短い read-modify-write として実行し、同じ turnID の再実行を冪等にする。
  - 互換性: 既存 StorySession は revision/checkpoint が nil のまま読み込み、
    最初の新しいターン開始時に世代を付与する。
*/

import Foundation

enum StoryTurnJournalRecordKind: String, Codable, Equatable, Hashable {
    case session
    case scene
}

struct StoryTurnJournalTombstone: Codable, Equatable, Hashable {
    let recordID: UUID
    let recordKind: StoryTurnJournalRecordKind
    let deletedAt: Date
}

enum StoryTurnPersistenceError: Error, Equatable {
    case sessionNotFound
    case revisionConflict(expected: UInt64, actual: UInt64)
    case turnInProgress
    case turnNotPending
    case worldMismatch
    case sceneConflict
    case recordDeleted(kind: StoryTurnJournalRecordKind, id: UUID)
    case corruptJournal
}

/// 同一プロセス内で現在生存しているStorySessionServiceを識別する。
/// 永続化されたownerIDだけではServiceのdeinitを検知できないため、
/// 新しい画面が古い画面の実行中turnを誤って中断しないよう登録状態を持つ。
final class StoryTurnOwnerRegistry: @unchecked Sendable {
    static let shared = StoryTurnOwnerRegistry()

    private let lock = NSLock()
    private var owners = Set<UUID>()

    @discardableResult
    func register() -> UUID {
        register(UUID())
    }

    @discardableResult
    func register(_ ownerID: UUID) -> UUID {
        lock.lock()
        owners.insert(ownerID)
        lock.unlock()
        return ownerID
    }

    func unregister(_ ownerID: UUID) {
        lock.lock()
        owners.remove(ownerID)
        lock.unlock()
    }

    func activeOwnerIDs() -> Set<UUID> {
        lock.lock()
        defer { lock.unlock() }
        return owners
    }
}

/// A service-owned registration that can be released from a nonisolated
/// teardown path. The registry itself is lock-protected, so deinit and the
/// MainActor lifecycle methods can safely perform the same idempotent release.
final class StoryTurnOwnerLease: @unchecked Sendable {
    let id: UUID
    private let registry: StoryTurnOwnerRegistry

    init(registry: StoryTurnOwnerRegistry = .shared) {
        self.id = UUID()
        self.registry = registry
        registry.register(id)
    }

    func register() {
        registry.register(id)
    }

    func unregister() {
        registry.unregister(id)
    }
}

enum StoryTurnOwner {
    /// 旧保存データと低レベルReducerの互換性用。実際のServiceは
    /// `StoryTurnOwnerRegistry`からインスタンス単位のIDを取得する。
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
    nonisolated private static let tombstoneFileName = "story_turn_journal_tombstones.json"

    private enum RecordOrdering: Equatable {
        case older
        case equal
        /// Revision and timestamp are tied, but the payload differs. There is
        /// no safe ordering signal, so the enclosing pair must remain in the
        /// journal for a later, explicit resolution.
        case ambiguous
        case newer
    }

    private enum PairRecoveryDecision: Equatable {
        case apply
        case discard
        case retain
    }

    private struct TombstoneFileSignature: Equatable {
        let basePath: String
        let exists: Bool
        let byteCount: UInt64
        let modificationDate: Date?
    }

    private final class TombstoneCache: @unchecked Sendable {
        struct Entry {
            let signature: TombstoneFileSignature
            let values: [StoryTurnJournalTombstone]
            var needsReconciliation: Bool
        }

        var entry: Entry?
    }

    // All callers of the `Unlocked` APIs already hold the shared file lock.
    // The reference wrapper keeps this process-wide cache compatible with
    // Swift's strict-concurrency checks while the lock serializes mutation.
    nonisolated private static let tombstoneCache = TombstoneCache()

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
            // Read deletion intent before any journal quarantine or repair.
            // A malformed tombstone must fail closed even when the journal
            // root is malformed too.
            let tombstones = try loadTombstonesUnlocked(baseURL: baseURL)
            try reconcileTombstonesUnlocked(tombstones, baseURL: baseURL)

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
                try purgeCompletedMemoryRetriesUnlocked(
                    keepingTurnIDs: [],
                    baseURL: baseURL
                )
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
                if hasTombstone(
                    recordID: entry.session.id,
                    recordKind: .session,
                    in: tombstones
                ) || hasTombstone(
                    recordID: entry.scene.id,
                    recordKind: .scene,
                    in: tombstones
                ) {
                    // A turn snapshot is a pair. If either side was explicitly
                    // deleted, never replay the other side by itself.
                    NSLog(
                        "[StoryTurnJournal] discarded tombstoned entry turn=%@",
                        entry.turnID.uuidString
                    )
                    try purgeMemoryRetriesForTurnIDsUnlocked(
                        Set([entry.turnID]),
                        baseURL: baseURL
                    )
                    continue
                }
                guard let sessionIndex = sessions.firstIndex(where: { $0.id == entry.session.id }),
                      let sceneIndex = scenes.firstIndex(where: { $0.id == entry.scene.id }) else {
                    unresolvedEntries.append(entry)
                    NSLog(
                        "[StoryTurnJournal] retained journal entry with missing record turn=%@",
                        entry.turnID.uuidString
                    )
                    continue
                }

                let persistedSession = sessions[sessionIndex]
                let persistedScene = scenes[sceneIndex]
                let sessionOrdering = ordering(entry.session, over: persistedSession)
                let sceneOrdering = ordering(entry.scene, over: persistedScene)

                let decision = recoveryDecision(
                    session: sessionOrdering,
                    scene: sceneOrdering
                )
                switch decision {
                case .retain:
                    // A pair cannot be consumed when one side is newer than
                    // the other, or when either side has an equal-metadata
                    // payload mismatch. Do not hand off memory retries before
                    // the pair decision is known.
                    unresolvedEntries.append(entry)
                    NSLog(
                        "[StoryTurnJournal] retained unresolved pair turn=%@ session=%@ scene=%@",
                        entry.turnID.uuidString,
                        String(describing: sessionOrdering),
                        String(describing: sceneOrdering)
                    )
                    continue
                case .discard, .apply:
                    // A stale pair must not overwrite a later pair, but its
                    // auxiliary memory work is still valid. The later pair
                    // may have been committed before the memory writes
                    // completed, so dropping these retries would lose
                    // session-owned memories. Handoff is idempotent by
                    // turnID and must finish before consuming the journal.
                    if !entry.memoryRetries.isEmpty {
                        do {
                            try mergeMemoryRetriesUnlocked(
                                entry.memoryRetries,
                                baseURL: baseURL
                            )
                        } catch {
                            // Do not consume an entry while its auxiliary
                            // retry store is unreadable. The memory
                            // candidates remain recoverable on the next
                            // launch.
                            unresolvedEntries.append(entry)
                            NSLog(
                                "[StoryTurnJournal] retained entry while merging memory retries turn=%@: %@",
                                entry.turnID.uuidString,
                                error.localizedDescription
                            )
                            continue
                        }
                    }
                    if decision == .discard {
                        continue
                    }
                }

                if sessionOrdering == .newer {
                    sessions[sessionIndex] = entry.session
                    sessionsChanged = true
                }
                if sceneOrdering == .newer {
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
            try purgeCompletedMemoryRetriesUnlocked(
                keepingTurnIDs: Set(unresolvedEntries.map(\.turnID)),
                baseURL: baseURL
            )
        }
    }

    /// Removes one already-recovered journal entry. This is intentionally a
    /// separate operation from recovery: auxiliary memory work keeps the
    /// journal until it is either persisted in the retry queue or completed.
    static func remove(
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

            let decoder = LocalJSONStoreCoding.makeDecoder()
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

    nonisolated private static func recoveryDecision(
        session: RecordOrdering,
        scene: RecordOrdering
    ) -> PairRecoveryDecision {
        switch (session, scene) {
        case (.ambiguous, _), (_, .ambiguous):
            return .retain
        case (.newer, .older), (.older, .newer):
            return .retain
        case (.newer, _), (_, .newer):
            return .apply
        case (.older, _), (_, .older), (.equal, .equal):
            return .discard
        }
    }

    nonisolated private static func ordering(
        _ journal: StorySession,
        over persisted: StorySession
    ) -> RecordOrdering {
        if journal.effectivePersistenceRevision != persisted.effectivePersistenceRevision {
            return journal.effectivePersistenceRevision > persisted.effectivePersistenceRevision
                ? .newer
                : .older
        }
        if journal.updatedAt != persisted.updatedAt {
            return journal.updatedAt > persisted.updatedAt ? .newer : .older
        }
        return journal == persisted ? .equal : .ambiguous
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

    nonisolated private static func ordering(
        _ journal: StoryScene,
        over persisted: StoryScene
    ) -> RecordOrdering {
        if journal.effectivePersistenceRevision != persisted.effectivePersistenceRevision {
            return journal.effectivePersistenceRevision > persisted.effectivePersistenceRevision
                ? .newer
                : .older
        }
        if journal.updatedAt != persisted.updatedAt {
            return journal.updatedAt > persisted.updatedAt ? .newer : .older
        }
        return journal == persisted ? .equal : .ambiguous
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
                // A completion marker is newer than the journal payload. Do
                // not resurrect an already-successful retry after a crash.
                if !existing[index].isCompleted || retry.isCompleted {
                    existing[index] = retry
                }
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

    private static func purgeCompletedMemoryRetriesUnlocked(
        keepingTurnIDs: Set<UUID>,
        baseURL: URL
    ) throws {
        let existing = try loadMemoryRetriesUnlocked(baseURL: baseURL)
        let retained = existing.filter { retry in
            !retry.isCompleted || keepingTurnIDs.contains(retry.turnID)
        }
        guard retained.count != existing.count else { return }
        try LocalJSONStoreTransaction.save(
            retained,
            fileName: memoryRetryFileName,
            baseURL: baseURL
        )
    }

    /// A tombstoned pair must not leave a retry that can later recreate memory
    /// for the deleted turn. This runs under the same shared lock as journal
    /// recovery, so the deletion fence and retry purge are observed together.
    private static func purgeMemoryRetriesForTurnIDsUnlocked(
        _ turnIDs: Set<UUID>,
        baseURL: URL
    ) throws {
        guard !turnIDs.isEmpty else { return }
        let existing = try loadMemoryRetriesUnlocked(baseURL: baseURL)
        let retained = existing.filter { !turnIDs.contains($0.turnID) }
        guard retained.count != existing.count else { return }
        try LocalJSONStoreTransaction.save(
            retained,
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
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw LocalJSONStoreError.ioFailure(underlying: error)
            }
            let rawObject: Any
            do {
                rawObject = try JSONSerialization.jsonObject(
                    with: data,
                    options: [.fragmentsAllowed]
                )
            } catch {
                throw LocalJSONStoreError.decode(underlying: error)
            }
            guard let rawItems = rawObject as? [Any] else {
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

            let decoder = LocalJSONStoreCoding.makeDecoder()
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

    /// Explicitly deleting a session also invalidates retry records that name
    /// that session. Legacy world-only retries are retained because their
    /// ownership cannot be inferred safely.
    private static func purgeMemoryRetriesForDeletedSessionsUnlocked(
        _ tombstones: [StoryTurnJournalTombstone],
        baseURL: URL
    ) throws {
        let deletedSessionIDs = Set(
            tombstones
                .filter { $0.recordKind == .session }
                .map(\.recordID)
        )
        guard !deletedSessionIDs.isEmpty else { return }

        let retries = try loadMemoryRetriesUnlocked(baseURL: baseURL)
        let retained = retries.filter { retry in
            let directSessionID = retry.storySessionID
            let embeddedSessionIDs = retry.storyMemories.compactMap(\.storySessionId)
            return !(directSessionID.map(deletedSessionIDs.contains) == true
                || embeddedSessionIDs.contains(where: deletedSessionIDs.contains))
        }
        guard retained.count != retries.count else { return }
        try LocalJSONStoreTransaction.save(
            retained,
            fileName: memoryRetryFileName,
            baseURL: baseURL
        )
    }
}

extension StoryTurnJournal {
    /// Load the deletion markers while the caller already owns the shared lock.
    /// A missing file is the backward-compatible empty state; malformed or
    /// unreadable data is propagated so callers fail closed.
    nonisolated static func loadTombstonesUnlocked(
        baseURL: URL = KizunaDataMigration.characterLibraryURL
    ) throws -> [StoryTurnJournalTombstone] {
        let signature = tombstoneFileSignature(baseURL: baseURL)
        if let cached = tombstoneCache.entry,
           cached.signature == signature {
            return cached.values
        }
        let values = try LocalJSONStoreTransaction.load(
            StoryTurnJournalTombstone.self,
            fileName: tombstoneFileName,
            baseURL: baseURL
        )
        tombstoneCache.entry = TombstoneCache.Entry(
            signature: signature,
            values: values,
            needsReconciliation: true
        )
        return values
    }

    nonisolated static func saveTombstonesUnlocked(
        _ tombstones: [StoryTurnJournalTombstone],
        baseURL: URL = KizunaDataMigration.characterLibraryURL
    ) throws {
        try LocalJSONStoreTransaction.save(
            tombstones,
            fileName: tombstoneFileName,
            baseURL: baseURL
        )
        tombstoneCache.entry = TombstoneCache.Entry(
            signature: tombstoneFileSignature(baseURL: baseURL),
            values: tombstones,
            needsReconciliation: true
        )
    }

    nonisolated static func hasTombstoneUnlocked(
        recordID: UUID,
        recordKind: StoryTurnJournalRecordKind,
        baseURL: URL = KizunaDataMigration.characterLibraryURL
    ) throws -> Bool {
        hasTombstone(
            recordID: recordID,
            recordKind: recordKind,
            in: try loadTombstonesUnlocked(baseURL: baseURL)
        )
    }

    nonisolated static func ensureRecordIsNotDeletedUnlocked(
        recordID: UUID,
        recordKind: StoryTurnJournalRecordKind,
        baseURL: URL = KizunaDataMigration.characterLibraryURL
    ) throws {
        let tombstones = try loadTombstonesUnlocked(baseURL: baseURL)
        try ensureRecordIsNotDeletedUnlocked(
            recordID: recordID,
            recordKind: recordKind,
            tombstones: tombstones
        )
    }

    nonisolated static func ensureRecordIsNotDeletedUnlocked(
        recordID: UUID,
        recordKind: StoryTurnJournalRecordKind,
        tombstones: [StoryTurnJournalTombstone]
    ) throws {
        guard !hasTombstone(
            recordID: recordID,
            recordKind: recordKind,
            in: tombstones
        ) else {
            throw StoryTurnPersistenceError.recordDeleted(kind: recordKind, id: recordID)
        }
    }

    /// Record an intentional deletion. This is idempotent and must be called
    /// while the caller owns LocalJSONStoreFileLock.shared. Callers persist the
    /// tombstone before removing the record; recovery then completes the delete
    /// if the process stops between those two writes.
    nonisolated static func recordDeletionUnlocked(
        recordID: UUID,
        recordKind: StoryTurnJournalRecordKind,
        deletedAt: Date = Date(),
        baseURL: URL = KizunaDataMigration.characterLibraryURL
    ) throws {
        try recordDeletionsUnlocked(
            recordIDs: [recordID],
            recordKind: recordKind,
            deletedAt: deletedAt,
            baseURL: baseURL
        )
    }

    nonisolated static func recordDeletionsUnlocked(
        recordIDs: [UUID],
        recordKind: StoryTurnJournalRecordKind,
        deletedAt: Date = Date(),
        baseURL: URL = KizunaDataMigration.characterLibraryURL
    ) throws {
        let uniqueRecordIDs = Array(Set(recordIDs))
        guard !uniqueRecordIDs.isEmpty else { return }
        var tombstones = try loadTombstonesUnlocked(baseURL: baseURL)
        var changed = false
        for recordID in uniqueRecordIDs where !hasTombstone(
            recordID: recordID,
            recordKind: recordKind,
            in: tombstones
        ) {
            tombstones.append(
                StoryTurnJournalTombstone(
                    recordID: recordID,
                    recordKind: recordKind,
                    deletedAt: deletedAt
                )
            )
            changed = true
        }
        if changed {
            try saveTombstonesUnlocked(tombstones, baseURL: baseURL)
        }
    }

    /// Complete deletion intents that were durable before the corresponding
    /// record file was updated. Tombstones are never removed, so a retry cannot
    /// recreate a deliberately deleted UUID.
    nonisolated private static func reconcileTombstonesUnlocked(
        _ tombstones: [StoryTurnJournalTombstone],
        baseURL: URL
    ) throws {
        let signature = tombstoneFileSignature(baseURL: baseURL)
        guard tombstoneCache.entry?.signature == signature,
              tombstoneCache.entry?.needsReconciliation == true else { return }
        guard !tombstones.isEmpty else {
            tombstoneCache.entry?.needsReconciliation = false
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
        let sessionIDs = Set(
            tombstones
                .filter { $0.recordKind == .session }
                .map(\.recordID)
        )
        let sceneIDs = Set(
            tombstones
                .filter { $0.recordKind == .scene }
                .map(\.recordID)
        )
        try removeStoryMemoriesForDeletedSessionsUnlocked(
            sessionIDs,
            baseURL: baseURL
        )
        let retainedSessions = sessions.filter { !sessionIDs.contains($0.id) }
        let retainedScenes = scenes.filter { !sceneIDs.contains($0.id) }
        try purgeMemoryRetriesForDeletedSessionsUnlocked(
            tombstones,
            baseURL: baseURL
        )
        if retainedSessions.count != sessions.count {
            sessions = retainedSessions
            try LocalJSONStoreTransaction.save(
                sessions,
                fileName: "story_sessions.json",
                baseURL: baseURL
            )
        }
        if retainedScenes.count != scenes.count {
            scenes = retainedScenes
            try LocalJSONStoreTransaction.save(
                scenes,
                fileName: "story_scenes.json",
                baseURL: baseURL
            )
        }
        tombstoneCache.entry?.needsReconciliation = false
    }

    /// Session deletion owns the lifecycle of session-scoped StoryMemory.
    /// Keep this cleanup under the same lock as tombstone reconciliation so a
    /// crash between the deletion intent and the session-file write cannot
    /// leave a memory that can later be mistaken for live session state.
    nonisolated static func removeStoryMemoriesForDeletedSessionsUnlocked(
        _ deletedSessionIDs: Set<UUID>,
        baseURL: URL
    ) throws {
        guard !deletedSessionIDs.isEmpty else { return }
        var memories = try LocalJSONStoreTransaction.load(
            StoryMemory.self,
            fileName: "story_memories.json",
            baseURL: baseURL
        )
        let retained = memories.filter { memory in
            guard let sessionID = memory.storySessionId else { return true }
            return !deletedSessionIDs.contains(sessionID)
        }
        guard retained.count != memories.count else { return }
        memories = retained
        try LocalJSONStoreTransaction.save(
            memories,
            fileName: "story_memories.json",
            baseURL: baseURL
        )
    }

    nonisolated private static func hasTombstone(
        recordID: UUID,
        recordKind: StoryTurnJournalRecordKind,
        in tombstones: [StoryTurnJournalTombstone]
    ) -> Bool {
        tombstones.contains {
            $0.recordID == recordID && $0.recordKind == recordKind
        }
    }

    nonisolated private static func tombstoneFileSignature(
        baseURL: URL
    ) -> TombstoneFileSignature {
        let url = baseURL.appendingPathComponent(tombstoneFileName)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return TombstoneFileSignature(
                basePath: baseURL.path,
                exists: false,
                byteCount: 0,
                modificationDate: nil
            )
        }
        return TombstoneFileSignature(
            basePath: baseURL.path,
            exists: true,
            byteCount: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            modificationDate: attributes[.modificationDate] as? Date
        )
    }

    /// Repository実装だけがジャーナルの全体を扱うための短い書き込みAPI。
    /// 同じファイルロックの中から呼び出す前提で、二重ロックはしない。
    nonisolated static func prepareUnlocked(
        _ entry: StoryTurnJournalEntry,
        baseURL: URL = KizunaDataMigration.characterLibraryURL
    ) throws {
        try prepareUnlocked(
            entry,
            baseURL: baseURL,
            tombstones: try loadTombstonesUnlocked(baseURL: baseURL)
        )
    }

    nonisolated static func prepareUnlocked(
        _ entry: StoryTurnJournalEntry,
        baseURL: URL = KizunaDataMigration.characterLibraryURL,
        tombstones: [StoryTurnJournalTombstone]
    ) throws {
        try ensureRecordIsNotDeletedUnlocked(
            recordID: entry.session.id,
            recordKind: .session,
            tombstones: tombstones
        )
        try ensureRecordIsNotDeletedUnlocked(
            recordID: entry.scene.id,
            recordKind: .scene,
            tombstones: tombstones
        )
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
