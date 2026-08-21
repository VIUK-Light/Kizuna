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

    static let auxiliaryCases: [AIModelRole] = [
        .classifier,
        .memoryExtraction,
        .memoryRetrieval,
        .sceneCharacterSelection,
        .sceneSummary,
        .nextSceneSuggestion,
        .safety
    ]
}

enum AIEndpointPolicy {
    static func isLocalEndpoint(_ rawValue: String?) -> Bool {
        guard let rawValue,
              let url = URL(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased() else {
            return false
        }
        return isLocalHost(host)
    }

    static func isLocalEndpoint(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return isLocalHost(host)
    }

    static func requiresAPIKey(providerID: AIProviderID, endpoint: String?) -> Bool {
        guard providerID == .openAICompatible || providerID == .anthropic else {
            return false
        }
        return !isLocalEndpoint(endpoint)
    }

    static func allowsEndpoint(providerID: AIProviderID, endpoint: String?) -> Bool {
        guard providerID != .localRuntime,
              let endpoint,
              endpoint.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: endpoint),
              let scheme = url.scheme?.lowercased(),
              url.host?.isEmpty == false else {
            return providerID == .localRuntime
        }
        return scheme == "https" || (scheme == "http" && isLocalEndpoint(url))
    }

    private static func isLocalHost(_ host: String) -> Bool {
        host == "localhost"
            || host == "127.0.0.1"
            || host == "::1"
            || host.hasSuffix(".localhost")
    }
}

/// The default settings surface stays intent-based. Raw sampler/runtime
/// values are persisted separately and are only used while Advanced mode is
/// selected.
enum AIModelSettingsMode: String, Codable, CaseIterable, Hashable, Sendable {
    case simple
    case advanced
}

enum AISimpleModelPreset: String, Codable, CaseIterable, Hashable, Sendable {
    case automatic
    case stable
    case balanced
    case creative
    case fast
}

/// Friendly routing choices for users who do not want to compare parameter
/// counts or provider names. Advanced mode can still pin a different model
/// for each use case.
enum AISimpleModelRoute: String, Codable, CaseIterable, Hashable, Sendable {
    case automatic
    case onDevice
    case online
}

/// Advanced overrides are grouped by product use case instead of being tied
/// to a provider. This lets a Persona/Story preference survive a model swap;
/// unsupported values are removed when the effective provider is resolved.
enum AIModelTuningScope: String, Codable, CaseIterable, Hashable, Sendable {
    case persona
    case story
    case auxiliary

    init(role: AIModelRole) {
        switch role {
        case .persona:
            self = .persona
        case .story:
            self = .story
        case .classifier, .memoryExtraction, .memoryRetrieval,
             .sceneCharacterSelection, .sceneSummary, .nextSceneSuggestion, .safety:
            self = .auxiliary
        }
    }

    var routingRole: AIModelRole {
        switch self {
        case .persona: return .persona
        case .story: return .story
        case .auxiliary: return .classifier
        }
    }
}

struct AILocalRuntimeOverrides: Codable, Equatable, Hashable, Sendable {
    var contextSize: Int?
    var batchSize: Int?
    var microBatchSize: Int?
    var threadCount: Int?
    var batchThreadCount: Int?
    var gpuLayers: Int?
    var flashAttentionEnabled: Bool?
    var disableKVOffload: Bool?

    init(
        contextSize: Int? = nil,
        batchSize: Int? = nil,
        microBatchSize: Int? = nil,
        threadCount: Int? = nil,
        batchThreadCount: Int? = nil,
        gpuLayers: Int? = nil,
        flashAttentionEnabled: Bool? = nil,
        disableKVOffload: Bool? = nil
    ) {
        self.contextSize = contextSize
        self.batchSize = batchSize
        self.microBatchSize = microBatchSize
        self.threadCount = threadCount
        self.batchThreadCount = batchThreadCount
        self.gpuLayers = gpuLayers
        self.flashAttentionEnabled = flashAttentionEnabled
        self.disableKVOffload = disableKVOffload
    }

    var isEmpty: Bool {
        contextSize == nil
            && batchSize == nil
            && microBatchSize == nil
            && threadCount == nil
            && batchThreadCount == nil
            && gpuLayers == nil
            && flashAttentionEnabled == nil
            && disableKVOffload == nil
    }
}

struct AIGenerationOverrides: Codable, Equatable, Hashable, Sendable {
    var temperature: Double?
    var topP: Double?
    var topK: Int?
    var maxOutputTokens: Int?
    var seed: Int?
    var localRuntime: AILocalRuntimeOverrides?

    init(
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        maxOutputTokens: Int? = nil,
        seed: Int? = nil,
        localRuntime: AILocalRuntimeOverrides? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.maxOutputTokens = maxOutputTokens
        self.seed = seed
        self.localRuntime = localRuntime
    }

    var isEmpty: Bool {
        temperature == nil
            && topP == nil
            && topK == nil
            && maxOutputTokens == nil
            && seed == nil
            && (localRuntime?.isEmpty ?? true)
    }
}

struct AIModelTuningPreferences: Codable, Equatable, Sendable {
    var mode: AIModelSettingsMode
    var simplePreset: AISimpleModelPreset
    var simpleModelRoute: AISimpleModelRoute
    private var scopeOverrides: [String: AIGenerationOverrides]
    private var preferredConfigurationIDs: [String: UUID]

    private enum CodingKeys: String, CodingKey {
        case mode
        case simplePreset
        case simpleModelRoute
        case scopeOverrides
        case preferredConfigurationIDs
    }

    init(
        mode: AIModelSettingsMode = .simple,
        simplePreset: AISimpleModelPreset = .automatic,
        simpleModelRoute: AISimpleModelRoute = .automatic,
        scopeOverrides: [String: AIGenerationOverrides] = [:],
        preferredConfigurationIDs: [String: UUID] = [:]
    ) {
        self.mode = mode
        self.simplePreset = simplePreset
        self.simpleModelRoute = simpleModelRoute
        self.scopeOverrides = scopeOverrides
        self.preferredConfigurationIDs = preferredConfigurationIDs
    }

    static let `default` = AIModelTuningPreferences()

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(AIModelSettingsMode.self, forKey: .mode) ?? .simple
        simplePreset = try container.decodeIfPresent(AISimpleModelPreset.self, forKey: .simplePreset) ?? .automatic
        simpleModelRoute = try container.decodeIfPresent(AISimpleModelRoute.self, forKey: .simpleModelRoute) ?? .automatic
        scopeOverrides = try container.decodeIfPresent(
            [String: AIGenerationOverrides].self,
            forKey: .scopeOverrides
        ) ?? [:]
        // This field was added after v1. Existing users keep their tuning
        // values instead of falling back to the complete default object.
        preferredConfigurationIDs = try container.decodeIfPresent(
            [String: UUID].self,
            forKey: .preferredConfigurationIDs
        ) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(simplePreset, forKey: .simplePreset)
        try container.encode(simpleModelRoute, forKey: .simpleModelRoute)
        try container.encode(scopeOverrides, forKey: .scopeOverrides)
        try container.encode(preferredConfigurationIDs, forKey: .preferredConfigurationIDs)
    }

    func overrides(for scope: AIModelTuningScope) -> AIGenerationOverrides {
        scopeOverrides[scope.rawValue] ?? AIGenerationOverrides()
    }

    mutating func setOverrides(_ overrides: AIGenerationOverrides, for scope: AIModelTuningScope) {
        if overrides.isEmpty {
            scopeOverrides[scope.rawValue] = nil
        } else {
            scopeOverrides[scope.rawValue] = overrides
        }
    }

    func preferredConfigurationID(for scope: AIModelTuningScope) -> UUID? {
        preferredConfigurationIDs[scope.rawValue]
    }

    func preferredConfigurationID(for role: AIModelRole) -> UUID? {
        let roleKey = role == .persona || role == .story
            ? AIModelTuningScope(role: role).rawValue
            : "role.\(role.rawValue)"
        return preferredConfigurationIDs[roleKey]
            ?? (AIModelTuningScope(role: role) == .auxiliary
                ? preferredConfigurationIDs[AIModelTuningScope.auxiliary.rawValue]
                : nil)
    }

    func simplePreferredConfigurationID(
        for role: AIModelRole,
        configurations: [AIModelConfiguration]
    ) -> UUID? {
        switch simpleModelRoute {
        case .automatic:
            return nil
        case .onDevice:
            return configurations.first(where: { $0.identity.providerID == .localRuntime })?.id
        case .online:
            return configurations.first(where: { $0.identity.providerID != .localRuntime })?.id
        }
    }

    /// Resolve the model selected by the current settings surface while
    /// retaining the legacy provider choice when Simple mode is Automatic.
    func configurationIDForCurrentMode(
        for role: AIModelRole,
        configurations: [AIModelConfiguration],
        fallbackProviderID: AIProviderID?
    ) -> UUID? {
        switch mode {
        case .advanced:
            if let preferred = preferredConfigurationID(for: role),
               configurations.contains(where: { $0.id == preferred }) {
                return preferred
            }
        case .simple:
            if let simple = simplePreferredConfigurationID(for: role, configurations: configurations) {
                return simple
            }
        }

        return fallbackProviderID.flatMap { providerID in
            configurations.first(where: { $0.identity.providerID == providerID })?.id
        }
    }

    mutating func setPreferredConfigurationID(_ id: UUID?, for scope: AIModelTuningScope) {
        if let id {
            preferredConfigurationIDs[scope.rawValue] = id
        } else {
            preferredConfigurationIDs[scope.rawValue] = nil
        }
    }

    mutating func setPreferredConfigurationID(_ id: UUID?, for role: AIModelRole) {
        let roleKey = role == .persona || role == .story
            ? AIModelTuningScope(role: role).rawValue
            : "role.\(role.rawValue)"
        if let id {
            preferredConfigurationIDs[roleKey] = id
        } else {
            preferredConfigurationIDs[roleKey] = nil
        }
    }

    mutating func resetOverrides() {
        scopeOverrides.removeAll()
    }
}

/// Metadata-only persistence for user tuning. Credentials stay in Keychain;
/// these values are safe to keep in UserDefaults and reset independently.
final class AIModelTuningStore: @unchecked Sendable {
    static let shared = AIModelTuningStore()

    private let defaults: UserDefaults
    private let lock = NSLock()
    private let storageKey = "ai.modelTuningPreferences.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var preferences: AIModelTuningPreferences {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked()
    }

    @discardableResult
    func setMode(_ mode: AIModelSettingsMode) -> Bool {
        update { $0.mode = mode }
    }

    @discardableResult
    func setSimplePreset(_ preset: AISimpleModelPreset) -> Bool {
        update { $0.simplePreset = preset }
    }

    @discardableResult
    func setSimpleModelRoute(_ route: AISimpleModelRoute) -> Bool {
        update { $0.simpleModelRoute = route }
    }

    @discardableResult
    func setOverrides(_ overrides: AIGenerationOverrides, for scope: AIModelTuningScope) -> Bool {
        update { $0.setOverrides(overrides, for: scope) }
    }

    func preferredConfigurationID(for scope: AIModelTuningScope) -> UUID? {
        preferences.preferredConfigurationID(for: scope)
    }

    func preferredConfigurationID(for role: AIModelRole) -> UUID? {
        preferences.preferredConfigurationID(for: role)
    }

    func simplePreferredConfigurationID(
        for role: AIModelRole,
        configurations: [AIModelConfiguration]
    ) -> UUID? {
        preferences.simplePreferredConfigurationID(for: role, configurations: configurations)
    }

    func configurationIDForCurrentMode(
        for role: AIModelRole,
        configurations: [AIModelConfiguration],
        fallbackProviderID: AIProviderID?
    ) -> UUID? {
        preferences.configurationIDForCurrentMode(
            for: role,
            configurations: configurations,
            fallbackProviderID: fallbackProviderID
        )
    }

    @discardableResult
    func setPreferredConfigurationID(_ id: UUID?, for scope: AIModelTuningScope) -> Bool {
        update { $0.setPreferredConfigurationID(id, for: scope) }
    }

    @discardableResult
    func setPreferredConfigurationID(_ id: UUID?, for role: AIModelRole) -> Bool {
        update { $0.setPreferredConfigurationID(id, for: role) }
    }

    @discardableResult
    func resetAdvancedOverrides() -> Bool {
        update { $0.resetOverrides() }
    }

    @discardableResult
    func resetToRecommended() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return saveUnlocked(.default)
    }

    private func update(_ mutation: (inout AIModelTuningPreferences) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var value = loadUnlocked()
        mutation(&value)
        return saveUnlocked(value)
    }

    private func loadUnlocked() -> AIModelTuningPreferences {
        guard let data = defaults.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(AIModelTuningPreferences.self, from: data) else {
            return .default
        }
        return value
    }

    private func saveUnlocked(_ value: AIModelTuningPreferences) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        defaults.set(data, forKey: storageKey)
        return true
    }
}

enum AIModelTuningParameter: String, Codable, CaseIterable, Hashable, Sendable {
    case temperature
    case topP
    case topK
    case maxOutputTokens
    case seed
    case contextSize
    case batchSize
    case threads
    case gpuLayers
    case flashAttention
}

struct AIModelCompatibilitySettings: Codable, Equatable, Hashable, Sendable {
    var disabledParameters: Set<AIModelTuningParameter>

    init(disabledParameters: Set<AIModelTuningParameter> = []) {
        self.disabledParameters = disabledParameters
    }

    static let automatic = AIModelCompatibilitySettings()

    func disables(_ parameter: AIModelTuningParameter) -> Bool {
        disabledParameters.contains(parameter)
    }
}

struct AIProviderParameterCapabilities: Sendable {
    let supportedParameters: Set<AIModelTuningParameter>

    func supports(_ parameter: AIModelTuningParameter) -> Bool {
        supportedParameters.contains(parameter)
    }

    static func capabilities(for providerID: AIProviderID) -> AIProviderParameterCapabilities {
        switch providerID {
        case .localRuntime:
            return AIProviderParameterCapabilities(supportedParameters: Set(AIModelTuningParameter.allCases))
        case .googleGenerativeLanguage:
            return AIProviderParameterCapabilities(
                supportedParameters: [.temperature, .topP, .topK, .maxOutputTokens, .seed]
            )
        case .openAICompatible:
            return AIProviderParameterCapabilities(
                supportedParameters: [.temperature, .topP, .maxOutputTokens, .seed]
            )
        case .anthropic:
            return AIProviderParameterCapabilities(
                supportedParameters: [.temperature, .topP, .topK, .maxOutputTokens]
            )
        }
    }

    static func capabilities(for configuration: AIModelConfiguration) -> AIProviderParameterCapabilities {
        let automatic = capabilities(for: configuration.identity.providerID)
        guard let compatibility = configuration.compatibility else {
            return automatic
        }
        return AIProviderParameterCapabilities(
            supportedParameters: automatic.supportedParameters.subtracting(compatibility.disabledParameters)
        )
    }
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
    /// Optional per-model compatibility overrides. `nil` preserves the
    /// provider's automatic capability profile for older registry entries.
    var compatibility: AIModelCompatibilitySettings?

    init(
        id: UUID = UUID(),
        identity: AIModelIdentity,
        roles: Set<AIModelRole>,
        endpoint: String? = nil,
        priority: Int = 0,
        isEnabled: Bool = true,
        compatibility: AIModelCompatibilitySettings? = nil
    ) {
        self.id = id
        self.identity = identity
        self.roles = roles
        self.endpoint = endpoint
        self.priority = priority
        self.isEnabled = isEnabled
        self.compatibility = compatibility
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

    /// Resolve or create the local artifact configuration used by auxiliary
    /// roles. The configuration ID is persisted so a selected 270M artifact
    /// remains distinct from the active Story/Persona model.
    func localArtifactConfiguration(
        artifactID: String,
        displayName: String,
        roles: Set<AIModelRole>
    ) -> AIModelConfiguration {
        if let existing = configurations.first(where: {
            $0.identity.providerID == .localRuntime
                && $0.identity.artifactID == artifactID
        }) {
            var updated = existing
            updated.roles.formUnion(roles)
            if updated != existing { _ = register(updated) }
            return updated
        }
        let configuration = AIModelConfiguration(
            identity: AIModelIdentity(
                providerID: .localRuntime,
                modelID: "local-artifact",
                displayName: displayName,
                artifactID: artifactID
            ),
            roles: roles,
            priority: -10
        )
        _ = register(configuration)
        return configuration
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
