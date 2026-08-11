import Foundation

/// Performs the final file swap only after a candidate has passed validation.
/// The transaction deliberately keeps the previous artifact until the caller
/// has persisted the completed model state, so a post-swap failure can recover
/// the model that was active before the download began.
enum LocalAssistantModelReplacement {
    enum ReplacementError: LocalizedError {
        case candidateMissing
        case backupPathRequired
        case backupAlreadyExists
        case backupMissingDuringRollback

        nonisolated var errorDescription: String? {
            switch self {
            case .candidateMissing:
                return "置換候補のモデルファイルが見つかりません。"
            case .backupPathRequired:
                return "既存モデルを置換するための復旧先を準備できません。"
            case .backupAlreadyExists:
                return "既存モデルの復旧先がすでに使われています。"
            case .backupMissingDuringRollback:
                return "既存モデルの復旧コピーが見つかりません。"
            }
        }
    }

    struct Transaction {
        let destinationURL: URL
        let backupURL: URL?
    }

    nonisolated static func backupURL(for destinationURL: URL) -> URL {
        destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).rollback-\(UUID().uuidString)")
    }

    nonisolated static func begin(
        candidateURL: URL,
        destinationURL: URL,
        backupURL: URL?,
        fileManager: FileManager = .default
    ) throws -> Transaction {
        guard fileManager.fileExists(atPath: candidateURL.path) else {
            throw ReplacementError.candidateMissing
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            guard let backupURL else {
                throw ReplacementError.backupPathRequired
            }
            guard !fileManager.fileExists(atPath: backupURL.path) else {
                throw ReplacementError.backupAlreadyExists
            }
            // `replaceItemAt` does not retain its backup on all supported
            // APFS volumes. The candidate is already staged in this same
            // directory, so two renames give us a durable, named rollback
            // copy and keep both steps on the same filesystem.
            try fileManager.moveItem(at: destinationURL, to: backupURL)
            do {
                try fileManager.moveItem(at: candidateURL, to: destinationURL)
            } catch {
                try? fileManager.moveItem(at: backupURL, to: destinationURL)
                throw error
            }
            return Transaction(destinationURL: destinationURL, backupURL: backupURL)
        }

        try fileManager.moveItem(at: candidateURL, to: destinationURL)
        return Transaction(destinationURL: destinationURL, backupURL: nil)
    }

    nonisolated static func rollback(
        _ transaction: Transaction,
        fileManager: FileManager = .default
    ) throws {
        guard let backupURL = transaction.backupURL else {
            if fileManager.fileExists(atPath: transaction.destinationURL.path) {
                try fileManager.removeItem(at: transaction.destinationURL)
            }
            return
        }

        guard fileManager.fileExists(atPath: backupURL.path) else {
            throw ReplacementError.backupMissingDuringRollback
        }
        if fileManager.fileExists(atPath: transaction.destinationURL.path) {
            try fileManager.removeItem(at: transaction.destinationURL)
        }
        try fileManager.moveItem(at: backupURL, to: transaction.destinationURL)
    }

    nonisolated static func finish(
        _ transaction: Transaction,
        fileManager: FileManager = .default
    ) throws {
        guard let backupURL = transaction.backupURL,
              fileManager.fileExists(atPath: backupURL.path) else {
            return
        }
        try fileManager.removeItem(at: backupURL)
    }
}
