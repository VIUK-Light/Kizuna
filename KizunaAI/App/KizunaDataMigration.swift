import Foundation

enum KizunaDataMigration {
    nonisolated private static let applicationSupportURL: URL = {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return support
    }()

    nonisolated static let characterLibraryURL: URL = {
        applicationSupportURL
            .appendingPathComponent("VIUK", isDirectory: true)
            .appendingPathComponent("KizunaAI", isDirectory: true)
            .appendingPathComponent("CharacterLibrary", isDirectory: true)
    }()

    nonisolated static let localModelsURL: URL = {
        applicationSupportURL
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

    nonisolated static func performIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationMarker) else { return }

        let didMigrateCharacters = migrateCharacterLibraryIfAvailable()
        let didMigrateModels = migrateLocalModelsIfAvailable()
        migratePersonaDefaultsIfAvailable(into: defaults)
        if didMigrateCharacters && didMigrateModels {
            defaults.set(true, forKey: migrationMarker)
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
                guard isUsableDataFile(source), !isUsableDataFile(destination) else { continue }

                // 空ファイルまたは未作成のファイルだけを補完する。非空ファイルは
                // 壊れていても上書きせず、loadRecoveringCorruptRecords()へ委ねる。
                let data = try Data(contentsOf: source)
                try data.write(to: destination, options: [.atomic])
                NSLog("[KizunaDataMigration] restored %@ from legacy CharacterLibrary", fileName)
            }
            return true
        } catch {
            NSLog("[KizunaDataMigration] character library migration failed: %@", String(describing: error))
            return false
        }
    }

    nonisolated private static func isUsableDataFile(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        // JSONの空配列は数バイトなので、空の保存先として扱う。
        return size.intValue > 2
    }

    @discardableResult
    nonisolated private static func migrateLocalModelsIfAvailable() -> Bool {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: localModelsURL.path) else { return true }

        let legacyURL = applicationSupportURL
            .appendingPathComponent("VIUK One", isDirectory: true)
            .appendingPathComponent("LocalModels", isDirectory: true)
        let parentURL = localModelsURL.deletingLastPathComponent()
        let stagingURL = parentURL.appendingPathComponent(".LocalModels.migrating", isDirectory: true)

        do {
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: stagingURL.path) {
                try fileManager.removeItem(at: stagingURL)
            }
            if fileManager.fileExists(atPath: legacyURL.path) {
                try fileManager.copyItem(at: legacyURL, to: stagingURL)
                try fileManager.moveItem(at: stagingURL, to: localModelsURL)
            } else {
                try fileManager.createDirectory(at: localModelsURL, withIntermediateDirectories: true)
            }
            return true
        } catch {
            return false
        }
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
