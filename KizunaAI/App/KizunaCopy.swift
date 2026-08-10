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

    static var appName: String {
        text(japanese: "kizuna", english: "kizuna")
    }
}

/// Shared UserDefaults/AppStorage keys. Keeping launch state in one place
/// prevents Settings, My Page, and the root gate from drifting apart.
enum KizunaStorageKeys {
    static let launchCompleted = "kizuna.launch.completed"
}
