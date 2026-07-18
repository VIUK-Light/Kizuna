/*
仕様:
- 役割: 3 つの安全 Protocol を統合した薄い Facade。
  キャラ作成/入力/出力の 3 経路で同じインタフェースで安全判定を呼べるようにする。
- 主な型: `SafetyPipeline`.
- 編集ポイント: 実装を Mock から本物 (Gemma 3 270M) に差し替える時、init のデフォルト値を変える。
*/

import Foundation

final class SafetyPipeline {
    private let characterChecker: CharacterSafetyChecking
    private let inputChecker: InputSafetyChecking
    private let outputChecker: OutputSafetyChecking

    init(
        characterChecker: CharacterSafetyChecking = MockCharacterSafetyChecker(),
        inputChecker: InputSafetyChecking = MockInputSafetyChecker(),
        outputChecker: OutputSafetyChecking = MockOutputSafetyChecker()
    ) {
        self.characterChecker = characterChecker
        self.inputChecker = inputChecker
        self.outputChecker = outputChecker
    }

    func evaluateCharacter(_ c: CharacterProfile) async -> SafetyDecision {
        await characterChecker.evaluate(c)
    }
    func evaluateInput(_ text: String, character: CharacterProfile) async -> SafetyDecision {
        await inputChecker.evaluate(text, character: character)
    }
    func evaluateOutput(_ text: String, character: CharacterProfile) async -> SafetyDecision {
        await outputChecker.evaluate(text, character: character)
    }

    /// 単一のデフォルトインスタンス (DI 不要なシンプルな呼び出し用)。
    static let shared = SafetyPipeline()
}
