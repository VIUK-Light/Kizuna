/*
仕様:
- 役割: iOS / iPadOS ビルドで macOS 専用ローカル runtime 型を参照可能にする無効スタブ。
- 制約: 実行機能は提供しない。macOS では Foundation.Process と ObjC runtime をそのまま使う。
*/

import Foundation

#if !os(macOS)
final class Process {
    var executableURL: URL?
    var arguments: [String]?
    var qualityOfService: QualityOfService = .default
    var standardOutput: Any?
    var standardError: Any?
    var standardInput: Any?
    var terminationHandler: ((Process) -> Void)?
    private(set) var isRunning: Bool = false
    private(set) var terminationStatus: Int32 = -1
    let processIdentifier: Int32 = 0

    func run() throws {
        throw CocoaError(.featureUnsupported)
    }

    func terminate() {
        isRunning = false
        terminationHandler?(self)
    }

    func interrupt() {
        terminate()
    }

    func waitUntilExit() {}
}

struct VIUKEmbeddedRuntimeResult: Sendable {
    let success: Bool
    let text: String?
    let errorMessage: String?

    nonisolated init(success: Bool, text: String?, errorMessage: String?) {
        self.success = success
        self.text = text
        self.errorMessage = errorMessage
    }
}

final class VIUKEmbeddedRuntime {
    static func shared() -> VIUKEmbeddedRuntime {
        VIUKEmbeddedRuntime()
    }

    func performSelfCheck(withModelPath modelPath: String, maxTokens: Int) -> VIUKEmbeddedRuntimeResult {
        VIUKEmbeddedRuntimeResult(success: false, text: nil, errorMessage: "このプラットフォームでは埋め込み runtime を使えません。")
    }

    func generate(
        withPrompt prompt: String,
        modelPath: String,
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        topK: Int,
        seed: UInt32
    ) -> VIUKEmbeddedRuntimeResult {
        VIUKEmbeddedRuntimeResult(success: false, text: nil, errorMessage: "このプラットフォームでは埋め込み runtime を使えません。")
    }

    func clearCachedModel() {}
}
#endif
