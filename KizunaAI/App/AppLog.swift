/*
仕様:
- 役割: NSLog の置き換え用ロガー。os.Logger へ出力し、動的な値を含む
  メッセージは既定でマスクする（GHSA-74pg-vrq9-372g）。
- 主な型: `AppLog`.
- 編集ポイント: ログレベルの運用やカテゴリ分割を変えるときに触る。
*/
import Foundation
import os

enum AppLog {
    private static let logger = Logger(subsystem: AppBrand.bundleIdentifier, category: "app")

    /// 整形後のメッセージをマスク付きで出力する。会話内容・パス・エラー詳細など
    /// 機微情報を含み得る動的値を既定で保護するため、静的な診断文も
    /// あわせてマスクされる。Console.app で利用者が確認する場合は
    /// 「機密データを表示」で復号できる。
    private static func formatted(_ format: String, _ args: [CVarArg]) -> String {
        args.isEmpty ? format : String(format: format, arguments: args)
    }

    /// NSLog互換のprintf書式（info相当）。
    static func note(_ format: String, _ args: CVarArg...) {
        let message = formatted(format, args)
        logger.info("\(message, privacy: .private)")
    }

    /// NSLog互換のprintf書式（error相当）。
    static func error(_ format: String, _ args: CVarArg...) {
        let message = formatted(format, args)
        logger.error("\(message, privacy: .private)")
    }
}
