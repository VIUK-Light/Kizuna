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

/// 初回設定で選ぶ「物語の入口」。細かい世界観を最初から入力させず、
/// 一覧のおすすめとAIの雰囲気だけに反映する軽い好みとして保存する。
enum KizunaStoryPreference: String, Codable, CaseIterable, Identifiable, Hashable {
    case everyday
    case mystery
    case fantasy
    case future

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .everyday:
            return KizunaCopy.text(japanese: "日常と青春", english: "Everyday & coming-of-age")
        case .mystery:
            return KizunaCopy.text(japanese: "謎解きと秘密", english: "Mystery & secrets")
        case .fantasy:
            return KizunaCopy.text(japanese: "幻想と冒険", english: "Fantasy & adventure")
        case .future:
            return KizunaCopy.text(japanese: "未来とSF", english: "Future & sci-fi")
        }
    }

    var detail: String {
        switch self {
        case .everyday:
            return KizunaCopy.text(japanese: "放課後、喫茶店、静かな会話", english: "After school, cafés, and quiet conversations")
        case .mystery:
            return KizunaCopy.text(japanese: "違和感を拾い、少しずつ真相へ", english: "Follow small clues toward the truth")
        case .fantasy:
            return KizunaCopy.text(japanese: "魔法、異世界、まだ見ぬ場所", english: "Magic, other worlds, and places unknown")
        case .future:
            return KizunaCopy.text(japanese: "遠い未来、AI、宇宙の物語", english: "Distant futures, AI, and space")
        }
    }

    var iconName: String {
        switch self {
        case .everyday: return "sun.max.fill"
        case .mystery: return "magnifyingglass"
        case .fantasy: return "wand.and.stars"
        case .future: return "sparkles"
        }
    }

    var promptHint: String {
        switch self {
        case .everyday:
            return KizunaCopy.text(japanese: "日常と青春の空気を好む。", english: "Prefers an everyday, coming-of-age atmosphere.")
        case .mystery:
            return KizunaCopy.text(japanese: "謎や秘密を少しずつ解いていく空気を好む。", english: "Prefers a story that reveals mysteries and secrets gradually.")
        case .fantasy:
            return KizunaCopy.text(japanese: "幻想的な世界や冒険の空気を好む。", english: "Prefers a fantastical world with a sense of adventure.")
        case .future:
            return KizunaCopy.text(japanese: "未来やSFの設定を味わう空気を好む。", english: "Prefers a future-facing, science-fiction atmosphere.")
        }
    }
}

struct KizunaUserProfile: Codable, Equatable {
    var displayName: String = ""
    var nickname: String = ""
    var about: String = ""
    // SF Symbol名を保存する。旧バージョンの絵文字値は KizunaAvatarView が後方互換で表示する。
    var avatarSymbol: String = KizunaAvatarCatalog.defaultID
    var conversationPreference: KizunaConversationPreference = .balanced
    var storyPreference: KizunaStoryPreference = .everyday

    private enum CodingKeys: String, CodingKey {
        case displayName
        case nickname
        case about
        case avatarSymbol
        case conversationPreference
        case storyPreference
    }

    init() {}

    // storyPreference追加前の保存データも壊さず読み込む。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        nickname = try container.decodeIfPresent(String.self, forKey: .nickname) ?? ""
        about = try container.decodeIfPresent(String.self, forKey: .about) ?? ""
        avatarSymbol = try container.decodeIfPresent(String.self, forKey: .avatarSymbol) ?? KizunaAvatarCatalog.defaultID
        conversationPreference = try container.decodeIfPresent(KizunaConversationPreference.self, forKey: .conversationPreference) ?? .balanced
        storyPreference = try container.decodeIfPresent(KizunaStoryPreference.self, forKey: .storyPreference) ?? .everyday
    }

    var visibleName: String {
        let preferred = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preferred.isEmpty { return preferred }
        let fallback = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback
    }

    var hasUsefulContent: Bool {
        !visibleName.isEmpty
            || !about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || conversationPreference != .balanced
            || storyPreference != .everyday
    }

    /// AIへ渡すのは利用者が入力した任意項目だけ。Keychainや会話本文はここへ混ぜない。
    var promptText: String {
        let name = visibleName
        let aboutText = about.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty
            || !aboutText.isEmpty
            || conversationPreference != .balanced
            || storyPreference != .everyday
        else { return "" }

        var lines: [String] = []
        let nameLabel = KizunaCopy.text(japanese: "名前または呼び名", english: "Name or nickname")
        let noteLabel = KizunaCopy.text(japanese: "本人が共有したメモ", english: "User-shared note")
        let preferenceLabel = KizunaCopy.text(japanese: "会話の希望", english: "Conversation preference")
        let storyLabel = KizunaCopy.text(japanese: "物語の入口", english: "Story preference")
        if !name.isEmpty { lines.append("\(nameLabel): \(name.prefix(60))") }
        if !aboutText.isEmpty { lines.append("\(noteLabel): \(aboutText.prefix(500))") }
        lines.append("\(preferenceLabel): \(conversationPreference.promptHint)")
        if storyPreference != .everyday {
            lines.append("\(storyLabel): \(storyPreference.promptHint)")
        }
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
        normalized.about = String(normalized.about.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        profile = normalized
        persist()
        primeBridge()
    }

    func reset() {
        profile = KizunaUserProfile()
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
