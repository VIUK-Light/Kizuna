/*
仕様:
- 役割: 安全性判定を担うコンポーネントの Protocol 群。
  本実装は Mock。将来 Gemma 3 270M 接続版へ差し替える。
- 主な型: CharacterSafetyChecking, InputSafetyChecking, OutputSafetyChecking.
*/

import Foundation

protocol CharacterSafetyChecking: AnyObject {
    /// キャラ作成・編集時に呼ばれ、設定全体の安全性を判定する。
    func evaluate(_ character: CharacterProfile) async -> SafetyDecision
}

protocol InputSafetyChecking: AnyObject {
    /// ユーザー入力に対する安全性判定。block/soften/warn の判断を返す。
    func evaluate(_ text: String, character: CharacterProfile) async -> SafetyDecision
}

protocol OutputSafetyChecking: AnyObject {
    /// AI 出力に対する安全性判定。
    func evaluate(_ text: String, character: CharacterProfile) async -> SafetyDecision
}
