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

    nonisolated private static let migrationMarker = "kizuna.migration.viuk-one.v1"
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
        guard !fileManager.fileExists(atPath: characterLibraryURL.path) else { return true }

        let legacyURL = characterLibraryURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CharacterLibrary", isDirectory: true)

        let parentURL = characterLibraryURL.deletingLastPathComponent()
        let stagingURL = parentURL.appendingPathComponent(".CharacterLibrary.migrating", isDirectory: true)

        do {
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: stagingURL.path) {
                try fileManager.removeItem(at: stagingURL)
            }
            if fileManager.fileExists(atPath: legacyURL.path) {
                try fileManager.copyItem(at: legacyURL, to: stagingURL)
                try fileManager.moveItem(at: stagingURL, to: characterLibraryURL)
            } else {
                try fileManager.createDirectory(at: characterLibraryURL, withIntermediateDirectories: true)
            }
            return true
        } catch {
            return false
        }
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
