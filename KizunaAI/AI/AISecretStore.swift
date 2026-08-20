/*
仕様:
- 役割: 絆AIの秘密情報をKeychainにだけ保存する。
- 制約: 平文JSONやUserDefaultsを正本として使わない。
- 参照順: Keychain -> 実行環境変数 -> 秘密を含まないInfo.plist設定。
*/
import Foundation

/// Provider/model metadata is deliberately separate from secret material.
/// These values are safe to persist in UserDefaults and can be exported for
/// diagnostics without exposing API keys.
enum AIProviderID: String, Codable, CaseIterable, Hashable, Sendable {
    case localRuntime
    case googleGenerativeLanguage
    case openAICompatible
    case anthropic
}

enum AIModelRole: String, Codable, CaseIterable, Hashable, Sendable {
    case persona
    case story
    case classifier
    case memoryExtraction
    case memoryRetrieval
    case sceneCharacterSelection
    case sceneSummary
    case nextSceneSuggestion
    case safety
}

struct AIModelIdentity: Codable, Equatable, Hashable, Sendable {
    let providerID: AIProviderID
    let modelID: String
    let displayName: String
    /// For local artifacts this is a stable filename or digest label. It must
    /// never contain an absolute path or secret URL.
    let artifactID: String?

    init(
        providerID: AIProviderID,
        modelID: String,
        displayName: String,
        artifactID: String? = nil
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.displayName = displayName
        self.artifactID = artifactID
    }

    var stableID: String {
        let artifact = artifactID.map { "/\($0)" } ?? ""
        return "\(providerID.rawValue)/\(modelID)\(artifact)"
    }
}

struct AIModelConfiguration: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: UUID
    var identity: AIModelIdentity
    var roles: Set<AIModelRole>
    /// Non-secret endpoint metadata. API keys remain in Keychain.
    var endpoint: String?
    var priority: Int
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        identity: AIModelIdentity,
        roles: Set<AIModelRole>,
        endpoint: String? = nil,
        priority: Int = 0,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.identity = identity
        self.roles = roles
        self.endpoint = endpoint
        self.priority = priority
        self.isEnabled = isEnabled
    }
}

/// A small, provider-neutral registry. It owns configuration metadata only;
/// execution remains in the existing runtime/API adapters until each adapter
/// migrates to the common contract. This makes the migration additive instead
/// of silently routing an old model through the wrong provider.
final class AIModelRegistry: @unchecked Sendable {
    static let shared = AIModelRegistry()

    private let defaults: UserDefaults
    private let lock = NSLock()
    private let storageKey = "ai.modelConfigurations.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.data(forKey: storageKey) == nil {
            save(Self.legacyDefaultConfigurations)
        }
    }

    var configurations: [AIModelConfiguration] {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked()
    }

    func configuration(id: UUID) -> AIModelConfiguration? {
        configurations.first { $0.id == id }
    }

    func configurations(for role: AIModelRole) -> [AIModelConfiguration] {
        configurations
            .filter { $0.isEnabled && $0.roles.contains(role) }
            .sorted {
                if $0.priority != $1.priority { return $0.priority < $1.priority }
                return $0.identity.displayName.localizedStandardCompare($1.identity.displayName) == .orderedAscending
            }
    }

    @discardableResult
    func register(_ configuration: AIModelConfiguration) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var items = loadUnlocked()
        if let index = items.firstIndex(where: { $0.id == configuration.id }) {
            items[index] = configuration
        } else {
            items.append(configuration)
        }
        return saveUnlocked(items)
    }

    @discardableResult
    func remove(id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var items = loadUnlocked()
        let originalCount = items.count
        items.removeAll { $0.id == id }
        guard items.count != originalCount else { return true }
        return saveUnlocked(items)
    }

    private func loadUnlocked() -> [AIModelConfiguration] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([AIModelConfiguration].self, from: data) else {
            return Self.legacyDefaultConfigurations
        }
        return decoded
    }

    private func save(_ items: [AIModelConfiguration]) {
        lock.lock()
        defer { lock.unlock() }
        _ = saveUnlocked(items)
    }

    private func saveUnlocked(_ items: [AIModelConfiguration]) -> Bool {
        guard let data = try? JSONEncoder().encode(items) else { return false }
        defaults.set(data, forKey: storageKey)
        return true
    }

    private static let legacyDefaultConfigurations: [AIModelConfiguration] = [
        AIModelConfiguration(
            id: UUID(uuidString: "9B3C7C72-8F0A-4D56-8A6D-1BCE7F05A001")!,
            identity: AIModelIdentity(
                providerID: .localRuntime,
                modelID: "local-artifact",
                displayName: "iori",
                artifactID: nil
            ),
            roles: Set(AIModelRole.allCases),
            priority: 0
        ),
        AIModelConfiguration(
            id: UUID(uuidString: "9B3C7C72-8F0A-4D56-8A6D-1BCE7F05A002")!,
            identity: AIModelIdentity(
                providerID: .googleGenerativeLanguage,
                modelID: "gemma-4-31b-it",
                displayName: "NAGI",
                artifactID: nil
            ),
            roles: [.persona, .story, .memoryExtraction, .sceneSummary],
            endpoint: "https://generativelanguage.googleapis.com/v1beta",
            priority: 10
        )
    ]
}

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
            return removeValue(for: key)
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

    @discardableResult
    func removeValue(for key: SecretKey) -> Bool {
        KeychainHelper.shared.delete(key: key.rawValue)
    }

    /// Provider credentials are keyed by configuration UUID, allowing more
    /// than one API key/provider without adding a new enum case for every
    /// vendor. The key itself never enters the model registry JSON.
    func providerAPIKey(for configurationID: UUID) -> String? {
        let key = "ai.secret.provider.\(configurationID.uuidString)"
        guard let raw = KeychainHelper.shared.getString(forKey: key) else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    @discardableResult
    func setProviderAPIKey(_ value: String, for configurationID: UUID) -> Bool {
        let key = "ai.secret.provider.\(configurationID.uuidString)"
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            return KeychainHelper.shared.delete(key: key)
        }
        return KeychainHelper.shared.setString(normalized, forKey: key)
    }

    @discardableResult
    func removeProviderAPIKey(for configurationID: UUID) -> Bool {
        KeychainHelper.shared.delete(key: "ai.secret.provider.\(configurationID.uuidString)")
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
