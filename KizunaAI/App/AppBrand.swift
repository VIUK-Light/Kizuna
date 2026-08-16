/*
仕様:
- 役割: アプリ名、バンドル名、タグライン、Keychainサービス名などブランド定数を一元管理する。
- 主な型: `AppBrand`.
- 編集ポイント: 表示名やブランド文言、旧ブランドからの移行情報を変えるときに触る。

  ブランド正本（source of truth）:
  - `displayName` … アプリ内 UI とバンドルの表示名（CFBundleDisplayName）で共通して使う。
  - `bundleName` … バンドル名（CFBundleName / PRODUCT_NAME）。.app のファイル名と一致させる。
  - `bundleIdentifier` … バンドル識別子（PRODUCT_BUNDLE_IDENTIFIER）。一度公開したら変えない。
  project.yml 側の CFBundleDisplayName / CFBundleName / PRODUCT_BUNDLE_IDENTIFIER は
  この enum の値と一致させること。表示名の言語切り替えは KizunaCopy.appName 経由で
  AppBrand.displayName を参照する（日本語・英語とも "Kizuna"）。
*/
import Foundation

enum AppBrand {
    static let displayName = "Kizuna"
    static let bundleName = "KizunaAI"
    static let bundleIdentifier = "com.viuk.KizunaAI"
    static let keychainService = "VIUKKizunaAI"
    static let legacyKeychainServices: [String] = []
}
