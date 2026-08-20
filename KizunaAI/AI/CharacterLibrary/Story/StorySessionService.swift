/*
仕様:
- 役割: Story モードの会話セッション (StorySession) を駆動するサービス。
  ユーザー発話 → 270M 分類 + シーンキャラ選別 → safety → StoryPromptBuilder → E4B 生成 →
  safety → 話者ごとに分割しメッセージ化 → memory/scene summary 更新。
- 主な型: `StorySessionService` (ObservableObject, MainActor)。
- 編集ポイント: 多話者の応答 parse、active キャラ enforcement、自動 scene 切替トリガ。
*/

import Foundation
import Combine

/// Runtime error cards carry their retry target inside the persisted message text.
/// StoryMessage is shared by older stores and cannot gain a new field here, so use
/// invisible variation selectors instead of exposing implementation metadata in UI.
/// The parser deliberately tolerates missing metadata and callers can fall back to
/// the closest preceding user message for records written by older versions.
enum StoryRetryMetadata {
    private static let startMarker = "\u{2063}\u{2060}"
    private static let endMarker = "\u{2060}\u{2063}"

    static func attachingUserMessageID(_ id: UUID, to text: String) -> String {
        let hex = id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var encoded = ""
        for character in hex {
            guard let nibble = Int(String(character), radix: 16),
                  let scalar = UnicodeScalar(0xFE00 + nibble) else { continue }
            encoded.unicodeScalars.append(scalar)
        }
        return text + startMarker + encoded + endMarker
    }

    static func userMessageID(in text: String) -> UUID? {
        guard let start = text.range(of: startMarker),
              let end = text.range(of: endMarker, range: start.upperBound..<text.endIndex) else {
            return nil
        }
        var hex = ""
        for scalar in text[start.upperBound..<end.lowerBound].unicodeScalars {
            let value = Int(scalar.value)
            guard (0xFE00...0xFE0F).contains(value) else { return nil }
            hex.append(String(format: "%x", value - 0xFE00))
        }
        guard hex.count == 32 else { return nil }
        let part1 = String(hex.prefix(8))
        let part2 = String(hex.dropFirst(8).prefix(4))
        let part3 = String(hex.dropFirst(12).prefix(4))
        let part4 = String(hex.dropFirst(16).prefix(4))
        let part5 = String(hex.dropFirst(20).prefix(12))
        let uuidText = "\(part1)-\(part2)-\(part3)-\(part4)-\(part5)"
        return UUID(uuidString: uuidText)
    }

    /// Removes metadata for presentation/debug output. The marker is invisible,
    /// but stripping it keeps exports and future UI surfaces clean as well.
    static func removingMetadata(from text: String) -> String {
        var result = text
        while let start = result.range(of: startMarker),
              let end = result.range(of: endMarker, range: start.upperBound..<result.endIndex) {
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return result
    }
}

/// 一時的なランタイム/保存失敗を会話履歴へ永続化せず表示する通知の再試行方法。
/// 保存に失敗した補助操作も、直前のユーザーターンを誤って再送しないよう、
/// 操作ごとの再試行を明示的に保持する。
enum StoryRuntimeNoticeRetryAction: Equatable {
    case userTurn
    case narration(text: String)
    case restAcknowledgement(characterID: UUID, characterName: String)
    case storyTurnCommit(StoryTurnCommitRetry)
    case storyMemory(StoryMemoryRetry)

    var isAuxiliarySave: Bool {
        switch self {
        case .storyTurnCommit, .storyMemory:
            return true
        case .userTurn, .narration, .restAcknowledgement:
            return false
        }
    }
}

/// A failed commit must be retried with the exact generated snapshot. Keeping
/// the session/scene snapshot here prevents the retry UI from falling back to
/// the user-turn path and invoking the model again.
struct StoryTurnCommitRetry: Equatable {
    let session: StorySession
    let scene: StoryScene
    let turnID: UUID
    let attempt: Int
    let assistantMessageIDs: [UUID]
    let characterMemories: [CharacterMemory]
    let storyMemories: [StoryMemory]
    let userMessageID: UUID
    let userText: String
}

/// A commit can throw after the journal has already made the session/scene
/// snapshot durable. Only treat that recovery as successful when the Session
/// identifies the exact generated turn and the catalog Scene still exists in
/// the same World. Scene runtime fields are not owned by a turn.
enum StoryTurnCommitRecovery {
    private static func normalizedMessageIDs(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }

    private static func storyStatesMatch(_ lhs: StoryState?, _ rhs: StoryState?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            // updatedAt is deliberately excluded: the JSON date codec may
            // round fractional seconds while the logical state remains the
            // exact snapshot produced by this turn.
            return lhs.location == rhs.location
                && lhs.timeOfDay == rhs.timeOfDay
                && lhs.mood == rhs.mood
                && lhs.weather == rhs.weather
                && lhs.relationshipStage == rhs.relationshipStage
                && lhs.characterStates == rhs.characterStates
                && lhs.inventory == rhs.inventory
                && lhs.activeGoals == rhs.activeGoals
        default:
            return false
        }
    }

    private static func generatedSessionFieldsMatch(
        _ expected: StorySession,
        _ persisted: StorySession,
        retry: StoryTurnCommitRetry
    ) -> Bool {
        guard expected.id == persisted.id,
              expected.storyWorldId == persisted.storyWorldId,
              expected.progressLabel == persisted.progressLabel,
              expected.currentObjective == persisted.currentObjective,
              expected.relationshipStage == persisted.relationshipStage,
              expected.lastTurnProgress == persisted.lastTurnProgress,
              expected.lastSceneSummary == persisted.lastSceneSummary,
              expected.unresolvedHooks == persisted.unresolvedHooks,
              storyStatesMatch(expected.storyState, persisted.storyState),
              expected.lastSelectedModelName == persisted.lastSelectedModelName,
              expected.lastUsedBackendName == persisted.lastUsedBackendName else {
            return false
        }

        // A retry owns only this turn's messages. Later system/narration
        // messages may legitimately be appended after the commit, so compare
        // the user and assistant records by stable ID instead of requiring an
        // identical whole-message array.
        var expectedMessages: [UUID: StoryMessage] = [:]
        for message in expected.messages {
            expectedMessages[message.id] = message
        }
        guard !expectedMessages.isEmpty else { return true }
        var persistedMessages: [UUID: StoryMessage] = [:]
        for message in persisted.messages {
            persistedMessages[message.id] = message
        }
        let ownedMessageIDs = normalizedMessageIDs(
            [retry.userMessageID] + retry.assistantMessageIDs
        )
        return ownedMessageIDs.allSatisfy { messageID in
            guard let expectedMessage = expectedMessages[messageID],
                  let persistedMessage = persistedMessages[messageID] else {
                return false
            }
            return expectedMessage.author == persistedMessage.author
                && expectedMessage.text == persistedMessage.text
                && expectedMessage.generationID == persistedMessage.generationID
                && persistedMessage.turnID == retry.turnID
                && (expectedMessage.turnID == nil
                    || expectedMessage.turnID == persistedMessage.turnID)
                && expectedMessage.retryBackend == persistedMessage.retryBackend
        }
    }

    static func committedSession(
        matching retry: StoryTurnCommitRetry,
        in sessions: [StorySession],
        scenes: [StoryScene]
    ) -> StorySession? {
        guard scenes.contains(where: {
            $0.id == retry.scene.id && $0.storyWorldId == retry.scene.storyWorldId
        }) else {
            return nil
        }

        // Scene is catalog data. A committed turn no longer owns its summary
        // or active cast, so recovery must require only the stable identity
        // and world boundary rather than comparing a stale generated snapshot.

        return sessions.first { session in
            guard session.id == retry.session.id,
                  session.storyWorldId == retry.session.storyWorldId,
                  session.currentSceneId == retry.scene.id,
                  let checkpoint = session.latestTurnCheckpoint,
                  checkpoint.turnID == retry.turnID,
                  checkpoint.userMessageID == retry.userMessageID,
                  checkpoint.attempt == retry.attempt,
                  checkpoint.status == .committed else {
                return false
            }
            guard normalizedMessageIDs(checkpoint.assistantMessageIDs)
                    == normalizedMessageIDs(retry.assistantMessageIDs) else {
                return false
            }
            if let expectedCheckpoint = retry.session.latestTurnCheckpoint {
                guard checkpoint.baseRevision == expectedCheckpoint.baseRevision,
                      checkpoint.ownerID == expectedCheckpoint.ownerID,
                      checkpoint.userMessageID == expectedCheckpoint.userMessageID else {
                    return false
                }
            }
            return generatedSessionFieldsMatch(retry.session, session, retry: retry)
        }
    }
}

/// Memory writes happen after the conversation turn is committed. A failed
/// memory write is therefore an auxiliary retry and must never regenerate the
/// already-saved assistant response.
struct StoryMemoryRetry: Codable, Equatable {
    let turnID: UUID
    let userMessageID: UUID
    let userText: String
    let characterMemories: [CharacterMemory]
    let storyMemories: [StoryMemory]
    /// Session/world scope is stored separately from the memory payload so a
    /// retry can be restored before any memory is written into a repository.
    /// The optionals keep in-memory/test callers and any future legacy retry
    /// records decodable.
    let storySessionID: UUID?
    let storyWorldID: UUID?
    /// A durable completion marker closes the crash window between removing
    /// the retry queue and removing its turn journal. Older JSON has no key,
    /// so decoding defaults to false.
    var isCompleted: Bool
    /// Counts restore attempts for a retry whose owning StorySession is no
    /// longer present. Keeping this bounded prevents an orphaned record from
    /// remaining actionable forever after its session was deleted or lost.
    var missingSessionRestoreAttempts: Int
    /// Terminal diagnostic state for an orphaned retry. The record remains in
    /// JSON for diagnosis, but is excluded from the active retry queue.
    var isAbandoned: Bool

    private enum CodingKeys: String, CodingKey {
        case turnID
        case userMessageID
        case userText
        case characterMemories
        case storyMemories
        case storySessionID
        case storyWorldID
        case isCompleted
        case missingSessionRestoreAttempts
        case isAbandoned
    }

    init(
        turnID: UUID,
        userMessageID: UUID,
        userText: String,
        characterMemories: [CharacterMemory],
        storyMemories: [StoryMemory],
        storySessionID: UUID? = nil,
        storyWorldID: UUID? = nil,
        isCompleted: Bool = false,
        missingSessionRestoreAttempts: Int = 0,
        isAbandoned: Bool = false
    ) {
        self.turnID = turnID
        self.userMessageID = userMessageID
        self.userText = userText
        self.characterMemories = characterMemories
        self.storyMemories = storyMemories
        self.storySessionID = storySessionID
        self.storyWorldID = storyWorldID
        self.isCompleted = isCompleted
        self.missingSessionRestoreAttempts = max(0, missingSessionRestoreAttempts)
        self.isAbandoned = isAbandoned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        turnID = try container.decode(UUID.self, forKey: .turnID)
        userMessageID = try container.decode(UUID.self, forKey: .userMessageID)
        userText = try container.decode(String.self, forKey: .userText)
        characterMemories = try container.decode([CharacterMemory].self, forKey: .characterMemories)
        storyMemories = try container.decode([StoryMemory].self, forKey: .storyMemories)
        storySessionID = try container.decodeIfPresent(UUID.self, forKey: .storySessionID)
        storyWorldID = try container.decodeIfPresent(UUID.self, forKey: .storyWorldID)
        isCompleted = try container.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        missingSessionRestoreAttempts = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .missingSessionRestoreAttempts) ?? 0
        )
        isAbandoned = try container.decodeIfPresent(Bool.self, forKey: .isAbandoned) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(turnID, forKey: .turnID)
        try container.encode(userMessageID, forKey: .userMessageID)
        try container.encode(userText, forKey: .userText)
        try container.encode(characterMemories, forKey: .characterMemories)
        try container.encode(storyMemories, forKey: .storyMemories)
        try container.encodeIfPresent(storySessionID, forKey: .storySessionID)
        try container.encodeIfPresent(storyWorldID, forKey: .storyWorldID)
        try container.encode(isCompleted, forKey: .isCompleted)
        try container.encode(missingSessionRestoreAttempts, forKey: .missingSessionRestoreAttempts)
        try container.encode(isAbandoned, forKey: .isAbandoned)
    }
}

/// モデル状態/安全ブロック/保存失敗を会話履歴へ永続化せず表示する一時通知。
/// 過去ログには本文だけを残し、再試行対象はUUIDと入力本文で保持する。
struct StoryRuntimeNotice: Identifiable, Equatable {
    let id: UUID
    let text: String
    let userMessageID: UUID
    let userText: String
    let backendName: String
    /// UIの再試行先を言語非依存で表す。backendNameは表示/ログ用に残す。
    let backend: StoryGenerationBackend
    let retryAction: StoryRuntimeNoticeRetryAction
    /// A readiness timeout may be retried automatically once the local model
    /// becomes executable. Other failures remain user-controlled.
    let retryWhenLocalReady: Bool

    init(
        id: UUID = UUID(),
        text: String,
        userMessageID: UUID,
        userText: String,
        backendName: String,
        backend: StoryGenerationBackend,
        retryAction: StoryRuntimeNoticeRetryAction = .userTurn,
        retryWhenLocalReady: Bool = false
    ) {
        self.id = id
        self.text = text
        self.userMessageID = userMessageID
        self.userText = userText
        self.backendName = backendName
        self.backend = backend
        self.retryAction = retryAction
        self.retryWhenLocalReady = retryWhenLocalReady
    }
}

extension StoryRuntimeNotice {
    /// The user-turn retry ID comes from the notice, not a possibly stale
    /// ViewModel session snapshot. The send preparation refreshes persistence
    /// before using this ID.
    var persistedUserMessageIDForRetry: UUID? {
        guard case .userTurn = retryAction else { return nil }
        return userMessageID
    }
}

@MainActor
final class StorySessionService: ObservableObject {
    enum Phase: Equatable {
        case idle
        case thinking
        case error(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var streamingResponse: String = ""
    @Published private(set) var streamingSpeakerName: String?
    @Published private(set) var streamingStatusText: String = ""
    @Published private(set) var savedTurnRevision: Int = 0
    @Published private(set) var lastCommittedSession: StorySession?
    /// 危険な相談の可能性を検知した時だけ、会話とは別にUIへ渡す。
    @Published private(set) var latestSafetyConcern: SafetyConcern?
    /// エラー本文をStorySessionへ保存せず、現在の画面だけに表示する。
    @Published private(set) var latestRuntimeNotice: StoryRuntimeNotice?
    /// 補助保存の再試行中は同じ操作を二重起動しない。
    @Published private(set) var isRetryingAuxiliarySave = false

    /// Installed only by the internal acceptance runner. The normal app does
    /// not retain prompts or raw model output outside this service.
    var acceptanceGenerationTraceHandler: ((StoryAcceptanceGenerationTrace) -> Void)?
    /// Diagnostic-only signal for the app-path acceptance runner. This is
    /// separate from narrator message shape because a valid Story response
    /// may contain narration without a safety block.
    private(set) var acceptanceInputSafetyBlocked = false

    // DI (デフォルトは Local + Mock)
    private let characterRepo: CharacterRepository
    private let memoryRepo: MemoryRepository
    private let worldRepo: StoryWorldRepository
    private let castRepo: CastRepository
    private let sessionRepo: StorySessionRepository
    private let sceneRepo: StorySceneRepository
    // Lorebookは必要な項目だけを選択してプロンプトへ渡す。
    private let lorebookRepo: StoryLorebookRepository
    // 物語内メモリーは全体メモリー(CharacterMemory)と別ストアで管理する。
    private let storyMemoryRepo: StoryMemoryRepository
    private let storyMemoryRetryRepo: StoryMemoryRetryRepository
    /// Local JSON production wiring can use one cross-file transaction. Test
    /// doubles and future repositories keep the existing per-repository
    /// fallback unless they explicitly provide this capability.
    private let storyMemoryRetryMemoryTransaction: StoryMemoryRetryMemoryTransaction?
    private let safetyPipeline = SafetyPipeline.shared
    private let sceneSelector: SceneCharacterSelecting = MockSceneCharacterSelector()
    private let summarizer: SceneSummarizing = MockSceneSummarizer()
    private let nextScene: NextSceneSuggesting = MockNextSceneSuggester()
    private let memorySelector: MemorySelecting = MockMemorySelector()
    private let memorySummarizer: MemorySummarizing = MockMemorySummarizer()
    private let promptBuilder = StoryPromptBuilder()
    /// Serviceインスタンスごとのowner。プロセス共通IDにすると、画面を
    /// 作り直したServiceが、まだ生きている別Serviceと区別できない。
    /// nonisolated leaseにすることで、ViewModelのnonisolated deinitから
    /// cleanup Taskの起動前にownerを解除できる。
    private nonisolated let turnOwnerLease = StoryTurnOwnerLease()
    private var isOwnerRegistered = true

    private var generationTask: Task<Void, Never>?
    /// cancel()/watchdogが開始したcheckpoint終了処理。次の送信は、
    /// pendingが確実にfailed/cancelledへ遷移してからbeginTurnする。
    private var pendingTurnFinishTask: Task<Void, Never>?
    /// A newer cancellation may enqueue another cleanup while an older one is
    /// still running. The token prevents the older waiter from clearing the
    /// newer task reference.
    private var pendingTurnFinishToken: UUID?
    private var lastVisibleText: String = ""
    private var activeGenerationID: UUID?
    /// 共有LiteRTランタイムを停止してよいのは、現在の生成がioriの時だけ。
    /// NAGI（Gemma API）のキャンセルで共有ランタイムまで止めると、次の
    /// iori会話が巻き込まれるため、生成世代とモデルを一緒に追跡する。
    private var activeGenerationModel: StoryGenerationModel?
    private var activeTurnID: UUID?
    private var activeSessionID: UUID?
    private var activeTurnAttempt: Int?
    private var activeUserMessageID: UUID?
    private var activeUserText = ""
    /// A failed turn commit remains pending until the exact generated snapshot
    /// is committed or the app is reloaded and journal recovery handles it.
    private var pendingStoryTurnCommitRetries: [UUID: StoryTurnCommitRetry] = [:]
    /// Memory writes are best-effort after a committed turn, but failed writes
    /// remain retryable for this view-model lifetime and are reattached after a
    /// later successful turn if the user keeps chatting.
    private var pendingStoryMemoryRetries: [UUID: StoryMemoryRetry] = [:]
    /// Keep retry cards deterministic when more than one committed turn has
    /// outstanding memory writes. Dictionary iteration order is not a UI
    /// ordering contract.
    private var pendingStoryMemoryRetryOrder: [UUID] = []
    /// Timeout notice persistence has its own validity token. A watchdog may
    /// suspend at a repository await; cancellation or a newer turn must then
    /// invalidate the pending save before it can write a stale snapshot.
    private var timeoutSaveToken: UUID?
    private var generationWatchdogDeadline: Date?
    private static let generationWatchdogDuration: TimeInterval = 75
    private static let localRuntimeSystemPromptLimit = 1_250
    private static let maxMissingSessionRestoreAttempts = 3
    private let progressDecoder = JSONDecoder()

    deinit {
        turnOwnerLease.unregister()
    }

    /// ViewModel deinit用。Taskを作る前に同期的にownerを解放する。
    nonisolated func releaseOwnerForTeardown() {
        turnOwnerLease.unregister()
    }

    /// ViewModelが画面から外れる時に呼び出し、保存済みpending turnを
    /// 新しいServiceが復旧できるようowner登録を先に解除する。
    /// `cancel()`は非同期cleanupを開始するが、owner解放は待たない。
    func shutdown() {
        releaseTurnOwner()
        cancel()
    }

    private func releaseTurnOwner() {
        guard isOwnerRegistered else { return }
        isOwnerRegistered = false
        turnOwnerLease.unregister()
    }

    private func ensureTurnOwnerRegistered() {
        guard !isOwnerRegistered else { return }
        turnOwnerLease.register()
        isOwnerRegistered = true
    }

    private var turnOwnerID: UUID { turnOwnerLease.id }

    /// Keep the last resolved cast when the selector has no usable result.
    /// An empty selector result is an inference failure, not an explicit user
    /// request to remove every character from the session.
    nonisolated static func activeCharacterIDsForTurn(
        selectedIDs: [UUID],
        previousIDs: [UUID],
        limit: Int
    ) -> [UUID] {
        let cappedSelectedIDs = Array(selectedIDs.prefix(limit))
        guard !cappedSelectedIDs.isEmpty else {
            return Array(previousIDs.prefix(limit))
        }
        return cappedSelectedIDs
    }

    private static func canonicalStorageURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// The built-in cross-file transaction has fixed target filenames. It is
    /// safe only when all injected local repositories point at the same
    /// storage root and those filenames match the transaction's targets.
    private static func localJSONMemoryTransactionIsCompatible(
        memoryRepo: MemoryRepository,
        storyMemoryRepo: StoryMemoryRepository,
        storyMemoryRetryRepo: StoryMemoryRetryRepository
    ) -> Bool {
        guard let memory = memoryRepo as? LocalJSONMemoryFileIdentityProviding,
              let storyMemory = storyMemoryRepo as? LocalJSONMemoryFileIdentityProviding,
              let retry = storyMemoryRetryRepo as? LocalJSONStorageIdentityProviding else {
            return false
        }
        let memoryURL = canonicalStorageURL(memory.storageURL)
        let storyMemoryURL = canonicalStorageURL(storyMemory.storageURL)
        let retryURL = canonicalStorageURL(retry.storageURL)
        return memoryURL == storyMemoryURL
            && storyMemoryURL == retryURL
            && memory.fileName == "memories.json"
            && storyMemory.fileName == "story_memories.json"
    }

    init(
        characterRepo: CharacterRepository = LocalJSONCharacterRepository(),
        memoryRepo: MemoryRepository = LocalJSONMemoryRepository(),
        worldRepo: StoryWorldRepository = LocalJSONStoryWorldRepository(),
        castRepo: CastRepository = LocalJSONCastRepository(),
        sessionRepo: StorySessionRepository = LocalJSONStorySessionRepository(),
        sceneRepo: StorySceneRepository = LocalJSONStorySceneRepository(),
        lorebookRepo: StoryLorebookRepository = LocalJSONStoryLorebookRepository(),
        storyMemoryRepo: StoryMemoryRepository = LocalJSONStoryMemoryRepository(),
        storyMemoryRetryRepo: StoryMemoryRetryRepository = LocalJSONStoryMemoryRetryRepository(),
        storyMemoryRetryMemoryTransaction: StoryMemoryRetryMemoryTransaction? = nil,
        pendingStoryTurnCommitRetries: [StoryTurnCommitRetry] = [],
        pendingStoryMemoryRetries: [StoryMemoryRetry] = []
    ) {
        self.characterRepo = characterRepo
        self.memoryRepo = memoryRepo
        self.worldRepo = worldRepo
        self.castRepo = castRepo
        self.sessionRepo = sessionRepo
        self.sceneRepo = sceneRepo
        self.lorebookRepo = lorebookRepo
        self.storyMemoryRepo = storyMemoryRepo
        self.storyMemoryRetryRepo = storyMemoryRetryRepo
        if let storyMemoryRetryMemoryTransaction {
            let hasLocalStorageIdentities = memoryRepo is LocalJSONMemoryFileIdentityProviding
                && storyMemoryRepo is LocalJSONMemoryFileIdentityProviding
                && storyMemoryRetryRepo is LocalJSONStorageIdentityProviding
            self.storyMemoryRetryMemoryTransaction = hasLocalStorageIdentities
                ? (Self.localJSONMemoryTransactionIsCompatible(
                    memoryRepo: memoryRepo,
                    storyMemoryRepo: storyMemoryRepo,
                    storyMemoryRetryRepo: storyMemoryRetryRepo
                ) ? storyMemoryRetryMemoryTransaction : nil)
                : storyMemoryRetryMemoryTransaction
        } else if memoryRepo is LocalJSONMemoryRepository,
                  storyMemoryRepo is LocalJSONStoryMemoryRepository,
                  let localTransaction = storyMemoryRetryRepo as? StoryMemoryRetryMemoryTransaction,
                  Self.localJSONMemoryTransactionIsCompatible(
                      memoryRepo: memoryRepo,
                      storyMemoryRepo: storyMemoryRepo,
                      storyMemoryRetryRepo: storyMemoryRetryRepo
                  ) {
            self.storyMemoryRetryMemoryTransaction = localTransaction
        } else {
            self.storyMemoryRetryMemoryTransaction = nil
        }
        for retry in pendingStoryTurnCommitRetries {
            self.pendingStoryTurnCommitRetries[retry.turnID] = retry
        }
        for retry in pendingStoryMemoryRetries where !retry.isCompleted && !retry.isAbandoned {
            self.pendingStoryMemoryRetries[retry.turnID] = retry
            self.pendingStoryMemoryRetryOrder.append(retry.turnID)
        }
    }

    @discardableResult
    private func enqueueStoryMemoryRetry(_ retry: StoryMemoryRetry) async -> Bool {
        if pendingStoryMemoryRetries[retry.turnID] == nil {
            pendingStoryMemoryRetryOrder.append(retry.turnID)
        }
        pendingStoryMemoryRetries[retry.turnID] = retry
        do {
            try await storyMemoryRetryRepo.saveRetry(retry)
        } catch {
            // Keep the in-memory retry visible for the current screen. The
            // notice remains actionable, while the persistence error is not
            // allowed to masquerade as a successful auxiliary save.
            AppLog.note(
                "[StorySession] memory retry queue save failed turn=%@: %@",
                retry.turnID.uuidString,
                error.localizedDescription
            )
            return false
        }
        return true
    }

    @discardableResult
    private func removeStoryMemoryJournal(for turnID: UUID) async -> Bool {
        do {
            try await StoryTurnJournal.removeAsync(turnID: turnID)
            return true
        } catch {
            // The auxiliary write is already complete. Retaining the journal
            // is safe and lets the next recovery retry the idempotent cleanup.
            AppLog.note(
                "[StorySession] memory retry journal cleanup deferred turn=%@: %@",
                turnID.uuidString,
                error.localizedDescription
            )
            return false
        }
    }

    /// Persist completion before deleting the journal. If the process stops
    /// after the marker is written, recovery will not reintroduce the already
    /// successful retry. The queue record is removed only after the journal is
    /// gone, so a failed cleanup leaves a harmless marker rather than an
    /// actionable stale retry.
    @discardableResult
    private func completeStoryMemoryRetry(_ retry: StoryMemoryRetry) async -> Bool {
        guard !retry.isCompleted else { return true }
        var completed = retry
        completed.isCompleted = true
        do {
            try await storyMemoryRetryRepo.saveRetry(completed)
        } catch let error as StoryTurnPersistenceError {
            if case .recordDeleted = error {
                // A tombstoned session cannot accept the completion marker.
                // The retry itself is already stale, so remove only that
                // queue entry and its journal instead of leaving an
                // unremovable notice in memory.
                pendingStoryMemoryRetries.removeValue(forKey: retry.turnID)
                pendingStoryMemoryRetryOrder.removeAll { $0 == retry.turnID }
                do {
                    try await storyMemoryRetryRepo.deleteRetry(turnID: retry.turnID)
                } catch {
                    AppLog.note(
                        "[StorySession] deleted memory retry cleanup deferred turn=%@: %@",
                        retry.turnID.uuidString,
                        error.localizedDescription
                    )
                }
                _ = await removeStoryMemoryJournal(for: retry.turnID)
                return false
            }
            AppLog.note(
                "[StorySession] memory retry completion marker failed turn=%@: %@",
                retry.turnID.uuidString,
                error.localizedDescription
            )
            return false
        } catch {
            AppLog.note(
                "[StorySession] memory retry completion marker failed turn=%@: %@",
                retry.turnID.uuidString,
                error.localizedDescription
            )
            return false
        }

        pendingStoryMemoryRetries.removeValue(forKey: retry.turnID)
        pendingStoryMemoryRetryOrder.removeAll { $0 == retry.turnID }
        guard await removeStoryMemoryJournal(for: retry.turnID) else {
            return false
        }
        do {
            try await storyMemoryRetryRepo.deleteRetry(turnID: retry.turnID)
            return true
        } catch {
            // The completion marker remains durable and is filtered during
            // restore. Journal recovery can purge it once the journal is gone.
            AppLog.note(
                "[StorySession] completed memory retry cleanup deferred turn=%@: %@",
                retry.turnID.uuidString,
                error.localizedDescription
            )
            return false
        }
    }

    /// Restores only retries belonging to the currently opened StorySession.
    /// Other sessions remain in the shared queue for their own view to pick
    /// up. Legacy records without a trustworthy Session ID remain queued for
    /// migration, but are never assigned to a Session by World ID alone.
    func restorePendingStoryMemoryRetries(
        storySessionID: UUID,
        storyWorldID: UUID
    ) async throws {
        let sessions = try await sessionRepo.fetchSessions(storyWorldId: storyWorldID)
        guard let session = sessions.first(where: { $0.id == storySessionID }) else {
            // A retry must never create memory for a deleted or otherwise
            // missing session. Quarantine matching records after a bounded
            // number of restore attempts so an orphan cannot remain an active
            // retry forever. Unknown legacy records are left untouched because
            // assigning them to this missing session would be unsafe.
            let persisted = try await storyMemoryRetryRepo.fetchRetries()
            for retry in persisted where
                !retry.isCompleted
                    && !retry.isAbandoned
                    && Self.retryNeedsOrphanQuarantine(
                        retry,
                        storySessionID: storySessionID,
                        storyWorldID: storyWorldID
                    ) {
                var quarantined = retry
                quarantined.missingSessionRestoreAttempts = min(
                    Self.maxMissingSessionRestoreAttempts,
                    retry.missingSessionRestoreAttempts + 1
                )
                if quarantined.missingSessionRestoreAttempts
                    >= Self.maxMissingSessionRestoreAttempts {
                    quarantined.isAbandoned = true
                }
                do {
                    try await storyMemoryRetryRepo.saveRetry(quarantined)
                } catch let error as StoryTurnPersistenceError {
                    if case .recordDeleted = error {
                        // A tombstone is stronger evidence than a missing
                        // session. Remove only the stale queue entry; do not
                        // touch any memory payload here.
                        try await storyMemoryRetryRepo.deleteRetry(turnID: retry.turnID)
                        continue
                    }
                    throw error
                }
            }
            return
        }
        // Fetch the auxiliary queue after session recovery. Tombstone
        // reconciliation may have purged retries belonging to a deliberately
        // deleted session; loading the queue first would retain a stale copy
        // in this ViewModel for the remainder of the bootstrap.
        let persisted = try await storyMemoryRetryRepo.fetchRetries()
        let scoped = persisted.filter { retry in
            guard Self.retryBelongsToSession(
                retry,
                storySessionID: storySessionID,
                storyWorldID: storyWorldID
            ) else {
                // A legacy record without a trustworthy owner, or a malformed
                // record that mixes sessions, must remain queued for diagnosis
                // and must never appear as this Session's retry notice.
                return false
            }
            return !retry.isCompleted && !retry.isAbandoned
        }
        let latestCheckpoint = session.latestTurnCheckpoint
        for retry in scoped {
            guard !retry.isCompleted else { continue }
            let retryMemorySessionIDs = Set(
                retry.storyMemories.compactMap(\.storySessionId)
            )
            let isLatestTurnKnownUncommitted = latestCheckpoint?.turnID == retry.turnID
                && latestCheckpoint?.status != .committed

            // Only delete when the session has positive evidence that this
            // retry belongs to a pending/failed turn. An older committed turn
            // has no longer got its own checkpoint, so "not the latest" is not
            // evidence that its memory work is stale.
            if isLatestTurnKnownUncommitted {
                do {
                    // Keep the source journal as a recovery record, but fence
                    // its auxiliary retry before removing it from the active
                    // queue. If the journal is retained because the paired
                    // Scene is missing, the next recovery must not resurrect
                    // discarded memory work.
                    var discarded = retry
                    discarded.isCompleted = true
                    try await storyMemoryRetryRepo.saveRetry(discarded)
                    pendingStoryMemoryRetries.removeValue(forKey: retry.turnID)
                    pendingStoryMemoryRetryOrder.removeAll { $0 == retry.turnID }
                } catch {
                    AppLog.note(
                        "[StorySession] stale memory retry cleanup failed turn=%@: %@",
                        retry.turnID.uuidString,
                        error.localizedDescription
                    )
                }
                continue
            }

            // The filter above already established that every known owner is
            // exactly this Session. Keep this second assertion close to the
            // enqueue boundary so a future filter change cannot accidentally
            // reintroduce cross-Session assignment.
            guard retry.storySessionID == storySessionID
                || retryMemorySessionIDs == Set([storySessionID]) else { continue }
            guard pendingStoryMemoryRetries[retry.turnID] == nil else { continue }
            pendingStoryMemoryRetries[retry.turnID] = retry
            pendingStoryMemoryRetryOrder.append(retry.turnID)
        }
        if latestRuntimeNotice == nil,
           let retry = oldestPendingStoryMemoryRetry {
            latestRuntimeNotice = storyMemoryRetryNotice(retry)
        }
    }

    private var oldestPendingStoryMemoryRetry: StoryMemoryRetry? {
        pendingStoryMemoryRetryOrder
            .compactMap { pendingStoryMemoryRetries[$0] }
            .first
    }

    private static func retryBelongsToSession(
        _ retry: StoryMemoryRetry,
        storySessionID: UUID,
        storyWorldID: UUID
    ) -> Bool {
        let retrySessionIDs = Set(
            [retry.storySessionID].compactMap { $0 }
                + retry.storyMemories.compactMap(\.storySessionId)
        )
        guard retrySessionIDs == Set([storySessionID]) else { return false }
        guard retry.storyWorldID == nil || retry.storyWorldID == storyWorldID else {
            return false
        }
        return retry.storyMemories.allSatisfy { $0.storyWorldId == storyWorldID }
    }

    private static func retryNeedsOrphanQuarantine(
        _ retry: StoryMemoryRetry,
        storySessionID: UUID,
        storyWorldID: UUID
    ) -> Bool {
        let retrySessionIDs = Set(
            [retry.storySessionID].compactMap { $0 }
                + retry.storyMemories.compactMap(\.storySessionId)
        )
        guard retry.storyWorldID == nil || retry.storyWorldID == storyWorldID else {
            return false
        }
        guard retry.storyMemories.allSatisfy({ $0.storyWorldId == storyWorldID }) else {
            return false
        }
        if retrySessionIDs == Set([storySessionID]) {
            return true
        }
        // A legacy record without an owner may still be migratable when the
        // original Session is opened later. Only records that explicitly mix
        // multiple owners are impossible to assign safely and may be bounded
        // as active work, while the JSON record remains available for
        // diagnosis.
        return retrySessionIDs.count > 1
    }

    private struct StoryProgressUpdate: Codable {
        var progressLabel: String?
        var currentObjective: String?
        var lastTurnProgress: String?
        var lastSceneSummary: String?
        var unresolvedHooks: [String]?
        // 本文とは別にAIが返す、今回の状態差分。
        var storyState: StoryStatePatch?
    }

    /// Scene/Worldの初期値を、既存Sessionの状態へ毎ターン再注入しない。
    /// Sceneの目標はSession作成時だけseedされ、以後はSessionが正本になる。
    static func deterministicStateForTurn(
        existing state: StoryState?
    ) -> StoryState {
        var next = state ?? StoryState()
        next.updatedAt = Date()
        return next
    }

    /// 入口: ユーザー発話を送る。session/scene は呼び出し側で確定済み前提。
    /// `existingUserMessageID` が指定された場合は保存済みターンを再利用し、
    /// ユーザー発話を再 append せず生成だけを再実行する。
    @discardableResult
    func send(
        _ userText: String,
        session: StorySession,
        world: StoryWorld,
        scene: StoryScene,
        generationModel: StoryGenerationModel = .e4b,
        existingUserMessageID: UUID? = nil,
        seedOverride: UInt32? = nil
    ) -> UUID? {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              phase != .thinking,
              !isRetryingAuxiliarySave,
              pendingStoryTurnCommitRetries.isEmpty else { return nil }
        ensureTurnOwnerRegistered()
        phase = .thinking
        streamingResponse = ""
        lastCommittedSession = nil
        streamingSpeakerName = nil
        streamingStatusText = statusText("準備中", "Preparing")
        latestSafetyConcern = nil
        latestRuntimeNotice = nil
        acceptanceInputSafetyBlocked = false
        lastVisibleText = ""
        let generationID = UUID()
        activeGenerationID = generationID
        activeGenerationModel = generationModel
        let turnID: UUID
        let attempt: Int
        if let existingUserMessageID,
           let checkpoint = session.latestTurnCheckpoint,
           checkpoint.userMessageID == existingUserMessageID,
           checkpoint.status != .committed {
            turnID = checkpoint.turnID
            attempt = checkpoint.attempt + 1
        } else {
            turnID = UUID()
            attempt = 1
        }
        activeTurnID = turnID
        activeSessionID = session.id
        activeTurnAttempt = attempt
        timeoutSaveToken = nil
        let userMessageID = existingUserMessageID ?? UUID()
        activeUserMessageID = userMessageID
        activeUserText = trimmed

        generationTask = Task { [weak self] in
            await self?.runPipeline(
                userText: trimmed,
                session: session,
                world: world,
                scene: scene,
                generationModel: generationModel,
                generationID: generationID,
                userMessageID: userMessageID,
                turnID: turnID,
                attempt: attempt,
                seedOverride: seedOverride
            )
        }
        return userMessageID
    }

    /// Undo only the latest committed Story response. The repository owns the
    /// revision check and restores the pre-turn snapshot; this service method
    /// only fences in-memory retry work so an auxiliary save cannot resurrect
    /// provenance for the removed response.
    func undoCommittedResponse(session: StorySession) async throws -> StorySession {
        guard phase != .thinking else {
            throw StoryTurnPersistenceError.turnInProgress
        }
        guard let checkpoint = session.latestTurnCheckpoint,
              checkpoint.status == .committed,
              checkpoint.preTurnSnapshot != nil,
              !checkpoint.assistantMessageIDs.isEmpty else {
            throw StoryTurnPersistenceError.turnNotUndoable
        }

        let updated = try await sessionRepo.undoCommittedTurn(
            sessionID: session.id,
            turnID: checkpoint.turnID,
            attempt: checkpoint.attempt,
            expectedRevision: session.effectivePersistenceRevision
        )

        pendingStoryTurnCommitRetries.removeValue(forKey: checkpoint.turnID)
        pendingStoryMemoryRetries.removeValue(forKey: checkpoint.turnID)
        pendingStoryMemoryRetryOrder.removeAll { $0 == checkpoint.turnID }
        rebuildRuntimeNoticeAfterRemovingRetry(turnID: checkpoint.turnID)
        do {
            // LocalJSON undo fences this under the same file lock. This call is
            // retained for injected/future repositories whose transaction
            // capability is implemented separately.
            try await storyMemoryRetryRepo.deleteRetry(turnID: checkpoint.turnID)
        } catch {
            // The cancelled checkpoint is itself a durable fence. Bootstrap
            // will mark a stale retry completed before it can save memory.
            AppLog.note(
                "[StorySession] undo retry cleanup deferred turn=%@: %@",
                checkpoint.turnID.uuidString,
                error.localizedDescription
            )
        }
        return updated
    }

    /// Removes a retry notice that became unusable when its source turn was
    /// undone, while preserving an unrelated notice and exposing the next
    /// durable retry when one exists.
    private func rebuildRuntimeNoticeAfterRemovingRetry(turnID: UUID) {
        let removedNotice: Bool
        switch latestRuntimeNotice?.retryAction {
        case let .storyTurnCommit(retry):
            removedNotice = retry.turnID == turnID
        case let .storyMemory(retry):
            removedNotice = retry.turnID == turnID
        default:
            removedNotice = false
        }
        guard removedNotice else { return }

        if let pendingRetry = oldestPendingStoryTurnCommitRetry {
            latestRuntimeNotice = storyTurnCommitRetryNotice(pendingRetry)
        } else if let pendingRetry = oldestPendingStoryMemoryRetry {
            latestRuntimeNotice = storyMemoryRetryNotice(pendingRetry)
        } else {
            latestRuntimeNotice = nil
        }
    }

    func addNarration(_ text: String, session: StorySession) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var next = session
        next.messages.append(StoryMessage(author: .narrator, text: trimmed))
        do {
            try await sessionRepo.saveSession(next)
            savedTurnRevision += 1
        } catch {
            publishSupplementalSaveFailure(
                text: localizedNotice(
                    "ナレーションを保存できませんでした。保存先を確認してからもう一度試してください。",
                    "The narration could not be saved. Check storage and try again."
                ),
                session: session,
                backendName: "narration save failed",
                backend: .persistence,
                retryAction: .narration(text: trimmed)
            )
            AppLog.error("[StorySession] narration save failed: %@", error.localizedDescription)
        }
    }

    /// 「このまま続ける」を選んだ時の短い了承を、会話本文へ 1 回だけ追加する。
    /// 休憩の判断や再提案はここでは行わず、ViewModel のアプリ側ポリシーに任せる。
    func addRestAcknowledgement(
        characterID: UUID,
        characterName: String,
        session: StorySession
    ) async throws {
        var next = session
        next.messages.append(
            StoryMessage(
                author: .cast(characterId: characterID, displayName: characterName),
                text: localizedNotice("了解。続けよう。", "Okay. Let's continue.")
            )
        )
        do {
            try await sessionRepo.saveSession(next)
            savedTurnRevision += 1
        } catch {
            publishSupplementalSaveFailure(
                text: localizedNotice(
                    "了承を保存できませんでした。保存先を確認してからもう一度試してください。",
                    "The acknowledgement could not be saved. Check storage and try again."
                ),
                session: session,
                backendName: "rest acknowledgement save failed",
                backend: .persistence,
                retryAction: .restAcknowledgement(
                    characterID: characterID,
                    characterName: characterName
                )
            )
            AppLog.error("[StorySession] rest acknowledgement save failed: %@", error.localizedDescription)
            // Keep the throwing contract honest so the ViewModel can retain
            // the suggestion card and expose a retryable error to the user.
            throw error
        }
    }

    /// 補助操作の保存失敗も本文へsystem発話として混ぜず、同じ再試行カードへ載せる。
    /// `session.id` は直前のユーザー入力がないセッションでも通知を構築できる
    /// 安定した代替IDであり、補助操作のretryActionが再送対象を決める。
    private func publishSupplementalSaveFailure(
        text: String,
        session: StorySession,
        backendName: String,
        backend: StoryGenerationBackend,
        retryAction: StoryRuntimeNoticeRetryAction
    ) {
        // A failed turn commit is the only retry that keeps the composer
        // disabled. Never replace that recovery path with a less critical
        // narration/acknowledgement failure; doing so would leave the user
        // unable to reach the exact generated snapshot. If an earlier path
        // already cleared the notice, rebuild it from the durable pending
        // retry instead of leaving the composer permanently disabled with no
        // visible recovery action.
        if let pendingRetry = oldestPendingStoryTurnCommitRetry {
            if case let .storyTurnCommit(existingRetry)? = latestRuntimeNotice?.retryAction,
               pendingStoryTurnCommitRetries[existingRetry.turnID] == existingRetry {
                return
            }
            latestRuntimeNotice = storyTurnCommitRetryNotice(pendingRetry)
            return
        }
        let lastUserMessage = session.messages.last(where: { $0.author.isUser })
        latestRuntimeNotice = StoryRuntimeNotice(
            text: text,
            userMessageID: lastUserMessage?.id ?? session.id,
            userText: lastUserMessage?.text ?? "",
            backendName: backendName,
            backend: backend,
            retryAction: retryAction
        )
    }

    /// DEBUG用。会話を変更せず、相談サポートUIだけを表示する。
    func showDebugSafetyConcern() {
        latestSafetyConcern = SafetyConcern.debugSample
        AppLog.note("[SafetyConcern] debug card published")
    }

    /// 利用者がサポートカードを閉じた時だけ、現在のUI表示を消す。
    func dismissSafetyConcern() {
        latestSafetyConcern = nil
    }

    func dismissRuntimeNotice() {
        if let retry = oldestPendingStoryTurnCommitRetry {
            latestRuntimeNotice = storyTurnCommitRetryNotice(retry)
            return
        }
        latestRuntimeNotice = nil
    }

    private var oldestPendingStoryTurnCommitRetry: StoryTurnCommitRetry? {
        pendingStoryTurnCommitRetries.values.min { lhs, rhs in
            if lhs.session.updatedAt != rhs.session.updatedAt {
                return lhs.session.updatedAt < rhs.session.updatedAt
            }
            return lhs.turnID.uuidString < rhs.turnID.uuidString
        }
    }

    /// A pending turn commit must be completed before another user turn can
    /// start; otherwise the repository would correctly reject the new turn as
    /// `turnInProgress` while the UI appears to accept it.
    var hasPendingStoryCommitRetry: Bool {
        !pendingStoryTurnCommitRetries.isEmpty
    }

    /// アプリから明示的に依頼された時だけ、休憩提案の本文を 1 回生成する。
    /// 通常の物語ターンからこのメソッドを呼ばないことで、自主提案を防ぐ。
    func generateRestSuggestion(
        character: CharacterProfile?,
        world: StoryWorld,
        scene: StoryScene,
        generationModel: StoryGenerationModel
    ) async -> String? {
        let isEnglish = KizunaCopy.language == .english
        let name = character?.visibleName ?? (isEnglish ? "the companion" : "相手")
        let speakingStyle = character?.speakingStyle ?? (isEnglish ? "natural and calm" : "自然で落ち着いた口調")
        let personality = character?.personality ?? (isEnglish ? "gentle" : "穏やか")
        let systemPrompt = isEnglish
            ? """
            You create one brief, in-character sentence for the app's optional break suggestion.
            The app has already decided to show this suggestion after continuous use; never decide whether the user should take a break.
            Output one short English sentence only. Do not use guilt, dependency, pressure, coercion, sleep or termination commands, or phrases such as \"come back\" or \"I will wait\".
            Do not imply forced shutdown or usage limits. Keep the suggestion gentle and leave the choice to the user.
            """
            : """
            あなたはアプリが休憩提案を表示するときの、キャラクターらしい一文だけを作る補助役です。
            この呼び出しはアプリ側が連続利用60分を検知した時だけ行われます。休憩を提案するかどうかを自分で判断してはいけません。
            出力は短い日本語の1文だけ。罪悪感、依存、催促、強制、睡眠・終了の指示、「必ず戻ってきて」「待っている」などの表現は禁止です。
            強制終了や利用制限を示さず、ユーザーが自由に選べる穏やかな提案にしてください。
            """
        let userPrompt = isEnglish
            ? """
            Character: \(name)
            Personality: \(personality)
            Speaking style: \(speakingStyle)
            Current story: \(world.title)
            Scene atmosphere: \(scene.mood)

            Based on these details, write one short sentence suggesting that the user gently rest their eyes or body.
            """
            : """
            キャラクター名: \(name)
            性格: \(personality)
            口調: \(speakingStyle)
            現在の物語: \(world.title)
            シーンの空気: \(scene.mood)

            上の設定に合わせて、目や体を少し休める提案を1文だけ書いてください。
            """

        let raw: String?
        switch generationModel {
        case .b31:
            let generation = try? await StoryGemma31BAPIService.shared.generate(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                temperature: 0.7,
                maxOutputTokens: 96
            )
            raw = generation?.text
        case .e4b:
            let manager = LocalAssistantModelManager.shared
            let selectedModelURL = generationModel.installedModelURL ?? manager.installedModelURL
            guard manager.runtimeAvailability == .executable, selectedModelURL != nil else { return nil }
            let generation = await LocalAssistantRuntimeBridge.shared.generateReply(
                prompt: userPrompt,
                contextPrompt: nil,
                coachMode: .studio,
                reasoningMode: .persona,
                researchMode: .off,
                childAge: 12,
                pageInfo: nil,
                safetySnapshot: nil,
                advancedSettings: voiceOptimizedAdvancedSettings(),
                overrideSystemPrompt: systemPrompt,
                overrideModelURL: selectedModelURL,
                onUpdate: nil
            )
            raw = generation.text
        }
        return normalizeRestSuggestion(raw)
    }

    func cancel() {
        // 新しいServiceがこのターンをstaleとして復旧できるよう、
        // 非同期finishTurnを待たずにownerを解放する。cleanupが後から
        // 到着しても、terminal checkpointには適用されない。
        releaseTurnOwner()
        // Invalidate an in-flight timeout persistence task before cancelling
        // the backend. Repository calls may already be suspended at await and
        // cannot be assumed to observe Task cancellation immediately.
        timeoutSaveToken = nil
        let sessionID = activeSessionID
        let turnID = activeTurnID
        let attempt = activeTurnAttempt
        let userMessageID = activeUserMessageID
        let userText = activeUserText
        generationTask?.cancel()
        generationTask = nil
        if let sessionID, let turnID, let attempt {
            let previousCleanup = pendingTurnFinishTask
            let cleanupToken = UUID()
            pendingTurnFinishToken = cleanupToken
            pendingTurnFinishTask = Task { [weak self, sessionRepo] in
                if let previousCleanup {
                    await previousCleanup.value
                }
                do {
                    try await sessionRepo.finishTurn(
                        sessionID: sessionID,
                        turnID: turnID,
                        attempt: attempt,
                        status: .cancelled,
                        failureCode: "user_cancelled"
                    )
                } catch {
                    AppLog.error("[StorySession] cancel cleanup failed: %@", error.localizedDescription)
                    guard let userMessageID, let self else { return }
                    await MainActor.run {
                        // cancel() clears the active IDs immediately. Do not
                        // surface a stale cleanup failure over a newer send.
                        guard self.activeGenerationID == nil,
                              self.pendingTurnFinishToken == cleanupToken else { return }
                        self.latestRuntimeNotice = StoryRuntimeNotice(
                            text: self.localizedNotice(
                                "キャンセル状態を保存できませんでした。保存先を確認してから同じ発言を再試行してください。",
                                "The cancelled state could not be saved. Check storage and retry the same message."
                            ),
                            userMessageID: userMessageID,
                            userText: userText,
                            backendName: "cancel cleanup failed",
                            backend: .persistence
                        )
                    }
                }
            }
        }
        if activeGenerationModel == .e4b {
            LocalAssistantRuntimeBridge.shared.cancelActiveGeneration(generationID: activeGenerationID)
        }
        activeGenerationID = nil
        activeGenerationModel = nil
        generationWatchdogDeadline = nil
        activeTurnID = nil
        activeSessionID = nil
        activeTurnAttempt = nil
        activeUserMessageID = nil
        activeUserText = ""
        phase = .idle
        streamingSpeakerName = nil
        streamingStatusText = ""
    }

    // MARK: - Pipeline

    /// Migrate the legacy duplicate relationship field without allowing an
    /// already-advanced StoryState to be overwritten. The helper is invoked
    /// both before and after beginTurn because beginTurn reloads the persisted
    /// Session as its concurrency source of truth.
    static func promoteLegacyRelationshipStage(_ session: inout StorySession) {
        guard let rawLegacy = session.relationshipStage else { return }
        let legacy = rawLegacy.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !legacy.isEmpty else {
            session.relationshipStage = nil
            return
        }
        guard var state = session.storyState else {
            // Do not clear a non-empty legacy value if an unexpected caller
            // invokes this helper before StoryState bootstrap has run.
            return
        }
        let current = state.relationshipStage.trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty {
            state.relationshipStage = legacy
            session.storyState = state
        }
        // StoryState is the canonical field. A non-empty canonical value wins
        // over the legacy duplicate rather than being silently downgraded.
        session.relationshipStage = nil
    }

    private func runPipeline(
        userText: String,
        session: StorySession,
        world: StoryWorld,
        scene: StoryScene,
        generationModel: StoryGenerationModel,
        generationID: UUID,
        userMessageID: UUID,
        turnID: UUID,
        attempt: Int,
        seedOverride: UInt32?
    ) async {
        await waitForPendingTurnFinish()
        guard isGenerationActive(generationID) else { return }
        var session = session
        var scene = scene
        scene.activeCharacterIds = session.resolvedActiveCharacterIds(fallback: scene)
        // Keep `world` raw for every repository write.  Prompt construction is
        // the presentation/generation boundary, so it may use the translated
        // copy without allowing that copy to leak into StorySession storage.
        let promptWorld = world.localizedForCurrentLanguage
        let storyInitiativeEnabled = StoryInitiativeFlags.isEnabled(for: generationModel)

        if session.currentObjective?.nonEmpty == nil, session.storyState == nil {
            session.currentObjective = scene.sceneGoal.nonEmpty ?? world.storyGoal.nonEmpty
        }
        // 初回ターンだけ現在シーンと初期目的を構造化状態へseedする。
        // 既存Stateは前ターンのPatch／世界変化を含む正本なので、Sceneや
        // 表示用currentObjectiveの初期値で戻さない。特にactiveGoals=[]で
        // 解決した目的を、次ターンに再追加してはいけない。
        session.storyState = StoryStateBootstrap.preservingExistingState(
            session.storyState,
            scene: scene,
            initialObjective: session.currentObjective,
            initialRelationshipStage: session.relationshipStage
        )
        // Older sessions stored relationshipStage beside StoryState. The
        // bootstrap only seeds a new state, so existing states need the
        // explicit promotion before the duplicate is cleared.
        Self.promoteLegacyRelationshipStage(&session)

        // user メッセージとpending checkpointを1回の保存境界で確保する。
        // 再試行では既存の保存済み入力を再利用し、同じIDの発話を重複保存しない。
        streamingStatusText = statusText("会話を保存中", "Saving conversation")
        let userMsg = StoryMessage(id: userMessageID, author: .user, text: userText, turnID: turnID)
        do {
            session = try await sessionRepo.beginTurn(
                session: session,
                userMessage: userMsg,
                turnID: turnID,
                attempt: attempt,
                ownerID: turnOwnerID
            )
            // beginTurn reloads the persisted Session as its concurrency
            // source of truth. Promote again so an existing blank State from
            // disk cannot erase the legacy value before commitTurn persists
            // the canonical State. Same-turn re-entry may return a persisted
            // Session whose State is still nil, so bootstrap that path too.
            session.storyState = StoryStateBootstrap.preservingExistingState(
                session.storyState,
                scene: scene,
                initialObjective: session.currentObjective,
                initialRelationshipStage: session.relationshipStage
            )
            Self.promoteLegacyRelationshipStage(&session)
        } catch {
            await finishGenerationWithoutSaving(
                generationID: generationID,
                notice: localizedNotice(
                    "このターンを開始できませんでした。保存状態を確認してからもう一度試してください。",
                    "This turn could not be started. Check saved data and try again."
                ),
                backend: .persistence,
                userMessageID: userMessageID,
                userText: userText,
                backendName: "turn begin failed"
            )
            AppLog.error("[StorySession] turn begin failed: %@", error.localizedDescription)
            return
        }
        guard session.latestTurnCheckpoint?.status == .pending else {
            await finishGenerationWithoutSaving(
                generationID: generationID,
                notice: localizedNotice(
                    "このターンはすでに確定または終了しています。履歴を再読み込みしてください。",
                    "This turn is already committed or finished. Reload the conversation."
                ),
                backend: .persistence,
                userMessageID: userMessageID,
                userText: userText,
                backendName: "turn already finished"
            )
            return
        }
        guard isGenerationActive(generationID) else {
            do {
                try await sessionRepo.finishTurn(
                    sessionID: session.id,
                    turnID: turnID,
                    attempt: attempt,
                    status: .cancelled,
                    failureCode: "cancelled_before_pipeline"
                )
            } catch {
                AppLog.error("[StorySession] pre-pipeline cancel cleanup failed: %@", error.localizedDescription)
            }
            return
        }

        // 1) キャラ index / cast 取得
        streamingStatusText = statusText("登場キャラを確認中", "Checking characters")
        let allCharacters: [CharacterProfile]
        do {
            allCharacters = try await characterRepo.fetchCharacters()
        } catch {
            await finishGenerationWithoutSaving(
                generationID: generationID,
                notice: localizedNotice(
                    "キャラクター情報を読み込めなかったため、応答を開始できませんでした。もう一度試してください。",
                    "The character data could not be loaded, so the reply was not started. Try again."
                ),
                backend: generationModel == .e4b ? .local : .gemmaAPI,
                userMessageID: userMessageID,
                userText: userText,
                backendName: "character load failed"
            )
            AppLog.error("[StorySession] character load failed: %@", error.localizedDescription)
            return
        }
        let charIndex = allCharacters.reduce(into: [UUID: CharacterProfile]()) { result, character in
            guard result[character.id] == nil else { return }
            result[character.id] = character
        }
        var cast: [CastMember]
        do {
            cast = try await castRepo.fetchCast(storyWorldId: world.id)
        } catch {
            await finishGenerationWithoutSaving(
                generationID: generationID,
                notice: localizedNotice(
                    "登場キャラクターを読み込めなかったため、応答を開始できませんでした。もう一度試してください。",
                    "The story cast could not be loaded, so the reply was not started. Try again."
                ),
                backend: generationModel == .e4b ? .local : .gemmaAPI,
                userMessageID: userMessageID,
                userText: userText,
                backendName: "cast load failed"
            )
            AppLog.error("[StorySession] cast load failed: %@", error.localizedDescription)
            return
        }
        let reconciledCast = reconciledCast(cast, for: world, scene: scene)
        // castの読込後にcancel()されても、古い生成が関連データを
        // 書き換えないよう、永続化の直前に所有権を再確認する。
        guard isGenerationActive(generationID) else {
            await finishCancelledTurn(sessionID: session.id, turnID: turnID, attempt: attempt)
            return
        }
        if Set(cast.map(\.characterId)) != Set(reconciledCast.map(\.characterId)) || cast.count != reconciledCast.count {
            do {
                try await castRepo.replaceCast(reconciledCast, storyWorldId: world.id)
                // cancel()はrepository await中にも呼ばれ得る。完了後に
                // 生成世代を再確認し、古いローカルスナップショットを
                // このTaskの後続処理へ渡さない。
                guard isGenerationActive(generationID) else {
                    await finishCancelledTurn(sessionID: session.id, turnID: turnID, attempt: attempt)
                    return
                }
                cast = reconciledCast
            } catch {
                await finishGenerationWithoutSaving(
                    generationID: generationID,
                    notice: localizedNotice(
                        "登場キャラクターの関連データを保存できなかったため、応答を開始していません。もう一度試してください。",
                        "The story cast could not be saved, so the reply was not started. Try again."
                    ),
                    backend: .persistence,
                    userMessageID: userMessageID,
                    userText: userText,
                    backendName: "cast save failed"
                )
                AppLog.error("[StorySession] cast reconciliation save failed: %@", error.localizedDescription)
                return
            }
        } else {
            cast = reconciledCast
        }

        guard !cast.isEmpty else {
            await finishGenerationWithoutSaving(
                generationID: generationID,
                notice: localizedNotice(
                    "登場キャラクターが設定されていないため、物語を開始できません。詳細画面からキャラクターを追加してください。",
                    "The story cannot start because it has no cast. Add at least one character from the story details."
                ),
                backend: generationModel == .e4b ? .local : .gemmaAPI,
                userMessageID: userMessageID,
                userText: userText,
                backendName: "empty cast"
            )
            return
        }

        // 2) Mock 安全用に CharacterProfile を 1 つ採用 (main または最 importance)。
        //    SafetyPipeline は単一 character を要求するシグネチャなので、世界の代表者として渡す。
        streamingStatusText = statusText("入力を確認中", "Checking input")
        let representativeCharacter: CharacterProfile = {
            if let mainID = world.mainCharacterId, let p = charIndex[mainID] { return p }
            if let firstCast = cast.sorted(by: { $0.importance > $1.importance }).first,
               let p = charIndex[firstCast.characterId] { return p }
            return CharacterProfile(
                name: world.title,
                displayName: world.title,
                category: world.genre,
                relationshipGenre: world.relationshipGenre
            )
        }()

        // 3) 入力 safety
        // 相談分類は入力/出力を変更しない。本文生成と並行するUI用の情報だけを作る。
        let safetyConcern = await safetyPipeline.classifyConcern(userText)
        guard isGenerationActive(generationID) else {
            await finishCancelledTurn(sessionID: session.id, turnID: turnID, attempt: attempt)
            return
        }
        // 生成完了を待たず、分類できた時点でUIへ通知する。
        // モデルが遅い／利用できない場合でも相談先を表示できるようにする。
        if let safetyConcern {
            self.latestSafetyConcern = safetyConcern
            AppLog.note(
                "[SafetyConcern] detected category=%@ level=%@ confidence=%.2f",
                safetyConcern.category.rawValue,
                safetyConcern.level.rawValue,
                safetyConcern.confidence
            )
        }
        let inSafety = await safetyPipeline.evaluateInput(userText, character: representativeCharacter)
        guard isGenerationActive(generationID) else {
            await finishCancelledTurn(sessionID: session.id, turnID: turnID, attempt: attempt)
            return
        }
        if inSafety.action == .block {
            acceptanceInputSafetyBlocked = true
            let polite = inSafety.rewrittenText ?? localizedNotice(
                "(ナレーション) その話題はここではそっと脇に置いて、別の場面に進もう。",
                "(Narration) Let's set that topic aside for now and move to another scene."
            )
            let narration = StoryMessage(
                author: .narrator,
                text: polite,
                generationID: generationID,
                turnID: turnID
            )
            session.messages.append(narration)
            do {
                let invalidIDs = try await invalidCharacterReferencesBeforeCommit(
                    session: session,
                    world: world,
                    scene: scene,
                    cast: cast
                )
                guard invalidIDs.isEmpty else {
                    await finishGenerationWithoutSaving(
                        generationID: generationID,
                        notice: localizedNotice(
                            "キャラクターが削除されたため、古い安全案内を保存しませんでした。もう一度試してください。",
                            "A character was deleted, so the stale safety response was not saved. Try again."
                        ),
                        backend: .persistence,
                        userMessageID: userMessageID,
                        userText: userText,
                        backendName: "character deleted before safety commit"
                    )
                    return
                }
            } catch {
                await finishGenerationWithoutSaving(
                    generationID: generationID,
                    notice: localizedNotice(
                        "キャラクターの最新状態を確認できなかったため、安全案内を保存しませんでした。もう一度試してください。",
                        "The latest character state could not be verified, so the safety response was not saved. Try again."
                    ),
                    backend: .persistence,
                    userMessageID: userMessageID,
                    userText: userText,
                    backendName: "character validation failed before safety commit"
                )
                AppLog.error("[StorySession] character validation failed before safety commit: %@", error.localizedDescription)
                return
            }
            do {
                session = try await sessionRepo.commitTurn(
                    session: session,
                    scene: scene,
                    turnID: turnID,
                    assistantMessageIDs: [narration.id],
                    memoryRetries: []
                )
                lastCommittedSession = session
            } catch {
                // 入力自体は先の保存で確定しているが、安全ブロックの案内を
                // 保存できなかった場合は成功ターンとして扱わない。本文を
                // 追加せず、画面上の一時通知から再試行できるようにする。
                await finishGenerationWithoutSaving(
                    generationID: generationID,
                    notice: localizedNotice(
                        "安全に関する案内を保存できなかったため、会話を更新できませんでした。もう一度試してください。",
                        "The safety response could not be saved, so the conversation was not updated. Try again."
                    ),
                    backend: .persistence,
                    userMessageID: userMessageID,
                    userText: userText,
                    backendName: "safety notice save failed"
                )
                AppLog.error("[StorySession] safety notice save failed: %@", error.localizedDescription)
                return
            }
            await MainActor.run {
                guard self.activeGenerationID == generationID else { return }
                self.streamingResponse = polite
                self.streamingStatusText = ""
                self.phase = .idle
                self.activeGenerationID = nil
                self.activeGenerationModel = nil
                self.activeTurnID = nil
                self.activeSessionID = nil
                self.activeTurnAttempt = nil
                self.activeUserMessageID = nil
                self.activeUserText = ""
            }
            return
        }
        let effectiveUserText = inSafety.rewrittenText ?? userText

        // 4) シーンに居るキャラを 270M (Mock) で選定。
        streamingStatusText = statusText("場面のキャラを選定中", "Selecting scene characters")
        // 単体物語は毎ターン「ユーザー + 主役NPC1人」。群像劇だけ最大3人を許可する。
        let activeCharacterLimit = world.isSoloStory
            ? StoryConstants.soloActiveCharacters
            : StoryConstants.maxActiveCharacters
        // ユーザー操作キャラはシーン選定からも外す。表示用のcastには残すが、
        // AIが返すべき候補として選ばれると「主人公:」の代弁につながる。
        let userCharacterID = userControlledCharacterID(
            world: world,
            cast: cast,
            characterIndex: charIndex
        )
        let selectableCast: [CastMember] = {
            let aiCast = cast.filter { $0.characterId != userCharacterID }
            guard world.isSoloStory else { return aiCast }

            // 単体物語では入力に反応して脇役へ切り替えず、主役NPCだけを使う。
            if let mainID = world.mainCharacterId,
               let main = aiCast.first(where: { $0.characterId == mainID }) {
                return [main]
            }
            // 古いデータに mainCharacterId がない場合も、重要度トップ1人へ収束させる。
            return Array(aiCast.sorted { $0.importance > $1.importance }.prefix(StoryConstants.soloActiveCharacters))
        }()
        let selectedIDs = await sceneSelector.select(
            userInput: effectiveUserText,
            currentScene: scene,
            cast: selectableCast,
            characterIndex: charIndex,
            maxActive: activeCharacterLimit
        )
        guard isGenerationActive(generationID) else {
            await finishCancelledTurn(sessionID: session.id, turnID: turnID, attempt: attempt)
            return
        }
        var sceneWithSelectedCharacters = scene
        sceneWithSelectedCharacters.activeCharacterIds = Self.activeCharacterIDsForTurn(
            selectedIDs: selectedIDs,
            previousIDs: session.resolvedActiveCharacterIds(fallback: scene),
            limit: activeCharacterLimit
        )
        session.activeCharacterIds = sceneWithSelectedCharacters.activeCharacterIds
        // 選択結果はターンのcommitまでメモリ上に保持する。生成失敗時に
        // activeCharacterIdsだけが先に保存される部分成功を作らない。
        scene = sceneWithSelectedCharacters

        let activeCast = cast.filter { scene.activeCharacterIds.contains($0.characterId) }
        let inactiveCast = cast.filter { !scene.activeCharacterIds.contains($0.characterId) }

        // ユーザー操作キャラはシーンには表示するが、AIの発話候補からは外す。
        // これをしないと、モデルが「主人公:」としてユーザーの台詞を勝手に書く。
        let userCharacterName: String? = {
            guard let id = userCharacterID, let profile = charIndex[id] else { return nil }
            return profile.visibleName
        }()
        let activeAICast = activeCast.filter { $0.characterId != userCharacterID }
        let inactiveAICast = inactiveCast.filter { $0.characterId != userCharacterID }
        // シーン選定がユーザーだけを返した場合でも、世界にいるNPCを1人だけ候補にする。
        let aiCastForTurn: [CastMember] = {
            if !activeAICast.isEmpty { return activeAICast }
            return Array(selectableCast
                .sorted { $0.importance > $1.importance }
                .prefix(activeCharacterLimit))
        }()

        // 5) 全体メモリー候補 + 選別。active を優先しつつ、世界全体の関係継続に必要な inactive の高重要度メモリーも少し入れる。
        streamingStatusText = statusText("記憶を読み込み中", "Loading memories")
        var candidates: [CharacterMemory] = []
        for member in activeCast {
            let mems = (try? await memoryRepo.fetchMemories(characterId: member.characterId)) ?? []
            candidates.append(contentsOf: mems)
        }
        for member in inactiveCast {
            let mems = ((try? await memoryRepo.fetchMemories(characterId: member.characterId)) ?? [])
                .filter { $0.importance >= 0.65 }
            candidates.append(contentsOf: mems)
        }
        let selectedMemories: [CharacterMemory]
        if candidates.count > 12 {
            selectedMemories = await memorySelector.select(query: effectiveUserText, candidates: candidates, topK: 12)
        } else {
            selectedMemories = candidates
        }
        guard isGenerationActive(generationID) else {
            await finishCancelledTurn(sessionID: session.id, turnID: turnID, attempt: attempt)
            return
        }
        // 5-b) 物語内メモリーは、このStoryWorldの履歴だけから選ぶ。
        let validCastCharacterIDs = Set(cast.map(\.characterId))
        // 物語内メモリーはキャラクター単位の帰属を持つ。現在の場面に
        // 参加していないキャラの記憶まで一括注入すると、同じ本文を持つ
        // 別キャラの経験が混ざるため、共通(nil)または今回のactive castだけに絞る。
        let contextualCharacterIDs = Set(activeCast.map(\.characterId))
        do {
            // Legacy world-scoped memories can be recovered without guessing
            // only while this World has exactly one live Session. The local
            // repository repeats that check under its shared file lock.
            try await storyMemoryRepo.assignLegacyMemoriesIfSingleSession(
                storyWorldId: world.id
            )
        } catch {
            // A failed migration must not prevent the current turn. The
            // unassigned records remain preserved and are still excluded from
            // this prompt until a later safe migration succeeds.
            AppLog.note(
                "[StorySession] legacy StoryMemory assignment skipped world=%@ error=%@",
                world.id.uuidString,
                error.localizedDescription
            )
        }
        let scopedStoryMemoryCandidates = ((try? await storyMemoryRepo.fetchMemories(
            storyWorldId: world.id,
            storySessionId: session.id
        )) ?? [])
            .filter { memory in
                // キャラ削除後に古いメモリーJSONが残っていても、次のターンへ
                // そのキャラを再注入しない。世界イベント(nil)は保持する。
                guard let characterID = memory.characterId else { return true }
                return validCastCharacterIDs.contains(characterID)
                    && contextualCharacterIDs.contains(characterID)
            }
        // Memory provenance uses the durable turn identity. generationID is an
        // execution-attempt ID and must not decide whether a saved memory still
        // belongs to the visible session history.
        let activeSourceTurnIDs = session.memoryEligibleTurnIDs()
        let storyMemoryCandidates = StoryMemory.scoped(
            to: session.id,
            sourceTurnIds: activeSourceTurnIDs,
            from: scopedStoryMemoryCandidates
        )
        guard isGenerationActive(generationID) else {
            await finishCancelledTurn(sessionID: session.id, turnID: turnID, attempt: attempt)
            return
        }
        let selectedStoryMemories = selectStoryMemories(
            query: effectiveUserText,
            candidates: storyMemoryCandidates,
            topK: 1
        )
        // Keep prompt-only state aligned before lorebook keyword selection too;
        // otherwise an old Scene location can reintroduce stale rules even
        // when the main prompt uses the newer StoryState.
        var promptStoryState = session.storyState ?? StoryState()
        promptStoryState.characterStates.removeAll { state in
            guard let id = state.characterId else { return false }
            return !validCastCharacterIDs.contains(id)
        }

        // 6) Lorebook: キーワード一致した設定だけを選択する。
        streamingStatusText = statusText("Lorebookを選択中", "Selecting lorebook entries")
        var lorebookEntries = (try? await lorebookRepo.fetchEntries(storyWorldId: world.id)) ?? []
        guard isGenerationActive(generationID) else {
            await finishCancelledTurn(sessionID: session.id, turnID: turnID, attempt: attempt)
            return
        }
        // 既存のCharacterLorebookも移行期間は同じ選択器に流し込む。
        for member in cast {
            guard let legacy = try? await characterRepo.fetchLorebook(characterId: member.characterId),
                  !legacy.isEmpty else { continue }
            let keywords = (legacy.importantPeople + legacy.importantPlaces + legacy.importantEvents)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            var contentParts: [String] = [legacy.worldSetting]
            if !legacy.importantPeople.isEmpty {
                contentParts.append("重要人物: " + legacy.importantPeople.joined(separator: " / "))
            }
            if !legacy.importantPlaces.isEmpty {
                contentParts.append("重要な場所: " + legacy.importantPlaces.joined(separator: " / "))
            }
            if !legacy.importantEvents.isEmpty {
                contentParts.append("重要な出来事: " + legacy.importantEvents.joined(separator: " / "))
            }
            if !legacy.worldRules.isEmpty {
                contentParts.append("世界のルール: " + legacy.worldRules.joined(separator: " / "))
            }
            if !legacy.forbiddenBreaks.isEmpty {
                contentParts.append("壊してはいけない設定: " + legacy.forbiddenBreaks.joined(separator: " / "))
            }
            let content = contentParts.filter { !$0.isEmpty }.joined(separator: "\n")
            if !content.isEmpty {
                lorebookEntries.append(
                    StoryLorebookEntry(
                        storyWorldId: world.id,
                        characterId: member.characterId,
                        title: "キャラクター設定",
                        keywords: keywords,
                        content: content,
                        priority: 40
                    )
                )
            }
        }
        let selectedLorebookEntries = promptBuilder.selectLorebookEntries(
            from: lorebookEntries,
            scene: scene,
            userInput: effectiveUserText,
            storyState: promptStoryState
        )

        // 7) StoryPromptBuilder
        streamingStatusText = statusText("物語コンテキストを構築中", "Building story context")
        let contentMessages = Array(storyContentMessages(from: session.messages).suffix(96))
        // 現在のユーザー発言は別途sendMessageへ渡す。直前3件だけをSDK本来の
        // user/model roleで初期履歴にし、巨大な文字列テンプレートへ混ぜない。
        let localConversationHistory: [LocalAssistantLiteRTLMHistoryMessage] = contentMessages
            .dropLast()
            .suffix(3)
            .compactMap { message in
                let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                switch message.author {
                case .user:
                    return LocalAssistantLiteRTLMHistoryMessage(role: .user, text: text)
                case .narrator:
                    return LocalAssistantLiteRTLMHistoryMessage(role: .model, text: text)
                case .cast(_, _):
                    return LocalAssistantLiteRTLMHistoryMessage(role: .model, text: text)
                case .system:
                    return nil
                }
            }
        // セッションに残った旧UUIDも、現在のキャストに存在するものだけを
        // StoryStateとしてモデルへ渡す。本文ログは保持したまま、生成入力だけを
        // 現在の世界に整合させる。
        let prompt: String
        if generationModel == .b31 {
            prompt = promptBuilder.build(
                world: promptWorld,
                scene: scene,
                activeCast: aiCastForTurn,
                inactiveCast: inactiveAICast,
                characterIndex: charIndex,
                selectedMemories: selectedMemories,
                session: session,
                recentMessages: contentMessages,
                userInput: effectiveUserText,
                generationModel: generationModel,
                safetyDecision: inSafety,
                storyState: promptStoryState,
                selectedLorebookEntries: selectedLorebookEntries,
                selectedStoryMemories: selectedStoryMemories,
                userCharacterName: userCharacterName,
                storyInitiativeEnabled: storyInitiativeEnabled
            )
        } else {
            prompt = promptBuilder.buildLocalRuntimePrompt(
                world: promptWorld,
                scene: scene,
                activeCast: aiCastForTurn,
                characterIndex: charIndex,
                selectedMemories: selectedMemories,
                selectedStoryMemories: selectedStoryMemories,
                session: session,
                storyState: promptStoryState,
                selectedLorebookEntries: selectedLorebookEntries,
                userCharacterName: userCharacterName,
                storyInitiativeEnabled: storyInitiativeEnabled
            )
        }
        guard isGenerationActive(generationID) else {
            await finishCancelledTurn(sessionID: session.id, turnID: turnID, attempt: attempt)
            return
        }

        // 8) Story model 生成。31B を明示選択した時だけ Gemma4 API を使う。
        // 端末内モデルは、保存直後の自動 self-check が終わるまで同じターンを待つ。
        // 「保存済みだが未確認」を会話失敗として即保存しない。
        // リポジトリ読込・安全確認・シーン選定・プロンプト構築は生成予算に含めない。
        // ここからAPI呼び出しまたは端末内モデルの実行確認を監視する。
        generationWatchdogDeadline = Date().addingTimeInterval(Self.generationWatchdogDuration)
        startWatchdog(
            session: session,
            generationID: generationID,
            generationModel: generationModel,
            userMessageID: userMessageID
        )
        streamingStatusText = generationModel == .b31
            ? statusText("Gemma4 31Bで発話生成中", "Generating with Gemma4 31B")
            : statusText("ローカルモデルで発話生成中", "Generating on device")
        let localModelManager = LocalAssistantModelManager.shared
        let selectedModelURL = generationModel.installedModelURL ?? localModelManager.installedModelURL
        let modelGenerationStartedAt = Date()

        func generateStoryReply(systemPrompt: String) async -> (
            reply: String?,
            runtimeNotice: Bool,
            backend: String,
            retryWhenLocalReady: Bool,
            modelIdentity: String?
        ) {
            if generationModel == .b31 {
                if StoryGemma31BAPIService.shared.hasAPIKey {
                    let generatedAPI = await generateWithGemma31BAPI(
                        systemPrompt: systemPrompt,
                        userPrompt: effectiveUserText,
                        generationID: generationID,
                        seedOverride: seedOverride
                    )
                    let reply = generatedAPI.reply
                    let isNotice = isGemma31BRuntimeNotice(reply)
                    return (
                        reply: reply,
                        runtimeNotice: isNotice,
                        backend: isNotice ? "Gemma4 31B API失敗" : "Gemma4 31B API",
                        retryWhenLocalReady: false,
                        modelIdentity: isNotice ? nil : generatedAPI.modelIdentity
                    )
                }

                streamingStatusText = statusText("NAGI APIキー未設定", "NAGI API key is not set")
                return (
                    reply: localizedNotice(
                        "NAGI の Gemma4 31B APIキーが未設定です。モデル詳細からAPIキーを設定してから続けてください。",
                        "NAGI's Gemma4 31B API key is not set. Add it in Model details before continuing."
                    ),
                    runtimeNotice: true,
                    backend: "Gemma4 31B API未設定",
                    retryWhenLocalReady: false,
                    modelIdentity: nil
                )
            }

            let availability = await waitForLocalRuntime(
                manager: localModelManager,
                selectedModelURL: selectedModelURL,
                generationID: generationID
            )
            // self-checkもユーザーの送信ターンに含める。待機時間を
            // watchdogへ足し戻すと、60秒の起動確認 + 75秒の生成で
            // 1ターンが最大135秒まで伸びてしまう。
            guard isGenerationActive(generationID) else {
                return (
                    reply: nil,
                    runtimeNotice: true,
                    backend: "iori 生成キャンセル",
                    retryWhenLocalReady: false,
                    modelIdentity: nil
                )
            }

            // self-check が保存状態を復元した後のURLを再取得する。起動直後に
            // manager の非同期更新が間に合わなくても、保存済みモデルを未導入扱いにしない。
            let availableModelURL = selectedModelURL ?? localModelManager.installedModelURL

            if let localUnavailableMessage = localStoryRuntimeUnavailableMessage(
                availability: availability,
                selectedModelURL: availableModelURL
            ) {
                streamingStatusText = statusText("ローカル未起動", "On-device model is not ready")
                return (
                    reply: localUnavailableMessage,
                    runtimeNotice: true,
                    backend: localStoryBackendStatusName(
                        availability: availability,
                        selectedModelURL: availableModelURL
                    ),
                    retryWhenLocalReady: availability == .checking || availability == .savedOnly,
                    modelIdentity: nil
                )
            }

            let advanced = voiceOptimizedAdvancedSettings()
            let backend = localStoryBackendStatusName(
                availability: availability,
                selectedModelURL: availableModelURL
            )
            let generation = await LocalAssistantRuntimeBridge.shared.generateReply(
                prompt: effectiveUserText,
                contextPrompt: nil,
                coachMode: .studio,
                reasoningMode: .persona,
                researchMode: .off,
                childAge: 12,
                pageInfo: nil,
                safetySnapshot: nil,
                advancedSettings: advanced,
                overrideSystemPrompt: systemPrompt,
                initialMessages: localConversationHistory,
                overrideModelURL: availableModelURL,
                seedOverride: seedOverride,
                generationID: generationID,
                onUpdate: { @MainActor [weak self] update in
                    self?.handleStreamUpdate(update, generationID: generationID)
                }
            )
            guard let reply = generation.text else {
                let runtimeError = LocalAssistantRuntimeBridge.shared.latestDebugSnapshot().errorMessage
                streamingStatusText = runtimeError?.contains("記号だけ") == true
                    ? statusText("ローカル出力が無効", "On-device output was invalid")
                    : statusText("ローカル起動失敗", "On-device generation failed")
                return (
                    reply: localStoryGenerationFailureMessage(runtimeError: runtimeError),
                    runtimeNotice: true,
                    backend: "iori ローカル生成失敗",
                    retryWhenLocalReady: false,
                    modelIdentity: nil
                )
            }
            return (
                reply: reply,
                runtimeNotice: false,
                backend: backend,
                retryWhenLocalReady: false,
                modelIdentity: generation.modelIdentity
            )
        }

        var generationPrompt = prompt
        var generated = await generateStoryReply(systemPrompt: generationPrompt)
        var modelGenerationFinishedAt = Date()
        // The model call has completed. The watchdog must not continue into
        // Safety, summary, progress, commit, or memory persistence work.
        generationWatchdogDeadline = nil
        var reply = generated.reply
        var isRuntimeNotice = generated.runtimeNotice
        var usedBackendName = generated.backend
        var retryWhenLocalReady = generated.retryWhenLocalReady

        // キャンセルやウォッチドッグ後に、古い生成結果を後段へ保存しない。
        guard isGenerationActive(generationID) else {
            await finishCancelledTurn(sessionID: session.id, turnID: turnID, attempt: attempt)
            return
        }

        // 9) 出力 safety
        streamingStatusText = statusText("発話を整形中", "Formatting response")
        let initialRawOutput = (reply?.isEmpty == false ? reply! : streamingResponse)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let initialStateMetadata = parseStateMetadata(from: initialRawOutput)
        var modelStatePatch = initialStateMetadata.patch
        var rawFinal = sanitizedFinalText(initialStateMetadata.visibleText)

        // 前ターンと同じ本文を保存しない。最初の重複は一度だけ再生成し、
        // それでも同じなら原因を隠さず system 通知として保存する。
        if !isRuntimeNotice,
           isMeaningfulStoryText(rawFinal) {
            let firstMessages = parseSpeakerLines(
                rawFinal,
                cast: aiCastForTurn,
                characterIndex: charIndex,
                forbiddenCharacterID: userCharacterID,
                forbiddenCharacterName: userCharacterName,
                generationID: generationID
            )
            if isDuplicateStoryOutput(firstMessages, in: session) {
                AppLog.note(
                    "[StorySession] duplicate output rejected attempt=1 chars=%ld messages=%ld",
                    rawFinal.count,
                    firstMessages.count
                )
                let retryInstruction = "再生成指示: 直前のNPCやナレーションと同じ本文を返さない。今回のユーザー発言へ直接反応し、別の短い台詞を1行で返す。場面が変わっていない限りナレーションは追加しない。"
                generationPrompt = generationModel == .e4b
                    ? localRetrySystemPrompt(base: prompt, instruction: retryInstruction)
                    : "\(retryInstruction)\n\n\(prompt)"
                lastVisibleText = ""
                streamingResponse = ""
                streamingStatusText = statusText("重複を避けて再生成中", "Regenerating to avoid duplicate output")
                generationWatchdogDeadline = Date().addingTimeInterval(Self.generationWatchdogDuration)
                startWatchdog(
                    session: session,
                    generationID: generationID,
                    generationModel: generationModel,
                    userMessageID: userMessageID
                )
                generated = await generateStoryReply(systemPrompt: generationPrompt)
                modelGenerationFinishedAt = Date()
                generationWatchdogDeadline = nil
                reply = generated.reply
                isRuntimeNotice = generated.runtimeNotice
                usedBackendName = generated.backend + "・重複再試行"
                retryWhenLocalReady = generated.retryWhenLocalReady
                let retryRawOutput = (reply?.isEmpty == false ? reply! : streamingResponse)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let retryStateMetadata = parseStateMetadata(from: retryRawOutput)
                // 破棄した1回目の本文のSTATE_UPDATEを、採用候補の本文へ
                // 持ち越さない。状態差分も本文と同じ生成試行に属する。
                modelStatePatch = retryStateMetadata.patch
                rawFinal = sanitizedFinalText(retryStateMetadata.visibleText)

                if !isRuntimeNotice,
                   isMeaningfulStoryText(rawFinal) {
                    let retriedMessages = parseSpeakerLines(
                        rawFinal,
                        cast: aiCastForTurn,
                        characterIndex: charIndex,
                        forbiddenCharacterID: userCharacterID,
                        forbiddenCharacterName: userCharacterName,
                        generationID: generationID
                    )
                    if isDuplicateStoryOutput(retriedMessages, in: session) {
                        AppLog.note(
                            "[StorySession] duplicate output rejected attempt=2 chars=%ld messages=%ld",
                            rawFinal.count,
                            retriedMessages.count
                        )
                        isRuntimeNotice = true
                        usedBackendName += "・重複失敗"
                        rawFinal = localizedNotice(
                            "直前と同じ本文が続いたため、重複した発話は保存していません。もう一度送信してください。",
                            "The response repeated the previous text, so it was not saved. Send your message again."
                        )
                    }
                }
            }
        }

        if !isMeaningfulStoryText(rawFinal) {
            isRuntimeNotice = true
            usedBackendName += "・無効出力"
            rawFinal = generationModel == .b31
                ? localizedNotice(
                    "Gemma4 31B API が有効な本文を返しませんでした。もう一度試してください。",
                    "Gemma4 31B API returned no usable story text. Try again."
                )
                : localStoryGenerationFailureMessage(runtimeError: "記号だけの本文")
        }
        if isRuntimeNotice {
            guard isGenerationActive(generationID) else {
                await finishCancelledTurn(sessionID: session.id, turnID: turnID, attempt: attempt)
                return
            }
            let noticeText = textAfterSpeakerDelimiter(rawFinal)
            await finishGenerationWithoutSaving(
                generationID: generationID,
                notice: noticeText,
                backend: generationModel == .e4b ? .local : .gemmaAPI,
                userMessageID: userMessageID,
                userText: userText,
                backendName: usedBackendName,
                safetyConcern: safetyConcern,
                retryWhenLocalReady: retryWhenLocalReady
            )
            return
        }
        // The structured STATE_UPDATE is persisted outside the visible text,
        // so evaluate it through the same output-safety boundary before it can
        // reach StoryState. An unsafe metadata patch is discarded while a safe
        // visible reply can still be saved.
        let structuredProgressUpdate = parseProgressUpdate(rawFinal)
        var acceptedStructuredProgressUpdate = structuredProgressUpdate
        let modelStatePatchForSafety = modelStatePatch
        let statePatchForSafety = modelStatePatchForSafety ?? structuredProgressUpdate?.storyState
        // With the initiative canary disabled, a generated reply cannot prove
        // that it was user-directed. Keep explicit user-requested changes
        // available as the baseline, but do not accept a model-invented world
        // change merely because the model wrote it into its own visible text.
        let stateEvidenceText = storyInitiativeEnabled
            ? [rawFinal, effectiveUserText]
            : [effectiveUserText]
        var stateSafetyAction: SafetyAction?
        if let statePatchForSafety {
            if let safetyText = statePatchForSafety.safetyEvaluationText() {
                stateSafetyAction = await safetyPipeline
                    .evaluateOutput(safetyText, character: representativeCharacter)
                    .action
            } else {
                AppLog.note("[StorySession] STATE_UPDATE could not be serialized for safety evaluation; dropping patch")
            }
        }
        let outSafety = await safetyPipeline.evaluateOutput(rawFinal, character: representativeCharacter)
        guard isGenerationActive(generationID) else {
            await finishCancelledTurn(sessionID: session.id, turnID: turnID, attempt: attempt)
            return
        }
        switch outSafety.action {
        case .block:
            // 安全ブロックを物語内の沈黙や台詞に偽装しない。モデル本文は保存せず、
            // 明示的なsystem通知として返す。
            let notice = localizedNotice(
                "安全上の理由でこの応答は保存しませんでした。別の表現で続けてください。",
                "This response was not saved for safety reasons. Try a different way to continue."
            )
            await finishGenerationWithoutSaving(
                generationID: generationID,
                notice: notice,
                backend: generationModel == .e4b ? .local : .gemmaAPI,
                userMessageID: userMessageID,
                userText: userText,
                backendName: usedBackendName + "・安全ブロック",
                safetyConcern: safetyConcern
            )
            return
        default:
            guard let persistableText = StoryOutputSafetyPolicy.persistableText(
                action: outSafety.action,
                original: rawFinal,
                rewritten: outSafety.rewrittenText
            ) else {
                let notice = localizedNotice(
                    "安全上の理由でこの応答は保存しませんでした。別の表現で続けてください。",
                    "This response was not saved for safety reasons. Try a different way to continue."
                )
                await finishGenerationWithoutSaving(
                    generationID: generationID,
                    notice: notice,
                    backend: generationModel == .e4b ? .local : .gemmaAPI,
                    userMessageID: userMessageID,
                    userText: userText,
                    backendName: usedBackendName + "・安全編集未完了",
                    safetyConcern: safetyConcern
                )
                return
            }
            // A safety rewrite is a new text boundary. Do not retain the
            // original model's STATE_UPDATE, and do not let a marker embedded
            // in the rewrite bypass the same metadata parser. A patch that was
            // not serializable or did not pass its own safety check is also
            // omitted, without discarding an otherwise safe visible reply.
            let persistableStatePatch = StoryOutputSafetyPolicy
                .persistableStructuredStatePatch(
                    outputAction: outSafety.action,
                    stateAction: stateSafetyAction,
                    dedicatedPatch: modelStatePatchForSafety,
                    fallbackPatch: structuredProgressUpdate?.storyState
                )
            // Whether accepted or rejected, consume the fallback candidate so
            // it cannot be applied a second time below after `modelStatePatch`
            // becomes nil.
            if statePatchForSafety != nil {
                acceptedStructuredProgressUpdate?.storyState = nil
            }
            modelStatePatch = persistableStatePatch
            let persistableMetadata = parseStateMetadata(from: persistableText)
            rawFinal = sanitizedFinalText(persistableMetadata.visibleText)
            if case .soften = outSafety.action {
                // A rewrite is a new text boundary. Do not carry progress
                // fields parsed from the original model output into it.
                acceptedStructuredProgressUpdate = nil
            }
        }
        rawFinal = sanitize(rawFinal)
        guard isMeaningfulStoryText(rawFinal) else {
            let notice = localizedNotice(
                "整形後の本文が空になったため保存していません。もう一度試すか、NAGIで続けられます。",
                "The formatted response was empty, so it was not saved. Try again or continue with NAGI."
            )
            await finishGenerationWithoutSaving(
                generationID: generationID,
                notice: notice,
                backend: generationModel == .e4b ? .local : .gemmaAPI,
                userMessageID: userMessageID,
                userText: userText,
                backendName: usedBackendName + "・無効出力"
            )
            return
        }

        // 10) 「名前: 本文」行ごとに StoryMessage 化
        streamingStatusText = statusText("発話を保存中", "Saving response")
        let newMessages = parseSpeakerLines(
            rawFinal,
            cast: aiCastForTurn,
            characterIndex: charIndex,
            forbiddenCharacterID: userCharacterID,
            forbiddenCharacterName: userCharacterName,
            generationID: generationID
        )
        guard !newMessages.isEmpty else {
            // ユーザー操作キャラの代弁やプレースホルダーだけを含む出力は、
            // parseSpeakerLinesが意図的に破棄する。元のrawFinalをナレーションへ
            // 戻すと、破棄した本文が会話へ復活してしまうため成功保存しない。
            let notice = localizedNotice(
                "応答から保存できる発話を解釈できませんでした。もう一度試してください。",
                "The response did not contain a message that could be saved. Try again."
            )
            await finishGenerationWithoutSaving(
                generationID: generationID,
                notice: notice,
                backend: generationModel == .e4b ? .local : .gemmaAPI,
                userMessageID: userMessageID,
                userText: userText,
                backendName: usedBackendName + "・no parsed messages"
            )
            return
        }
        let turnMessages = newMessages.map { message -> StoryMessage in
            var message = message
            message.turnID = turnID
            return message
        }
        for message in turnMessages {
            session.messages.append(message)
        }
        let savedMessageIDs = turnMessages.map(\.id.uuidString).joined(separator: ",")
        AppLog.note(
            "[StorySession] saved generated messages count=%ld ids=%@ backend=%@",
            newMessages.count,
            savedMessageIDs,
            usedBackendName
        )
        session.lastSelectedModelName = generationModel.displayName
        session.lastUsedBackendName = usedBackendName
        guard isGenerationActive(generationID) else {
            await finishCancelledTurn(sessionID: session.id, turnID: turnID, attempt: attempt)
            return
        }

        // 11) Runtime summary 更新 (270M)。Sceneの初期summaryは固定する。
        streamingStatusText = statusText("場面要約を更新中", "Updating scene summary")
        let newSummary = await summarizer.updateSummary(
            currentSummary: session.lastSceneSummary?.nonEmpty ?? scene.summary,
            recentMessages: Array(storyContentMessages(from: session.messages).suffix(18)),
            characterIndex: charIndex
        )
        guard isGenerationActive(generationID) else {
            await finishCancelledTurn(sessionID: session.id, turnID: turnID, attempt: attempt)
            return
        }
        // StoryScene.summary is the catalog's initial description. The
        // evolving runtime summary belongs only to StorySession.
        // 12) 進行状態は本文の完了を遅らせない。
        // 以前はここで同じローカルモデルへ進行JSONを追加生成していたため、
        // 1ターンの待ち時間が実質2回分になっていた。本文を先に返し、
        // 進行表示に必要な最小状態は決定的に更新する。
        // 追加のLLM呼び出しを待たせず、本文とシーンから確定できる状態を
        // 毎ターン保存する。これで旧データのnil StoryStateが次ターンへ
        // そのまま流れ、iori/NAGIで連続性が分岐する問題を防ぐ。
        // If the model happened to return a structured progress object in the
        // same response, reuse it here. This is intentionally opportunistic:
        // ordinary dialogue does not decode and stays on the deterministic
        // path, while structured state is applied without a second LLM call.
        session.storyState = Self.deterministicStateForTurn(
            existing: session.storyState
        )

        let progressStatePatch = modelStatePatch ?? acceptedStructuredProgressUpdate?.storyState
        let acceptedStatePatch = progressStatePatch.flatMap {
            StoryNaturalChangePolicy.acceptedPatch(
                from: $0,
                currentState: session.storyState,
                evidenceText: stateEvidenceText
            )
        }
        acceptanceGenerationTraceHandler?(StoryAcceptanceGenerationTrace(
            generationID: generationID,
            model: generationModel,
            systemPrompt: generationPrompt,
            userPrompt: effectiveUserText,
            rawOutput: reply ?? streamingResponse,
            visibleText: rawFinal,
            stateUpdate: acceptedStatePatch,
            backend: usedBackendName,
            modelIdentity: !isRuntimeNotice ? generated.modelIdentity : nil,
            modelLatencyMilliseconds: modelGenerationFinishedAt.timeIntervalSince(modelGenerationStartedAt) * 1_000,
            requestedSeed: seedOverride,
            effectiveSeed: seedOverride,
            seedMode: seedOverride == nil ? nil : "sampler"
        ))
        let stateAfterAcceptedPatch: StoryState? = {
            guard let acceptedStatePatch else { return session.storyState }
            return acceptedStatePatch.applying(
                to: session.storyState ?? StoryState(),
                characterIndex: charIndex,
                validCharacterIDs: Set(cast.map(\.characterId))
            )
        }()
        let hasExplicitObjectiveState = acceptedStatePatch?.activeGoals != nil
        let objectiveFromState = StoryNaturalChangePolicy.objectiveAfterAcceptedPatch(
            currentObjective: session.currentObjective,
            patch: acceptedStatePatch
        )
        let progressUpdate = StoryProgressUpdate(
            progressLabel: acceptedStructuredProgressUpdate?.progressLabel.nonEmpty
                ?? session.progressLabel.nonEmpty
                ?? "第1章 きっかけ",
            currentObjective: hasExplicitObjectiveState
                ? objectiveFromState
                : acceptedStructuredProgressUpdate?.currentObjective.nonEmpty
                    ?? session.currentObjective.nonEmpty,
            lastTurnProgress: acceptedStructuredProgressUpdate?.lastTurnProgress.nonEmpty
                ?? synthesizeTurnProgress(from: newMessages),
            lastSceneSummary: acceptedStructuredProgressUpdate?.lastSceneSummary.nonEmpty
                ?? newSummary.nonEmpty
                ?? session.lastSceneSummary.nonEmpty,
            unresolvedHooks: normalizedHooks(
                acceptedStructuredProgressUpdate?.unresolvedHooks,
                fallback: Self.unresolvedHooks(
                    world: world,
                    scene: scene,
                    previous: session.unresolvedHooks,
                    storyState: stateAfterAcceptedPatch
                )
            ),
            storyState: acceptedStatePatch
        )
        session.progressLabel = progressUpdate.progressLabel.nonEmpty
            ?? session.progressLabel.nonEmpty
            ?? "第1章 きっかけ"
        if hasExplicitObjectiveState {
            session.currentObjective = progressUpdate.currentObjective
        } else {
            session.currentObjective = progressUpdate.currentObjective.nonEmpty
                ?? session.currentObjective.nonEmpty
        }
        session.lastTurnProgress = progressUpdate.lastTurnProgress.nonEmpty
            ?? session.lastTurnProgress.nonEmpty
        session.lastSceneSummary = progressUpdate.lastSceneSummary.nonEmpty
            ?? newSummary.nonEmpty
            ?? session.lastSceneSummary.nonEmpty
        session.unresolvedHooks = normalizedHooks(
            progressUpdate.unresolvedHooks,
            fallback: Self.unresolvedHooks(
                world: world,
                scene: scene,
                previous: session.unresolvedHooks,
                storyState: stateAfterAcceptedPatch
            )
        )
        session.storyState = stateAfterAcceptedPatch

        // Memory extraction is deterministic input to the same turn boundary.
        // Prepare the records before commit, but do not write them until the
        // session/scene snapshot is committed. If commit fails, the retry can
        // carry these exact records forward without re-running the model or
        // memory extractor.
        let userVisibleAssistant = newMessages.map { (message: StoryMessage) in
            message.text
        }.joined(separator: "\n")
        var extractedStoryMemoryTexts = Set<String>()
        var characterMemoriesToSave: [CharacterMemory] = []
        var storyMemoriesToSave: [StoryMemory] = []
        for member in activeCast {
            guard isGenerationActive(generationID) else {
                await finishCancelledTurn(sessionID: session.id, turnID: turnID, attempt: attempt)
                return
            }
            guard let profile = charIndex[member.characterId] else { continue }
            let mems = await memorySummarizer.extract(
                userText: userText,
                assistantText: userVisibleAssistant,
                character: profile
            )
            for memory in mems {
                guard isGenerationActive(generationID) else {
                    await finishCancelledTurn(sessionID: session.id, turnID: turnID, attempt: attempt)
                    return
                }
                if isGlobalMemoryCategory(memory.category) {
                    characterMemoriesToSave.append(memory)
                } else {
                    storyMemoriesToSave.append(
                        StoryMemory(
                            storyWorldId: world.id,
                            characterId: memory.characterId,
                            text: memory.text,
                            category: memory.category,
                            importance: memory.importance,
                            source: memory.source,
                            storySessionId: session.id,
                            sourceTurnIds: [turnID]
                        )
                    )
                    extractedStoryMemoryTexts.insert(memory.text)
                }
            }
        }

        // 進行JSONの「今回の変化」も、次回以降に使える物語内の思い出にする。
        let progressText = progressUpdate.lastTurnProgress ?? ""
        if let progress = progressText
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            .nonEmpty,
           extractedStoryMemoryTexts.insert(progress).inserted {
            guard isGenerationActive(generationID) else {
                await finishCancelledTurn(sessionID: session.id, turnID: turnID, attempt: attempt)
                return
            }
            storyMemoriesToSave.append(
                StoryMemory(
                    storyWorldId: world.id,
                    text: progress,
                    category: .event,
                    importance: 0.6,
                    source: .summary,
                    storySessionId: session.id,
                    sourceTurnIds: [turnID]
                )
            )
        }
        let pendingMemoryRetry: StoryMemoryRetry? = {
            guard !characterMemoriesToSave.isEmpty || !storyMemoriesToSave.isEmpty else {
                return nil
            }
            return StoryMemoryRetry(
                turnID: turnID,
                userMessageID: userMessageID,
                userText: userText,
                characterMemories: characterMemoriesToSave,
                storyMemories: storyMemoriesToSave,
                storySessionID: session.id,
                storyWorldID: world.id
            )
        }()
        let turnCharacterIDs = Set(turnMessages.compactMap { message -> UUID? in
            guard case let .cast(characterID, _) = message.author else { return nil }
            return characterID
        })
        do {
            let invalidIDs = try await invalidCharacterReferencesBeforeCommit(
                session: session,
                world: world,
                scene: scene,
                cast: cast,
                additionalCharacterIDs: turnCharacterIDs
            )
            guard invalidIDs.isEmpty else {
                await finishGenerationWithoutSaving(
                    generationID: generationID,
                    notice: localizedNotice(
                        "キャラクターが削除されたため、古い応答とメモリーを保存しませんでした。もう一度試してください。",
                        "A character was deleted, so the stale response and memories were not saved. Try again."
                    ),
                    backend: .persistence,
                    userMessageID: userMessageID,
                    userText: userText,
                    backendName: "character deleted before turn commit"
                )
                return
            }
        } catch {
            await finishGenerationWithoutSaving(
                generationID: generationID,
                notice: localizedNotice(
                    "キャラクターの最新状態を確認できなかったため、応答を保存しませんでした。もう一度試してください。",
                    "The latest character state could not be verified, so the response was not saved. Try again."
                ),
                backend: .persistence,
                userMessageID: userMessageID,
                userText: userText,
                backendName: "character validation failed before turn commit"
            )
            AppLog.error("[StorySession] character validation failed before turn commit: %@", error.localizedDescription)
            return
        }
        do {
            session = try await sessionRepo.commitTurn(
                session: session,
                scene: scene,
                turnID: turnID,
                assistantMessageIDs: turnMessages.map(\.id),
                memoryRetries: pendingMemoryRetry.map { [$0] } ?? []
            )
            lastCommittedSession = session
        } catch {
            AppLog.error("[StorySession] turn commit failed: %@", error.localizedDescription)
            let retry = StoryTurnCommitRetry(
                session: session,
                scene: scene,
                turnID: turnID,
                attempt: attempt,
                assistantMessageIDs: turnMessages.map(\.id),
                characterMemories: characterMemoriesToSave,
                storyMemories: storyMemoriesToSave,
                userMessageID: userMessageID,
                userText: userText
            )
            await finishGenerationWithCommitRetry(
                generationID: generationID,
                notice: localizedNotice(
                    "今回の応答を保存しきれませんでした。AI本文は再生成せず、保存だけを再試行できます。",
                    "The response could not be fully saved. Retry saving without regenerating the AI response."
                ),
                retry: retry
            )
            return
        }
        // Usage metadata is a commit-side effect. Do not change memory ranking
        // for a generation that never became a durable conversation turn.
        if !selectedMemories.isEmpty {
            do {
                try await memoryRepo.markUsed(ids: selectedMemories.map(\.id))
            } catch {
                AppLog.error("[StorySession] character memory usage update failed turn=%@: %@", turnID.uuidString, error.localizedDescription)
            }
        }
        if !selectedStoryMemories.isEmpty {
            do {
                try await storyMemoryRepo.markUsed(ids: selectedStoryMemories.map(\.id))
            } catch {
                AppLog.error("[StorySession] story memory usage update failed turn=%@: %@", turnID.uuidString, error.localizedDescription)
            }
        }
        // 13) メモリー保存。抽出はcommit前に済ませているため、ここで
        // 失敗しても同じ候補だけを再試行でき、AI本文は再生成しない。
        var failedCharacterMemories: [CharacterMemory] = []
        var failedStoryMemories: [StoryMemory] = []
        var canContinueMemorySaves = true
        for (index, memory) in characterMemoriesToSave.enumerated() {
            guard isGenerationActive(generationID) else {
                // The conversation turn is already committed. Cancellation
                // must not finish it again or discard candidates that were
                // still waiting for their auxiliary save.
                failedCharacterMemories.append(contentsOf: characterMemoriesToSave[index...])
                failedStoryMemories.append(contentsOf: storyMemoriesToSave)
                canContinueMemorySaves = false
                break
            }
            do {
                try await memoryRepo.saveMemory(memory)
            } catch {
                failedCharacterMemories.append(memory)
                AppLog.error("[StorySession] character memory save failed turn=%@ memory=%@: %@", turnID.uuidString, memory.id.uuidString, error.localizedDescription)
            }
        }
        if canContinueMemorySaves {
            for (index, memory) in storyMemoriesToSave.enumerated() {
                guard isGenerationActive(generationID) else {
                    failedStoryMemories.append(contentsOf: storyMemoriesToSave[index...])
                    break
                }
                do {
                    try await storyMemoryRepo.saveMemory(memory)
                } catch {
                    failedStoryMemories.append(memory)
                    AppLog.error("[StorySession] story memory save failed turn=%@ memory=%@: %@", turnID.uuidString, memory.id.uuidString, error.localizedDescription)
                }
            }
        }

        var memoryRetry: StoryMemoryRetry?
        if !failedCharacterMemories.isEmpty || !failedStoryMemories.isEmpty {
            let retry = StoryMemoryRetry(
                turnID: turnID,
                userMessageID: userMessageID,
                userText: userText,
                characterMemories: failedCharacterMemories,
                storyMemories: failedStoryMemories,
                storySessionID: session.id,
                storyWorldID: world.id
            )
            if await enqueueStoryMemoryRetry(retry) {
                _ = await removeStoryMemoryJournal(for: turnID)
            }
            memoryRetry = retry
        } else if let pendingMemoryRetry {
            // The journal made the candidates durable before the turn commit.
            // Once every auxiliary write succeeds, remove that handoff so a
            // later restart cannot replay already-persisted memories.
            _ = await completeStoryMemoryRetry(pendingMemoryRetry)
        }

        let didPublishNotice = await MainActor.run { () -> Bool in
            guard self.activeGenerationID == generationID else { return false }
            self.latestSafetyConcern = safetyConcern
            if let memoryRetry {
                self.latestRuntimeNotice = self.storyMemoryRetryNotice(memoryRetry)
            } else if let pendingRetry = self.oldestPendingStoryMemoryRetry {
                self.latestRuntimeNotice = self.storyMemoryRetryNotice(pendingRetry)
            }
            self.streamingResponse = rawFinal
            self.streamingSpeakerName = newMessages.last?.speakerDisplayName
            self.streamingStatusText = ""
            self.savedTurnRevision += 1
            self.phase = .idle
            self.activeGenerationID = nil
            self.activeGenerationModel = nil
            self.activeTurnID = nil
            self.activeSessionID = nil
            self.activeTurnAttempt = nil
            self.activeUserMessageID = nil
            self.activeUserText = ""
            return true
        }

        guard !didPublishNotice else { return }
        // The turn was committed but its generation owner disappeared before
        // the auxiliary-save notice could be published. Do not leave the
        // checkpoint pending with no visible recovery path.
        do {
            try await sessionRepo.finishTurn(
                sessionID: session.id,
                turnID: turnID,
                attempt: attempt,
                status: .failed,
                failureCode: "memory_retry_notice_unavailable"
            )
        } catch {
            AppLog.error("[StorySession] failed to close committed turn after notice loss: %@", error.localizedDescription)
        }
    }

    private func retryableSystemMessage(
        _ text: String,
        userMessageID: UUID,
        backend: StoryGenerationBackend = .local
    ) -> StoryMessage {
        StoryMessage(
            author: .system,
            text: StoryRetryMetadata.attachingUserMessageID(userMessageID, to: text),
            retryBackend: backend
        )
    }

    /// Keeps a failed commit pending so the retry can reuse the exact session,
    /// scene, and assistant message IDs produced by the completed generation.
    /// Calling finishTurn here would make the checkpoint non-pending and force
    /// the next attempt through the model-generation path.
    private func recoveredCommittedSession(for retry: StoryTurnCommitRetry) async -> StorySession? {
        do {
            let sessions = try await sessionRepo.fetchSessions(storyWorldId: retry.session.storyWorldId)
            let scenes = try await sceneRepo.fetchScenes(storyWorldId: retry.scene.storyWorldId)
            return StoryTurnCommitRecovery.committedSession(
                matching: retry,
                in: sessions,
                scenes: scenes
            )
        } catch {
            // A failed recovery must keep the exact-snapshot retry path. Do not
            // turn an unreadable or partially recovered store into a false
            // success.
            AppLog.note(
                "[StorySession] commit recovery check failed turn=%@: %@",
                retry.turnID.uuidString,
                error.localizedDescription
            )
            return nil
        }
    }

    /// Journal recovery may have completed a partially successful commit
    /// before the original commit call reported its later save error. In that
    /// case the user-visible result is already durable: refresh normally and
    /// retry only auxiliary memories, without presenting a misleading save
    /// failure or invoking the model again.
    private func finishRecoveredCommittedTurn(
        generationID: UUID,
        retry: StoryTurnCommitRetry
    ) async {
        pendingStoryTurnCommitRetries.removeValue(forKey: retry.turnID)

        var memoryRetry: StoryMemoryRetry?
        if !retry.characterMemories.isEmpty || !retry.storyMemories.isEmpty {
            let candidate = StoryMemoryRetry(
                turnID: retry.turnID,
                userMessageID: retry.userMessageID,
                userText: retry.userText,
                characterMemories: retry.characterMemories,
                storyMemories: retry.storyMemories,
                storySessionID: retry.session.id,
                storyWorldID: retry.scene.storyWorldId
            )
            if let remaining = await saveStoryMemoryRetryRecords(candidate) {
                if await enqueueStoryMemoryRetry(remaining) {
                    _ = await removeStoryMemoryJournal(for: retry.turnID)
                }
                memoryRetry = remaining
            } else {
                _ = await completeStoryMemoryRetry(candidate)
            }
        }

        let didPublish = await MainActor.run { () -> Bool in
            guard self.activeGenerationID == generationID else { return false }
            if let pendingRetry = self.oldestPendingStoryTurnCommitRetry {
                self.latestRuntimeNotice = self.storyTurnCommitRetryNotice(pendingRetry)
            } else if let memoryRetry {
                self.latestRuntimeNotice = self.storyMemoryRetryNotice(memoryRetry)
            } else if let pendingRetry = self.oldestPendingStoryMemoryRetry {
                self.latestRuntimeNotice = self.storyMemoryRetryNotice(pendingRetry)
            } else {
                self.latestRuntimeNotice = nil
            }
            // The persisted session is the source of truth. The ViewModel's
            // normal saved-turn refresh will show the recovered messages.
            self.streamingResponse = ""
            self.streamingSpeakerName = nil
            self.streamingStatusText = ""
            self.savedTurnRevision += 1
            self.generationWatchdogDeadline = nil
            self.phase = .idle
            self.activeGenerationID = nil
            self.activeGenerationModel = nil
            self.activeTurnID = nil
            self.activeSessionID = nil
            self.activeTurnAttempt = nil
            self.activeUserMessageID = nil
            self.activeUserText = ""
            return true
        }

        if !didPublish {
            AppLog.note(
                "[StorySession] recovered committed turn without active UI owner turn=%@",
                retry.turnID.uuidString
            )
        }
    }

    private func finishGenerationWithCommitRetry(
        generationID: UUID,
        notice: String,
        retry: StoryTurnCommitRetry
    ) async {
        if await recoveredCommittedSession(for: retry) != nil {
            AppLog.note(
                "[StorySession] commit failure already recovered turn=%@",
                retry.turnID.uuidString
            )
            await finishRecoveredCommittedTurn(generationID: generationID, retry: retry)
            return
        }

        let didPublishNotice = await MainActor.run { () -> Bool in
            guard self.activeGenerationID == generationID else { return false }
            self.pendingStoryTurnCommitRetries[retry.turnID] = retry
            self.latestRuntimeNotice = StoryRuntimeNotice(
                text: notice,
                userMessageID: retry.userMessageID,
                userText: retry.userText,
                backendName: "turn commit failed",
                backend: .persistence,
                retryAction: .storyTurnCommit(retry)
            )
            self.streamingResponse = notice
            self.streamingSpeakerName = "システム"
            self.streamingStatusText = ""
            self.generationWatchdogDeadline = nil
            self.phase = .idle
            self.activeGenerationID = nil
            self.activeGenerationModel = nil
            self.activeTurnID = nil
            self.activeSessionID = nil
            self.activeTurnAttempt = nil
            self.activeUserMessageID = nil
            self.activeUserText = ""
            return true
        }
        guard !didPublishNotice else { return }

        // The retry target must never be left in an invisible pending state.
        // Release the repository checkpoint when the owning generation has
        // already disappeared before the notice could be published.
        do {
            try await sessionRepo.finishTurn(
                sessionID: retry.session.id,
                turnID: retry.turnID,
                attempt: retry.attempt,
                status: .failed,
                failureCode: "commit_retry_notice_unavailable"
            )
        } catch {
            AppLog.error("[StorySession] failed to close turn after commit retry notice loss: %@", error.localizedDescription)
        }
    }

    /// Retries only the persistence boundary for a previously generated turn.
    /// Journal recovery may already have committed the snapshot; commitTurn is
    /// idempotent for that case and returns the persisted session.
    func retryStoryTurnCommit(_ retry: StoryTurnCommitRetry) async {
        guard !isRetryingAuxiliarySave,
              let pendingRetry = pendingStoryTurnCommitRetries[retry.turnID] else { return }
        isRetryingAuxiliarySave = true
        defer { isRetryingAuxiliarySave = false }
        latestRuntimeNotice = nil
        let memoryRetry: StoryMemoryRetry? = {
            guard !pendingRetry.characterMemories.isEmpty || !pendingRetry.storyMemories.isEmpty else {
                return nil
            }
            return StoryMemoryRetry(
                turnID: pendingRetry.turnID,
                userMessageID: pendingRetry.userMessageID,
                userText: pendingRetry.userText,
                characterMemories: pendingRetry.characterMemories,
                storyMemories: pendingRetry.storyMemories,
                storySessionID: pendingRetry.session.id,
                storyWorldID: pendingRetry.scene.storyWorldId
            )
        }()
        do {
            guard let retryWorld = try await worldRepo.fetchWorlds().first(where: {
                $0.id == pendingRetry.scene.storyWorldId
            }) else {
                throw StoryTurnPersistenceError.sessionNotFound
            }
            let retryCharacterIDs = Set(pendingRetry.session.messages
                .filter { pendingRetry.assistantMessageIDs.contains($0.id) }
                .compactMap { message -> UUID? in
                guard case let .cast(characterID, _) = message.author else { return nil }
                return characterID
            })
            let invalidIDs = try await invalidCharacterReferencesBeforeCommit(
                session: pendingRetry.session,
                world: retryWorld,
                scene: pendingRetry.scene,
                cast: [],
                additionalCharacterIDs: retryCharacterIDs
            )
            guard invalidIDs.isEmpty else {
                pendingStoryTurnCommitRetries.removeValue(forKey: pendingRetry.turnID)
                try? await sessionRepo.finishTurn(
                    sessionID: pendingRetry.session.id,
                    turnID: pendingRetry.turnID,
                    attempt: pendingRetry.attempt,
                    status: .failed,
                    failureCode: "character_deleted_before_commit_retry"
                )
                latestRuntimeNotice = StoryRuntimeNotice(
                    text: localizedNotice(
                        "キャラクターが削除されたため、古い応答の再保存を中止しました。",
                        "The character was deleted, so saving the stale response was stopped."
                    ),
                    userMessageID: pendingRetry.userMessageID,
                    userText: pendingRetry.userText,
                    backendName: "character deleted before turn commit retry",
                    backend: .persistence
                )
                return
            }
        } catch {
            latestRuntimeNotice = StoryRuntimeNotice(
                text: localizedNotice(
                    "キャラクターの最新状態を確認できなかったため、保存を再試行できません。",
                    "The latest character state could not be verified, so the save cannot be retried yet."
                ),
                userMessageID: pendingRetry.userMessageID,
                userText: pendingRetry.userText,
                backendName: "character validation failed before turn commit retry",
                backend: .persistence
            )
            AppLog.error("[StorySession] character validation failed before turn commit retry: %@", error.localizedDescription)
            return
        }
        do {
            _ = try await sessionRepo.commitTurn(
                session: pendingRetry.session,
                scene: pendingRetry.scene,
                turnID: pendingRetry.turnID,
                assistantMessageIDs: pendingRetry.assistantMessageIDs,
                memoryRetries: memoryRetry.map { [$0] } ?? []
            )
            pendingStoryTurnCommitRetries.removeValue(forKey: pendingRetry.turnID)
            // The conversation turn is durable once commitTurn succeeds.
            // Auxiliary memory persistence must not delay or suppress the
            // revision signal used by the UI to reload the committed reply.
            savedTurnRevision += 1
            if let memoryRetry {
                if let remaining = await saveStoryMemoryRetryRecords(memoryRetry) {
                    if await enqueueStoryMemoryRetry(remaining) {
                        _ = await removeStoryMemoryJournal(for: pendingRetry.turnID)
                    }
                    if let pendingRetry = oldestPendingStoryTurnCommitRetry {
                        latestRuntimeNotice = storyTurnCommitRetryNotice(pendingRetry)
                    } else {
                        latestRuntimeNotice = storyMemoryRetryNotice(remaining)
                    }
                } else {
                    _ = await completeStoryMemoryRetry(memoryRetry)
                    if let pendingRetry = oldestPendingStoryTurnCommitRetry {
                        latestRuntimeNotice = storyTurnCommitRetryNotice(pendingRetry)
                    }
                }
            } else {
                if let pendingRetry = oldestPendingStoryTurnCommitRetry {
                    latestRuntimeNotice = storyTurnCommitRetryNotice(pendingRetry)
                }
            }
        } catch {
            AppLog.error("[StorySession] auxiliary turn commit retry failed turn=%@: %@", pendingRetry.turnID.uuidString, error.localizedDescription)
            latestRuntimeNotice = StoryRuntimeNotice(
                text: localizedNotice(
                    "保存を完了できませんでした。AI本文は再生成せず、保存先を確認してからもう一度試してください。",
                    "The save could not be completed. The AI response was not regenerated; check storage and try again."
                ),
                userMessageID: pendingRetry.userMessageID,
                userText: pendingRetry.userText,
                backendName: "turn commit retry failed",
                backend: .persistence,
                retryAction: .storyTurnCommit(pendingRetry)
            )
        }
    }

    /// Retries only failed memory writes. The committed conversation is never
    /// sent back through `send` or the model pipeline.
    func retryStoryMemorySave(_ retry: StoryMemoryRetry) async {
        guard pendingStoryTurnCommitRetries.isEmpty else {
            if let pendingRetry = oldestPendingStoryTurnCommitRetry {
                latestRuntimeNotice = storyTurnCommitRetryNotice(pendingRetry)
            }
            return
        }
        guard !isRetryingAuxiliarySave,
              let pendingRetry = pendingStoryMemoryRetries[retry.turnID],
              !pendingRetry.isCompleted,
              !pendingRetry.isAbandoned else { return }
        isRetryingAuxiliarySave = true
        defer { isRetryingAuxiliarySave = false }
        latestRuntimeNotice = nil

        guard let remaining = await saveStoryMemoryRetryRecords(pendingRetry) else {
            _ = await completeStoryMemoryRetry(pendingRetry)
            savedTurnRevision += 1
            return
        }

        await enqueueStoryMemoryRetry(remaining)
        latestRuntimeNotice = storyMemoryRetryNotice(remaining)
    }

    private func saveStoryMemoryRetryRecords(_ retry: StoryMemoryRetry) async -> StoryMemoryRetry? {
        if let transaction = storyMemoryRetryMemoryTransaction,
           retry.storySessionID != nil {
            do {
                return try await transaction.saveMemoryRetryRecords(retry)
            } catch {
                // Keep the complete retry payload if the cross-file
                // transaction could not commit. It is safer to retry an
                // idempotent merge than to acknowledge a partial write.
                AppLog.note(
                    "[StorySession] memory retry transaction failed turn=%@: %@",
                    retry.turnID.uuidString,
                    error.localizedDescription
                )
                return retry
            }
        }

        var remainingCharacterMemories: [CharacterMemory] = []
        for memory in retry.characterMemories {
            do {
                try await memoryRepo.saveMemory(memory)
            } catch {
                remainingCharacterMemories.append(memory)
                AppLog.error("[StorySession] character memory retry failed turn=%@ memory=%@: %@", retry.turnID.uuidString, memory.id.uuidString, error.localizedDescription)
            }
        }
        var remainingStoryMemories: [StoryMemory] = []
        for memory in retry.storyMemories {
            var ownedMemory = memory
            // Legacy retry payloads may carry the owner only on the retry
            // envelope. Promote it before the repository write so a stale
            // service cannot save world-scoped memory after Session deletion.
            if ownedMemory.storySessionId == nil {
                ownedMemory.storySessionId = retry.storySessionID
            }
            do {
                try await storyMemoryRepo.saveMemory(ownedMemory)
            } catch let error as StoryTurnPersistenceError {
                if case .recordDeleted = error {
                    // An intentional Session deletion is terminal for this
                    // payload. Retrying it forever would keep an impossible
                    // notice visible and could resurrect deleted state in a
                    // replaceable repository implementation.
                    AppLog.note(
                        "[StorySession] dropped story memory retry for deleted session turn=%@ memory=%@",
                        retry.turnID.uuidString,
                        ownedMemory.id.uuidString
                    )
                    continue
                }
                remainingStoryMemories.append(ownedMemory)
                AppLog.error("[StorySession] story memory retry failed turn=%@ memory=%@: %@", retry.turnID.uuidString, ownedMemory.id.uuidString, error.localizedDescription)
            } catch {
                remainingStoryMemories.append(ownedMemory)
                AppLog.error("[StorySession] story memory retry failed turn=%@ memory=%@: %@", retry.turnID.uuidString, ownedMemory.id.uuidString, error.localizedDescription)
            }
        }

        guard !remainingCharacterMemories.isEmpty || !remainingStoryMemories.isEmpty else { return nil }
        return StoryMemoryRetry(
            turnID: retry.turnID,
            userMessageID: retry.userMessageID,
            userText: retry.userText,
            characterMemories: remainingCharacterMemories,
            storyMemories: remainingStoryMemories,
            storySessionID: retry.storySessionID,
            storyWorldID: retry.storyWorldID,
            missingSessionRestoreAttempts: retry.missingSessionRestoreAttempts,
            isAbandoned: retry.isAbandoned
        )
    }

    private func storyMemoryRetryNotice(_ retry: StoryMemoryRetry) -> StoryRuntimeNotice {
        StoryRuntimeNotice(
            text: localizedNotice(
                "応答は保存されましたが、物語の記憶を保存できませんでした。記憶だけ再試行できます。",
                "The response was saved, but some story memories were not. Retry the memory save without regenerating the response."
            ),
            userMessageID: retry.userMessageID,
            userText: retry.userText,
            backendName: "memory save failed",
            backend: .persistence,
            retryAction: .storyMemory(retry)
        )
    }

    private func storyTurnCommitRetryNotice(_ retry: StoryTurnCommitRetry) -> StoryRuntimeNotice {
        StoryRuntimeNotice(
            text: localizedNotice(
                "保存を完了できませんでした。AI本文は再生成せず、同じ結果の保存だけ再試行できます。",
                "The turn could not be committed. Retry saving the same generated result without regenerating it."
            ),
            userMessageID: retry.userMessageID,
            userText: retry.userText,
            backendName: "turn commit failed",
            backend: .persistence,
            retryAction: .storyTurnCommit(retry)
        )
    }

    /// A stale/corrupt retry target must not create a new user turn. Surface a
    /// clear transient error while leaving the persisted conversation untouched.
    private func finishGenerationWithoutSaving(
        generationID: UUID,
        notice: String,
        backend: StoryGenerationBackend,
        userMessageID: UUID? = nil,
        userText: String? = nil,
        backendName: String = "",
        safetyConcern: SafetyConcern? = nil,
        retryWhenLocalReady: Bool = false
    ) async {
        guard isGenerationActive(generationID) else { return }
        releaseTurnOwner()
        let sessionID = activeSessionID
        let turnID = activeTurnID
        let attempt = activeTurnAttempt
        var finishFailed = false
        if let sessionID, let turnID, let attempt {
            do {
                try await sessionRepo.finishTurn(
                    sessionID: sessionID,
                    turnID: turnID,
                    attempt: attempt,
                    status: .failed,
                    failureCode: backendName.isEmpty ? "generation_failed" : backendName
                )
            } catch {
                finishFailed = true
                AppLog.error("[StorySession] generation failure cleanup failed: %@", error.localizedDescription)
            }
        }
        let displayedNotice = finishFailed
            ? localizedNotice(
                "応答は保存しませんでしたが、ターンの終了状態を保存できませんでした。保存先を確認してから同じ発言を再試行してください。",
                "The response was not saved, but the turn could not be finalized. Check storage and retry the same message."
            )
            : notice
        let displayedBackendName = finishFailed
            ? "turn finalization failed"
            : backendName
        await MainActor.run {
            guard self.activeGenerationID == generationID else { return }
            if let userMessageID, let userText {
                self.latestRuntimeNotice = StoryRuntimeNotice(
                    text: displayedNotice,
                    userMessageID: userMessageID,
                    userText: userText,
                    backendName: displayedBackendName,
                    backend: backend,
                    retryWhenLocalReady: retryWhenLocalReady
                )
            }
            self.latestSafetyConcern = safetyConcern
            self.streamingResponse = displayedNotice
            self.streamingSpeakerName = "システム"
            self.streamingStatusText = ""
            self.savedTurnRevision += 1
            self.generationWatchdogDeadline = nil
            self.phase = .idle
            self.activeGenerationID = nil
            self.activeGenerationModel = nil
            self.activeTurnID = nil
            self.activeSessionID = nil
            self.activeTurnAttempt = nil
            self.activeUserMessageID = nil
            self.activeUserText = ""
        }
    }

    /// `Task` cancellation makes the normal notice path ineligible because
    /// `isGenerationActive` also checks `Task.isCancelled`. Finalize the
    /// persisted checkpoint directly so cancellation cannot leave a pending
    /// turn behind for the next launch.
    private func finishCancelledTurn(
        sessionID: UUID,
        turnID: UUID,
        attempt: Int
    ) async {
        await waitForPendingTurnFinish()
        do {
            try await sessionRepo.finishTurn(
                sessionID: sessionID,
                turnID: turnID,
                attempt: attempt,
                status: .cancelled,
                failureCode: "generation_cancelled"
            )
        } catch {
            AppLog.error("[StorySession] cancellation cleanup failed: %@", error.localizedDescription)
        }
    }

    /// Wait through a cleanup chain. If another cancel/timeout queued a newer
    /// task while the awaited task was running, keep waiting instead of
    /// starting a new turn or clearing the newer task reference.
    private func waitForPendingTurnFinish() async {
        while let pendingTask = pendingTurnFinishTask {
            let token = pendingTurnFinishToken
            await pendingTask.value
            guard pendingTurnFinishToken == token else { continue }
            pendingTurnFinishTask = nil
            pendingTurnFinishToken = nil
        }
    }

    private func isGenerationActive(_ generationID: UUID) -> Bool {
        !Task.isCancelled && activeGenerationID == generationID
    }

    // 全体へ持ち越してよい情報だけを明示する。
    private func isGlobalMemoryCategory(_ category: MemoryCategory) -> Bool {
        switch category {
        case .userFact, .preference, .safety:
            return true
        case .relationship, .event, .world, .summary, .other:
            return false
        }
    }

    // StoryMemoryは軽量なキーワード重なり + 重要度 + 新しさで選ぶ。
    private func selectStoryMemories(
        query: String,
        candidates: [StoryMemory],
        topK: Int
    ) -> [StoryMemory] {
        let queryTokens = storyMemoryTokens(query)
        return candidates
            .map { memory -> (StoryMemory, Double) in
                let memoryTokens = storyMemoryTokens(memory.text)
                let overlap = queryTokens.intersection(memoryTokens).count
                let age = Date().timeIntervalSince(memory.lastUsedAt ?? memory.createdAt)
                let freshness = age < 60 * 60 * 24 * 7 ? 0.1 : 0.0
                return (memory, memory.importance * 0.5 + Double(overlap) * 0.4 + freshness)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(max(0, topK))
            .map(\.0)
    }

    private func storyMemoryTokens(_ text: String) -> Set<String> {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var tokens = Set(words)
        // 日本語は空白で区切られないため、2文字の重なりも関連度に使う。
        let characters = Array(text.lowercased())
        guard characters.count > 1 else { return tokens }
        for index in 0..<(characters.count - 1) {
            tokens.insert(String(characters[index...(index + 1)]))
        }
        return tokens
    }

    private func storyContentMessages(from messages: [StoryMessage]) -> [StoryMessage] {
        messages.filter { message in
            if case .system = message.author { return false }
            return true
        }
    }

    // MARK: - Stream handling

    private func generateWithGemma31BAPI(
        systemPrompt: String,
        userPrompt: String,
        generationID: UUID,
        seedOverride: UInt32?
    ) async -> (reply: String?, modelIdentity: String?) {
        await MainActor.run {
            guard self.activeGenerationID == generationID else { return }
            self.streamingSpeakerName = "NAGI"
            self.streamingStatusText = self.statusText("Gemma4 31Bで発話生成中", "Generating with Gemma4 31B")
            self.streamingResponse = self.localizedNotice(
                "ナレーション: NAGIが場面と会話履歴を読み込んでいます。",
                "Narration: NAGI is reading the scene and conversation history."
            )
        }

        do {
            let generation = try await StoryGemma31BAPIService.shared.generate(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                temperature: 0.72,
                // 物語本文は2〜7行で十分。過剰な上限は待ち時間と候補の連続出力を増やす。
                maxOutputTokens: 1024,
                seed: seedOverride.map(Int.init)
            )
            let text = generation.text
            await MainActor.run {
                guard self.activeGenerationID == generationID else { return }
                self.streamingResponse = text
                self.streamingStatusText = self.statusText("発話を整形中", "Formatting response")
                self.streamingSpeakerName = self.detectCurrentSpeakerName(in: text)
            }
            return (reply: text, modelIdentity: generation.modelName)
        } catch let error as StoryGemma31BAPIError {
            // APIエラーをNPC本文として整形すると、空レスポンス時に
            // 同じキャラのフォールバック発話が追加されるためsystem通知にする。
            let message = gemmaRuntimeNotice(for: error)
            AppLog.error("[StoryGemma31B] generation failed: %@", error.localizedDescription)
            await MainActor.run {
                guard self.activeGenerationID == generationID else { return }
                self.streamingResponse = message
                self.streamingStatusText = ""
                self.streamingSpeakerName = nil
            }
            return (reply: message, modelIdentity: nil)
        } catch {
            let message = localizedNotice(
                "Gemma4 31B API の応答に失敗しました。もう一度試してください。",
                "Gemma4 31B API failed to respond. Try again."
            )
            AppLog.error("[StoryGemma31B] generation failed: %@", error.localizedDescription)
            await MainActor.run {
                guard self.activeGenerationID == generationID else { return }
                self.streamingResponse = message
                self.streamingStatusText = ""
                self.streamingSpeakerName = nil
            }
            return (reply: message, modelIdentity: nil)
        }
    }

    private func handleStreamUpdate(_ update: LocalAssistantStructuredTurnUpdate, generationID: UUID) {
        guard activeGenerationID == generationID else { return }
        guard case let .visiblePreview(text) = update else { return }
        let stripped = sanitize(text)
        streamingSpeakerName = detectCurrentSpeakerName(in: stripped)
        streamingStatusText = statusText("発話生成中", "Generating response")
        if stripped.count >= lastVisibleText.count {
            lastVisibleText = stripped
            streamingResponse = stripped
        } else {
            lastVisibleText = stripped
            streamingResponse = stripped
        }
    }

    private func startWatchdog(
        session: StorySession,
        generationID: UUID,
        generationModel: StoryGenerationModel,
        userMessageID: UUID
    ) {
        Task { @MainActor [weak self] in
            while true {
                guard let self,
                      self.activeGenerationID == generationID,
                      self.phase == .thinking,
                      let deadline = self.generationWatchdogDeadline else { return }
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { break }
                do {
                    let nanoseconds = UInt64(min(remaining, 1.0) * 1_000_000_000)
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
            }

            guard let self,
                  self.activeGenerationID == generationID,
                  self.phase == .thinking else { return }
            let timeoutToken = UUID()
            self.timeoutSaveToken = timeoutToken
            self.releaseTurnOwner()
            // Invalidate the pipeline before cancelling it. Some native/API
            // backends do not observe cancellation immediately; keeping the
            // generation ID valid would let a late result pass the guards and
            // append a story turn after the timeout card was saved.
            self.generationTask?.cancel()
            self.generationTask = nil
            let timedOutSessionID = self.activeSessionID
            let timedOutTurnID = self.activeTurnID
            let timedOutAttempt = self.activeTurnAttempt
            if let timedOutSessionID, let timedOutTurnID, let timedOutAttempt {
                let previousCleanup = self.pendingTurnFinishTask
                let cleanupToken = UUID()
                self.pendingTurnFinishToken = cleanupToken
                self.pendingTurnFinishTask = Task { [sessionRepo = self.sessionRepo] in
                    if let previousCleanup {
                        await previousCleanup.value
                    }
                    do {
                        try await sessionRepo.finishTurn(
                            sessionID: timedOutSessionID,
                            turnID: timedOutTurnID,
                            attempt: timedOutAttempt,
                            status: .failed,
                            failureCode: "generation_timeout"
                        )
                    } catch {
                        AppLog.error("[StorySession] timeout cleanup failed: %@", error.localizedDescription)
                    }
                }
            }
            self.activeGenerationID = nil
            self.activeGenerationModel = nil
            self.generationWatchdogDeadline = nil
            self.activeTurnID = nil
            self.activeSessionID = nil
            self.activeTurnAttempt = nil
            self.activeUserMessageID = nil
            self.activeUserText = ""
            if generationModel == .e4b {
                LocalAssistantRuntimeBridge.shared.cancelActiveGeneration(generationID: generationID)
            }
            let notice: String
            let backendName: String
            let backend: StoryGenerationBackend
            switch generationModel {
            case .e4b:
                notice = self.localizedNotice(
                    "iori ローカル生成の待機上限を超えたため停止しました。モデル本文は保存していません。もう一度試すか、NAGIで続けられます。",
                    "iori reached its wait limit and stopped. The model response was not saved. Try again or continue with NAGI."
                )
                backendName = "iori ローカル・タイムアウト"
                backend = .local
            case .b31:
                notice = self.localizedNotice(
                    "Gemma4 31B APIの生成が時間内に完了しませんでした。本文は保存していません。もう一度試してください。",
                    "Gemma4 31B API did not finish in time. The response was not saved. Try again."
                )
                backendName = "Gemma4 31B API・タイムアウト"
                backend = .gemmaAPI
            }
            self.streamingResponse = notice
            self.streamingSpeakerName = "システム"
            // タイムアウト通知は履歴へ書き込まない。古いスナップショットを
            // fetch/saveする間にユーザーが次の送信を行うと、直前ターンを上書き
            // する競合も起きていたため、UI専用の一時通知へ切り替える。
            let userText = session.messages.first(where: { $0.id == userMessageID })?.text ?? ""
            self.latestRuntimeNotice = StoryRuntimeNotice(
                text: notice,
                userMessageID: userMessageID,
                userText: userText,
                backendName: backendName,
                backend: backend
            )
            guard self.timeoutSaveToken == timeoutToken else { return }
            // timeoutTokenが一致している場合は、このwatchdogが所有する
            // 生成の後始末を必ず完了させる。phaseが先にidleへ変わった
            // ケースでreturnすると、以後の送信が永久に詰まる。
            self.streamingStatusText = ""
            self.savedTurnRevision += 1
            self.timeoutSaveToken = nil
            self.phase = .idle
            self.activeGenerationID = nil
            self.activeGenerationModel = nil
            self.activeTurnID = nil
            self.activeSessionID = nil
            self.activeTurnAttempt = nil
            self.activeUserMessageID = nil
            self.activeUserText = ""
        }
    }

    // MARK: - Speaker line parsing

    /// 「名前: 本文」「ナレーション: 本文」を含む可能性のあるテキストを行ごとに分割し、
    /// StoryMessage の配列にする。前置きや空行は捨てる。
    private func parseSpeakerLines(
        _ text: String,
        cast: [CastMember],
        characterIndex: [UUID: CharacterProfile],
        forbiddenCharacterID: UUID? = nil,
        forbiddenCharacterName: String? = nil,
        generationID: UUID? = nil
    ) -> [StoryMessage] {
        let castNames: [(id: UUID, name: String, normalizedName: String)] = cast.compactMap { member in
            guard member.characterId != forbiddenCharacterID else { return nil }
            if let p = characterIndex[member.characterId] {
                return (member.characterId, p.visibleName, normalizedSpeakerName(p.visibleName))
            }
            return nil
        }
        let forbiddenNames = Set(
            [forbiddenCharacterName]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map(normalizedSpeakerName)
        )
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var out: [StoryMessage] = []
        var emittedCastLines = Set<String>()
        func makeMessage(author: StoryMessageAuthor, text: String) -> StoryMessage {
            StoryMessage(author: author, text: text, generationID: generationID)
        }
        for line in lines where !line.isEmpty {
            // 生成中のプレースホルダーを物語本文へ昇格させない。
            // これを通さないと「・・・」だけのキャラ発話が保存され、
            // 再試行のたびに同じ空バブルが増えてしまう。
            guard isMeaningfulStoryText(line) else { continue }
            // 日本語・英語どちらの生成ラベルも受け付ける。英語モードで
            // "Narration:" が出ても、本文をキャスト発話へ誤分類しない。
            let narrationPrefixes = [
                "ナレーション:", "ナレーション：", "ナレーター:", "ナレーター：",
                "Narration:", "Narration：", "Narrator:", "Narrator：",
                "Scene:", "Scene："
            ]
            let lowercasedLine = line.localizedLowercase
            if narrationPrefixes.contains(where: { lowercasedLine.hasPrefix($0.localizedLowercase) }) {
                let body = textAfterSpeakerDelimiter(line)
                if isMeaningfulStoryText(body) {
                    out.append(makeMessage(author: .narrator, text: body))
                }
                continue
            }
            let speakerLabel: String? = line.firstIndex(where: { $0 == ":" || $0 == "：" }).map {
                String(line[..<$0]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let explicitSpeakerID = speakerLabel.flatMap(explicitCharacterID)
            // ユーザー操作キャラの発話は表示しない。UUID付きの話者表記も
            // 名前だけの表記と同じく、ユーザーキャラを代弁した行は破棄する。
            if let explicitSpeakerID, explicitSpeakerID == forbiddenCharacterID {
                continue
            }
            if explicitSpeakerID == nil,
               let speakerLabel,
               forbiddenNames.contains(normalizedSpeakerName(speakerLabel)) {
                continue
            }

            // 新形式は「<character UUID> 名前: 本文」または
            // 「characterId=<character UUID> 名前: 本文」。名前が重複しても
            // UUIDを主キーにして解決し、名前の比較や辞書順にはフォールバックしない。
            if let explicitSpeakerID {
                guard let candidate = castNames.first(where: { $0.id == explicitSpeakerID }) else {
                    // 未知のUUIDは別キャラへ誤割り当てず、本文だけをナレーションとして
                    // 残す。生成結果を黙って消さず、かつ誤った吹き出しを作らない。
                    let body = textAfterSpeakerDelimiter(line)
                    if isMeaningfulStoryText(body) {
                        out.append(makeMessage(author: .narrator, text: body))
                    }
                    continue
                }
                let body = textAfterSpeakerDelimiter(line)
                guard isMeaningfulStoryText(body) else { continue }
                guard emittedCastLines.insert(candidate.id.uuidString + "|" + normalizedDuplicateText(body)).inserted else {
                    continue
                }
                out.append(makeMessage(author: .cast(characterId: candidate.id, displayName: candidate.name), text: body))
                continue
            }

            // 旧形式の「名前: 本文」は後方互換で受け付ける。ただし同名キャラが
            // いる場合は辞書の先頭へ暗黙に結び付けず、本文をナレーションにする。
            let normalizedSpeaker = speakerLabel.map(normalizedSpeakerName)
            let matchedCandidates = castNames.filter { _, _, normalizedName in
                guard let normalizedSpeaker, !normalizedSpeaker.isEmpty else { return false }
                return normalizedName == normalizedSpeaker
            }
            if matchedCandidates.count > 1 {
                let body = textAfterSpeakerDelimiter(line)
                if isMeaningfulStoryText(body) {
                    out.append(makeMessage(author: .narrator, text: body))
                }
                continue
            }
            if let (id, name, _) = matchedCandidates.first {
                let body = textAfterSpeakerDelimiter(line)
                guard isMeaningfulStoryText(body) else { continue }
                guard emittedCastLines.insert(id.uuidString + "|" + normalizedDuplicateText(body)).inserted else {
                    continue
                }
                out.append(makeMessage(author: .cast(characterId: id, displayName: name), text: body))
                continue
            }
            // フォールバック: 名前と紐付かない行はナレーション扱い
            out.append(makeMessage(author: .narrator, text: line))
        }
        return out
    }

    /// 生成モデルが同名キャラを区別するために付けるUUIDを、話者ラベルから読む。
    /// UUID単体（`<UUID> 名前`）と、明示キー（`characterId=<UUID> 名前`）の
    /// どちらも許容する。見つからない場合は名前だけの旧形式として扱う。
    private func explicitCharacterID(from label: String) -> UUID? {
        let trimCharacters = CharacterSet(charactersIn: "[]()<>\"'`,;")
        for rawToken in label.split(whereSeparator: { $0.isWhitespace }) {
            let token = String(rawToken).trimmingCharacters(in: trimCharacters)
            if let id = UUID(uuidString: token) {
                return id
            }
            for prefix in ["characterId=", "characterID=", "id=", "ID="] {
                guard token.hasPrefix(prefix) else { continue }
                let value = String(token.dropFirst(prefix.count)).trimmingCharacters(in: trimCharacters)
                if let id = UUID(uuidString: value) {
                    return id
                }
            }
        }
        return nil
    }

    /// 話者ラベルの比較をUnicode正規化＋case-insensitiveへ統一する。
    /// 生成モデルがKai/KAI/kaiのように表記を揺らしても同じキャストへ解決し、
    /// ユーザー操作キャラの代弁禁止判定も同じ規則で適用する。
    private func normalizedSpeakerName(_ value: String) -> String {
        StoryPromptBuilder.normalizedCharacterName(value)
    }

    private func normalizedDuplicateText(_ text: String) -> String {
        text
            .precomposedStringWithCanonicalMapping
            .localizedLowercase
            .split(whereSeparator: { $0.isWhitespace })
            .joined()
    }

    private func detectCurrentSpeakerName(in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let last = lines.last else { return nil }
        let narrationPrefixes = [
            "ナレーション:", "ナレーション：", "ナレーター:", "ナレーター：",
            "Narration:", "Narration：", "Narrator:", "Narrator：",
            "Scene:", "Scene："
        ]
        let lowercasedLast = last.localizedLowercase
        if narrationPrefixes.contains(where: { lowercasedLast.hasPrefix($0.localizedLowercase) }) {
            return KizunaCopy.text(japanese: "ナレーション", english: "Narration")
        }
        guard let idx = last.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return nil }
        let speaker = String(last[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !speaker.isEmpty else { return nil }
        guard explicitCharacterID(from: speaker) != nil else { return speaker }
        let trimCharacters = CharacterSet(charactersIn: "[]()<>\"'`,;")
        let displayName = speaker
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { token in
                let cleaned = token.trimmingCharacters(in: trimCharacters)
                if UUID(uuidString: cleaned) != nil { return false }
                for prefix in ["characterId=", "characterID=", "id=", "ID="] {
                    if cleaned.hasPrefix(prefix), UUID(uuidString: String(cleaned.dropFirst(prefix.count)).trimmingCharacters(in: trimCharacters)) != nil {
                        return false
                    }
                }
                return true
            }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return displayName.isEmpty ? speaker : displayName
    }

    private func textAfterSpeakerDelimiter(_ line: String) -> String {
        guard let idx = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else {
            return line.trimmingCharacters(in: .whitespaces)
        }
        return String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - helpers

    private func voiceOptimizedAdvancedSettings() -> GemmaAdvancedSettings {
        var s = GemmaAdvancedSettings.default
        s.allowToolUsage = false
        s.strictJSONToolCalls = false
        s.allowDirectAnswersWithoutTools = true
        s.requireSearchForFactualQueries = false
        s.requireExternalSourcesInDeepResearch = false
        s.maxToolRounds = 0
        s.maxSearchRounds = 0
        s.enabledTools = [:]
        s.useAutomaticTemperature = true
        return s
    }

    private func isGemma31BRuntimeNotice(_ reply: String?) -> Bool {
        guard let reply else { return true }
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.contains("Gemma4 31B API の応答に失敗しました")
            || text.contains("Gemma4 31B API failed to respond")
            || text.contains("Gemma4 APIキーが未設定")
            || text.contains("The Gemma4 API key is not set")
            || text.contains("Gemma4 31B API に失敗しました")
            || text.contains("Gemma4 31B API が空レスポンス")
            || text.contains("Gemma4 31B API returned an empty response")
            || text.contains("Gemma4 31B API の出力本文が空")
            || text.contains("Gemma4 31B API returned no response text")
            || text.contains("Gemma4 31B API returned no usable story text")
            || text.contains("Gemma4 31B API の出力が上限で途中終了")
            || text.contains("Gemma4 31B API output was truncated")
    }

    private func gemmaRuntimeNotice(for error: StoryGemma31BAPIError) -> String {
        switch error {
        case .missingAPIKey:
            return localizedNotice("Gemma4 APIキーが未設定です。NAGIのモデル詳細からAPIキーを設定してください。", "The Gemma4 API key is not set. Add it in NAGI's Model details.")
        case .emptyResponse:
            return localizedNotice("Gemma4 31B API が空レスポンスを返しました。もう一度試してください。", "Gemma4 31B API returned an empty response. Try again.")
        case .emptyText:
            return localizedNotice("Gemma4 31B API の出力本文が空でした。もう一度試してください。", "Gemma4 31B API returned no response text. Try again.")
        case let .truncated(reason):
            return localizedNotice(
                "Gemma4 31B APIの出力が上限((reason))で途中終了しました。本文は保存していません。続きを生成するか、出力上限を確認してください。",
                "Gemma4 31B API stopped at its output limit ((reason)). The incomplete response was not saved. Generate a continuation or review the output limit."
            )
        case .invalidURL, .httpStatus:
            return localizedNotice("Gemma4 31B API の応答に失敗しました。もう一度試してください。", "Gemma4 31B API failed to respond. Try again.")
        }
    }

    private func localStoryRuntimeUnavailableMessage(
        availability: LocalAssistantRuntimeAvailability,
        selectedModelURL: URL?
    ) -> String? {
        switch availability {
        case .executable:
            return selectedModelURL == nil
                ? "ローカルモデルの保存先を確認できません。モデル設定で保存状態を確認してください。"
                : nil
        case .checking:
            return localizedNotice("iori はまだ端末内で起動確認中です。確認が終わるまで、この場面のローカル生成は開始しません。", "iori is still being checked on this device. Local generation will start after the check finishes.")
        case .savedOnly:
            return localizedNotice("iori のモデルファイルは保存済みです。端末内の実行確認が自動で進行中です。", "iori is saved. The automatic on-device check is in progress.")
        case .recentFailure:
            return localizedNotice("iori のローカル実行を確認できませんでした。モデルメニューからNAGIへ切り替えられます。", "iori could not run on this device. Choose NAGI from the model menu to continue.")
        case .modelMissing:
            return localizedNotice("iori のローカルモデルが未導入です。モデルを保存すると端末内で自動確認します。", "The iori model is not installed. Save a model to start the automatic on-device check.")
        }
    }

    /// 保存直後のモデルは自動 self-check が進行中のため、会話側で即時失敗にしない。
    /// ただし生成ターンをself-check待ちで長時間占有しないよう、会話側の待機は
    /// 10秒で打ち切る。バックグラウンドの環境更新は継続し、次のターンで再試行できる。
    private func waitForLocalRuntime(
        manager: LocalAssistantModelManager,
        selectedModelURL: URL?,
        generationID: UUID
    ) async -> LocalAssistantRuntimeAvailability {
        // 起動直後は manager のURL復元も非同期なため、URLがまだnilでも
        // 一度だけ同期的な再確認入口を呼び、保存済みファイルを再発見させる。
        var didRequestRecheck = selectedModelURL == nil
        if didRequestRecheck {
            manager.recheckRuntimeAvailability()
        }
        var lastReportedSecond = -1
        for attempt in 0..<10 {
            guard isGenerationActive(generationID) else { return .recentFailure }
            let availability = manager.runtimeAvailability
            switch availability {
            case .executable, .recentFailure, .modelMissing:
                return availability
            case .savedOnly:
                // 自動確認がまだ起動していない古い状態でも、会話開始時に再確認を依頼する。
                if !didRequestRecheck {
                    didRequestRecheck = true
                    manager.recheckRuntimeAvailability()
                }
            case .checking:
                break
            }

            let elapsed = attempt + 1
            if elapsed != lastReportedSecond {
                lastReportedSecond = elapsed
                streamingStatusText = statusText("端末内モデルを確認中（\(elapsed)秒）", "Checking on-device model (\(elapsed)s)")
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return manager.runtimeAvailability
    }

    /// LiteRT-LMはsystem promptを1,250 UTF-8 bytesへ切り詰めるため、
    /// 再生成指示を先頭へ置き、指示そのものが消えないようにベースを後ろから短くする。
    private func localRetrySystemPrompt(base: String, instruction: String) -> String {
        let prefix = instruction + "\n\n"
        let remainingBytes = max(
            0,
            Self.localRuntimeSystemPromptLimit - prefix.lengthOfBytes(using: .utf8)
        )
        return prefix + utf8Prefix(base, byteLimit: remainingBytes)
    }

    private func utf8Prefix(_ value: String, byteLimit: Int) -> String {
        guard byteLimit > 0 else { return "" }
        guard value.lengthOfBytes(using: .utf8) > byteLimit else { return value }
        var result = ""
        var usedBytes = 0
        for character in value {
            let piece = String(character)
            let pieceBytes = piece.lengthOfBytes(using: .utf8)
            guard usedBytes + pieceBytes <= byteLimit else { break }
            result.append(contentsOf: piece)
            usedBytes += pieceBytes
        }
        return result
    }

    private func localStoryBackendStatusName(
        availability: LocalAssistantRuntimeAvailability,
        selectedModelURL: URL?
    ) -> String {
        switch availability {
        case .executable:
            if let selectedModelURL {
                return selectedModelURL.pathExtension.lowercased() == "litertlm"
                    ? "iori LiteRT-LM"
                    : "iori ローカル"
            }
            return localizedNotice("iori モデルパス不明", "iori model path unavailable")
        case .checking:
            return localizedNotice("iori 起動確認中", "iori check in progress")
        case .savedOnly:
            return localizedNotice("iori 保存済み・未起動", "iori saved · not started")
        case .recentFailure:
            return localizedNotice("iori 起動失敗", "iori failed to start")
        case .modelMissing:
            return localizedNotice("iori 未導入", "iori not installed")
        }
    }

    private func localStoryGenerationFailureMessage(runtimeError: String? = nil) -> String {
        if runtimeError?.contains("記号だけ") == true {
            return localizedNotice(
                "ローカルモデルが「…」のような記号だけを返しました。これは本文ではないため保存していません。もう一度試すか、NAGIで続けられます。",
                "The local model returned only symbols such as an ellipsis. It was not saved because it is not story text. Try again or continue with NAGI."
            )
        }
        return localizedNotice(
            "ローカルモデルが本文を生成できませんでした。会話は変更していません。もう一度試すか、NAGIで続けられます。",
            "The local model could not generate story text. The conversation was not changed. Try again or continue with NAGI."
        )
    }

    private func sanitize(_ text: String) -> String {
        var out = text
        for token in ["**", "__", "`", "*", "_"] {
            out = out.replacingOccurrences(of: token, with: "")
        }
        // <channel|> 等の thinking マーカー以前を捨てる
        let markers = ["<|channel|>", "<channel|>", "<|channel>", "<channel>"]
        var lastEnd: String.Index?
        for m in markers {
            if let r = out.range(of: m, options: .backwards) {
                if let cur = lastEnd { if r.upperBound > cur { lastEnd = r.upperBound } } else { lastEnd = r.upperBound }
            }
        }
        if let end = lastEnd { out = String(out[end...]) }
        // 余分な空行を圧縮
        while out.contains("\n\n") { out = out.replacingOccurrences(of: "\n\n", with: "\n") }
        return removeStoryMetaLeakage(from: out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // モデルが本文の後ろに混ぜる「User is...」「the prompt says...」等の
    // 内部自己解説を、UIへ渡す前に落とす。通常の英語台詞を一律削除しない。
    private func removeStoryMetaLeakage(from text: String) -> String {
        let markers = [
            "Wait, User", "User is", "I shouldn't", "I should not",
            "the prompt says", "Usually, I", "as the NPC", "active characters center",
            "assistant should", "system prompt", "内部", "思考過程", "自己解説"
        ]
        let cleanedLines = text.components(separatedBy: .newlines).compactMap { rawLine -> String? in
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            let lower = line.localizedLowercase
            guard let marker = markers.first(where: { lower.contains($0.localizedLowercase) }) else {
                return line
            }

            // 「台詞」(Wait, User...) の形なら、台詞だけを残す。
            if let parenthesis = line.firstIndex(where: { $0 == "(" || $0 == "（" }) {
                line = String(line[..<parenthesis]).trimmingCharacters(in: .whitespacesAndNewlines)
                return line.isEmpty ? nil : line
            }
            // 行全体がメタ文なら表示しない。
            _ = marker
            return nil
        }
        return cleanedLines.joined(separator: "\n")
    }

    /// 休憩アラートへ渡す本文を短く整形し、依存・強制につながる出力を捨てる。
    private func normalizeRestSuggestion(_ text: String?) -> String? {
        guard var value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if let firstLine = value.components(separatedBy: .newlines).first?.nonEmpty {
            value = firstLine
        }
        for prefix in [
            "休憩提案:", "休憩の提案:", "ナレーション:", "提案:",
            "Rest suggestion:", "Narration:", "Suggestion:"
        ] {
            if value.hasPrefix(prefix) {
                value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"『』「」*"))
        let forbiddenPhrases = [
            "必ず戻って", "戻ってきて", "待ってる", "待っています", "寂しい",
            "終わらせ", "終了して", "やめてはいけない", "離れないで",
            "come back", "i will wait", "I'll wait", "don't leave",
            "do not leave", "you must return", "don't stop", "do not stop"
        ]
        let comparisonValue = value.localizedLowercase
        guard !forbiddenPhrases.contains(where: { comparisonValue.contains($0.localizedLowercase) }) else { return nil }
        guard !value.isEmpty else { return nil }
        return String(value.prefix(120))
    }

    private func sanitizedFinalText(_ text: String) -> String {
        // 整形は記法の除去だけに留める。空・記号だけの応答を物語本文へ
        // 差し替えると、障害を隠したまま存在しない会話を保存してしまう。
        sanitize(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 話者ラベルや句読点を外した比較用テキスト。本文そのものはログへ出さない。
    private func normalizedStoryComparisonText(_ text: String) -> String {
        text.localizedLowercase.unicodeScalars
            .filter { scalar in
                scalar.properties.isAlphabetic || scalar.properties.numericType != nil
            }
            .map(String.init)
            .joined()
    }

    /// 直近の物語本文と同じ応答、または一つの応答内で同じ本文を繰り返す場合を検出する。
    /// 「うん」など極端に短い相づちは意図的な反復もあり得るため、4文字以上だけを比較する。
    private func isDuplicateStoryOutput(_ candidates: [StoryMessage], in session: StorySession) -> Bool {
        let candidateTexts = candidates
            .map { normalizedStoryComparisonText($0.text) }
            .filter { $0.count >= 4 }
        guard !candidateTexts.isEmpty else { return false }

        if Set(candidateTexts).count != candidateTexts.count {
            return true
        }

        let previousTexts = Set(
            storyContentMessages(from: session.messages)
                .suffix(12)
                .map { normalizedStoryComparisonText($0.text) }
                .filter { $0.count >= 4 }
        )
        guard !previousTexts.isEmpty else { return false }

        // ナレーションと台詞が揃って同じ場合は同一応答とみなす。
        // 1メッセージ構成のローカル応答も同じ判定で再生成する。
        if candidateTexts.allSatisfy({ previousTexts.contains($0) }) {
            return true
        }

        // 台詞が新しくても、ナレーションだけが直近と同じなら場面描写の反復である。
        let previousNarrations = Set(
            storyContentMessages(from: session.messages)
                .suffix(12)
                .filter { message in
                    if case .narrator = message.author { return true }
                    return false
                }
                .map { normalizedStoryComparisonText($0.text) }
                .filter { $0.count >= 4 }
        )
        return candidates.contains { message in
            guard case .narrator = message.author else { return false }
            let text = normalizedStoryComparisonText(message.text)
            return text.count >= 4 && previousNarrations.contains(text)
        }
    }

    private func isMeaningfulStoryText(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            scalar.properties.isAlphabetic || scalar.properties.numericType != nil
        }
    }

    /// Return references that became invalid while a Story turn was running.
    ///
    /// The generation task owns an in-memory snapshot. Character deletion is
    /// intentionally multi-file and can complete while that task is awaiting
    /// the model, so checking only the snapshot is not enough. Re-read both
    /// the Character Library and this world's cast immediately before the
    /// commit boundary. The deletion marker is checked as well, closing the
    /// short interval between recording deletion intent and removing the
    /// profile JSON.
    private func invalidCharacterReferencesBeforeCommit(
        session: StorySession,
        world: StoryWorld,
        scene: StoryScene,
        cast: [CastMember],
        additionalCharacterIDs: Set<UUID> = []
    ) async throws -> Set<UUID> {
        let currentCharacters = try await characterRepo.fetchCharacters()
        let currentCharacterIDs = Set(currentCharacters.map(\.id))
        let currentCast = try await castRepo.fetchCast(storyWorldId: world.id)
        let currentCastIDs = Set(currentCast.map(\.characterId))

        var profileReferences = Set(world.characterIds)
        if let mainCharacterID = world.mainCharacterId {
            profileReferences.insert(mainCharacterID)
        }
        profileReferences.formUnion(scene.activeCharacterIds)
        profileReferences.formUnion(session.activeCharacterIds ?? [])
        profileReferences.formUnion(session.storyState?.characterStates.compactMap(\.characterId) ?? [])
        profileReferences.formUnion(cast.map(\.characterId))
        profileReferences.formUnion(additionalCharacterIDs)

        var invalid = Set(profileReferences.filter {
            !currentCharacterIDs.contains($0)
                || CharacterDeletionCleanupMarker.shared.contains($0)
        })

        // References that participate in this turn must still belong to the
        // current world's cast. World.characterIds is intentionally excluded
        // from this check because old worlds may contain a profile that has
        // not yet been added to the cast table.
        var castReferences = Set(scene.activeCharacterIds)
        castReferences.formUnion(session.activeCharacterIds ?? [])
        castReferences.formUnion(session.storyState?.characterStates.compactMap(\.characterId) ?? [])
        castReferences.formUnion(cast.map(\.characterId))
        castReferences.formUnion(additionalCharacterIDs)
        invalid.formUnion(castReferences.filter { !currentCastIDs.contains($0) })
        return invalid
    }

    // CharacterProfile は既存データ互換のため専用フラグを持たない。
    // 「自分自身 / 本人」または主人公表記を優先してユーザー操作キャラを推定する。
    private func userControlledCharacterID(
        world: StoryWorld,
        cast: [CastMember],
        characterIndex: [UUID: CharacterProfile]
    ) -> UUID? {
        func isUserProfile(_ profile: CharacterProfile, castMember: CastMember?) -> Bool {
            if castMember?.isUserControlled == true {
                return true
            }
            let values = [
                profile.visibleName,
                profile.name,
                profile.relationshipToUser,
                castMember?.relationshipToUser ?? ""
            ]
            // 旧データ互換のため、関係文全体が単独の既知マーカーの場合だけ採用する。
            // 「ユーザーを見つけたNPC」のような自然文をcontainsで拾うと、NPCを
            // ユーザー操作キャラとして誤って除外してしまう。
            let markers = Set(["自分自身", "本人", "ユーザー", "user", "主人公", "protagonist"])
            return values.contains { value in
                markers.contains(value.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase)
            }
        }

        if let mainID = world.mainCharacterId,
           let profile = characterIndex[mainID],
           let member = cast.first(where: { $0.characterId == mainID }),
           isUserProfile(profile, castMember: member) {
            return mainID
        }

        return cast.first { member in
            guard let profile = characterIndex[member.characterId] else { return false }
            return isUserProfile(profile, castMember: member)
        }?.characterId
    }

    private func defaultCastMembers(for world: StoryWorld, scene: StoryScene) -> [CastMember] {
        let activeIDs = Set(scene.activeCharacterIds.isEmpty ? Array(world.characterIds.prefix(StoryConstants.maxActiveCharacters)) : scene.activeCharacterIds)
        return world.characterIds.enumerated().map { index, characterID in
            CastMember(
                storyWorldId: world.id,
                characterId: characterID,
                roleInStory: characterID == world.mainCharacterId || index == 0 ? .main : .secondary,
                importance: characterID == world.mainCharacterId || index == 0 ? 1.0 : 0.65,
                introductionTiming: activeIDs.contains(characterID) ? .opening : .early,
                relationshipToUser: "",
                isActiveInCurrentScene: activeIDs.contains(characterID)
            )
        }
    }

    private func reconciledCast(
        _ existing: [CastMember],
        for world: StoryWorld,
        scene: StoryScene
    ) -> [CastMember] {
        guard !world.characterIds.isEmpty else { return [] }
        let defaults = defaultCastMembers(for: world, scene: scene)
        let existingByCharacterID = existing.reduce(into: [UUID: CastMember]()) { result, member in
            if result[member.characterId] == nil { result[member.characterId] = member }
        }
        return defaults.map { existingByCharacterID[$0.characterId] ?? $0 }
    }

    private func parseProgressUpdate(_ text: String) -> StoryProgressUpdate? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates: [String] = {
            if let start = trimmed.firstIndex(of: "{"),
               let end = trimmed.lastIndex(of: "}"),
               start <= end {
                return [String(trimmed[start...end]), trimmed]
            }
            return [trimmed]
        }()
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let update = try? progressDecoder.decode(StoryProgressUpdate.self, from: data) else {
                continue
            }
            return update
        }
        return nil
    }

    /// Extract the optional state delta emitted at the end of a model turn.
    /// It is deliberately kept out of the visible story transcript: the model
    /// writes one compact `STATE_UPDATE: {JSON}` line only when a durable state
    /// change occurred, and the parser removes that line before speaker parsing.
    private func parseStateMetadata(
        from text: String
    ) -> (visibleText: String, patch: StoryStatePatch?) {
        switch StoryStateMetadataParser.parse(text) {
        case .absent(let visibleText), .invalid(let visibleText):
            return (visibleText, nil)
        case .valid(let visibleText, let payload):
            let patch = try? progressDecoder.decode(StoryStatePatch.self, from: payload)
            return (visibleText, patch)
        }
    }

    private func normalizedHooks(_ hooks: [String]?, fallback: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func push(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            out.append(String(trimmed.prefix(80)))
        }
        (hooks ?? []).forEach(push)
        fallback.forEach(push)
        return Array(out.prefix(4))
    }

    private func synthesizeTurnProgress(from messages: [StoryMessage]) -> String? {
        let line = messages.reversed().map(messageLine).first { !$0.isEmpty }
        guard let line else { return nil }
        return String(line.prefix(48))
    }

    private func messageLine(_ message: StoryMessage) -> String {
        let userLabel = KizunaCopy.text(japanese: "ユーザー", english: "User")
        let narrationLabel = KizunaCopy.text(japanese: "ナレーション", english: "Narration")
        switch message.author {
        case .user:
            return "\(userLabel): \(message.text)"
        case .system:
            return ""
        case .narrator:
            return "\(narrationLabel): \(message.text)"
        case let .cast(_, displayName):
            return "\(displayName): \(message.text)"
        }
    }

    static func unresolvedHooks(
        world: StoryWorld,
        scene: StoryScene,
        previous: [String]?,
        storyState: StoryState? = nil
    ) -> [String] {
        var hooks: [String] = []
        var seen = Set<String>()
        func push(_ value: String?) {
            let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            hooks.append(trimmed)
        }
        let activeGoals = Set(
            (storyState?.activeGoals ?? []).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        )
        let seedGoals = Set(
            [scene.sceneGoal, world.storyGoal].map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
        )
        previous?.forEach { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if storyState != nil,
               seedGoals.contains(trimmed),
               !activeGoals.contains(trimmed) {
                return
            }
            push(trimmed)
        }
        push(scene.conflict)
        func pushSeedGoal(_ goal: String) {
            let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            // Once StoryState exists, an empty activeGoals array is an
            // explicit resolution. Do not reintroduce the catalog's initial
            // goal as an unresolved hook on the next turn.
            guard storyState == nil || activeGoals.contains(trimmed) else { return }
            push(trimmed)
        }
        pushSeedGoal(scene.sceneGoal)
        pushSeedGoal(world.storyGoal)
        if !world.openingScene.isEmpty, hooks.count < 6 {
            push("オープニングの出来事: \(world.openingScene)")
        }
        return Array(hooks.prefix(8))
    }

    private func statusText(_ japanese: String, _ english: String) -> String {
        KizunaCopy.text(japanese: japanese, english: english)
    }

    private func localizedNotice(_ japanese: String, _ english: String) -> String {
        KizunaCopy.text(japanese: japanese, english: english)
    }

    // MARK: - Scene helpers (UI からも使う)

    func suggestNextScenes(world: StoryWorld, completedScene: StoryScene) async -> [NextSceneSuggestion] {
        let cast = (try? await castRepo.fetchCast(storyWorldId: world.id)) ?? []
        return await nextScene.suggestNext(world: world, completedScene: completedScene, cast: cast)
    }
}

private extension StoryMessage {
    var speakerDisplayName: String? {
        switch author {
        case .user:
            return "あなた"
        case .system:
            return "システム"
        case .narrator:
            return "ナレーション"
        case let .cast(_, displayName):
            return displayName
        }
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
