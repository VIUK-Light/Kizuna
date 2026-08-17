import Foundation

/// Kizuna の画面用コピーを、保存データや AI 用プロンプトの文言から分離する。
/// UserDefaults の値は AppStorage と同じキーを使うため、設定画面を閉じた後も
/// 次の再描画でただちに反映される。
enum KizunaCopy {
    static var language: KizunaLanguage {
        KizunaLanguage(rawValue: UserDefaults.standard.string(forKey: "kizuna.language") ?? "")
            ?? .japanese
    }

    static func text(japanese: String, english: String) -> String {
        language == .english ? english : japanese
    }

    /// 英語で単複形が分かれる文言のためのヘルパー (#287)。
    /// 日本語は単複で変わらないため count を受け取るだけで表示に使わない。
    static func pluralText(
        japanese: String,
        englishSingular: String,
        englishPlural: String,
        count: Int
    ) -> String {
        guard language == .english else { return japanese }
        return count == 1 ? englishSingular : englishPlural
    }

    /// アプリ名はブランド正本 `AppBrand.displayName` を参照し、言語を問わず "Kizuna" に統一する。
    static var appName: String {
        AppBrand.displayName
    }
}

/// Shared UserDefaults/AppStorage keys. Keeping launch state in one place
/// prevents Settings, My Page, and the root gate from drifting apart.
enum KizunaStorageKeys {
    static let launchCompleted = "kizuna.launch.completed"
    /// The selected workspace tab is presentation state, not conversation data.
    /// Keeping it under a namespaced key lets the standard TabView restore the
    /// user's last destination without touching any saved Persona/Story records.
    static let workspaceSection = "kizuna.workspace.section"
}
