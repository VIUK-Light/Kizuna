/*
仕様:
- 役割: アプリ名、タグライン、Keychainサービス名などブランド定数を一元管理する。
- 主な型: `AppBrand`.
- 編集ポイント: 表示名やブランド文言、旧ブランドからの移行情報を変えるときに触る。
*/
import Foundation

enum AppBrand {
    static let displayName = "VIUK 絆"
    static let keychainService = "VIUKKizunaAI"
    static let legacyKeychainServices: [String] = []
}
