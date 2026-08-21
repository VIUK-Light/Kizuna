import Foundation

/// WindowGroupの複数シーンから同時に呼ばれても、移行先とステージングを
/// 共有したまま操作しないためのプロセス内ロック。移行は同一プロセスの
/// ファイル操作なので、actorをまたぐ非同期処理ではなく短い同期区間で直列化する。
private final class KizunaDataMigrationLock: @unchecked Sendable {
    private let lock = NSLock()

    // SwiftLint's required_deinit rule asks synchronization helpers to make
    // their lifetime explicit. NSLock has no extra teardown work here.
    deinit {}

    nonisolated func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

enum KizunaDataMigration {
    nonisolated private static let migrationLock = KizunaDataMigrationLock()

    /// A temporary directory is never a valid persistence fallback. If the
    /// system cannot provide Application Support, the migration gate must
    /// stop before any repository can create data.
    nonisolated private static let applicationSupportURL: URL? = {
#if DEBUG || KIZUNA_INTERNAL_CANARY
        if let acceptanceRoot = ProcessInfo.processInfo.environment["KIZUNA_ACCEPTANCE_STORAGE_ROOT"],
           !acceptanceRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: acceptanceRoot, isDirectory: true)
        }
#endif
        return try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }()

    /// This is only a non-writable sentinel for APIs that still require a
    /// non-optional URL. The launch gate refuses to enter the workspace while
    /// this sentinel is active, so user data cannot be written there.
    nonisolated private static let unavailableStorageURL = URL(fileURLWithPath: "/dev/null", isDirectory: true)

    nonisolated static var isStorageAvailable: Bool {
        applicationSupportURL != nil
    }

    nonisolated static let characterLibraryURL: URL = {
        guard let applicationSupportURL else { return unavailableStorageURL }
        return applicationSupportURL
            .appendingPathComponent("VIUK", isDirectory: true)
            .appendingPathComponent("KizunaAI", isDirectory: true)
            .appendingPathComponent("CharacterLibrary", isDirectory: true)
    }()

    nonisolated static let localModelsURL: URL = {
        guard let applicationSupportURL else { return unavailableStorageURL }
        return applicationSupportURL
            .appendingPathComponent("VIUK", isDirectory: true)
            .appendingPathComponent("KizunaAI", isDirectory: true)
            .appendingPathComponent("LocalModels", isDirectory: true)
    }()

    // v2 は、v1で「ディレクトリが存在するだけ」の移行先を有効と判定して
    // しまったMacを一度だけ再確認する。既存ファイルを上書きしないため、
    // すでにKizuna側で作成されたデータは保持される。
    nonisolated private static let migrationMarker = "kizuna.migration.viuk-one.v2"
    nonisolated private static let personaKeys = [
        "persona.threads.v1",
        "persona.activeThreadID.v1",
        "persona.activeProfile.v1"
    ]
    nonisolated private static let legacyBundleIdentifiers = [
        "viuk-12",
        "com.viuk.safeKidsSearch",
        "com.viuk.VIUKOne",
        "VIUK-app.SafeKids-Search3-1"
    ]

    @discardableResult
    nonisolated static func performIfNeeded() -> Bool {
        migrationLock.withLock {
            guard isStorageAvailable else {
                AppLog.error("[KizunaDataMigration] Application Support URL is unavailable")
                return false
            }
            let defaults = UserDefaults.standard
            guard !defaults.bool(forKey: migrationMarker) else { return true }

            let didMigrateCharacters = migrateCharacterLibraryIfAvailable()
            let didMigrateModels = migrateLocalModelsIfAvailable()
            migratePersonaDefaultsIfAvailable(into: defaults)
            if didMigrateCharacters && didMigrateModels {
                defaults.set(true, forKey: migrationMarker)
            }
            return didMigrateCharacters && didMigrateModels
        }
    }

    @discardableResult
    nonisolated private static func migrateCharacterLibraryIfAvailable() -> Bool {
        let fileManager = FileManager.default
        let legacyURL = characterLibraryURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CharacterLibrary", isDirectory: true)

        do {
            try fileManager.createDirectory(at: characterLibraryURL, withIntermediateDirectories: true)
            guard fileManager.fileExists(atPath: legacyURL.path) else { return true }

            let fileNames = [
                "characters.json", "lorebooks.json", "memories.json", "reports.json", "templates.json",
                "story_cast.json", "story_lorebook.json", "story_memories.json", "story_scenes.json",
                "story_sessions.json", "story_worlds.json"
            ]
            for fileName in fileNames {
                let source = legacyURL.appendingPathComponent(fileName)
                let destination = characterLibraryURL.appendingPathComponent(fileName)
                switch dataFileState(source) {
                case .missing:
                    continue
                case .invalid:
                    // 壊れた旧ファイルを有効な移行元として扱わない。内容を
                    // 推測して上書きせず、次回起動でも再確認できるよう失敗を返す。
                    AppLog.error("[KizunaDataMigration] legacy file is invalid JSON: %@", source.path)
                    return false
                case .validArray:
                    break
                }

                switch dataFileState(destination) {
                case .validArray:
                    // 空配列を含む有効なJSON配列は、ユーザーが現在使っている
                    // 保存先として扱い、旧データで上書きしない。
                    continue
                case .missing:
                    break
                case .invalid:
                    // 既存の壊れた保存先を置き換える場合でも、元ファイルを
                    // 同じディレクトリへ退避してから原子的に復元する。
                    let backupURL = invalidBackupURL(for: destination)
                    try fileManager.copyItem(at: destination, to: backupURL)
                    try LocalJSONStoreFileProtection.apply(to: backupURL)
                    AppLog.error("[KizunaDataMigration] backed up invalid destination %@ to %@", fileName, backupURL.lastPathComponent)
                }

                let data = try Data(contentsOf: source)
                try data.write(to: destination, options: LocalJSONStoreFileProtection.atomicWriteOptions)
                try LocalJSONStoreFileProtection.apply(to: destination)
                AppLog.note("[KizunaDataMigration] restored %@ from legacy CharacterLibrary", fileName)
            }
            return true
        } catch {
            AppLog.error("[KizunaDataMigration] character library migration failed: %@", String(describing: error))
            return false
        }
    }

    private enum DataFileState {
        case missing
        case validArray
        case invalid
    }

    nonisolated private static func dataFileState(_ url: URL) -> DataFileState {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              object is [Any] else {
            return .invalid
        }
        return .validArray
    }

    nonisolated private static func invalidBackupURL(for url: URL) -> URL {
        url.deletingPathExtension()
            .appendingPathExtension("invalid-\(UUID().uuidString).json")
    }

    @discardableResult
    nonisolated private static func migrateLocalModelsIfAvailable() -> Bool {
        let fileManager = FileManager.default
        guard let applicationSupportURL else { return false }
        let legacyURL = applicationSupportURL
            .appendingPathComponent("VIUK One", isDirectory: true)
            .appendingPathComponent("LocalModels", isDirectory: true)
        let parentURL = localModelsURL.deletingLastPathComponent()
        let stagingURL = parentURL.appendingPathComponent(".LocalModels.migrating", isDirectory: true)

        do {
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
            // 旧保存先を先に調べる。新しい保存先にすでにモデルがあっても、
            // 旧保存先にもモデルがあればマージし、片方だけを見て早期終了しない。
            // mergeModelDirectoryContents は既存ファイルを保持し、衝突時は
            // 移行サフィックスを付けるため、再実行でも上書きしない。
            let destinationHasArtifact = containsModelArtifact(in: localModelsURL)
            let legacyHasArtifact = fileManager.fileExists(atPath: legacyURL.path)
                && containsModelArtifact(in: legacyURL)
            guard legacyHasArtifact else {
                // 空の旧ディレクトリやキャンセル途中のメタデータだけでは
                // 移行完了とみなさない。ただし既存の有効な保存先は保持する。
                if !destinationHasArtifact {
                    try fileManager.createDirectory(at: localModelsURL, withIntermediateDirectories: true)
                }
                return true
            }

            // Stage the complete legacy tree before touching the destination. A
            // failed copy leaves no migration marker and can be retried safely.
            if fileManager.fileExists(atPath: stagingURL.path) {
                try fileManager.removeItem(at: stagingURL)
            }
            try fileManager.copyItem(at: legacyURL, to: stagingURL)
            try fileManager.createDirectory(at: localModelsURL, withIntermediateDirectories: true)
            try mergeModelDirectoryContents(from: stagingURL, to: localModelsURL)
            try fileManager.removeItem(at: stagingURL)

            // Verify the post-merge destination, not merely the directory.
            return containsModelArtifact(in: localModelsURL)
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            AppLog.error("[KizunaDataMigration] local model migration failed: %@", String(describing: error))
            return false
        }
    }

    /// Model files are the only evidence that a LocalModels tree is useful.
    /// JSON state, resume data, and empty folders must not make migration look
    /// complete. Keep this list aligned with LocalAssistantModelManager's
    /// accepted local formats without depending on its instance state.
    nonisolated private static let modelFileExtensions: Set<String> = ["gguf", "bin", "litertlm"]
    nonisolated private static let minimumModelArtifactSize: Int64 = 50 * 1024 * 1024

    nonisolated private static func containsModelArtifact(in directoryURL: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return false
        }

        for case let candidateURL as URL in enumerator {
            guard isModelArtifact(candidateURL) else { continue }
            return true
        }
        return false
    }

    nonisolated private static func isModelArtifact(_ url: URL) -> Bool {
        let extensionName = url.pathExtension.lowercased()
        guard modelFileExtensions.contains(extensionName) else { return false }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              Int64(fileSize) >= minimumModelArtifactSize else {
            return false
        }
        return true
    }

    /// Merge a staged legacy tree without overwriting files already created by
    /// Kizuna. A differing filename collision gets a deterministic-looking
    /// migration suffix while retaining the original extension so a model file
    /// remains discoverable by the runtime.
    nonisolated private static func mergeModelDirectoryContents(from sourceURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: sourceURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        for case let sourceFileURL as URL in enumerator {
            let values = try sourceFileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }

            let relativePath = String(sourceFileURL.path.dropFirst(sourceURL.path.count).drop(while: { $0 == "/" }))
            guard !relativePath.isEmpty else { continue }
            let destinationFileURL = destinationURL.appendingPathComponent(relativePath)
            try fileManager.createDirectory(
                at: destinationFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            if !fileManager.fileExists(atPath: destinationFileURL.path) {
                try fileManager.copyItem(at: sourceFileURL, to: destinationFileURL)
                continue
            }

            // Preserve an existing destination file. If it is byte-identical,
            // no second copy is needed; otherwise retain both copies.
            if fileManager.contentsEqual(atPath: sourceFileURL.path, andPath: destinationFileURL.path) {
                continue
            }
            let collisionURL = migrationCollisionURL(for: destinationFileURL)
            try fileManager.copyItem(at: sourceFileURL, to: collisionURL)
        }
    }

    nonisolated private static func migrationCollisionURL(for url: URL) -> URL {
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let fileName = ext.isEmpty
            ? "\(stem).migrated-\(UUID().uuidString)"
            : "\(stem).migrated-\(UUID().uuidString).\(ext)"
        return url.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    nonisolated private static func migratePersonaDefaultsIfAvailable(into defaults: UserDefaults) {
        for key in personaKeys where defaults.object(forKey: key) == nil {
            for bundleIdentifier in legacyBundleIdentifiers {
                guard let value = defaults.persistentDomain(forName: bundleIdentifier)?[key] else { continue }
                defaults.set(value, forKey: key)
                break
            }
        }

        for bundleIdentifier in legacyBundleIdentifiers {
            guard let domain = defaults.persistentDomain(forName: bundleIdentifier) else { continue }
            for (key, value) in domain where key.hasPrefix("storySessionGenerationModel.") {
                if defaults.object(forKey: key) == nil {
                    defaults.set(value, forKey: key)
                }
            }
        }
    }
}
