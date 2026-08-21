/*
仕様:
- 役割: CharacterProfile の保存・取得・削除を抽象化する。Local JSON 実装をデフォルトに、
  将来は CloudKit/SQLite 等へ差し替え可能にする。
- 主な型: `CharacterRepository` (protocol), `LocalJSONCharacterRepository`.
*/

import Foundation

/// Result of the serialized character deletion check.
///
/// The repository decides whether the current record is protected while it
/// holds the same file lock used by saves.  Callers must only remove related
/// story/memory data after receiving `.deleted` or `.needsCleanup`.
enum CharacterDeletionResult: Equatable {
    case deleted
    /// The profile was removed by an earlier attempt, but related data still
    /// needs to be cleaned. Retrying must continue the cleanup workflow rather
    /// than treating the missing profile as a new `.notFound` error.
    case needsCleanup
    case protected
    case notFound
}

enum CharacterRepositoryError: LocalizedError, Equatable {
    case deletionInProgress(UUID)

    var errorDescription: String? {
        switch self {
        case .deletionInProgress(let id):
            return "Character deletion is in progress for \(id.uuidString)."
        }
    }
}

/// Persists the small amount of state needed to resume a multi-file deletion
/// after the profile JSON has already been changed. UserDefaults is used only
/// as a marker store; story, memory, and persona data remain in their existing
/// repositories and are removed by the view models after the marker is seen.
final class CharacterDeletionCleanupMarker: @unchecked Sendable {
    nonisolated static let shared = CharacterDeletionCleanupMarker()

    private let lock = NSLock()
    private let defaults: UserDefaults
    private nonisolated let keyPrefix = "kizuna.characterDeletion.cleanupPending."
    private nonisolated let tombstoneKeyPrefix = "kizuna.characterDeletion.tombstone."
    private nonisolated let pendingIDsIndexKey = "kizuna.characterDeletion.cleanupPending.ids.v1"
    private nonisolated let pendingIDsIndexInitializedKey = "kizuna.characterDeletion.cleanupPending.idsInitialized.v1"
    private nonisolated let tombstoneRetention: TimeInterval = 30 * 24 * 60 * 60

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    nonisolated func contains(_ id: UUID) -> Bool {
        withLock {
            defaults.bool(forKey: key(for: id)) || hasTombstoneUnlocked(id)
        }
    }

    nonisolated func containsPending(_ id: UUID) -> Bool {
        withLock { defaults.bool(forKey: key(for: id)) }
    }

    nonisolated func insert(_ id: UUID) {
        withLock {
            defaults.set(true, forKey: key(for: id))
            var IDs = pendingIDsUnlocked()
            if !IDs.contains(id) { IDs.append(id) }
            savePendingIDsUnlocked(IDs)
        }
    }

    nonisolated func remove(_ id: UUID) {
        withLock {
            defaults.removeObject(forKey: key(for: id))
            savePendingIDsUnlocked(pendingIDsUnlocked().filter { $0 != id })
        }
    }

    /// A deleted character ID must remain blocked after cleanup completes.
    /// Otherwise late Persona memory writes can recreate data for the deleted
    /// profile after the temporary cleanup marker has been cleared.
    nonisolated func insertTombstone(_ id: UUID) {
        withLock { defaults.set(Date().timeIntervalSince1970, forKey: tombstoneKey(for: id)) }
    }

    /// Atomically moves an ID from the resumable deletion marker to its
    /// permanent tombstone. Writers must never observe a gap between the two.
    nonisolated func finish(_ id: UUID) {
        withLock {
            defaults.removeObject(forKey: key(for: id))
            savePendingIDsUnlocked(pendingIDsUnlocked().filter { $0 != id })
            defaults.set(Date().timeIntervalSince1970, forKey: tombstoneKey(for: id))
        }
    }

    nonisolated func pendingIDs() -> [UUID] {
        withLock { pendingIDsUnlocked() }
    }

    /// Remove only tombstones older than the explicit retention window. A
    /// profile that currently exists is protected from compaction so a
    /// malformed or restored data set is never made writable by cleanup.
    @discardableResult
    nonisolated func compactTombstones(
        olderThan retention: TimeInterval? = nil,
        protectedIDs: Set<UUID> = []
    ) -> Int {
        withLock {
            let threshold = Date().timeIntervalSince1970 - (retention ?? tombstoneRetention)
            var removedCount = 0
            for rawKey in defaults.dictionaryRepresentation().keys where rawKey.hasPrefix(tombstoneKeyPrefix) {
                let rawID = String(rawKey.dropFirst(tombstoneKeyPrefix.count))
                guard let id = UUID(uuidString: rawID), !protectedIDs.contains(id) else { continue }
                guard let object = defaults.object(forKey: rawKey), !(object is Bool) else { continue }
                let timestamp = defaults.double(forKey: rawKey)
                guard timestamp > 0, timestamp < threshold else { continue }
                defaults.removeObject(forKey: rawKey)
                removedCount += 1
            }
            return removedCount
        }
    }

    nonisolated private func key(for id: UUID) -> String {
        "\(keyPrefix)\(id.uuidString)"
    }

    nonisolated private func tombstoneKey(for id: UUID) -> String {
        "\(tombstoneKeyPrefix)\(id.uuidString)"
    }

    nonisolated private func hasTombstoneUnlocked(_ id: UUID) -> Bool {
        let rawKey = tombstoneKey(for: id)
        guard let object = defaults.object(forKey: rawKey) else { return false }
        if object is Bool { return defaults.bool(forKey: rawKey) }
        return defaults.double(forKey: rawKey) > 0
    }

    nonisolated private func pendingIDsUnlocked() -> [UUID] {
        if defaults.bool(forKey: pendingIDsIndexInitializedKey) {
            return (defaults.stringArray(forKey: pendingIDsIndexKey) ?? []).compactMap(UUID.init)
        }
        let IDs = defaults.dictionaryRepresentation().keys.compactMap { rawKey -> UUID? in
            guard rawKey.hasPrefix(keyPrefix) else { return nil }
            return UUID(uuidString: String(rawKey.dropFirst(keyPrefix.count)))
        }
        savePendingIDsUnlocked(IDs)
        defaults.set(true, forKey: pendingIDsIndexInitializedKey)
        return IDs
    }

    nonisolated private func savePendingIDsUnlocked(_ IDs: [UUID]) {
        defaults.set(IDs.map(\.uuidString), forKey: pendingIDsIndexKey)
        defaults.set(true, forKey: pendingIDsIndexInitializedKey)
    }

    nonisolated private func withLock<Result>(_ body: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

protocol CharacterRepository: AnyObject {
    func fetchCharacters() async throws -> [CharacterProfile]
    func saveCharacter(_ character: CharacterProfile) async throws
    func deleteCharacter(id: UUID) async throws -> CharacterDeletionResult
    /// Clears the durable marker after story/memory/persona cleanup completes.
    /// A default keeps lightweight test/future repositories source-compatible.
    func completeCharacterDeletionCleanup(id: UUID) async throws

    // Lorebook (1:1)。CharacterProfile と一緒に管理した方が呼び出し側が楽なのでここに置く。
    func fetchLorebook(characterId: UUID) async throws -> CharacterLorebook?
    func saveLorebook(_ lorebook: CharacterLorebook) async throws
}

extension CharacterRepository {
    func completeCharacterDeletionCleanup(id: UUID) async throws {}
}

/// 複数キャラクターを一度の read-modify-write で保存できるリポジトリ。
///
/// Story の初期シードでは、既存の `characters.json` が大きい環境でも
/// 1件ずつファイル全体を書き戻さないようにする。旧来の実装やテスト用
/// リポジトリは `CharacterRepository` のままでも動作するよう、呼び出し側
/// ではこのプロトコルを任意機能として扱う。
protocol BatchCharacterRepository: CharacterRepository {
    func saveCharacters(_ characters: [CharacterProfile]) async throws
}

final class LocalJSONCharacterRepository: BatchCharacterRepository {
    private let charStore = LocalJSONStore<CharacterProfile>(fileName: "characters.json")
    private let loreStore = LocalJSONStore<CharacterLorebook>(fileName: "lorebooks.json")

    func fetchCharacters() async throws -> [CharacterProfile] {
        let all = try await charStore.loadRecoveringCorruptRecords()
        _ = CharacterDeletionCleanupMarker.shared.compactTombstones(
            protectedIDs: Set(all.map(\.id))
        )
        return deduplicatedCharacters(all).sorted { $0.updatedAt > $1.updatedAt }
    }

    static var pendingDeletionIDs: [UUID] {
        CharacterDeletionCleanupMarker.shared.pendingIDs()
    }

    static func isCharacterDeletionPending(_ id: UUID) -> Bool {
        CharacterDeletionCleanupMarker.shared.contains(id)
    }

    func saveCharacter(_ character: CharacterProfile) async throws {
        guard !CharacterDeletionCleanupMarker.shared.contains(character.id) else {
            throw CharacterRepositoryError.deletionInProgress(character.id)
        }
        try await charStore.mutate { items in
            // Re-check while holding the character-file lock. A deletion may
            // have recorded its intent after the caller's fast-path check but
            // before this read-modify-write reached the lock.
            guard !CharacterDeletionCleanupMarker.shared.contains(character.id) else {
                throw CharacterRepositoryError.deletionInProgress(character.id)
            }
            var updated = character.normalizedForPersistence
            let existing = items.filter { $0.id == character.id }
            if let protected = existing.first(where: { $0.isSystemProtected == true }) {
                updated.isSystemProtected = true
                if updated.avatarImageData == nil, let imageData = protected.avatarImageData {
                    updated.avatarImageData = imageData
                    updated.imageKey = protected.imageKey
                }
            }
            updated.updatedAt = Date()
            // appendOrReplaceは最初の1件だけを置き換えるため、旧データに
            // 残った同UUIDレコードを一緒に除去して保存層を一意に保つ。
            items.removeAll { $0.id == updated.id }
            items.append(updated)
        }
    }

    func saveCharacters(_ characters: [CharacterProfile]) async throws {
        guard !characters.isEmpty else { return }
        if let pendingID = characters.map(\.id).first(where: { CharacterDeletionCleanupMarker.shared.contains($0) }) {
            throw CharacterRepositoryError.deletionInProgress(pendingID)
        }

        // charStore.mutate はファイルの読み込み・変更・保存を同じロック内で
        // 完了させる。初期シードで数百回発生していた全量I/Oを1回にまとめる。
        try await charStore.mutate { items in
            if let pendingID = characters.map(\.id).first(where: {
                CharacterDeletionCleanupMarker.shared.contains($0)
            }) {
                throw CharacterRepositoryError.deletionInProgress(pendingID)
            }
            let timestamp = Date()

            // 先に既存ファイル全体をUUID単位へ正規化し、バッチ入力にも同じ
            // IDが複数ある場合は最後の入力を採用する。
            var normalized = deduplicatedCharacters(items)
            for character in characters {
                var updated = character.normalizedForPersistence
                let existing = normalized.filter { $0.id == character.id }
                if let protected = existing.first(where: { $0.isSystemProtected == true }) {
                    updated.isSystemProtected = true
                    if updated.avatarImageData == nil, let imageData = protected.avatarImageData {
                        updated.avatarImageData = imageData
                        updated.imageKey = protected.imageKey
                    }
                }
                updated.updatedAt = timestamp
                normalized.removeAll { $0.id == updated.id }
                normalized.append(updated)
            }
            items = normalized
        }
    }

    /// 旧バージョンや中断したシードで残った同一UUIDを1件へ統合する。
    /// 保護済みフラグと画像は失わず、本文は更新日時が新しいレコードを優先する。
    private func deduplicatedCharacters(_ characters: [CharacterProfile]) -> [CharacterProfile] {
        var result: [CharacterProfile] = []
        var indexByID: [UUID: Int] = [:]
        for character in characters {
            guard let existingIndex = indexByID[character.id] else {
                indexByID[character.id] = result.count
                result.append(character)
                continue
            }
            let existing = result[existingIndex]
            let protected = existing.isSystemProtected == true || character.isSystemProtected == true
            var preferred = character.updatedAt >= existing.updatedAt ? character : existing
            preferred.isSystemProtected = protected
            if preferred.avatarImageData == nil {
                let fallback = character.avatarImageData ?? existing.avatarImageData
                preferred.avatarImageData = fallback
                if preferred.imageKey == nil { preferred.imageKey = character.imageKey ?? existing.imageKey }
            }
            result[existingIndex] = preferred
        }
        return result
    }

    func deleteCharacter(id: UUID) async throws -> CharacterDeletionResult {
        // A previous attempt already removed the profile. Do not turn that
        // state into `.notFound`, because callers still need to remove orphaned
        // story/memory/persona references.
        let markerWasPending = CharacterDeletionCleanupMarker.shared.containsPending(id)
        if !markerWasPending {
            // Record deletion intent before changing characters.json. A crash
            // after this point leaves a discoverable recovery marker.
            CharacterDeletionCleanupMarker.shared.insert(id)
        }
        var result: CharacterDeletionResult = .notFound
        // Protection and removal share the charStore read-modify-write lock.
        // A concurrent seed/save can therefore not turn a protected character
        // into a successful deletion after a caller has already cleaned refs.
        try await charStore.mutate { items in
            guard items.contains(where: { $0.id == id }) else {
                result = .notFound
                return
            }
            guard !items.contains(where: { $0.id == id && $0.isSystemProtected == true }) else {
                result = .protected
                return
            }
            items.removeAll { $0.id == id }
            result = .deleted
        }

        if result == .protected {
            // A stale marker must not make a now-protected record impossible
            // to recover on every launch.
            CharacterDeletionCleanupMarker.shared.remove(id)
            return result
        }
        if result == .notFound {
            if !markerWasPending { CharacterDeletionCleanupMarker.shared.remove(id) }
            return markerWasPending ? .needsCleanup : result
        }
        guard result == .deleted else { return result }
        // Lorebook cleanup belongs to the character repository, but story and
        // memory cleanup is intentionally left to callers after `.deleted`.
        try await loreStore.delete(matching: { $0.characterId == id })
        return result
    }

    func completeCharacterDeletionCleanup(id: UUID) async throws {
        // Retry the lorebook cleanup as well. The marker is only removed after
        // every repository-owned part of deletion has succeeded. Keep a
        // tombstone after that point so late writes for this UUID remain
        // rejected even after the resumable cleanup marker is cleared.
        try await loreStore.delete(matching: { $0.characterId == id })
        CharacterDeletionCleanupMarker.shared.finish(id)
    }

    func fetchLorebook(characterId: UUID) async throws -> CharacterLorebook? {
        let all = try await loreStore.loadRecoveringCorruptRecords()
        return all.first { $0.characterId == characterId }
    }

    func saveLorebook(_ lorebook: CharacterLorebook) async throws {
        guard !CharacterDeletionCleanupMarker.shared.contains(lorebook.characterId) else {
            throw CharacterRepositoryError.deletionInProgress(lorebook.characterId)
        }
        try await loreStore.mutate { items in
            guard !CharacterDeletionCleanupMarker.shared.contains(lorebook.characterId) else {
                throw CharacterRepositoryError.deletionInProgress(lorebook.characterId)
            }
            if let index = items.firstIndex(where: { $0.characterId == lorebook.characterId }) {
                items[index] = lorebook
            } else {
                items.append(lorebook)
            }
        }
    }
}
