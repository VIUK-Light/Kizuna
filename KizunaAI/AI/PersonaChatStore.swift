/*
仕様:
- 役割: ペルソナモード専用のスレッド・メッセージ履歴をローカル永続化する。
  AICoachService の既存スレッドとは完全分離し、AI Studio の他モードに影響を与えない。
- 主な型: `PersonaChatStore` (ObservableObject), `PersonaThread`, `PersonaMessage`.
- 編集ポイント: 永続化キー、スレッド削除/リネーム、件数上限を変えるときに触る。
- データ保存: UserDefaults に Codable JSON で保存。シングルトン。
*/

import Foundation
import Combine

enum PersonaThreadOrdering {
    /// Keep the store's published order consistent with the order used by the
    /// conversation home: most recently active threads first.
    static func mostRecentFirst(_ threads: [PersonaThread]) -> [PersonaThread] {
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

struct PersonaMessage: Codable, Hashable, Identifiable {
    enum Role: String, Codable { case user, assistant, narrator }

    var id: UUID
    var role: Role
    var text: String
    var createdAt: Date

    init(id: UUID = UUID(), role: Role, text: String, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

struct PersonaThread: Codable, Hashable, Identifiable {
    var id: UUID
    /// スレッド作成時の PersonaProfile スナップショット。会話途中で persona 設定を変えても
    /// このスレッドは固定された人格で続けられるようにする。
    var personaSnapshot: PersonaProfile
    /// キャラライブラリー由来の場合に紐付く CharacterProfile.id。
    /// nil の場合は旧 PersonaSettings 経由のスレッド。
    var characterID: UUID?
    var title: String
    var messages: [PersonaMessage]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        personaSnapshot: PersonaProfile,
        characterID: UUID? = nil,
        title: String,
        messages: [PersonaMessage] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.personaSnapshot = personaSnapshot
        self.characterID = characterID
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // Codable: 既存保存データに characterID が無くてもデコード可能にする
    private enum CodingKeys: String, CodingKey {
        case id, personaSnapshot, characterID, title, messages, createdAt, updatedAt
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.personaSnapshot = try c.decode(PersonaProfile.self, forKey: .personaSnapshot)
        self.characterID = try c.decodeIfPresent(UUID.self, forKey: .characterID)
        self.title = try c.decode(String.self, forKey: .title)
        self.messages = try c.decode([PersonaMessage].self, forKey: .messages)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}

enum PersonaChatRecoveryError: LocalizedError {
    case noCorruptPersistedValue
    case unsupportedPersistedValue

    var errorDescription: String? {
        switch self {
        case .noCorruptPersistedValue:
            return "復旧対象の保存データが見つかりません。"
        case .unsupportedPersistedValue:
            return "保存データをバックアップ形式へ変換できません。"
        }
    }
}

@MainActor
final class PersonaChatStore: ObservableObject {
    static let shared = PersonaChatStore(defaults: UserDefaults.standard)

    private let defaults: UserDefaults
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
    @Published private(set) var activeThreadID: UUID? {
        didSet {
            guard !didFailToLoadPersistedThreads else {
                NSLog("[PersonaChatStore] skipped active thread write while recovery is required")
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
        return threads.first { $0.id == id }
    }

    func thread(id: UUID) -> PersonaThread? {
        threads.first { $0.id == id }
    }

    /// テストや復旧画面が保存先を明示できる初期化経路。
    /// 本番は `shared` から同じUserDefaults.standardを使う。
    init(defaults: UserDefaults) {
        self.defaults = defaults
        load()
        guard !didFailToLoadPersistedThreads else {
            NSLog("[PersonaChatStore] thread data was not decoded; preserving the source file")
            return
        }
        // 起動時に「空メッセージのスレッド」を 1 件残して残りを掃除する。
        // (バグや誤操作で同じキャラの空スレッドが大量に残るのを防ぐ)
        var seenEmptyPersonaKeys = Set<String>()
        threads.removeAll { thread in
            guard thread.messages.isEmpty else { return false }
            // 名前だけでまとめると、同名だが別UUIDのキャラを削除してしまう。
            // キャラ由来はcharacterID、旧ペルソナはprofile UUIDで識別する。
            let key = thread.characterID.map { "character:\($0.uuidString)" }
                ?? "persona:\(thread.personaSnapshot.id.uuidString)"
            if seenEmptyPersonaKeys.insert(key).inserted {
                return false   // 各キャラで最初の 1 件は残す
            }
            return true        // 2 件目以降は削除
        }
        persist()
        if let saved = defaults.string(forKey: Key.activeThreadID),
           let uuid = UUID(uuidString: saved),
           threads.contains(where: { $0.id == uuid }) {
            self.activeThreadID = uuid
        }
    }

    private func load() {
        guard defaults.object(forKey: Key.threads) != nil else {
            return
        }
        guard let data = defaults.data(forKey: Key.threads) else {
            didFailToLoadPersistedThreads = true
            NSLog("[PersonaChatStore] saved thread value is not a Data blob")
            return
        }
        do {
            let decoded = try JSONDecoder().decode([PersonaThread].self, from: data)
            self.threads = PersonaThreadOrdering.mostRecentFirst(decoded)
        } catch {
            didFailToLoadPersistedThreads = true
            NSLog("[PersonaChatStore] failed to decode saved threads: %@", error.localizedDescription)
        }
    }

    private func persist() {
        guard !didFailToLoadPersistedThreads else {
            NSLog("[PersonaChatStore] skipped thread persist while recovery is required")
            return
        }
        if let data = try? JSONEncoder().encode(threads) {
            defaults.set(data, forKey: Key.threads)
        }
    }

    /// 壊れた保存データを破棄する唯一の明示的な復旧操作。
    /// 先にraw値をバックアップキーへ移し、確認済みの呼び出し元だけが
    /// 空状態として保存を再開できるようにする。
    @discardableResult
    func discardCorruptPersistedThreads() -> Bool {
        guard didFailToLoadPersistedThreads else { return false }
        if let rawValue = defaults.object(forKey: Key.threads) {
            defaults.set(rawValue, forKey: Key.corruptThreadsBackup)
        }
        defaults.removeObject(forKey: Key.threads)
        defaults.removeObject(forKey: Key.activeThreadID)
        didFailToLoadPersistedThreads = false
        threads = []
        activeThreadID = nil
        persist()
        return true
    }

    var isPersistenceRecoveryRequired: Bool {
        didFailToLoadPersistedThreads
    }

    /// 破損した保存値を、明示的な共有・保存操作へ渡せる一時ファイルへ書き出す。
    /// Data と String は保存されていた値をそのままバイト列として扱い、
    /// その他の UserDefaults のプロパティリスト値も内容を失わない形式で保存する。
    /// この操作は保存値を変更せず、復旧が必要な状態でのみ実行できる。
    func exportCorruptPersistedThreads() throws -> URL {
        guard didFailToLoadPersistedThreads,
              let rawValue = defaults.object(forKey: Key.threads) else {
            throw PersonaChatRecoveryError.noCorruptPersistedValue
        }

        let data: Data
        let fileExtension: String
        if let rawData = rawValue as? Data {
            data = rawData
            fileExtension = "bin"
        } else if let rawString = rawValue as? String {
            data = Data(rawString.utf8)
            fileExtension = "txt"
        } else if PropertyListSerialization.propertyList(
            rawValue,
            isValidFor: .binary
        ) {
            data = try PropertyListSerialization.data(
                fromPropertyList: rawValue,
                format: .binary,
                options: 0
            )
            fileExtension = "plist"
        } else {
            throw PersonaChatRecoveryError.unsupportedPersistedValue
        }

        let fileName = "Kizuna-Persona-Recovery-\(UUID().uuidString).\(fileExtension)"
        let exportURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try data.write(to: exportURL, options: .atomic)
        return exportURL
    }

    /// 破損した保存値を自動的に空状態で上書きしないための共通ガード。
    /// 復旧操作以外の公開ミューテーションは、メモリ上の状態も変更しない。
    private func canMutatePersistedState() -> Bool {
        guard !didFailToLoadPersistedThreads else {
            NSLog("[PersonaChatStore] skipped mutation while recovery is required")
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
                && $0.messages.isEmpty
        }) {
            // An empty thread is only a reusable draft. Refresh its snapshot
            // before returning it so edits made in Character Library are
            // reflected in the chat header, avatar style, and future prompt.
            // Once a message exists, the snapshot remains immutable for the
            // lifetime of that conversation.
            if let index = threads.firstIndex(where: { $0.id == existing.id }) {
                threads[index].personaSnapshot = persona
                threads[index].title = persona.name
                threads[index].updatedAt = Date()
                threads.sort { $0.updatedAt > $1.updatedAt }
                persist()
            }
            activeThreadID = existing.id
            return threads.first(where: { $0.id == existing.id }) ?? existing
        }
        let thread = PersonaThread(
            personaSnapshot: persona,
            characterID: characterID,
            title: persona.name
        )
        threads.insert(thread, at: 0)
        activeThreadID = thread.id
        persist()
        return thread
    }

    func selectThread(id: UUID) {
        guard canMutatePersistedState() else { return }
        guard threads.contains(where: { $0.id == id }) else { return }
        activeThreadID = id
    }

    /// キャラ本体が削除されても、会話スナップショットは残して再開できるようにする。
    func detachCharacterReference(threadID: UUID) {
        guard canMutatePersistedState() else { return }
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
        guard threads[index].characterID != nil else { return }
        threads[index].characterID = nil
        threads[index].updatedAt = Date()
        persist()
    }

    /// キャラクター本体を削除した後に、関連する全Personaスレッドを
    /// 保存済みの `personaSnapshot` へ切り替える。会話本文はそのまま残し、
    /// 次回送信時に削除済みUUIDを再取得し続けないよう参照だけを切り離す。
    func detachCharacterReferences(for characterID: UUID) {
        guard canMutatePersistedState() else { return }
        var didChange = false
        for index in threads.indices where threads[index].characterID == characterID {
            threads[index].characterID = nil
            didChange = true
        }
        guard didChange else { return }
        // Detaching a deleted profile is metadata maintenance, not a new
        // conversation event. Keep each thread's updatedAt and existing order
        // so deleting a character cannot reshuffle the user's history.
        persist()
    }

    func deleteThread(id: UUID) {
        guard canMutatePersistedState() else { return }
        threads.removeAll { $0.id == id }
        if activeThreadID == id {
            activeThreadID = threads.first?.id
        }
        persist()
    }

    func renameThread(id: UUID, title: String) {
        guard canMutatePersistedState() else { return }
        guard let idx = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[idx].title = title
        threads[idx].updatedAt = Date()
        // ソートし直し
        persistAfterActivityUpdate()
    }

    // MARK: - Messages

    func appendMessage(_ message: PersonaMessage, toThread threadID: UUID) {
        guard canMutatePersistedState() else { return }
        guard let idx = threads.firstIndex(where: { $0.id == threadID }) else { return }
        threads[idx].messages.append(message)
        threads[idx].updatedAt = Date()
        // 最新スレッドを先頭に
        let updated = threads.remove(at: idx)
        threads.insert(updated, at: 0)
        persist()
    }

    /// アシスタント応答のストリーミング途中で「最新メッセージのテキスト」を上書きする用。
    func updateLastAssistantMessage(in threadID: UUID, text: String) {
        guard canMutatePersistedState() else { return }
        guard let threadIdx = threads.firstIndex(where: { $0.id == threadID }) else { return }
        guard let lastIdx = threads[threadIdx].messages.lastIndex(where: { $0.role == .assistant }) else { return }
        threads[threadIdx].messages[lastIdx].text = text
        threads[threadIdx].updatedAt = Date()
        // ストリーミング毎の persist は重いので、ここでは保存しない。最終 finalize 側で persist する。
    }

    /// Commit the final assistant text and activity order as one MainActor
    /// operation. Streaming updates use `updateLastAssistantMessage` so this
    /// sort/persist work happens only once per completed turn.
    @discardableResult
    func finalizeLastAssistantMessage(in threadID: UUID, text: String) -> Bool {
        guard let threadIdx = threads.firstIndex(where: { $0.id == threadID }) else { return false }
        guard let lastIdx = threads[threadIdx].messages.lastIndex(where: { $0.role == .assistant }) else { return false }
        threads[threadIdx].messages[lastIdx].text = text
        threads[threadIdx].updatedAt = Date()
        persistAfterActivityUpdate()
        return true
    }

    /// 生成開始直後に作った空のアシスタント枠を、ユーザーが停止した時だけ取り除く。
    /// 部分応答がある場合は呼び出し側がその本文を保存するため、ここでは削除しない。
    func removePendingAssistantMessage(in threadID: UUID) {
        guard canMutatePersistedState() else { return }
        guard let threadIdx = threads.firstIndex(where: { $0.id == threadID }) else { return }
        guard let last = threads[threadIdx].messages.last,
              last.role == .assistant,
              isPendingAssistantText(last.text) else { return }
        threads[threadIdx].messages.removeLast()
        threads[threadIdx].updatedAt = Date()
        persistAfterActivityUpdate()
    }

    /// 失敗確定時に、ストリーミング途中の本文を履歴へ残さないための削除。
    func removeLastAssistantMessage(in threadID: UUID) {
        guard canMutatePersistedState() else { return }
        guard let threadIdx = threads.firstIndex(where: { $0.id == threadID }),
              threads[threadIdx].messages.last?.role == .assistant else { return }
        threads[threadIdx].messages.removeLast()
        threads[threadIdx].updatedAt = Date()
        persistAfterActivityUpdate()
    }

    /// 失敗したターンを再送する前に、直前のユーザー発話だけを取り除く。
    /// アシスタント側の空枠は `removePendingAssistantMessage` で先に処理する。
    func removeLastUserMessage(in threadID: UUID, matching text: String? = nil) {
        guard canMutatePersistedState() else { return }
        guard let threadIdx = threads.firstIndex(where: { $0.id == threadID }),
              let last = threads[threadIdx].messages.last,
              last.role == .user else { return }
        if let text, last.text != text { return }
        threads[threadIdx].messages.removeLast()
        threads[threadIdx].updatedAt = Date()
        persistAfterActivityUpdate()
    }

    func finalizePersist() {
        guard canMutatePersistedState() else { return }
        // Keep non-assistant final saves (for example narration) consistent
        // with the same activity-order invariant.
        persistAfterActivityUpdate()
    }

    private func persistAfterActivityUpdate() {
        threads = PersonaThreadOrdering.mostRecentFirst(threads)
        persist()
    }

    private func isPendingAssistantText(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty || ["…", "・・・", "・・", "...", "..", "."].contains(normalized)
    }
}
