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

@MainActor
final class PersonaChatStore: ObservableObject {
    static let shared = PersonaChatStore()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let threads = "persona.threads.v1"
        static let activeThreadID = "persona.activeThreadID.v1"
    }

    /// 新しい順 (updatedAt 降順) でソートして保持。
    @Published private(set) var threads: [PersonaThread] = []
    @Published var activeThreadID: UUID? {
        didSet {
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

    private init() {
        load()
        // 起動時に「空メッセージのスレッド」を 1 件残して残りを掃除する。
        // (バグや誤操作で同じキャラの空スレッドが大量に残るのを防ぐ)
        var seenEmptyPersonaNames = Set<String>()
        threads.removeAll { thread in
            guard thread.messages.isEmpty else { return false }
            if seenEmptyPersonaNames.insert(thread.personaSnapshot.name).inserted {
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
        guard let data = defaults.data(forKey: Key.threads),
              let decoded = try? JSONDecoder().decode([PersonaThread].self, from: data) else {
            return
        }
        self.threads = decoded.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(threads) {
            defaults.set(data, forKey: Key.threads)
        }
    }

    // MARK: - Thread CRUD

    /// 新しい会話スレッドを作る。ただし、既に「同じキャラ・空メッセージのスレッド」が
    /// 存在する場合はそれを再利用してアクティブ化する (空スレッドの量産防止)。
    @discardableResult
    func createThread(with persona: PersonaProfile, characterID: UUID? = nil) -> PersonaThread {
        if let existing = threads.first(where: {
            $0.personaSnapshot.name == persona.name
                && $0.characterID == characterID
                && $0.messages.isEmpty
        }) {
            activeThreadID = existing.id
            return existing
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
        guard threads.contains(where: { $0.id == id }) else { return }
        activeThreadID = id
    }

    func deleteThread(id: UUID) {
        threads.removeAll { $0.id == id }
        if activeThreadID == id {
            activeThreadID = threads.first?.id
        }
        persist()
    }

    func renameThread(id: UUID, title: String) {
        guard let idx = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[idx].title = title
        threads[idx].updatedAt = Date()
        // ソートし直し
        threads.sort { $0.updatedAt > $1.updatedAt }
        persist()
    }

    // MARK: - Messages

    func appendMessage(_ message: PersonaMessage, toThread threadID: UUID) {
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
        guard let threadIdx = threads.firstIndex(where: { $0.id == threadID }) else { return }
        guard let lastIdx = threads[threadIdx].messages.lastIndex(where: { $0.role == .assistant }) else { return }
        threads[threadIdx].messages[lastIdx].text = text
        threads[threadIdx].updatedAt = Date()
        // ストリーミング毎の persist は重いので、ここでは保存しない。最終 finalize 側で persist する。
    }

    func finalizePersist() {
        persist()
    }
}
