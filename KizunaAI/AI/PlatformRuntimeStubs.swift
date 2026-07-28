/*
仕様:
- 役割: macOS以外でFoundation.Processを参照可能にする最小スタブ。
- iOSの埋め込みAI runtimeはObjCブリッジ側を実際に使うため、runtime型の偽スタブは置かない。
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

#endif
