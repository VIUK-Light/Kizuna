import Foundation
import Combine

enum KizunaConversationPreference: String, Codable, CaseIterable, Identifiable {
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
    var about: String = ""
    var avatarSymbol: String = "🙂"
    var conversationPreference: KizunaConversationPreference = .balanced

    var visibleName: String {
        let preferred = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preferred.isEmpty { return preferred }
        let fallback = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback
    }

    var hasUsefulContent: Bool {
        !visibleName.isEmpty || !about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// AIへ渡すのは利用者が入力した任意項目だけ。Keychainや会話本文はここへ混ぜない。
    var promptText: String {
        let name = visibleName
        let aboutText = about.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty || !aboutText.isEmpty else { return "" }

        var lines: [String] = []
        let nameLabel = KizunaCopy.text(japanese: "名前または呼び名", english: "Name or nickname")
        let noteLabel = KizunaCopy.text(japanese: "本人が共有したメモ", english: "User-shared note")
        let preferenceLabel = KizunaCopy.text(japanese: "会話の希望", english: "Conversation preference")
        if !name.isEmpty { lines.append("\(nameLabel): \(name.prefix(60))") }
        if !aboutText.isEmpty { lines.append("\(noteLabel): \(aboutText.prefix(500))") }
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
