/*
仕様:
- 役割: ペルソナモード専用のスレッド・メッセージ履歴をローカル永続化する。
  AICoachService の既存スレッドとは完全分離し、AI Studio の他モードに影響を与えない。
- 主な型: `PersonaChatStore` (ObservableObject), `PersonaThread`, `PersonaMessage`.
- 編集ポイント: 永続化キー、スレッド削除/リネーム、件数上限を変えるときに触る。
- データ保存: Application Supportにindex + Thread別JSONで保存。UserDefaultsは移行元とactive IDのみ。
*/

import Foundation
import Combine

enum PersonaThreadOrdering {
    /// Keep the store's published order consistent with the order used by the
    /// conversation home: most recently active threads first.
    nonisolated static func mostRecentFirst(_ threads: [PersonaThread]) -> [PersonaThread] {
        threads.sorted {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt > $1.updatedAt
            }
            if $0.createdAt != $1.createdAt {
                return $0.createdAt > $1.createdAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

struct PersonaMessage: Codable, Hashable, Identifiable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant, narrator }

    var id: UUID
    var role: Role
    var text: String
    var createdAt: Date

    nonisolated init(id: UUID = UUID(), role: Role, text: String, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }

    nonisolated static func isPendingAssistantText(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty || ["…", "・・・", "・・", "...", "..", "."].contains(normalized)
    }
}

enum PersonaAssistantCommitResult: Equatable {
    case inserted
    case alreadyPresent
    case rejected
}

struct PersonaThread: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    /// スレッド作成時の PersonaProfile スナップショット。会話途中で persona 設定を変えても
    /// このスレッドは固定された人格で続けられるようにする。
    var personaSnapshot: PersonaProfile
    /// キャラライブラリー由来の場合に紐付く CharacterProfile.id。
    /// nil の場合は旧 PersonaSettings 経由のスレッド。
    var characterID: UUID?
    var title: String
    var messages: [PersonaMessage]
    /// File-backed stores initially load only the lightweight thread index.
    /// These two values preserve list previews/counts until the full thread
    /// file is materialized on first use. They are runtime-only and are not
    /// encoded into the canonical thread file.
    private var unloadedMessageCount: Int? = nil
    private var unloadedLastMessage: PersonaMessage? = nil
    /// Stable identity reported by the runtime that produced the latest
    /// assistant response. Optional for backward-compatible thread JSON.
    var lastUsedModelIdentity: String?
    /// A nil value follows PersonaChatService's app-wide default. A non-nil
    /// value is an explicit model choice for this conversation only.
    var preferredGenerationModel: PersonaGenerationModel?
    /// Optional registry selection for this conversation. When present it
    /// takes precedence over the family-level preference above.
    var preferredGenerationConfigurationID: UUID?
    var createdAt: Date
    var updatedAt: Date

    nonisolated init(
        id: UUID = UUID(),
        personaSnapshot: PersonaProfile,
        characterID: UUID? = nil,
        title: String,
        messages: [PersonaMessage] = [],
        lastUsedModelIdentity: String? = nil,
        preferredGenerationModel: PersonaGenerationModel? = nil,
        preferredGenerationConfigurationID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.personaSnapshot = personaSnapshot
        self.characterID = characterID
        self.title = title
        self.messages = messages
        self.lastUsedModelIdentity = lastUsedModelIdentity
        self.preferredGenerationModel = preferredGenerationModel
        self.preferredGenerationConfigurationID = preferredGenerationConfigurationID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // Codable: 既存保存データに characterID が無くてもデコード可能にする
    private enum CodingKeys: String, CodingKey {
        case id, personaSnapshot, characterID, title, messages, lastUsedModelIdentity, preferredGenerationModel, preferredGenerationConfigurationID, createdAt, updatedAt
    }
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.personaSnapshot = try c.decode(PersonaProfile.self, forKey: .personaSnapshot)
        self.characterID = try c.decodeIfPresent(UUID.self, forKey: .characterID)
        self.title = try c.decode(String.self, forKey: .title)
        self.messages = try c.decode([PersonaMessage].self, forKey: .messages)
        self.lastUsedModelIdentity = try c.decodeIfPresent(String.self, forKey: .lastUsedModelIdentity)
        self.preferredGenerationModel = try c.decodeIfPresent(PersonaGenerationModel.self, forKey: .preferredGenerationModel)
        self.preferredGenerationConfigurationID = try c.decodeIfPresent(UUID.self, forKey: .preferredGenerationConfigurationID)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    nonisolated var isMessageHistoryLoaded: Bool {
        unloadedMessageCount == nil
    }

    nonisolated var messageCount: Int {
        unloadedMessageCount ?? messages.count
    }

    nonisolated var hasMessages: Bool {
        messageCount > 0
    }

    nonisolated var latestMessage: PersonaMessage? {
        isMessageHistoryLoaded ? messages.last : unloadedLastMessage
    }

    nonisolated var latestDisplayableMessage: PersonaMessage? {
        if isMessageHistoryLoaded {
            return messages.last {
                !($0.role == .assistant && PersonaMessage.isPendingAssistantText($0.text))
            }
        }
        guard let unloadedLastMessage,
              !(unloadedLastMessage.role == .assistant
                && PersonaMessage.isPendingAssistantText(unloadedLastMessage.text)) else {
            return nil
        }
        return unloadedLastMessage
    }

    nonisolated mutating func markMessageHistoryUnloaded(
        count: Int,
        lastMessage: PersonaMessage?
    ) {
        messages = []
        unloadedMessageCount = count
        unloadedLastMessage = lastMessage
    }
}

/// A portable, versioned representation of Persona history.
///
/// The thread payload remains the existing Codable schema so an export can be
/// used for inspection or a future, explicit migration without losing the
/// persona snapshot or message metadata.
struct PersonaThreadExportDocument: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let appVersion: String
    let threads: [PersonaThread]
}

enum PersonaChatRecoveryError: LocalizedError {
    case noCorruptPersistedValue
    case noPersistedValue
    case persistenceRecoveryRequired
    case unsupportedPersistedValue

    nonisolated var errorDescription: String? {
        switch self {
        case .noCorruptPersistedValue:
            return "復旧対象の保存データが見つかりません。"
        case .noPersistedValue:
            return "保存されたPersona履歴が見つかりません。"
        case .persistenceRecoveryRequired:
            return "先に保存データを復旧またはバックアップしてください。"
        case .unsupportedPersistedValue:
            return "保存データをバックアップ形式へ変換できません。"
        }
    }
}

private struct PersonaThreadIndexProfile: Codable, Sendable {
    let id: UUID
    let name: String
    let age: Int?
    let tone: PersonaTone
    let relation: PersonaRelation
    let safetyRating: SafetyRating
    let avatarStyleID: String?

    nonisolated init(profile: PersonaProfile) {
        id = profile.id
        name = profile.name
        age = profile.age
        tone = profile.tone
        relation = profile.relation
        safetyRating = profile.safetyRating
        avatarStyleID = profile.avatarStyleID
    }

    nonisolated func makeProfile() -> PersonaProfile {
        PersonaProfile(
            id: id,
            name: name,
            age: age,
            personality: "",
            tone: tone,
            relation: relation,
            safetyRating: safetyRating,
            avatarStyleID: avatarStyleID
        )
    }
}

private struct PersonaThreadIndexEntry: Codable, Sendable {
    let id: UUID
    let personaIndex: PersonaThreadIndexProfile
    let characterID: UUID?
    let title: String
    let lastUsedModelIdentity: String?
    let preferredGenerationModel: PersonaGenerationModel?
    let preferredGenerationConfigurationID: UUID?
    let createdAt: Date
    let updatedAt: Date
    let messageCount: Int
    let lastMessage: PersonaMessage?

    private enum CodingKeys: String, CodingKey {
        case id
        case personaIndex
        case personaSnapshot
        case characterID
        case title
        case lastUsedModelIdentity
        case preferredGenerationModel
        case preferredGenerationConfigurationID
        case createdAt
        case updatedAt
        case messageCount
        case lastMessage
    }

    nonisolated init(thread: PersonaThread) {
        id = thread.id
        personaIndex = PersonaThreadIndexProfile(profile: thread.personaSnapshot)
        characterID = thread.characterID
        title = thread.title
        lastUsedModelIdentity = thread.lastUsedModelIdentity
        preferredGenerationModel = thread.preferredGenerationModel
        preferredGenerationConfigurationID = thread.preferredGenerationConfigurationID
        createdAt = thread.createdAt
        updatedAt = thread.updatedAt
        messageCount = thread.messageCount
        if var preview = thread.latestMessage {
            // The index is intentionally lightweight. Full text remains in
            // the per-thread file and is materialized when the conversation
            // is opened or explicitly exported.
            preview.text = String(preview.text.prefix(512))
            lastMessage = preview
        } else {
            lastMessage = nil
        }
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        if let index = try container.decodeIfPresent(PersonaThreadIndexProfile.self, forKey: .personaIndex) {
            personaIndex = index
        } else {
            // Existing index.json files contain a full PersonaProfile. Read
            // them once without making the legacy payload the new write shape.
            personaIndex = PersonaThreadIndexProfile(
                profile: try container.decode(PersonaProfile.self, forKey: .personaSnapshot)
            )
        }
        characterID = try container.decodeIfPresent(UUID.self, forKey: .characterID)
        title = try container.decode(String.self, forKey: .title)
        lastUsedModelIdentity = try container.decodeIfPresent(String.self, forKey: .lastUsedModelIdentity)
        preferredGenerationModel = try container.decodeIfPresent(PersonaGenerationModel.self, forKey: .preferredGenerationModel)
        preferredGenerationConfigurationID = try container.decodeIfPresent(UUID.self, forKey: .preferredGenerationConfigurationID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        messageCount = try container.decode(Int.self, forKey: .messageCount)
        lastMessage = try container.decodeIfPresent(PersonaMessage.self, forKey: .lastMessage)
    }

    nonisolated func makePlaceholder() -> PersonaThread {
        var thread = PersonaThread(
            id: id,
            personaSnapshot: personaIndex.makeProfile(),
            characterID: characterID,
            title: title,
            messages: [],
            lastUsedModelIdentity: lastUsedModelIdentity,
            preferredGenerationModel: preferredGenerationModel,
            preferredGenerationConfigurationID: preferredGenerationConfigurationID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        thread.markMessageHistoryUnloaded(
            count: messageCount,
            lastMessage: lastMessage
        )
        return thread
    }
}

private struct PersonaThreadPersistenceRequest: Sendable {
    let allThreads: [PersonaThread]
    let changedThreads: [PersonaThread]
    let deletedThreadIDs: Set<UUID>
    let replaceAll: Bool

    nonisolated init(
        allThreads: [PersonaThread],
        changedThreads: [PersonaThread],
        deletedThreadIDs: Set<UUID>,
        replaceAll: Bool
    ) {
        self.allThreads = allThreads
        self.changedThreads = changedThreads
        self.deletedThreadIDs = deletedThreadIDs
        self.replaceAll = replaceAll
    }
}

private enum PersonaThreadFilePersistenceError: LocalizedError {
    case missingThread(UUID)
    case mismatchedThread(expected: UUID, actual: UUID)

    nonisolated var errorDescription: String? {
        switch self {
        case .missingThread(let id):
            return "Persona thread file is missing for \(id.uuidString)."
        case .mismatchedThread(let expected, let actual):
            return "Persona thread file ID mismatch: expected \(expected.uuidString), found \(actual.uuidString)."
        }
    }
}

/// Low-level per-thread persistence used by the production Persona store.
/// The index contains only list metadata and a short last-message preview;
/// each complete conversation is isolated in its own file.
private enum PersonaThreadFilePersistence {
    nonisolated static let indexFileName = "index.json"
    nonisolated static let deletionJournalFileName = "deletion-journal.json"
    nonisolated private static let threadPrefix = "thread-"
    nonisolated private static let threadSuffix = ".json"

    nonisolated static func hasIndex(at directoryURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: indexURL(in: directoryURL).path)
    }

    nonisolated static func loadIndex(at directoryURL: URL) throws -> ([PersonaThread], Int64)? {
        try LocalJSONStoreFileLock.shared.withLock {
            let url = indexURL(in: directoryURL)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let data = try Data(contentsOf: url)
            let entries = try LocalJSONStoreCoding.makeDecoder().decode(
                [PersonaThreadIndexEntry].self,
                from: data
            )
            recoverPendingDeletions(at: directoryURL)
            var seen = Set<UUID>()
            let threads = try entries.map { entry -> PersonaThread in
                guard seen.insert(entry.id).inserted else {
                    throw DecodingError.dataCorrupted(
                        .init(
                            codingPath: [],
                            debugDescription: "Duplicate Persona thread ID \(entry.id.uuidString) in index"
                        )
                    )
                }
                guard entry.messageCount >= 0 else {
                    throw DecodingError.dataCorrupted(
                        .init(
                            codingPath: [],
                            debugDescription: "Negative Persona message count for \(entry.id.uuidString)"
                        )
                    )
                }
                // Keep the rest of the index available even when one thread
                // file is missing. Opening that conversation marks only that
                // record for partial recovery instead of hiding all history.
                return entry.makePlaceholder()
            }
            return (PersonaThreadOrdering.mostRecentFirst(threads), persistedByteCountUnlocked(at: directoryURL))
        }
    }

    nonisolated static func loadThread(id: UUID, at directoryURL: URL) throws -> PersonaThread {
        try LocalJSONStoreFileLock.shared.withLock {
            let url = threadURL(for: id, in: directoryURL)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw PersonaThreadFilePersistenceError.missingThread(id)
            }
            let data = try Data(contentsOf: url)
            let thread = try LocalJSONStoreCoding.makeDecoder().decode(PersonaThread.self, from: data)
            guard thread.id == id else {
                throw PersonaThreadFilePersistenceError.mismatchedThread(
                    expected: id,
                    actual: thread.id
                )
            }
            return thread
        }
    }

    nonisolated static func writeInitial(_ threads: [PersonaThread], at directoryURL: URL) throws -> Int64 {
        try write(
            PersonaThreadPersistenceRequest(
                allThreads: threads,
                changedThreads: threads,
                deletedThreadIDs: [],
                replaceAll: true
            ),
            at: directoryURL
        )
    }

    nonisolated static func write(
        _ request: PersonaThreadPersistenceRequest,
        at directoryURL: URL
    ) throws -> Int64 {
        try LocalJSONStoreFileLock.shared.withLock {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let encoder = LocalJSONStoreCoding.makeEncoder()
            for thread in request.changedThreads {
                // A placeholder never replaces its full history. Callers must
                // materialize a thread before mutating/persisting it.
                guard thread.isMessageHistoryLoaded else { continue }
                let data = try encoder.encode(thread)
                let url = threadURL(for: thread.id, in: directoryURL)
                try data.write(to: url, options: LocalJSONStoreFileProtection.atomicWriteOptions)
                try LocalJSONStoreFileProtection.apply(to: url)
            }

            let indexData = try encoder.encode(
                request.allThreads.map { PersonaThreadIndexEntry(thread: $0) }
            )
            let manifestURL = indexURL(in: directoryURL)
            try indexData.write(
                to: manifestURL,
                options: LocalJSONStoreFileProtection.atomicWriteOptions
            )
            try LocalJSONStoreFileProtection.apply(to: manifestURL)

            var IDsToDelete = request.deletedThreadIDs
            if request.replaceAll {
                let liveIDs = Set(request.allThreads.map(\.id))
                let fileURLs = try fileManager.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                for fileURL in fileURLs {
                    guard let id = threadID(from: fileURL), !liveIDs.contains(id) else { continue }
                    IDsToDelete.insert(id)
                }
            }
            if !IDsToDelete.isEmpty {
                try writeDeletionJournal(IDsToDelete, at: directoryURL)
            }
            for id in IDsToDelete {
                let url = threadURL(for: id, in: directoryURL)
                guard fileManager.fileExists(atPath: url.path) else { continue }
                try fileManager.removeItem(at: url)
            }
            if !IDsToDelete.isEmpty {
                try clearDeletionJournal(at: directoryURL)
            }
            return persistedByteCountUnlocked(at: directoryURL)
        }
    }

    /// Retry only deletion IDs explicitly requested by the user. The journal
    /// remains on disk when a file cannot be removed, so a later launch does
    /// not silently lose the deletion intent.
    nonisolated private static func recoverPendingDeletions(at directoryURL: URL) {
        let journalURL = directoryURL.appendingPathComponent(deletionJournalFileName)
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
        do {
            let data = try Data(contentsOf: journalURL)
            let IDs = try LocalJSONStoreCoding.makeDecoder().decode([UUID].self, from: data)
            var unresolved = false
            for id in IDs {
                let url = threadURL(for: id, in: directoryURL)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    unresolved = true
                    AppLog.error(
                        "[PersonaChatStore] deferred deletion failed for %@: %@",
                        id.uuidString,
                        error.localizedDescription
                    )
                }
            }
            if !unresolved {
                try FileManager.default.removeItem(at: journalURL)
            }
        } catch {
            AppLog.error(
                "[PersonaChatStore] failed to recover deletion journal: %@",
                error.localizedDescription
            )
        }
    }

    nonisolated private static func writeDeletionJournal(
        _ IDs: Set<UUID>,
        at directoryURL: URL
    ) throws {
        let data = try LocalJSONStoreCoding.makeEncoder().encode(
            IDs.sorted { $0.uuidString < $1.uuidString }
        )
        let url = directoryURL.appendingPathComponent(deletionJournalFileName)
        try data.write(to: url, options: LocalJSONStoreFileProtection.atomicWriteOptions)
        try LocalJSONStoreFileProtection.apply(to: url)
    }

    nonisolated private static func clearDeletionJournal(at directoryURL: URL) throws {
        let url = directoryURL.appendingPathComponent(deletionJournalFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    nonisolated static func rawIndexData(at directoryURL: URL) throws -> Data {
        try LocalJSONStoreFileLock.shared.withLock {
            try Data(contentsOf: indexURL(in: directoryURL))
        }
    }

    nonisolated static func rawThreadData(id: UUID, at directoryURL: URL) throws -> Data {
        try LocalJSONStoreFileLock.shared.withLock {
            try Data(contentsOf: threadURL(for: id, in: directoryURL))
        }
    }

    nonisolated static func backupIndex(at directoryURL: URL) throws -> URL {
        try LocalJSONStoreFileLock.shared.withLock {
            let sourceURL = indexURL(in: directoryURL)
            let backupURL = directoryURL.appendingPathComponent(
                "index.recovery-\(UUID().uuidString).json"
            )
            try FileManager.default.copyItem(at: sourceURL, to: backupURL)
            try LocalJSONStoreFileProtection.apply(to: backupURL)
            return backupURL
        }
    }

    /// Preserve every top-level Persona payload before an explicit reset of
    /// an unreadable index. The index alone is not enough to recover message
    /// bodies because those live in separate thread files.
    nonisolated static func backupStore(at directoryURL: URL) throws -> URL {
        try LocalJSONStoreFileLock.shared.withLock {
            let fileManager = FileManager.default
            let backupURL = directoryURL.appendingPathComponent(
                "recovery-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: backupURL,
                withIntermediateDirectories: false
            )
            do {
                let sourceURLs = try fileManager.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
                for sourceURL in sourceURLs where sourceURL != backupURL {
                    let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey])
                    guard values.isRegularFile == true else { continue }
                    let destinationURL = backupURL.appendingPathComponent(
                        sourceURL.lastPathComponent
                    )
                    try fileManager.copyItem(at: sourceURL, to: destinationURL)
                    try LocalJSONStoreFileProtection.apply(to: destinationURL)
                }
                try LocalJSONStoreFileProtection.apply(to: backupURL)
                return backupURL
            } catch {
                try? fileManager.removeItem(at: backupURL)
                throw error
            }
        }
    }

    nonisolated static func backupThread(id: UUID, at directoryURL: URL) throws -> URL? {
        try LocalJSONStoreFileLock.shared.withLock {
            let sourceURL = threadURL(for: id, in: directoryURL)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                return nil
            }
            let backupURL = directoryURL.appendingPathComponent(
                "thread-\(id.uuidString).recovery-\(UUID().uuidString).json"
            )
            try FileManager.default.copyItem(at: sourceURL, to: backupURL)
            try LocalJSONStoreFileProtection.apply(to: backupURL)
            return backupURL
        }
    }

    nonisolated private static func indexURL(in directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent(indexFileName)
    }

    nonisolated private static func threadURL(for id: UUID, in directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent("\(threadPrefix)\(id.uuidString)\(threadSuffix)")
    }

    nonisolated private static func threadID(from fileURL: URL) -> UUID? {
        let name = fileURL.lastPathComponent
        guard name.hasPrefix(threadPrefix), name.hasSuffix(threadSuffix) else { return nil }
        let start = name.index(name.startIndex, offsetBy: threadPrefix.count)
        let end = name.index(name.endIndex, offsetBy: -threadSuffix.count)
        return UUID(uuidString: String(name[start..<end]))
    }

    nonisolated private static func persistedByteCountUnlocked(at directoryURL: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            ), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}

/// Serializes file writes away from the MainActor. Requests contain only the
/// changed complete threads plus the lightweight index snapshot.
private actor PersonaChatPersistenceWriter {
    private let directoryURL: URL

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    func write(_ request: PersonaThreadPersistenceRequest) throws -> Int64 {
        try PersonaThreadFilePersistence.write(request, at: directoryURL)
    }
}

@MainActor
final class PersonaChatStore: ObservableObject {
    static let shared = PersonaChatStore(
        defaults: UserDefaults.standard,
        storageURL: KizunaDataMigration.personaHistoryURL
    )

    private let defaults: UserDefaults
    private let storageURL: URL?
    private enum Key {
        static let threads = "persona.threads.v1"
        static let activeThreadID = "persona.activeThreadID.v1"
        static let corruptThreadsBackup = "persona.threads.v1.corrupt-backup"
    }

    /// 新しい順 (updatedAt 降順) でソートして保持。
    @Published private(set) var threads: [PersonaThread] = []
    /// 保存データのデコードに失敗した場合は、空配列を正常値として書き戻さない。
    /// 破損データを上書きすると、復旧可能な履歴まで失われるため、明示的な
    /// リセット/再保存が行われるまで現在のファイルを保持する。
    private var didFailToLoadPersistedThreads = false
    /// Thread単位の部分復旧が発生した場合、読めた履歴は表示するが、
    /// 明示的な修復までは元の保存データを上書きしない。
    @Published private(set) var partialRecoveryInvalidCount = 0
    @Published private(set) var persistedHistoryByteCount: Int64 = 0
    private let persistenceWriter: PersonaChatPersistenceWriter?
    private var pendingPersistTask: Task<Void, Never>?
    private var pendingDirtyThreadIDs = Set<UUID>()
    private var pendingDeletedThreadIDs = Set<UUID>()
    private var pendingReplaceAll = false
    private var persistenceRevision = 0
    private var filePersistenceHasValue = false
    private var invalidFileThreadIDs = Set<UUID>()
    /// A read-only view lookup may happen while SwiftUI is evaluating `body`.
    /// Cache that materialized value without mutating the @Published index;
    /// editing paths promote it into `threads` before making any changes.
    private var materializedThreadCache = [UUID: PersonaThread]()
    @Published private(set) var activeThreadID: UUID? {
        didSet {
            guard !hasRecoveryState else {
                AppLog.note("[PersonaChatStore] skipped active thread write while recovery is required")
                return
            }
            if let id = activeThreadID {
                defaults.set(id.uuidString, forKey: Key.activeThreadID)
            } else {
                defaults.removeObject(forKey: Key.activeThreadID)
            }
        }
    }

    var activeThread: PersonaThread? {
        guard let id = activeThreadID else { return nil }
        return thread(id: id)
    }

    func thread(id: UUID) -> PersonaThread? {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return nil }
        if threads[index].isMessageHistoryLoaded {
            return threads[index]
        }
        if let cached = materializedThreadCache[id] {
            return cached
        }
        guard let loaded = loadThreadBody(id: id) else { return nil }
        materializedThreadCache[id] = loaded
        return loaded
    }

    /// テストや復旧画面が保存先を明示できる初期化経路。
    /// `storageURL == nil` は既存の軽量テスト用UserDefaults経路を保つ。
    /// 本番の `shared` はApplication SupportのThread単位Storeを使う。
    init(
        defaults: UserDefaults = UserDefaults.standard,
        storageURL: URL? = nil
    ) {
        self.defaults = defaults
        self.storageURL = storageURL
        self.persistenceWriter = storageURL.map { PersonaChatPersistenceWriter(directoryURL: $0) }
        KizunaPersonaExportFileLifecycle.cleanupOrphanedFiles()
        if let storageURL {
            loadFileBackedStore(at: storageURL)
        } else {
            loadLegacyDefaults()
        }
        guard !didFailToLoadPersistedThreads else {
            AppLog.note("[PersonaChatStore] thread data was not decoded; preserving the source file")
            return
        }
        // 起動時に「空メッセージのスレッド」を 1 件残して残りを掃除する。
        // (バグや誤操作で同じキャラの空スレッドが大量に残るのを防ぐ)
        var seenEmptyPersonaKeys = Set<String>()
        let IDsBeforeEmptyCleanup = Set(threads.map(\.id))
        threads.removeAll { thread in
            guard !thread.hasMessages else { return false }
            // 名前だけでまとめると、同名だが別UUIDのキャラを削除してしまう。
            // キャラ由来はcharacterID、旧ペルソナはprofile UUIDで識別する。
            let key = thread.characterID.map { "character:\($0.uuidString)" }
                ?? "persona:\(thread.personaSnapshot.id.uuidString)"
            if seenEmptyPersonaKeys.insert(key).inserted {
                return false   // 各キャラで最初の 1 件は残す
            }
            return true        // 2 件目以降は削除
        }
        let removedEmptyThreadIDs = IDsBeforeEmptyCleanup.subtracting(Set(threads.map(\.id)))
        if storageURL == nil {
            persist()
        } else if !removedEmptyThreadIDs.isEmpty {
            persist(changedThreadIDs: [], deletedThreadIDs: removedEmptyThreadIDs)
        }
        if let saved = defaults.string(forKey: Key.activeThreadID),
           let uuid = UUID(uuidString: saved),
           threads.contains(where: { $0.id == uuid }) {
            // Keep startup lightweight. `activeThread` materializes this file
            // only when a screen actually asks for the conversation body.
            self.activeThreadID = uuid
        }
    }

    private func loadFileBackedStore(at storageURL: URL) {
        do {
            if let loaded = try PersonaThreadFilePersistence.loadIndex(at: storageURL) {
                threads = loaded.0
                persistedHistoryByteCount = loaded.1
                filePersistenceHasValue = true
                // A valid manifest is authoritative. A legacy blob left by an
                // interrupted migration is now redundant and can be removed.
                defaults.removeObject(forKey: Key.threads)
                return
            }
        } catch {
            didFailToLoadPersistedThreads = true
            filePersistenceHasValue = true
            AppLog.error(
                "[PersonaChatStore] failed to load file-backed index: %@",
                error.localizedDescription
            )
            return
        }

        // One-time migration from the former UserDefaults blob. The legacy
        // value is removed only after every thread file and the index have
        // committed successfully.
        loadLegacyDefaults()
        guard !hasRecoveryState, defaults.object(forKey: Key.threads) != nil else { return }
        do {
            persistedHistoryByteCount = try PersonaThreadFilePersistence.writeInitial(
                threads,
                at: storageURL
            )
            filePersistenceHasValue = true
            defaults.removeObject(forKey: Key.threads)
            AppLog.note(
                "[PersonaChatStore] migrated %ld Persona threads from UserDefaults",
                threads.count
            )
        } catch {
            didFailToLoadPersistedThreads = true
            AppLog.error(
                "[PersonaChatStore] failed to migrate Persona history: %@",
                error.localizedDescription
            )
        }
    }

    private func loadLegacyDefaults() {
        guard defaults.object(forKey: Key.threads) != nil else {
            return
        }
        guard let data = defaults.data(forKey: Key.threads) else {
            didFailToLoadPersistedThreads = true
            AppLog.note("[PersonaChatStore] saved thread value is not a Data blob")
            return
        }
        do {
            let decoded = try JSONDecoder().decode([PersonaThread].self, from: data)
            self.threads = PersonaThreadOrdering.mostRecentFirst(decoded)
        } catch {
            guard let partial = recoverThreads(from: data), partial.invalidCount > 0 else {
                didFailToLoadPersistedThreads = true
                AppLog.error("[PersonaChatStore] failed to decode saved threads: %@", error.localizedDescription)
                return
            }
            self.threads = PersonaThreadOrdering.mostRecentFirst(partial.threads)
            self.partialRecoveryInvalidCount = partial.invalidCount
            AppLog.error(
                "[PersonaChatStore] partially recovered saved threads: %ld valid, %ld invalid",
                partial.threads.count,
                partial.invalidCount
            )
        }
    }

    @discardableResult
    private func materializeThreadIfNeeded(at index: Int) -> Bool {
        guard threads.indices.contains(index) else { return false }
        let id = threads[index].id
        guard !threads[index].isMessageHistoryLoaded else {
            materializedThreadCache.removeValue(forKey: id)
            return true
        }
        if let cached = materializedThreadCache.removeValue(forKey: id) {
            threads[index] = cached
            return true
        }
        guard let loaded = loadThreadBody(id: id) else { return false }
        threads[index] = loaded
        return true
    }

    private func loadThreadBody(id: UUID) -> PersonaThread? {
        guard let storageURL else { return nil }
        do {
            let loaded = try PersonaThreadFilePersistence.loadThread(
                id: id,
                at: storageURL
            )
            if invalidFileThreadIDs.remove(id) != nil {
                partialRecoveryInvalidCount = max(0, partialRecoveryInvalidCount - 1)
            }
            return loaded
        } catch {
            if invalidFileThreadIDs.insert(id).inserted {
                partialRecoveryInvalidCount += 1
            }
            AppLog.error(
                "[PersonaChatStore] failed to materialize Persona thread %@: %@",
                id.uuidString,
                error.localizedDescription
            )
            return nil
        }
    }

    private func recoverThreads(
        from data: Data
    ) -> (threads: [PersonaThread], invalidCount: Int)? {
        guard let rawItems = try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) as? [Any] else {
            return nil
        }

        let decoder = JSONDecoder()
        var validThreads: [PersonaThread] = []
        var invalidCount = 0
        for (index, rawItem) in rawItems.enumerated() {
            do {
                let itemData = try JSONSerialization.data(
                    withJSONObject: rawItem,
                    options: [.fragmentsAllowed]
                )
                validThreads.append(try decoder.decode(PersonaThread.self, from: itemData))
            } catch {
                invalidCount += 1
                AppLog.note(
                    "[PersonaChatStore] skipped invalid thread at index %ld during recovery: %@",
                    index,
                    String(describing: error)
                )
            }
        }
        return (validThreads, invalidCount)
    }

    private var hasRecoveryState: Bool {
        didFailToLoadPersistedThreads || partialRecoveryInvalidCount > 0
    }

    private func persist(
        changedThreadIDs: Set<UUID>? = nil,
        deletedThreadIDs: Set<UUID> = [],
        replaceAll: Bool = false
    ) {
        guard !hasRecoveryState else {
            AppLog.note("[PersonaChatStore] skipped thread persist while recovery is required")
            return
        }

        // Custom/test stores retain the old synchronous behavior. Production
        // never takes this path because `shared` always supplies storageURL.
        guard storageURL != nil else {
            do {
                let data = try JSONEncoder().encode(threads)
                defaults.set(data, forKey: Key.threads)
                persistedHistoryByteCount = Int64(data.count)
            } catch {
                AppLog.error(
                    "[PersonaChatStore] failed to persist legacy test store: %@",
                    error.localizedDescription
                )
            }
            return
        }

        let dirtyIDs = changedThreadIDs
            ?? Set(threads.lazy.filter(\.isMessageHistoryLoaded).map(\.id))
        pendingDirtyThreadIDs.formUnion(dirtyIDs)
        pendingDeletedThreadIDs.formUnion(deletedThreadIDs)
        pendingDirtyThreadIDs.subtract(deletedThreadIDs)
        pendingReplaceAll = pendingReplaceAll || replaceAll
        schedulePendingPersistence(delayNanoseconds: 120_000_000)
    }

    private func schedulePendingPersistence(delayNanoseconds: UInt64) {
        guard let writer = persistenceWriter else { return }
        guard !pendingDirtyThreadIDs.isEmpty
                || !pendingDeletedThreadIDs.isEmpty
                || pendingReplaceAll else { return }
        pendingPersistTask?.cancel()
        persistenceRevision += 1
        let revision = persistenceRevision
        let dirtyIDs = pendingDirtyThreadIDs
        let deletedIDs = pendingDeletedThreadIDs
        let replaceAll = pendingReplaceAll
        let allThreads = threads
        let changedThreads = threads.filter {
            dirtyIDs.contains($0.id) && $0.isMessageHistoryLoaded
        }
        let request = PersonaThreadPersistenceRequest(
            allThreads: allThreads,
            changedThreads: changedThreads,
            deletedThreadIDs: deletedIDs,
            replaceAll: replaceAll
        )
        pendingPersistTask = Task(priority: .utility) { [weak self] in
            do {
                if delayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                }
                let byteCount = try await writer.write(request)
                guard let self, self.persistenceRevision == revision else { return }
                self.pendingDirtyThreadIDs.subtract(dirtyIDs)
                self.pendingDeletedThreadIDs.subtract(deletedIDs)
                if replaceAll { self.pendingReplaceAll = false }
                self.persistedHistoryByteCount = byteCount
                self.filePersistenceHasValue = true
            } catch is CancellationError {
                return
            } catch {
                AppLog.error(
                    "[PersonaChatStore] failed to persist threads off-main: %@",
                    error.localizedDescription
                )
            }
        }
    }

    /// 壊れた保存データを破棄する唯一の明示的な復旧操作。
    /// UserDefaults値またはThread別Store全体を先に退避し、確認済みの
    /// 呼び出し元だけが空状態として保存を再開できるようにする。
    @discardableResult
    func discardCorruptPersistedThreads() -> Bool {
        guard didFailToLoadPersistedThreads else { return false }
        if let rawValue = defaults.object(forKey: Key.threads) {
            defaults.set(rawValue, forKey: Key.corruptThreadsBackup)
        } else if let storageURL,
                  PersonaThreadFilePersistence.hasIndex(at: storageURL) {
            do {
                _ = try PersonaThreadFilePersistence.backupStore(at: storageURL)
            } catch {
                AppLog.error(
                    "[PersonaChatStore] failed to back up corrupt file store: %@",
                    error.localizedDescription
                )
                return false
            }
        }
        if let storageURL {
            do {
                persistedHistoryByteCount = try PersonaThreadFilePersistence.writeInitial(
                    [],
                    at: storageURL
                )
                filePersistenceHasValue = true
            } catch {
                AppLog.error(
                    "[PersonaChatStore] failed to replace corrupt file store: %@",
                    error.localizedDescription
                )
                return false
            }
        }
        defaults.removeObject(forKey: Key.threads)
        defaults.removeObject(forKey: Key.activeThreadID)
        didFailToLoadPersistedThreads = false
        partialRecoveryInvalidCount = 0
        invalidFileThreadIDs.removeAll()
        materializedThreadCache.removeAll()
        threads = []
        activeThreadID = nil
        if storageURL == nil { persist() }
        return true
    }

    /// Explicitly repair partially recovered history. The original defaults
    /// blob or the affected index/thread files are backed up before valid
    /// records are written, so skipped data remains recoverable.
    @discardableResult
    func repairPartiallyRecoveredThreads() -> Bool {
        guard partialRecoveryInvalidCount > 0 else { return false }

        if let rawValue = defaults.object(forKey: Key.threads) {
            defaults.set(rawValue, forKey: Key.corruptThreadsBackup)
            if let storageURL {
                do {
                    persistedHistoryByteCount = try PersonaThreadFilePersistence.writeInitial(
                        threads,
                        at: storageURL
                    )
                    defaults.removeObject(forKey: Key.threads)
                    filePersistenceHasValue = true
                } catch {
                    AppLog.error(
                        "[PersonaChatStore] partial migration repair failed: %@",
                        error.localizedDescription
                    )
                    return false
                }
            }
        } else if let storageURL, !invalidFileThreadIDs.isEmpty {
            do {
                _ = try PersonaThreadFilePersistence.backupIndex(at: storageURL)
                for id in invalidFileThreadIDs {
                    _ = try PersonaThreadFilePersistence.backupThread(id: id, at: storageURL)
                }
                let invalidIDs = invalidFileThreadIDs
                threads.removeAll { invalidIDs.contains($0.id) }
                persistedHistoryByteCount = try PersonaThreadFilePersistence.writeInitial(
                    threads,
                    at: storageURL
                )
            } catch {
                AppLog.error(
                    "[PersonaChatStore] partial file repair failed: %@",
                    error.localizedDescription
                )
                return false
            }
        } else {
            return false
        }
        partialRecoveryInvalidCount = 0
        invalidFileThreadIDs.removeAll()
        materializedThreadCache.removeAll()
        threads = PersonaThreadOrdering.mostRecentFirst(threads)
        if let activeThreadID,
           !threads.contains(where: { $0.id == activeThreadID }) {
            self.activeThreadID = threads.first?.id
        }
        if storageURL == nil { persist() }
        return true
    }

    var isPersistenceRecoveryRequired: Bool {
        didFailToLoadPersistedThreads
    }

    var isPartialRecoveryRequired: Bool {
        partialRecoveryInvalidCount > 0
    }

    /// `true` when either the file-backed store or legacy UserDefaults value
    /// exists. This is intentionally separate from `threads.isEmpty` so an
    /// empty in-memory fallback can never be mistaken for saved data.
    var hasPersistedValue: Bool {
        filePersistenceHasValue || defaults.object(forKey: Key.threads) != nil
    }

    /// The app version is metadata for an export, not a migration decision.
    /// Tests and previews may not have a fully populated application bundle.
    private var currentAppVersion: String {
        guard let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String else {
            return "unknown"
        }
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    /// Export a legacy value as-is, or produce a lossless aggregate JSON array
    /// from the normal multi-file store. Corrupt files use their original
    /// bytes so a user can preserve evidence before a recovery decision.
    func exportRawPersistedThreads() throws -> URL {
        let raw = try rawPersistedThreadsData()
        return try writeExport(
            raw.data,
            prefix: "Kizuna-Persona-Raw",
            fileExtension: raw.fileExtension
        )
    }

    /// Export valid decoded history as a versioned machine-readable document.
    /// A recovery-required store must not export its empty in-memory fallback.
    func exportPersistedThreadsJSON() throws -> URL {
        guard !hasRecoveryState else {
            throw PersonaChatRecoveryError.persistenceRecoveryRequired
        }
        let completeThreads = try materializeAllThreadsForExport()

        let document = PersonaThreadExportDocument(
            schemaVersion: PersonaThreadExportDocument.currentSchemaVersion,
            appVersion: currentAppVersion,
            threads: completeThreads
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        return try writeExport(
            data,
            prefix: "Kizuna-Persona-Threads",
            fileExtension: "json"
        )
    }

    /// Export valid decoded history in a stable, human-readable format.
    /// Message bodies keep their line breaks while each line remains visibly
    /// inside its message block.
    func exportPersistedThreadsText() throws -> URL {
        guard !hasRecoveryState else {
            throw PersonaChatRecoveryError.persistenceRecoveryRequired
        }
        let completeThreads = try materializeAllThreadsForExport()

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        var lines = [
            "Kizuna Persona history",
            "schemaVersion: \(PersonaThreadExportDocument.currentSchemaVersion)",
            "appVersion: \(currentAppVersion)",
            "threadCount: \(completeThreads.count)",
            ""
        ]

        for (threadIndex, thread) in completeThreads.enumerated() {
            let characterID = thread.characterID?.uuidString ?? "none"
            let age = thread.personaSnapshot.age.map(String.init) ?? "none"
            lines.append("thread[\(threadIndex)]")
            lines.append("id: \(thread.id.uuidString)")
            lines.append("characterID: \(characterID)")
            lines.append("title: \(thread.title)")
            lines.append("createdAt: \(formatter.string(from: thread.createdAt))")
            lines.append("updatedAt: \(formatter.string(from: thread.updatedAt))")
            lines.append("personaSnapshot.id: \(thread.personaSnapshot.id.uuidString)")
            lines.append("personaSnapshot.name: \(thread.personaSnapshot.name)")
            lines.append("personaSnapshot.age: \(age)")
            lines.append("personaSnapshot.personality: \(thread.personaSnapshot.personality)")
            lines.append("personaSnapshot.tone: \(thread.personaSnapshot.tone.rawValue)")
            lines.append("personaSnapshot.relation: \(thread.personaSnapshot.relation.rawValue)")
            lines.append("personaSnapshot.freeFormAddendum: \(thread.personaSnapshot.freeFormAddendum)")
            lines.append("messageCount: \(thread.messages.count)")

            for (messageIndex, message) in thread.messages.enumerated() {
                lines.append("message[\(messageIndex)]")
                lines.append("id: \(message.id.uuidString)")
                lines.append("role: \(message.role.rawValue)")
                lines.append("createdAt: \(formatter.string(from: message.createdAt))")
                lines.append("text:")
                let bodyLines = message.text.split(
                    omittingEmptySubsequences: false,
                    whereSeparator: { $0 == "\n" }
                )
                if bodyLines.isEmpty {
                    lines.append("  ")
                } else {
                    lines.append(contentsOf: bodyLines.map { "  \($0)" })
                }
            }
            lines.append("")
        }

        let data = Data(lines.joined(separator: "\n").utf8)
        return try writeExport(
            data,
            prefix: "Kizuna-Persona-Threads",
            fileExtension: "txt"
        )
    }

    /// 破損した保存値を、明示的な共有・保存操作へ渡せる一時ファイルへ書き出す。
    /// Data と String は保存されていた値をそのままバイト列として扱い、
    /// その他の UserDefaults のプロパティリスト値も内容を失わない形式で保存する。
    /// この操作は保存値を変更せず、復旧が必要な状態でのみ実行できる。
    func exportCorruptPersistedThreads() throws -> URL {
        guard hasRecoveryState,
              defaults.object(forKey: Key.threads) != nil
                || (storageURL.map { PersonaThreadFilePersistence.hasIndex(at: $0) } == true) else {
            throw PersonaChatRecoveryError.noCorruptPersistedValue
        }

        let raw = try rawPersistedThreadsData()
        return try writeExport(
            raw.data,
            prefix: "Kizuna-Persona-Recovery",
            fileExtension: raw.fileExtension
        )
    }

    private func rawPersistedThreadsData() throws -> (data: Data, fileExtension: String) {
        if let rawValue = defaults.object(forKey: Key.threads) {
            if let rawData = rawValue as? Data {
                return (rawData, "bin")
            }
            if let rawString = rawValue as? String {
                return (Data(rawString.utf8), "txt")
            }
            if PropertyListSerialization.propertyList(rawValue, isValidFor: .binary) {
                return (
                    try PropertyListSerialization.data(
                        fromPropertyList: rawValue,
                        format: .binary,
                        options: 0
                    ),
                    "plist"
                )
            }
            throw PersonaChatRecoveryError.unsupportedPersistedValue
        }

        if let storageURL {
            if let invalidID = invalidFileThreadIDs.first {
                if let data = try? PersonaThreadFilePersistence.rawThreadData(
                    id: invalidID,
                    at: storageURL
                ) {
                    return (data, "json")
                }
                // A missing thread has no payload to export. Preserve the
                // index that references it so the recovery context is not lost.
                if PersonaThreadFilePersistence.hasIndex(at: storageURL) {
                    return (
                        try PersonaThreadFilePersistence.rawIndexData(at: storageURL),
                        "json"
                    )
                }
            }
            if didFailToLoadPersistedThreads,
               PersonaThreadFilePersistence.hasIndex(at: storageURL) {
                return (
                    try PersonaThreadFilePersistence.rawIndexData(at: storageURL),
                    "json"
                )
            }
            let completeThreads = try materializeAllThreadsForExport()
            return (
                try LocalJSONStoreCoding.makeEncoder().encode(completeThreads),
                "json"
            )
        }
        throw PersonaChatRecoveryError.noPersistedValue
    }

    private func materializeAllThreadsForExport() throws -> [PersonaThread] {
        for index in threads.indices {
            guard materializeThreadIfNeeded(at: index) else {
                throw PersonaChatRecoveryError.persistenceRecoveryRequired
            }
        }
        return threads
    }

    private func writeExport(
        _ data: Data,
        prefix: String,
        fileExtension: String
    ) throws -> URL {
        let exportDirectory = KizunaPersonaExportFileLifecycle.directoryURL
        try FileManager.default.createDirectory(
            at: exportDirectory,
            withIntermediateDirectories: true
        )
        let fileName = "\(prefix)-\(UUID().uuidString).\(fileExtension)"
        let exportURL = exportDirectory.appendingPathComponent(fileName)
        try data.write(
            to: exportURL,
            options: [.atomic, .completeFileProtection]
        )
        return exportURL
    }

    /// 破損した保存値を自動的に空状態で上書きしないための共通ガード。
    /// 復旧操作以外の公開ミューテーションは、メモリ上の状態も変更しない。
    private func canMutatePersistedState() -> Bool {
        guard !hasRecoveryState else {
            AppLog.note("[PersonaChatStore] skipped mutation while recovery is required")
            return false
        }
        return true
    }

    // MARK: - Thread CRUD

    /// 新しい会話スレッドを作る。ただし、既に「同じキャラ・空メッセージのスレッド」が
    /// 存在する場合はそれを再利用してアクティブ化する (空スレッドの量産防止)。
    @discardableResult
    func createThread(with persona: PersonaProfile, characterID: UUID? = nil) -> PersonaThread? {
        guard canMutatePersistedState() else { return nil }
        if let existing = threads.first(where: {
            $0.characterID == characterID
                && (characterID != nil || $0.personaSnapshot.id == persona.id)
                && !$0.hasMessages
        }) {
            // An empty thread is only a reusable draft. Refresh its snapshot
            // before returning it so edits made in Character Library are
            // reflected in the chat header, avatar style, and future prompt.
            // Once a message exists, the snapshot remains immutable for the
            // lifetime of that conversation.
            if let index = threads.firstIndex(where: { $0.id == existing.id }) {
                guard materializeThreadIfNeeded(at: index) else { return nil }
                threads[index].personaSnapshot = persona
                threads[index].title = persona.name
                threads[index].updatedAt = Date()
                persistAfterActivityUpdate(changedThreadIDs: [existing.id])
            }
            activeThreadID = existing.id
            return thread(id: existing.id) ?? existing
        }
        let thread = PersonaThread(
            personaSnapshot: persona,
            characterID: characterID,
            title: persona.name
        )
        threads.insert(thread, at: 0)
        activeThreadID = thread.id
        persist(changedThreadIDs: [thread.id])
        return thread
    }

    func selectThread(id: UUID) {
        guard canMutatePersistedState() else { return }
        guard let index = threads.firstIndex(where: { $0.id == id }),
              materializeThreadIfNeeded(at: index) else { return }
        activeThreadID = id
    }

    /// Keep a character's current library image in every linked conversation while
    /// leaving the conversation's personality and messages unchanged.
    @discardableResult
    func refreshCharacterAppearance(
        for characterID: UUID,
        avatarStyleID: String?,
        avatarImageData: Data?
    ) -> Bool {
        guard canMutatePersistedState() else { return false }
        var changedIDs = Set<UUID>()
        let matchingIndices = threads.indices.filter {
            threads[$0].characterID == characterID
        }
        for index in matchingIndices {
            guard threads[index].personaSnapshot.avatarStyleID != avatarStyleID
                    || threads[index].personaSnapshot.avatarImageData != avatarImageData else {
                continue
            }
            guard materializeThreadIfNeeded(at: index) else { return false }
            threads[index].personaSnapshot.avatarStyleID = avatarStyleID
            threads[index].personaSnapshot.avatarImageData = avatarImageData
            changedIDs.insert(threads[index].id)
        }
        if !changedIDs.isEmpty { persist(changedThreadIDs: changedIDs) }
        return !changedIDs.isEmpty
    }

    /// Compatibility helper for callers that only have a thread ID. New entry
    /// points should use the character-wide method so older threads do not keep
    /// stale images.
    func refreshCharacterAppearance(
        threadID: UUID,
        avatarStyleID: String?,
        avatarImageData: Data?
    ) {
        guard let thread = threads.first(where: { $0.id == threadID }),
              let characterID = thread.characterID else {
            guard canMutatePersistedState(),
                  let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
            guard threads[index].personaSnapshot.avatarStyleID != avatarStyleID
                    || threads[index].personaSnapshot.avatarImageData != avatarImageData else {
                return
            }
            guard materializeThreadIfNeeded(at: index) else { return }
            threads[index].personaSnapshot.avatarStyleID = avatarStyleID
            threads[index].personaSnapshot.avatarImageData = avatarImageData
            persist(changedThreadIDs: [threadID])
            return
        }
        refreshCharacterAppearance(
            for: characterID,
            avatarStyleID: avatarStyleID,
            avatarImageData: avatarImageData
        )
    }

    /// キャラ本体が削除されても、会話スナップショットは残して再開できるようにする。
    func detachCharacterReference(threadID: UUID) {
        guard canMutatePersistedState() else { return }
        guard let index = threads.firstIndex(where: { $0.id == threadID }),
              materializeThreadIfNeeded(at: index) else { return }
        guard threads[index].characterID != nil else { return }
        threads[index].characterID = nil
        threads[index].updatedAt = Date()
        persistAfterActivityUpdate(changedThreadIDs: [threadID])
    }

    /// キャラクター本体を削除した後に、関連する全Personaスレッドを
    /// 保存済みの `personaSnapshot` へ切り替える。会話本文はそのまま残し、
    /// 次回送信時に削除済みUUIDを再取得し続けないよう参照だけを切り離す。
    func detachCharacterReferences(for characterID: UUID) {
        guard canMutatePersistedState() else { return }
        var changedIDs = Set<UUID>()
        let matchingIndices = threads.indices.filter {
            threads[$0].characterID == characterID
        }
        for index in matchingIndices {
            guard materializeThreadIfNeeded(at: index) else { return }
            threads[index].characterID = nil
            changedIDs.insert(threads[index].id)
        }
        guard !changedIDs.isEmpty else { return }
        // Detaching a deleted profile is metadata maintenance, not a new
        // conversation event. Keep each thread's updatedAt and existing order
        // so deleting a character cannot reshuffle the user's history.
        persist(changedThreadIDs: changedIDs)
    }

    func deleteThread(id: UUID) {
        guard canMutatePersistedState() else { return }
        guard threads.contains(where: { $0.id == id }) else { return }
        materializedThreadCache.removeValue(forKey: id)
        threads.removeAll { $0.id == id }
        if activeThreadID == id {
            activeThreadID = threads.first?.id
        }
        persist(changedThreadIDs: [], deletedThreadIDs: [id])
    }

    /// Delete every Persona conversation after an explicit user confirmation.
    /// Recovery-required stores refuse this operation so corrupted bytes cannot
    /// be silently replaced by an empty valid array.
    @discardableResult
    func deleteAllThreads() -> Bool {
        guard canMutatePersistedState() else { return false }
        let deletedIDs = Set(threads.map(\.id))
        materializedThreadCache.removeAll()
        threads = []
        activeThreadID = nil
        persist(changedThreadIDs: [], deletedThreadIDs: deletedIDs, replaceAll: true)
        return true
    }

    func renameThread(id: UUID, title: String) {
        guard canMutatePersistedState() else { return }
        guard let idx = threads.firstIndex(where: { $0.id == id }),
              materializeThreadIfNeeded(at: idx) else { return }
        threads[idx].title = title
        threads[idx].updatedAt = Date()
        // ソートし直し
        persistAfterActivityUpdate(changedThreadIDs: [id])
    }

    /// Persist runtime identity metadata without changing conversation order.
    /// The value is diagnostic provenance, not a new user activity event.
    @discardableResult
    func setLastUsedModelIdentity(_ identity: String?, forThread threadID: UUID) -> Bool {
        guard canMutatePersistedState(),
              let index = threads.firstIndex(where: { $0.id == threadID }),
              materializeThreadIfNeeded(at: index) else {
            return false
        }
        let normalized = identity?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = normalized?.isEmpty == true ? nil : normalized
        guard threads[index].lastUsedModelIdentity != value else { return true }
        threads[index].lastUsedModelIdentity = value
        persist(changedThreadIDs: [threadID])
        return true
    }

    /// Store a thread-local model override without changing conversation
    /// ordering. Nil restores the app-wide Persona default.
    @discardableResult
    func setPreferredGenerationModel(
        _ model: PersonaGenerationModel?,
        configurationID: UUID? = nil,
        forThread threadID: UUID
    ) -> Bool {
        guard canMutatePersistedState(),
              let index = threads.firstIndex(where: { $0.id == threadID }),
              materializeThreadIfNeeded(at: index) else {
            return false
        }
        guard threads[index].preferredGenerationModel != model
                || threads[index].preferredGenerationConfigurationID != configurationID else {
            return true
        }
        threads[index].preferredGenerationModel = model
        threads[index].preferredGenerationConfigurationID = configurationID
        persist(changedThreadIDs: [threadID])
        return true
    }

    // MARK: - Messages

    @discardableResult
    func appendMessage(_ message: PersonaMessage, toThread threadID: UUID) -> Bool {
        guard canMutatePersistedState() else { return false }
        guard let idx = threads.firstIndex(where: { $0.id == threadID }),
              materializeThreadIfNeeded(at: idx) else { return false }
        threads[idx].messages.append(message)
        threads[idx].updatedAt = Date()
        // 最新スレッドを先頭に
        let updated = threads.remove(at: idx)
        threads.insert(updated, at: 0)
        persist(changedThreadIDs: [threadID])
        return true
    }

    /// Commit the final assistant text and activity order as one MainActor
    /// operation. Streaming previews stay in the service/UI layer and never
    /// mutate the persisted message array.
    @discardableResult
    func finalizeLastAssistantMessage(in threadID: UUID, text: String) -> Bool {
        guard canMutatePersistedState() else { return false }
        guard let threadIdx = threads.firstIndex(where: { $0.id == threadID }),
              materializeThreadIfNeeded(at: threadIdx) else { return false }
        guard let lastIdx = threads[threadIdx].messages.lastIndex(where: { $0.role == .assistant }) else { return false }
        threads[threadIdx].messages[lastIdx].text = text
        threads[threadIdx].updatedAt = Date()
        persistAfterActivityUpdate(changedThreadIDs: [threadID])
        return true
    }

    /// Commit a specific assistant placeholder. Generation cleanup must use
    /// the message identity it created instead of whichever assistant happens
    /// to be last after a concurrent history update.
    @discardableResult
    func finalizeAssistantMessage(in threadID: UUID, messageID: UUID, text: String) -> Bool {
        guard canMutatePersistedState() else { return false }
        guard let threadIdx = threads.firstIndex(where: { $0.id == threadID }),
              materializeThreadIfNeeded(at: threadIdx) else { return false }
        guard let messageIdx = threads[threadIdx].messages.firstIndex(where: {
            $0.id == messageID && $0.role == .assistant
        }) else { return false }
        threads[threadIdx].messages[messageIdx].text = text
        threads[threadIdx].updatedAt = Date()
        persistAfterActivityUpdate(changedThreadIDs: [threadID])
        return true
    }

    /// Add a completed assistant response after it has crossed the output
    /// safety boundary. A generation ID makes the commit idempotent and keeps
    /// a retry or duplicate completion from appending the same response twice.
    @discardableResult
    func appendFinalizedAssistantMessage(
        in threadID: UUID,
        messageID: UUID,
        text: String
    ) -> PersonaAssistantCommitResult {
        guard canMutatePersistedState(),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let threadIdx = threads.firstIndex(where: { $0.id == threadID }),
              materializeThreadIfNeeded(at: threadIdx) else {
            return .rejected
        }
        if let existing = threads[threadIdx].messages.first(where: { $0.id == messageID }) {
            guard existing.role == .assistant, existing.text == text else {
                return .rejected
            }
            return .alreadyPresent
        }
        threads[threadIdx].messages.append(
            PersonaMessage(id: messageID, role: .assistant, text: text)
        )
        threads[threadIdx].updatedAt = Date()
        persistAfterActivityUpdate(changedThreadIDs: [threadID])
        return .inserted
    }

    /// 旧バージョンが生成開始時に保存した空のアシスタント枠を、
    /// 別経路へ切り替える時に取り除く。新しい生成経路は枠を保存せず、
    /// `appendFinalizedAssistantMessage`でSafety評価済みの本文だけを保存する。
    func removePendingAssistantMessage(in threadID: UUID) {
        guard canMutatePersistedState() else { return }
        guard let threadIdx = threads.firstIndex(where: { $0.id == threadID }),
              materializeThreadIfNeeded(at: threadIdx) else { return }
        guard let last = threads[threadIdx].messages.last,
              last.role == .assistant,
              isPendingAssistantText(last.text) else { return }
        threads[threadIdx].messages.removeLast()
        threads[threadIdx].updatedAt = Date()
        persistAfterActivityUpdate(changedThreadIDs: [threadID])
    }

    /// 失敗確定時に、ストリーミング途中の本文を履歴へ残さないための削除。
    func removeLastAssistantMessage(in threadID: UUID) {
        guard canMutatePersistedState() else { return }
        guard let threadIdx = threads.firstIndex(where: { $0.id == threadID }),
              materializeThreadIfNeeded(at: threadIdx),
              threads[threadIdx].messages.last?.role == .assistant else { return }
        threads[threadIdx].messages.removeLast()
        threads[threadIdx].updatedAt = Date()
        persistAfterActivityUpdate(changedThreadIDs: [threadID])
    }

    /// Remove only the assistant placeholder owned by the active generation.
    /// Requiring the message ID prevents cancellation from deleting a prior
    /// completed response when the placeholder append was lost in a race.
    @discardableResult
    func removeAssistantMessage(in threadID: UUID, messageID: UUID) -> Bool {
        guard canMutatePersistedState() else { return false }
        guard let threadIdx = threads.firstIndex(where: { $0.id == threadID }),
              materializeThreadIfNeeded(at: threadIdx),
              let messageIdx = threads[threadIdx].messages.firstIndex(where: {
                  $0.id == messageID && $0.role == .assistant
              }) else { return false }
        threads[threadIdx].messages.remove(at: messageIdx)
        threads[threadIdx].updatedAt = Date()
        persistAfterActivityUpdate(changedThreadIDs: [threadID])
        return true
    }

    /// 失敗したターンを再送する前に、直前のユーザー発話だけを取り除く。
    func removeLastUserMessage(in threadID: UUID, matching text: String? = nil) {
        guard canMutatePersistedState() else { return }
        guard let threadIdx = threads.firstIndex(where: { $0.id == threadID }),
              materializeThreadIfNeeded(at: threadIdx),
              let last = threads[threadIdx].messages.last,
              last.role == .user else { return }
        if let text, last.text != text { return }
        threads[threadIdx].messages.removeLast()
        threads[threadIdx].updatedAt = Date()
        persistAfterActivityUpdate(changedThreadIDs: [threadID])
    }

    func finalizePersist() {
        guard canMutatePersistedState() else { return }
        // Keep non-assistant final saves (for example narration) consistent
        // with the same activity-order invariant.
        threads = PersonaThreadOrdering.mostRecentFirst(threads)
        if storageURL == nil {
            persist()
        } else {
            flushPendingPersistence()
        }
    }

    private func persistAfterActivityUpdate(changedThreadIDs: Set<UUID>) {
        threads = PersonaThreadOrdering.mostRecentFirst(threads)
        persist(changedThreadIDs: changedThreadIDs)
    }

    /// Finish the latest coalesced snapshot when the scene is backgrounded.
    /// The write remains off the MainActor, but is no longer delayed by the
    /// normal debounce window.
    func flushPendingPersistence() {
        guard !hasRecoveryState else { return }
        if storageURL == nil {
            persist()
        } else {
            schedulePendingPersistence(delayNanoseconds: 0)
        }
    }

    /// Allows lifecycle coordination and persistence tests to await the
    /// currently scheduled atomic write without exposing the writer itself.
    func waitForPendingPersistence() async {
        await pendingPersistTask?.value
    }

    private func isPendingAssistantText(_ text: String) -> Bool {
        PersonaMessage.isPendingAssistantText(text)
    }
}
