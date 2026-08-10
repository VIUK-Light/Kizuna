import Foundation

/// Kizuna内だけで使う表示言語。端末全体の言語設定は変更しない。
enum KizunaLanguage: String, CaseIterable, Identifiable {
    case japanese = "ja"
    case english = "en"

    var id: String { rawValue }

    var locale: Locale {
        Locale(identifier: rawValue)
    }

    var displayName: String {
        switch self {
        case .japanese: return KizunaCopy.text(japanese: "日本語", english: "Japanese")
        case .english: return KizunaCopy.text(japanese: "英語", english: "English")
        }
    }
}
