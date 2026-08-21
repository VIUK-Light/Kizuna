import Foundation
import Combine

enum KizunaConversationPreference: String, Codable, CaseIterable, Identifiable, Hashable {
    case short
    case balanced
    case detailed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .short:
            return KizunaCopy.text(japanese: "短め", english: "Short")
        case .balanced:
            return KizunaCopy.text(japanese: "標準", english: "Balanced")
        case .detailed:
            return KizunaCopy.text(japanese: "少し詳しく", english: "Detailed")
        }
    }

    var promptHint: String {
        switch self {
        case .short:
            return KizunaCopy.text(
                japanese: "返答は要点を短くまとめる。",
                english: "Keep replies concise and focused."
            )
        case .balanced:
            return KizunaCopy.text(
                japanese: "自然な長さで、必要なら補足する。",
                english: "Use a natural length and add context when useful."
            )
        case .detailed:
            return KizunaCopy.text(
                japanese: "急いで結論だけにせず、必要な背景も説明する。",
                english: "Explain useful context instead of giving only a bare conclusion."
            )
        }
    }
}

struct KizunaUserProfile: Codable, Equatable {
    var displayName: String = ""
    var nickname: String = ""
    // SF Symbol名を保存する。旧バージョンの絵文字値は KizunaAvatarView が後方互換で表示する。
    var avatarSymbol: String = KizunaAvatarCatalog.defaultID
    var avatarImageData: Data?
    var conversationPreference: KizunaConversationPreference = .balanced

    private enum CodingKeys: String, CodingKey {
        case displayName
        case nickname
        case avatarSymbol
        case avatarImageData
        case conversationPreference
    }

    init() {}

    // 旧保存データに残っている削除済みの項目は無視して読み込む。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        nickname = try container.decodeIfPresent(String.self, forKey: .nickname) ?? ""
        avatarSymbol = try container.decodeIfPresent(String.self, forKey: .avatarSymbol) ?? KizunaAvatarCatalog.defaultID
        let storedImageData = try container.decodeIfPresent(Data.self, forKey: .avatarImageData)
        avatarImageData = KizunaAvatarImage.normalizedStoredData(from: storedImageData)
        conversationPreference = try container.decodeIfPresent(KizunaConversationPreference.self, forKey: .conversationPreference) ?? .balanced
    }

    var visibleName: String {
        let preferred = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preferred.isEmpty { return preferred }
        let fallback = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback
    }

    var hasUsefulContent: Bool {
        !visibleName.isEmpty
            || avatarImageData != nil
            || (KizunaAvatarCatalog.option(for: avatarSymbol) != nil
                && avatarSymbol != KizunaAvatarCatalog.defaultID)
            || conversationPreference != .balanced
    }

    /// AIへ渡すのは利用者が設定した名前と会話の長さだけ。画像データや
    /// 画面上の選択肢、年齢Tierはプロンプトへ混ぜない。年齢Tierは
    /// SafetyPipeline内で抽象化されたpolicy ruleへ変換する。
    var promptText: String {
        let name = visibleName
        guard !name.isEmpty
            || conversationPreference != .balanced
        else { return "" }

        var lines: [String] = []
        let nameLabel = KizunaCopy.text(japanese: "名前または呼び名", english: "Name or nickname")
        let preferenceLabel = KizunaCopy.text(japanese: "会話の希望", english: "Conversation preference")
        if !name.isEmpty { lines.append("\(nameLabel): \(name.prefix(60))") }
        lines.append("\(preferenceLabel): \(conversationPreference.promptHint)")
        return lines.joined(separator: "\n")
    }
}

@MainActor
final class KizunaUserProfileStore: ObservableObject {
    static let shared = KizunaUserProfileStore()

    @Published private(set) var profile: KizunaUserProfile

    private let defaults: UserDefaults
    private let storageKey = "kizuna.userProfile.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(KizunaUserProfile.self, from: data) {
            self.profile = decoded
        } else {
            self.profile = KizunaUserProfile()
        }
    }

    func update(_ value: KizunaUserProfile) {
        var normalized = value
        normalized.displayName = String(normalized.displayName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        normalized.nickname = String(normalized.nickname.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        normalized.avatarImageData = KizunaAvatarImage.normalizedStoredData(from: normalized.avatarImageData)
        profile = normalized
        persist()
        primeBridge()
    }

    func reset() {
        profile = KizunaUserProfile()
        UserAgeSafetyStore.shared.reset()
        persist()
        primeBridge()
    }

    func primeBridge() {
        LocalAssistantRuntimeBridge.userProfileAddendum = profile.promptText
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
