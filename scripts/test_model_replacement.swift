import Foundation

@main
struct LocalAssistantModelReplacementTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kizuna-model-replacement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try testRollbackRestoresExistingModel(in: directory)
        try testRollbackRemovesFirstInstall(in: directory)
        try testFinishKeepsValidatedCandidate(in: directory)
        print("Model replacement tests passed")
    }

    private static func testRollbackRestoresExistingModel(in directory: URL) throws {
        let destination = directory.appendingPathComponent("rollback.gguf")
        let candidate = directory.appendingPathComponent("rollback.candidate.gguf")
        try Data("old model".utf8).write(to: destination)
        try Data("new model".utf8).write(to: candidate)

        let transaction = try LocalAssistantModelReplacement.begin(
            candidateURL: candidate,
            destinationURL: destination,
            backupURL: LocalAssistantModelReplacement.backupURL(for: destination)
        )
        try expectContents(of: destination, equalTo: "new model")

        // Simulate a failure after the swap but before state completion.
        try LocalAssistantModelReplacement.rollback(transaction)
        try expectContents(of: destination, equalTo: "old model")
        if let backupURL = transaction.backupURL,
           FileManager.default.fileExists(atPath: backupURL.path) {
            throw TestFailure.backupWasNotConsumed
        }
    }

    private static func testRollbackRemovesFirstInstall(in directory: URL) throws {
        let destination = directory.appendingPathComponent("first-install.gguf")
        let candidate = directory.appendingPathComponent("first-install.candidate.gguf")
        try Data("new model".utf8).write(to: candidate)

        let transaction = try LocalAssistantModelReplacement.begin(
            candidateURL: candidate,
            destinationURL: destination,
            backupURL: nil
        )
        try LocalAssistantModelReplacement.rollback(transaction)
        if FileManager.default.fileExists(atPath: destination.path) {
            throw TestFailure.firstInstallWasNotRolledBack
        }
    }

    private static func testFinishKeepsValidatedCandidate(in directory: URL) throws {
        let destination = directory.appendingPathComponent("complete.gguf")
        let candidate = directory.appendingPathComponent("complete.candidate.gguf")
        try Data("old model".utf8).write(to: destination)
        try Data("new model".utf8).write(to: candidate)

        let transaction = try LocalAssistantModelReplacement.begin(
            candidateURL: candidate,
            destinationURL: destination,
            backupURL: LocalAssistantModelReplacement.backupURL(for: destination)
        )
        try LocalAssistantModelReplacement.finish(transaction)
        try expectContents(of: destination, equalTo: "new model")
        if let backupURL = transaction.backupURL,
           FileManager.default.fileExists(atPath: backupURL.path) {
            throw TestFailure.backupWasNotRemoved
        }
    }

    private static func expectContents(of url: URL, equalTo expected: String) throws {
        let actual = try String(contentsOf: url, encoding: .utf8)
        guard actual == expected else {
            throw TestFailure.unexpectedContents(actual)
        }
    }

    private enum TestFailure: Error {
        case backupWasNotConsumed
        case firstInstallWasNotRolledBack
        case backupWasNotRemoved
        case unexpectedContents(String)
    }
}
