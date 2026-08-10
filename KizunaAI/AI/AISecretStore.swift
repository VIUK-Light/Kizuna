/*
仕様:
- 役割: 絆AIの秘密情報をKeychainにだけ保存する。
- 制約: 平文JSONやUserDefaultsを正本として使わない。
- 参照順: Keychain -> 実行環境変数 -> 秘密を含まないInfo.plist設定。
*/
import Foundation

final class AISecretStore {
    static let shared = AISecretStore()

    enum SecretKey: String {
        case geminiAPIKey = "ai.secret.gemini.apiKey"
        case gemmaWebReaderAPIKey = "ai.secret.gemma.webReader.apiKey"
        case ollamaWebSearchAPIKey = "ai.secret.ollama.webSearch.apiKey"
        case localModelAccessToken = "ai.secret.localModel.accessToken"
        case localSupportModelAccessToken = "ai.secret.localSupportModel.accessToken"
        case textRazorAPIKey = "ai.secret.textrazor.apiKey"
    }

    private let defaults = UserDefaults.standard

    private init() {
        migrateLegacySecretsIfNeeded()
    }

    func string(for key: SecretKey) -> String? {
        let value = KeychainHelper.shared.getString(forKey: key.rawValue)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    func strings(for key: SecretKey) -> [String] {
        splitSecretList(string(for: key)).compactMap { $0 }
    }

    @discardableResult
    func setString(_ value: String, for key: SecretKey) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            removeValue(for: key)
            return true
        } else {
            return KeychainHelper.shared.setString(normalized, forKey: key.rawValue)
        }
    }

    func setStrings(_ values: [String], for key: SecretKey) {
        var unique: [String] = []
        for value in values {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, !unique.contains(normalized) else { continue }
            unique.append(normalized)
        }
        setString(unique.joined(separator: "\n"), for: key)
    }

    func removeValue(for key: SecretKey) {
        KeychainHelper.shared.delete(key: key.rawValue)
    }

    func availableGeminiAPIKeys() -> [String] {
        []
    }

    func geminiKeySourceLabel() -> String {
        "廃止済み"
    }

    func configuredTextRazorAPIKey() -> String? {
        uniqueNonEmptyValues([
            string(for: .textRazorAPIKey),
            environmentValue(for: "TEXTRAZOR_API_KEY")
        ]).first
    }

    func configuredGemmaWebReaderAPIKey() -> String? {
        uniqueNonEmptyValues([
            string(for: .gemmaWebReaderAPIKey),
            environmentValue(for: "GEMMA_API_KEY"),
            environmentValue(for: "GOOGLE_API_KEY"),
            environmentValue(for: "GEMINI_API_KEY"),
            string(for: .geminiAPIKey)
        ]).first
    }

    func configuredOllamaWebSearchAPIKeys() -> [String] {
        uniqueNonEmptyValues([
            string(for: .ollamaWebSearchAPIKey),
            environmentValue(for: "OLLAMA_WEB_SEARCH_API_KEY"),
            environmentValue(for: "OLLAMA_API_KEY")
        ].flatMap { splitSecretList($0) })
    }

    private func migrateLegacySecretsIfNeeded() {
        migrateSecret(
            to: .geminiAPIKey,
            primaryKey: "geminiAPIKey",
            aliases: AILegacyCompatibility.geminiAPIKeyAliases
        )
        migrateSecret(
            to: .gemmaWebReaderAPIKey,
            primaryKey: "gemmaWebReaderAPIKey",
            aliases: AILegacyCompatibility.gemmaWebReaderAPIKeyAliases
        )
        migrateSecret(
            to: .ollamaWebSearchAPIKey,
            primaryKey: "ollamaWebSearchAPIKey",
            aliases: AILegacyCompatibility.webSearchAPIKeyAliases
        )
        migrateSecret(
            to: .localModelAccessToken,
            primaryKey: "localAssistantDownloadToken",
            aliases: AILegacyCompatibility.localModelTokenAliases
        )
        migrateSecret(
            to: .localSupportModelAccessToken,
            primaryKey: "localSupportAssistantDownloadToken",
            aliases: []
        )
    }

    private func migrateSecret(to destination: SecretKey, primaryKey: String, aliases: [String]) {
        guard string(for: destination) == nil else {
            AILegacyCompatibility.removeValue(primaryKey: primaryKey, aliases: aliases, defaults: defaults)
            return
        }

        if let legacyValue = AILegacyCompatibility.stringValue(
            primaryKey: primaryKey,
            aliases: aliases,
            defaults: defaults
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
           !legacyValue.isEmpty,
           KeychainHelper.shared.setString(legacyValue, forKey: destination.rawValue) {
            AILegacyCompatibility.removeValue(primaryKey: primaryKey, aliases: aliases, defaults: defaults)
        }
    }

    private func environmentValue(for key: String) -> String? {
        if let environmentValue = ProcessInfo.processInfo.environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !environmentValue.isEmpty {
            return environmentValue
        }
        return nil
    }

    private func uniqueNonEmptyValues(_ values: [String?]) -> [String] {
        var resolved: [String] = []
        for value in values {
            let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !normalized.isEmpty, !resolved.contains(normalized) else { continue }
            resolved.append(normalized)
        }
        return resolved
    }

    private func splitSecretList(_ value: String?) -> [String?] {
        guard let value else { return [] }
        return value.components(separatedBy: CharacterSet(charactersIn: "\n\r,;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
