import SwiftUI
import Foundation
import UniformTypeIdentifiers

private enum AIRegistryConnectionStatus: Equatable {
    case unverified
    case checking
    case available
    case disabled
    case missingCredential
    case invalidEndpoint
    case unavailable
}

struct KizunaSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var modelManager = LocalAssistantModelManager.shared
    @ObservedObject private var profileStore = KizunaUserProfileStore.shared

    @State private var nagiAPIKey = ""
    @State private var modelSourceURL = ""
    @State private var modelSourceSHA256 = ""
    @State private var modelAccessToken = ""
    @State private var nagiAvailability = StoryGemma31BAPIService.shared.availability
    @State private var isCheckingNAGI = false
    @State private var registryConfigurations: [AIModelConfiguration] = []
    @State private var registryProvider: AIProviderID = .openAICompatible
    @State private var registryModelID = ""
    @State private var registryArtifactID: String?
    @State private var registryDisplayName = ""
    @State private var registryEndpoint = "https://api.openai.com/v1"
    @State private var registryAPIKey = ""
    @State private var registryRoles: Set<AIModelRole> = [.persona]
    @State private var registryPriority = 20
    @State private var registryIsEnabled = true
    @State private var registryMessage: String?
    @State private var editingRegistryConfiguration: AIModelConfiguration?
    @State private var pendingRegistryDeletion: AIModelConfiguration?
    @State private var registryConnectionStatuses: [UUID: AIRegistryConnectionStatus] = [:]
    @State private var pendingLocalModelDeletion: LocalAssistantInstalledModel?
    @State private var modelSourceSelection: LocalModelSourceSelection = .standard
    @State private var selectedStandardModelURL = LocalAssistantModelProfile.defaultDownloadURL
    @State private var selectedActiveModelID = ""
    @State private var selectedAuxiliaryModelID = "__automatic__"
    @State private var saveMessage: String?
    @State private var saveMessageIsError = false
    @State private var showClearProfileAlert = false
    @State private var showResetLaunchAlert = false
    @State private var showUnsavedChangesAlert = false
    @State private var isShowingProfile = false
    @State private var isImportingLocalModel = false
    @State private var modelSettingsMode = AIModelTuningStore.shared.preferences.mode
    @State private var simpleModelPreset = AIModelTuningStore.shared.preferences.simplePreset
    @State private var simpleModelRoute = AIModelTuningStore.shared.preferences.simpleModelRoute
    @AppStorage("kizuna.language") private var languageRawValue = KizunaLanguage.japanese.rawValue
#if DEBUG
    @AppStorage("kizuna.debug.restSuggestion.enabled") private var debugRestSuggestionEnabled = false
#endif

    private var canDownload: Bool {
        modelSourceSelection == .standard
            || !modelSourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var localModelFileTypes: [UTType] {
        ["gguf", "litertlm", "bin"].compactMap { UTType(filenameExtension: $0) }
    }

    private var selectedStandardInstalledModel: LocalAssistantInstalledModel? {
        guard modelSourceSelection == .standard,
              let selectedOption = standardModelOptions.first(where: { $0.url == selectedStandardModelURL }),
              let selectedURL = URL(string: selectedOption.url) else {
            return nil
        }
        let expectedFileName = selectedURL.lastPathComponent
        return modelManager.installedModels.first { model in
            model.fileName == expectedFileName || model.sourceURL == selectedOption.url
        }
    }

    private var selectedStandardModelIsActive: Bool {
        guard let selectedStandardInstalledModel else { return false }
        return selectedStandardInstalledModel.id == modelManager.activeModelID
    }

    private var modelDownloadActionTitle: String {
        if selectedStandardInstalledModel != nil {
            return selectedStandardModelIsActive
                ? KizunaCopy.text(japanese: "使用中", english: "In use")
                : KizunaCopy.text(japanese: "このモデルを使用", english: "Use this model")
        }
        if modelSourceSelection == .standard && !modelManager.installedModels.isEmpty {
            return KizunaCopy.text(japanese: "モデルを追加", english: "Add model")
        }
        return modelManager.installedModelURL == nil
            ? KizunaCopy.text(japanese: "モデルをダウンロード", english: "Download model")
            : KizunaCopy.text(japanese: "再ダウンロード", english: "Download again")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(KizunaCopy.text(japanese: "表示言語", english: "Display language")) {
                    Picker(KizunaCopy.text(japanese: "言語", english: "Language"), selection: $languageRawValue) {
                        ForEach(KizunaLanguage.allCases) { language in
                            Text(language.displayName).tag(language.rawValue)
                        }
                    }
                    Text(KizunaCopy.text(
                        japanese: "\(KizunaCopy.appName)内の表示だけが切り替わります。端末全体の言語は変更しません。",
                        english: "Only \(KizunaCopy.appName) changes language. Your device language stays the same."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    HStack(spacing: 10) {
                        KizunaAvatarView(
                            symbol: profileStore.profile.avatarSymbol,
                            imageData: profileStore.profile.avatarImageData,
                            size: 42
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profileStore.profile.visibleName.isEmpty
                                 ? KizunaCopy.text(japanese: "未設定", english: "Not set")
                                 : profileStore.profile.visibleName)
                                .font(.headline)
                            Text(profileStore.profile.hasUsefulContent
                                 ? KizunaCopy.text(japanese: "プロフィール設定済み", english: "Profile configured")
                                 : KizunaCopy.text(japanese: "入力は任意です", english: "Optional")
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(KizunaCopy.text(japanese: "編集", english: "Edit")) {
                            isShowingProfile = true
                        }
                    }
                    LabeledContent(
                        KizunaCopy.text(japanese: "年齢に合わせた安全設定", english: "Age-appropriate safety"),
                        value: UserAgeSafetyStore.shared.context.tier.localizedDisplayName
                    )
                    if profileStore.profile.hasUsefulContent
                        || UserAgeSafetyStore.shared.context.tier != .unknown {
                        Button(KizunaCopy.text(japanese: "プロフィールを消去", english: "Clear profile"), role: .destructive) {
                            showClearProfileAlert = true
                        }
                    }
                } header: {
                    Text(KizunaCopy.text(japanese: "プロフィール", english: "Profile"))
                }

                Section(KizunaCopy.text(japanese: "AIの動作", english: "AI behavior")) {
                    if modelSettingsMode == .simple {
                        Picker(
                            KizunaCopy.text(japanese: "使い方", english: "Preference"),
                            selection: $simpleModelPreset
                        ) {
                            ForEach(AISimpleModelPreset.allCases, id: \.self) { preset in
                                Text(simplePresetName(preset)).tag(preset)
                            }
                        }
                        .onChange(of: simpleModelPreset) { _, newValue in
                            _ = AIModelTuningStore.shared.setSimplePreset(newValue)
                        }

                        Text(simplePresetDetail(simpleModelPreset))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Picker(
                            KizunaCopy.text(japanese: "AIの選び方", english: "How to choose AI"),
                            selection: $simpleModelRoute
                        ) {
                            ForEach(AISimpleModelRoute.allCases, id: \.self) { route in
                                Text(simpleModelRouteName(route)).tag(route)
                            }
                        }
                        .onChange(of: simpleModelRoute) { _, newValue in
                            _ = AIModelTuningStore.shared.setSimpleModelRoute(newValue)
                        }

                        Text(simpleModelRouteDetail(simpleModelRoute))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button {
                            modelSettingsMode = .advanced
                            _ = AIModelTuningStore.shared.setMode(.advanced)
                        } label: {
                            Label(
                                KizunaCopy.text(japanese: "詳細なモデル設定を開く", english: "Open advanced model settings"),
                                systemImage: "slider.horizontal.3"
                            )
                        }
                    } else {
                        LabeledContent(
                            KizunaCopy.text(japanese: "モード", english: "Mode"),
                            value: KizunaCopy.text(japanese: "詳細設定", english: "Advanced")
                        )
                        NavigationLink {
                            AIAdvancedModelSettingsView()
                        } label: {
                            Label(
                                KizunaCopy.text(japanese: "用途別の生成・実行設定", english: "Generation and runtime by use case"),
                                systemImage: "slider.horizontal.3"
                            )
                        }
                        Button {
                            modelSettingsMode = .simple
                            _ = AIModelTuningStore.shared.setMode(.simple)
                        } label: {
                            Label(
                                KizunaCopy.text(japanese: "かんたん設定に戻る", english: "Return to simple settings"),
                                systemImage: "wand.and.stars"
                            )
                        }
                        Button {
                            _ = AIModelTuningStore.shared.resetToRecommended()
                            modelSettingsMode = .simple
                            simpleModelPreset = .automatic
                            simpleModelRoute = .automatic
                        } label: {
                            Label(
                                KizunaCopy.text(japanese: "Kizuna推奨設定に戻す", english: "Restore Kizuna recommendations"),
                                systemImage: "arrow.counterclockwise"
                            )
                        }
                    }
                }

                if modelSettingsMode == .advanced {
                Section(KizunaCopy.text(japanese: "NAGI（Gemma4 31B API）", english: "NAGI (Gemma4 31B API)")) {
                    SecureField(KizunaCopy.text(japanese: "Google AI APIキー", english: "Google AI API key"), text: $nagiAPIKey)
                        .textContentType(.password)

                    Text(KizunaCopy.text(
                        japanese: "APIキーはKeychainに保存されます。",
                        english: "The API key is stored in Keychain."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        LabeledContent(
                            KizunaCopy.text(japanese: "接続状態", english: "Connection"),
                            value: nagiAvailabilityLabel
                        )
                        Spacer(minLength: 12)
                        Button {
                            validateNAGI()
                        } label: {
                            Label(
                                isCheckingNAGI
                                    ? KizunaCopy.text(japanese: "確認中…", english: "Checking…")
                                    : KizunaCopy.text(japanese: "接続を確認", english: "Verify connection"),
                                systemImage: isCheckingNAGI ? "arrow.triangle.2.circlepath" : "checkmark.seal"
                            )
                        }
                        .buttonStyle(.bordered)
                        .disabled(isCheckingNAGI || nagiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Section(KizunaCopy.text(japanese: "AIモデルRegistry", english: "AI model registry")) {
                    ForEach(registryConfigurations) { configuration in
                        HStack(alignment: .top, spacing: 8) {
                            Button {
                                editingRegistryConfiguration = configuration
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(configuration.identity.displayName)
                                        .font(.headline)
                                    Text(configuration.identity.stableID)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                    Text(registryRoutingSummary(configuration))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                    HStack(spacing: 5) {
                                        Image(systemName: registryConnectionStatusIcon(configuration))
                                        Text(registryConnectionStatusLabel(configuration))
                                    }
                                    .font(.caption)
                                    .foregroundStyle(registryConnectionStatusColor(configuration))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button {
                                verifyRegistryConfiguration(configuration)
                            } label: {
                                Label(
                                    KizunaCopy.text(japanese: "接続を確認", english: "Verify"),
                                    systemImage: registryConnectionStatus(configuration) == .checking
                                        ? "arrow.triangle.2.circlepath"
                                        : "checkmark.seal"
                                )
                            }
                            .buttonStyle(.borderless)
                            .disabled(registryConnectionStatus(configuration) == .checking)

                            Button {
                                pendingRegistryDeletion = configuration
                            } label: {
                                Image(systemName: "trash")
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                        }
                    }

                    Picker(
                        KizunaCopy.text(japanese: "Provider", english: "Provider"),
                        selection: $registryProvider
                    ) {
                        ForEach(AIProviderID.allCases, id: \.self) { provider in
                            Text(providerDisplayName(provider)).tag(provider)
                        }
                    }
                    .onChange(of: registryProvider) { oldProvider, newProvider in
                        let currentEndpoint = registryEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                        if currentEndpoint.isEmpty || currentEndpoint == registryDefaultEndpoint(for: oldProvider) {
                            registryEndpoint = registryDefaultEndpoint(for: newProvider)
                        }
                        if newProvider != .localRuntime {
                            registryArtifactID = nil
                        }
                    }
                    TextField(
                        KizunaCopy.text(japanese: "Model ID", english: "Model ID"),
                        text: $registryModelID
                    )
                    .autocorrectionDisabled()
                    TextField(
                        KizunaCopy.text(japanese: "表示名", english: "Display name"),
                        text: $registryDisplayName
                    )
                    if registryProvider == .localRuntime {
                        Text(KizunaCopy.text(
                            japanese: "ローカルランタイムではEndpointは必要ありません。",
                            english: "Local runtime does not require an endpoint."
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker(
                            KizunaCopy.text(japanese: "使用するインストール済みモデル", english: "Installed model to use"),
                            selection: $registryArtifactID
                        ) {
                            Text(KizunaCopy.text(
                                japanese: "現在のアクティブモデルに追従",
                                english: "Follow active local model"
                            ))
                            .tag(Optional<String>.none)
                            ForEach(modelManager.installedModels) { model in
                                Text("\(model.displayName) · \(model.fileName)")
                                    .tag(Optional(model.id))
                            }
                        }
                        Text(KizunaCopy.text(
                            japanese: "固定モデルを選ぶと、active modelを切り替えてもこの構成は同じartifactを使います。",
                            english: "A fixed artifact keeps this configuration on the same model when the active model changes."
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        TextField(
                            KizunaCopy.text(japanese: "Endpoint", english: "Endpoint"),
                            text: $registryEndpoint
                        )
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                    }
                    if registryProvider != .localRuntime {
                        SecureField(
                            registryRequiresAPIKey(
                                for: registryProvider,
                                endpoint: registryEndpoint
                            )
                                ? KizunaCopy.text(japanese: "APIキー（必須）", english: "API key (required)")
                                : KizunaCopy.text(japanese: "APIキー（任意）", english: "API key (optional)"),
                            text: $registryAPIKey
                        )
                        .textContentType(.password)
                    }
                    Menu {
                        ForEach(AIModelRole.allCases, id: \.self) { role in
                            Button {
                                registryRoles.formSymmetricDifference([role])
                            } label: {
                                Label(
                                    roleDisplayName(role),
                                    systemImage: registryRoles.contains(role) ? "checkmark" : "circle"
                                )
                            }
                        }
                    } label: {
                        LabeledContent(
                            KizunaCopy.text(japanese: "用途", english: "Roles"),
                            value: registryRoles.isEmpty
                                ? KizunaCopy.text(japanese: "未選択", english: "None selected")
                                : registryRoleNames(registryRoles)
                        )
                    }
                    .frame(minHeight: 44)
                    Stepper(value: $registryPriority, in: -100...100) {
                        LabeledContent(
                            KizunaCopy.text(japanese: "優先度（小さいほど先）", english: "Priority (lower first)"),
                            value: "\(registryPriority)"
                        )
                    }
                    Toggle(
                        KizunaCopy.text(japanese: "有効", english: "Enabled"),
                        isOn: $registryIsEnabled
                    )
                    Button {
                        addRegistryConfiguration()
                    } label: {
                        Label(
                            KizunaCopy.text(japanese: "モデル構成を追加", english: "Add model configuration"),
                            systemImage: "plus.circle"
                        )
                    }
                    .buttonStyle(.bordered)
                    if let registryMessage {
                        Text(registryMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(KizunaCopy.text(
                        japanese: "Provider metadataはUserDefaults、APIキーはconfiguration UUIDごとにKeychainへ保存します。",
                        english: "Provider metadata is stored in UserDefaults; API keys are stored in Keychain per configuration UUID."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(KizunaCopy.text(japanese: "ローカルAIモデル", english: "Local AI model")) {
                    LabeledContent(KizunaCopy.text(japanese: "状態", english: "Status"), value: modelManager.runtimeStatusSummary)

                    if let name = modelManager.installedFileName {
                        LabeledContent(KizunaCopy.text(japanese: "モデル", english: "Model"), value: name)
                    }

                    if modelManager.installedModels.count > 1 {
                        Picker(
                            KizunaCopy.text(japanese: "使用するローカルモデル", english: "Active local model"),
                            selection: Binding(
                                get: { selectedActiveModelID },
                                set: { selectedActiveModelID = $0 }
                            )
                        ) {
                            ForEach(modelManager.installedModels) { model in
                                Text("\(model.displayName) (\(ByteCountFormatter.string(fromByteCount: model.fileSize, countStyle: .file)))")
                                    .tag(model.id)
                            }
                        }
                        Text(KizunaCopy.text(
                            japanese: "複数の検証済みモデルを保持したまま、使用する1つを切り替えられます。",
                            english: "Keep multiple validated models installed and switch the active one without replacing the others."
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !modelManager.installedModels.isEmpty {
                        Picker(
                            KizunaCopy.text(japanese: "補助AIモデル", english: "Auxiliary AI model"),
                            selection: Binding(
                                get: { selectedAuxiliaryModelID },
                                set: { selectedAuxiliaryModelID = $0 }
                            )
                        ) {
                            Text(KizunaCopy.text(japanese: "本文モデルに合わせる", english: "Use active model"))
                                .tag("__automatic__")
                            ForEach(modelManager.installedModels) { model in
                                Text(model.displayName).tag(model.id)
                            }
                        }
                        Text(KizunaCopy.text(
                            japanese: "classifier・Memory・Scene補助処理だけに使うlocal artifactを選べます。Gemma 3 270Mを導入した場合はここで指定してください。",
                            english: "Choose a local artifact for classifier, memory, and scene helpers. Select a Gemma 3 270M artifact here when installed."
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !modelManager.installedModels.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(KizunaCopy.text(japanese: "インストール済みモデル", english: "Installed models"))
                                .font(.subheadline.weight(.semibold))
                            ForEach(modelManager.installedModels) { model in
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(model.displayName)
                                            .font(.body.weight(.medium))
                                        Text(ByteCountFormatter.string(fromByteCount: model.fileSize, countStyle: .file))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        HStack(spacing: 6) {
                                            if model.id == modelManager.activeModelID {
                                                Label(
                                                    KizunaCopy.text(japanese: "使用中", english: "Active"),
                                                    systemImage: "checkmark.circle.fill"
                                                )
                                            }
                                            if model.id == modelManager.auxiliaryModelID {
                                                Label(
                                                    KizunaCopy.text(japanese: "補助", english: "Auxiliary"),
                                                    systemImage: "wand.and.stars"
                                                )
                                            }
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    Text(model.id == modelManager.activeModelID
                                         ? modelManager.runnerStatusLabel
                                         : KizunaCopy.text(japanese: "保存済み", english: "Installed"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Button {
                                        pendingLocalModelDeletion = model
                                    } label: {
                                        Image(systemName: "trash")
                                            .frame(width: 44, height: 44)
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.red)
                                    .accessibilityLabel(
                                        KizunaCopy.text(
                                            japanese: "\(model.displayName)を削除",
                                            english: "Delete \(model.displayName)"
                                        )
                                    )
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }

                    Button {
                        isImportingLocalModel = true
                    } label: {
                        Label(
                            KizunaCopy.text(japanese: "モデルファイルを追加", english: "Add a model file"),
                            systemImage: "plus.circle"
                        )
                    }
                    .disabled(modelManager.isDownloading)
                    Text(KizunaCopy.text(
                        japanese: "既存モデルを置き換えず、GGUF・LiteRT-LM・対応binを検証して追加します。",
                        english: "Add a validated GGUF, LiteRT-LM, or supported bin without replacing existing models."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker(KizunaCopy.text(japanese: "モデルの入手先", english: "Model source"), selection: $modelSourceSelection) {
                        ForEach(LocalModelSourceSelection.allCases) { source in
                            Label(source.title, systemImage: source.icon)
                                .tag(source)
                        }
                    }

                    if modelSourceSelection == .standard {
                        Picker(KizunaCopy.text(japanese: "標準リンク", english: "Standard link"), selection: $selectedStandardModelURL) {
                            ForEach(standardModelOptions) { option in
                                VStack(alignment: .leading) {
                                    Text(option.title)
                                    Text(localizedModelDetail(option))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .tag(option.url)
                            }
                        }
                        if let selectedOption = standardModelOptions.first(where: {
                            $0.url == selectedStandardModelURL
                        }) {
                            Text(localizedModelDetail(selectedOption))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(KizunaCopy.text(
                            japanese: "アプリに設定された標準リンクからダウンロードします。",
                            english: "Download from a standard link configured by the app."
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        // 認証が必要な標準モデルだけ、トークン入力を表示する。
                        if selectedStandardModelRequiresToken {
                            SecureField(KizunaCopy.text(japanese: "Hugging Faceアクセストークン（必要な場合）", english: "Hugging Face access token (if required)"), text: $modelAccessToken)
                                .textContentType(.password)
                            Text(KizunaCopy.text(
                                japanese: "Gemma 3n E2BはHugging Faceで利用許諾を確認したアクセストークンが必要です。",
                                english: "Gemma 3n E2B requires an access token after accepting its Hugging Face license."
                            ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        TextField(KizunaCopy.text(japanese: "Hugging FaceのファイルURL", english: "Hugging Face file URL"), text: $modelSourceURL)
                            .textContentType(.URL)
                            .autocorrectionDisabled()

                        SecureField(KizunaCopy.text(japanese: "アクセストークン（必要な場合）", english: "Access token (if required)"), text: $modelAccessToken)
                            .textContentType(.password)

                        TextField(KizunaCopy.text(japanese: "SHA-256（任意・整合性検証用）", english: "SHA-256 (optional, integrity check)"), text: $modelSourceSHA256)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif

                        Text(KizunaCopy.text(
                            japanese: "配布元が公開しているSHA-256（64桁の16進数）を入力すると、ダウンロード後に整合性を検証します。未入力の場合は形式のみ検証します。",
                            english: "If you enter the SHA-256 digest (64 hex digits) published by the source, Kizuna verifies the download's integrity. Without it, only the format is checked."
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(KizunaCopy.text(
                            japanese: "リポジトリページではなく、GGUFまたはLiteRT-LMファイルの直接ダウンロードURLを指定してください。",
                            english: "Enter a direct download URL for a GGUF or LiteRT-LM file, not a repository page."
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let progress = modelManager.progressValue {
                        ProgressView(value: progress)
                    } else if modelManager.isDownloading {
                        ProgressView()
                    }

                    Text(modelManager.localizedStatusMessage)
                        .font(.caption)
                        .foregroundStyle(modelManager.isDownloadStateFailure ? Color.red : Color.secondary)

                    if let error = modelManager.localizedSupplementalLastErrorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    // ダウンロード後の端末内runtime確認はモデル検出時に自動で行う。
                    // ユーザーにself-checkを押させる導線は置かない。
                    VStack(alignment: .leading, spacing: 8) {
                        if modelManager.isDownloading {
                            Button(KizunaCopy.text(japanese: "一時停止", english: "Pause")) {
                                modelManager.cancelDownload()
                            }
                            .buttonStyle(.bordered)
                        } else if modelManager.canResumeDownload {
                            Button(KizunaCopy.text(japanese: "ダウンロードを再開", english: "Resume download")) {
                                saveSecretsAndModelSource()
                                modelManager.resumeDownloadIfPossible()
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button {
                                if let selectedStandardInstalledModel {
                                    _ = modelManager.selectInstalledModel(id: selectedStandardInstalledModel.id)
                                } else {
                                    saveSecretsAndModelSource()
                                    modelManager.startDownload()
                                }
                            } label: {
                                Text(modelDownloadActionTitle)
                            }
                            .buttonStyle(.bordered)
                            .disabled(!canDownload || selectedStandardModelIsActive)
                        }

                        Label(
                            modelManager.runtimeAvailability == .checking
                                ? KizunaCopy.text(japanese: "端末内で実行確認中", english: "Checking on-device runtime")
                                : KizunaCopy.text(japanese: "端末内の実行確認は自動で行われます", english: "On-device runtime checks run automatically"),
                            systemImage: modelManager.runtimeAvailability == .checking
                                ? "arrow.triangle.2.circlepath"
                                : "checkmark.seal"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    }
                }

#if DEBUG
                Section(KizunaCopy.text(japanese: "デバッグ", english: "Debug")) {
                    Toggle(
                        KizunaCopy.text(japanese: "デバッグオプションを有効化", english: "Enable debug options"),
                        isOn: $debugRestSuggestionEnabled
                    )
                    Button(KizunaCopy.text(japanese: "休憩提案を30秒後に表示", english: "Show rest suggestion after 30 seconds")) {
                        KizunaDebugOptions.requestRestSuggestionUI()
                        dismiss()
                    }
                    .disabled(!debugRestSuggestionEnabled)
                    Text(KizunaCopy.text(
                        japanese: "設定を閉じ、最初のストーリーを開いて30秒後にカードを表示します。",
                        english: "Closes settings, opens the first story, and shows the card after 30 seconds."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(KizunaCopy.text(japanese: "危険相談サポートを30秒後に表示", english: "Show safety support after 30 seconds")) {
                        KizunaDebugOptions.requestSafetyConcernUI()
                        dismiss()
                    }
                    .disabled(!debugRestSuggestionEnabled)
                    Text(KizunaCopy.text(
                        japanese: "設定を閉じ、最初のストーリーを開いて30秒後に相談サポートカードを表示します。",
                        english: "Closes settings, opens the first story, and shows the support card after 30 seconds."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
#endif

                Section {
                    Button(KizunaCopy.text(japanese: "初期設定を今すぐ開く", english: "Open welcome setup now")) {
                        showResetLaunchAlert = true
                    }
                    Text(KizunaCopy.text(
                        japanese: "設定を閉じると、プロフィール設定へ移動します。",
                        english: "After settings closes, \(KizunaCopy.appName) opens profile setup."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    LabeledContent(
                        KizunaCopy.text(japanese: "端末内ランタイム", english: "On-device runtime"),
                        value: modelManager.runtimeStatusSummary
                    )
                    LabeledContent(
                        KizunaCopy.text(japanese: "最終確認", english: "Last check"),
                        value: modelManager.runtimeRefreshedAt.formatted(date: .abbreviated, time: .shortened)
                    )
                } header: {
                    Text(KizunaCopy.text(japanese: "起動と診断", english: "Launch & diagnostics"))
                }

                Section(KizunaCopy.text(japanese: "データ保存先", english: "Data locations")) {
                    Text(KizunaDataMigration.characterLibraryURL.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Text(KizunaDataMigration.localModelsURL.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }

            }
            .formStyle(.grouped)
            .safeAreaInset(edge: .top, spacing: 0) {
                if let saveMessage {
                    Label(saveMessage, systemImage: saveMessageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(saveMessageIsError ? .red : .green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .navigationTitle(KizunaCopy.text(japanese: "設定", english: "Settings"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(KizunaCopy.text(japanese: "閉じる", english: "Close")) {
                        closeSettings()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(KizunaCopy.text(japanese: "保存", english: "Save")) {
                        saveSecretsAndModelSource()
                    }
                }
            }
        }
        .alert(
            pendingLocalModelDeletion.map {
                KizunaCopy.text(
                    japanese: "「\($0.displayName)」を削除しますか？",
                    english: "Delete \($0.displayName)?"
                )
            } ?? KizunaCopy.text(japanese: "ローカルモデルを削除しますか？", english: "Delete the local model?"),
            isPresented: Binding(
                get: { pendingLocalModelDeletion != nil },
                set: { if !$0 { pendingLocalModelDeletion = nil } }
            )
        ) {
            Button(KizunaCopy.text(japanese: "削除", english: "Delete"), role: .destructive) {
                if let model = pendingLocalModelDeletion {
                    _ = modelManager.removeInstalledModel(id: model.id)
                }
                pendingLocalModelDeletion = nil
            }
            Button(KizunaCopy.text(japanese: "キャンセル", english: "Cancel"), role: .cancel) {
                pendingLocalModelDeletion = nil
            }
        } message: {
            Text(KizunaCopy.text(
                japanese: "対象のモデルだけを削除します。ほかのインストール済みモデルは残ります。この操作は取り消せません。",
                english: "Only this model will be deleted. Other installed models will remain. This action cannot be undone."
            ))
        }
        .alert(
            KizunaCopy.text(japanese: "プロフィールを消去しますか？", english: "Clear your profile?"),
            isPresented: $showClearProfileAlert
        ) {
            Button(KizunaCopy.text(japanese: "消去", english: "Clear"), role: .destructive) {
                profileStore.reset()
            }
            Button(KizunaCopy.text(japanese: "キャンセル", english: "Cancel"), role: .cancel) {}
        } message: {
            Text(KizunaCopy.text(
                japanese: "名前、プロフィール画像、標準アバターの選択、会話設定、年齢に合わせた安全設定が消去されます。この操作は取り消せません。",
                english: "Your name, profile photo, standard avatar selection, conversation preference, and age-appropriate safety setting will be reset. This cannot be undone."
            ))
        }
        .alert(
            KizunaCopy.text(japanese: "初期設定を今すぐ開きますか？", english: "Open the welcome setup now?"),
            isPresented: $showResetLaunchAlert
        ) {
            Button(KizunaCopy.text(japanese: "開く", english: "Open")) {
                UserDefaults.standard.set(false, forKey: KizunaStorageKeys.launchCompleted)
                // KizunaMigrationGateView observes this AppStorage value. Close this
                // sheet so the immediate transition is visible instead of appearing
                // to take effect only after the next process launch.
                dismiss()
            }
            Button(KizunaCopy.text(japanese: "キャンセル", english: "Cancel"), role: .cancel) {}
        } message: {
            Text(KizunaCopy.text(
                japanese: "保存済みのプロフィールやモデル設定は変更しません。設定を閉じたあと初期設定へ移動します。",
                english: "Your saved profile and model settings will stay unchanged. The setup opens after this sheet closes."
            ))
        }
        .alert(
            KizunaCopy.text(japanese: "未保存の変更があります", english: "You have unsaved changes"),
            isPresented: $showUnsavedChangesAlert
        ) {
            Button(KizunaCopy.text(japanese: "保存して閉じる", english: "Save and close")) {
                if saveSecretsAndModelSource() {
                    dismiss()
                }
            }
            Button(KizunaCopy.text(japanese: "変更を破棄", english: "Discard changes"), role: .destructive) {
                dismiss()
            }
            Button(KizunaCopy.text(japanese: "キャンセル", english: "Cancel"), role: .cancel) {}
        } message: {
            Text(KizunaCopy.text(
                japanese: "設定を保存せずに閉じると、入力した変更は破棄されます。保存するか、変更を破棄するかを選んでください。",
                english: "If you close Settings without saving, your draft changes will be discarded. Choose whether to save or discard them."
            ))
        }
        .alert(
            KizunaCopy.text(japanese: "モデル構成を削除しますか？", english: "Delete this model configuration?"),
            isPresented: Binding(
                get: { pendingRegistryDeletion != nil },
                set: { if !$0 { pendingRegistryDeletion = nil } }
            )
        ) {
            Button(KizunaCopy.text(japanese: "削除", english: "Delete"), role: .destructive) {
                if let configuration = pendingRegistryDeletion {
                    removeRegistryConfiguration(configuration)
                }
                pendingRegistryDeletion = nil
            }
            Button(KizunaCopy.text(japanese: "キャンセル", english: "Cancel"), role: .cancel) {
                pendingRegistryDeletion = nil
            }
        } message: {
            Text(KizunaCopy.text(
                japanese: "この構成と、この構成に保存されたAPIキーをこの端末から削除します。この操作は取り消せません。",
                english: "This removes the configuration and its saved API key from this device. This cannot be undone."
            ))
        }
        .sheet(isPresented: $isShowingProfile) {
            KizunaUserProfileView(store: KizunaUserProfileStore.shared)
                .viukAdaptiveSheetSizing(minWidth: 520, minHeight: 620)
        }
        .sheet(item: $editingRegistryConfiguration) { configuration in
            AIModelRegistryEditorView(configuration: configuration) { updated, apiKey in
                guard let error = saveRegistryConfiguration(updated, apiKey: apiKey) else {
                    registryMessage = KizunaCopy.text(
                        japanese: "モデル構成を更新しました。",
                        english: "Model configuration updated."
                    )
                    return nil
                }
                return error
            }
            .viukAdaptiveSheetSizing(minWidth: 560, minHeight: 640)
        }
        .onAppear {
            let tuningPreferences = AIModelTuningStore.shared.preferences
            modelSettingsMode = tuningPreferences.mode
            simpleModelPreset = tuningPreferences.simplePreset
            nagiAPIKey = AISecretStore.shared.string(for: .gemmaWebReaderAPIKey) ?? ""
            nagiAvailability = StoryGemma31BAPIService.shared.availability
            registryConfigurations = AIModelRegistry.shared.configurations
            registryConnectionStatuses = registryConnectionStatuses.filter { id, _ in
                registryConfigurations.contains { $0.id == id }
            }
            modelSourceURL = modelManager.sourceURLString
            modelAccessToken = modelManager.accessToken
            selectedStandardModelURL = standardModelOptions.first(where: {
                $0.url == modelManager.resolvedSourceURLString
            })?.url ?? LocalAssistantModelProfile.defaultDownloadURL
            modelSourceSelection = standardModelOptions.contains(where: {
                $0.url == modelManager.resolvedSourceURLString
            }) ? .standard : .huggingFace
            selectedActiveModelID = modelManager.activeModelID ?? ""
            selectedAuxiliaryModelID = modelManager.auxiliaryModelID ?? "__automatic__"
            modelManager.refreshEnvironment()
        }
        .fileImporter(
            isPresented: $isImportingLocalModel,
            allowedContentTypes: localModelFileTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { @MainActor in
                    let imported = await modelManager.importAdditionalModel(from: url)
                    saveMessageIsError = !imported
                    saveMessage = imported
                        ? KizunaCopy.text(japanese: "追加モデルを検証して保存しました", english: "The additional model was validated and saved")
                        : KizunaCopy.text(japanese: "追加モデルを保存できませんでした", english: "The additional model could not be saved")
                }
            case .failure(let error):
                saveMessageIsError = true
                saveMessage = error.localizedDescription
            }
        }
    }

    private var hasUnsavedChanges: Bool {
        let storedNAGIKey = AISecretStore.shared.string(for: .gemmaWebReaderAPIKey) ?? ""
        let draftNAGIKey = nagiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedSourceURL = modelManager.sourceURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let draftSourceURL = (modelSourceSelection == .standard
            ? selectedStandardModelURL
            : modelSourceURL
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveDraftSourceURL = draftSourceURL.isEmpty
            ? LocalAssistantModelProfile.defaultDownloadURL
            : draftSourceURL

        return draftNAGIKey != storedNAGIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            || effectiveDraftSourceURL != storedSourceURL
            || modelSourceSHA256.trimmingCharacters(in: .whitespacesAndNewlines)
                != modelManager.customSourceSHA256.trimmingCharacters(in: .whitespacesAndNewlines)
            || modelAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
                != modelManager.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
            || selectedActiveModelID != (modelManager.activeModelID ?? "")
            || selectedAuxiliaryModelID != (modelManager.auxiliaryModelID ?? "__automatic__")
    }

    private func closeSettings() {
        if hasUnsavedChanges {
            showUnsavedChangesAlert = true
        } else {
            dismiss()
        }
    }

    @discardableResult
    private func saveSecretsAndModelSource() -> Bool {
        let apiKeySaved = AISecretStore.shared.setString(nagiAPIKey, for: .gemmaWebReaderAPIKey)

        if modelSourceSelection == .standard {
            modelManager.updateSourceURL(selectedStandardModelURL)
        } else {
            modelManager.updateSourceURL(modelSourceURL)
        }
        modelManager.customSourceSHA256 = modelSourceSHA256

        nagiAvailability = apiKeySaved && !nagiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .savedNotVerified
            : .notConfigured

        let accessTokenSaved = modelManager.updateAccessToken(modelAccessToken)
        let activeModelSaved = selectedActiveModelID.isEmpty
            ? modelManager.activeModelID == nil
            : modelManager.selectInstalledModel(id: selectedActiveModelID)
        let auxiliaryModelSaved = modelManager.selectAuxiliaryModel(
            id: selectedAuxiliaryModelID == "__automatic__" ? nil : selectedAuxiliaryModelID
        )
        let succeeded = apiKeySaved && accessTokenSaved && activeModelSaved && auxiliaryModelSaved
        saveMessageIsError = !succeeded
        saveMessage = saveMessageIsError
            ? KizunaCopy.text(
                japanese: "秘密情報をKeychainへ保存できませんでした。入力は保持したまま、もう一度試してください。",
                english: "A secret could not be saved to Keychain. Your input was kept; try again."
            )
            : KizunaCopy.text(japanese: "設定を保存しました", english: "Settings saved")
        return succeeded
    }

    private var nagiAvailabilityLabel: String {
        switch nagiAvailability {
        case .notConfigured:
            return KizunaCopy.text(japanese: "未設定", english: "Not configured")
        case .savedNotVerified:
            return KizunaCopy.text(japanese: "保存済み・未確認", english: "Saved · not verified")
        case .checking:
            return KizunaCopy.text(japanese: "確認中", english: "Checking")
        case .available:
            return KizunaCopy.text(japanese: "確認済み", english: "Verified")
        case .authenticationError:
            return KizunaCopy.text(japanese: "認証エラー", english: "Authentication error")
        case .modelUnavailable:
            return KizunaCopy.text(japanese: "モデル利用不可", english: "Model unavailable")
        case .rateLimited:
            return KizunaCopy.text(japanese: "quota / rate limit", english: "Quota / rate limit")
        case .unavailable:
            return KizunaCopy.text(japanese: "接続不可", english: "Unavailable")
        }
    }

    private func validateNAGI() {
        saveSecretsAndModelSource()
        guard nagiAvailability == .savedNotVerified else { return }
        isCheckingNAGI = true
        Task { @MainActor in
            let result = await StoryGemma31BAPIService.shared.validateConfiguration()
            nagiAvailability = result
            isCheckingNAGI = false
            saveMessageIsError = !result.isUsable
            saveMessage = result.isUsable
                ? KizunaCopy.text(japanese: "NAGIの接続を確認しました", english: "NAGI connection verified")
                : KizunaCopy.text(japanese: "NAGIの接続を確認できませんでした", english: "NAGI connection could not be verified")
        }
    }

    private func addRegistryConfiguration() {
        let enteredModelID = registryModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedArtifact = registryArtifactID.flatMap { artifactID in
            modelManager.installedModels.first { $0.id == artifactID }
        }
        if registryProvider == .localRuntime,
           registryArtifactID != nil,
           selectedArtifact == nil {
            registryMessage = KizunaCopy.text(
                japanese: "選択したローカルモデルが見つかりません。インストール済みモデルを選び直してください。",
                english: "The selected local model is missing. Choose an installed model again."
            )
            return
        }
        let modelID = enteredModelID.isEmpty && registryProvider == .localRuntime
            ? (selectedArtifact?.id ?? "local-active")
            : enteredModelID
        let displayName = registryDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else {
            registryMessage = KizunaCopy.text(japanese: "Model IDを入力してください。", english: "Enter a model ID.")
            return
        }
        guard !registryRoles.isEmpty else {
            registryMessage = KizunaCopy.text(
                japanese: "少なくとも1つの用途を選択してください。",
                english: "Select at least one role."
            )
            return
        }
        if registryRequiresAPIKey(for: registryProvider, endpoint: registryEndpoint)
            && registryAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            registryMessage = KizunaCopy.text(
                japanese: "このProviderにはAPIキーが必要です。",
                english: "This provider requires an API key."
            )
            return
        }
        if let endpointError = registryEndpointValidationError(
            provider: registryProvider,
            endpoint: registryEndpoint
        ) {
            registryMessage = endpointError
            return
        }
        let configuration = AIModelConfiguration(
            identity: AIModelIdentity(
                providerID: registryProvider,
                modelID: modelID,
                displayName: displayName.isEmpty
                    ? (selectedArtifact?.displayName ?? modelID)
                    : displayName,
                artifactID: registryProvider == .localRuntime ? registryArtifactID : nil
            ),
            roles: registryRoles,
            endpoint: registryProvider == .localRuntime
                ? nil
                : registryEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : registryEndpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            priority: registryPriority,
            isEnabled: registryIsEnabled
        )
        if let error = saveRegistryConfiguration(configuration, apiKey: registryAPIKey) {
            registryMessage = error
            return
        }
        registryModelID = ""
        registryArtifactID = nil
        registryDisplayName = ""
        registryAPIKey = ""
        registryRoles = [.persona]
        registryPriority = 20
        registryIsEnabled = true
        registryMessage = KizunaCopy.text(japanese: "モデル構成を追加しました。", english: "Model configuration added.")
    }

    private func saveRegistryConfiguration(
        _ configuration: AIModelConfiguration,
        apiKey: String
    ) -> String? {
        if let endpointError = registryEndpointValidationError(
            provider: configuration.identity.providerID,
            endpoint: configuration.endpoint
        ) {
            return endpointError
        }
        let previous = AIModelRegistry.shared.configuration(id: configuration.id)
        if registryRequiresAPIKey(for: configuration.identity.providerID, endpoint: configuration.endpoint),
           apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           AISecretStore.shared.providerAPIKey(for: configuration.id) == nil {
            return KizunaCopy.text(
                japanese: "このProviderにはAPIキーが必要です。",
                english: "This provider requires an API key."
            )
        }
        guard AIModelRegistry.shared.register(configuration) else {
            return KizunaCopy.text(
                japanese: "モデル構成を保存できませんでした。",
                english: "The model configuration could not be saved."
            )
        }

        let normalizedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedAPIKey.isEmpty,
           !AISecretStore.shared.setProviderAPIKey(normalizedAPIKey, for: configuration.id) {
            if let previous {
                _ = AIModelRegistry.shared.register(previous)
            } else {
                _ = AIModelRegistry.shared.remove(id: configuration.id)
            }
            return KizunaCopy.text(
                japanese: "APIキーをKeychainに保存できなかったため、モデル構成を保存しませんでした。入力を確認して再試行してください。",
                english: "The model configuration was not saved because its API key could not be stored in Keychain. Check the input and try again."
            )
        }

        registryConfigurations = AIModelRegistry.shared.configurations
        registryConnectionStatuses[configuration.id] = nil
        return nil
    }

    private func removeRegistryConfiguration(_ configuration: AIModelConfiguration) {
        let metadataRemoved = AIModelRegistry.shared.remove(id: configuration.id)
        guard metadataRemoved else {
            registryMessage = KizunaCopy.text(
                japanese: "モデル構成またはAPIキーを削除できませんでした。設定を確認して再試行してください。",
                english: "The model configuration or API key could not be deleted. Check Settings and try again."
            )
            return
        }

        guard AISecretStore.shared.removeProviderAPIKey(for: configuration.id) else {
            // Keep metadata and credentials consistent if Keychain deletion fails.
            _ = AIModelRegistry.shared.register(configuration)
            registryMessage = KizunaCopy.text(
                japanese: "モデル構成またはAPIキーを削除できませんでした。設定を確認して再試行してください。",
                english: "The model configuration or API key could not be deleted. Check Settings and try again."
            )
            return
        }

        registryConfigurations = AIModelRegistry.shared.configurations
        registryConnectionStatuses[configuration.id] = nil
        registryMessage = KizunaCopy.text(japanese: "モデル構成を削除しました。", english: "Model configuration removed.")
    }

    private func registryConnectionStatus(_ configuration: AIModelConfiguration) -> AIRegistryConnectionStatus {
        if let status = registryConnectionStatuses[configuration.id] {
            return status
        }
        guard configuration.isEnabled else { return .disabled }
        if registryEndpointValidationError(
            provider: configuration.identity.providerID,
            endpoint: configuration.endpoint
        ) != nil {
            return .invalidEndpoint
        }
        switch configuration.identity.providerID {
        case .localRuntime:
            if let artifactID = configuration.identity.artifactID,
               LocalAssistantModelManager.shared.modelURL(forArtifactID: artifactID) == nil {
                return .unavailable
            }
            return LocalAssistantModelManager.shared.runtimeAvailability == .executable
                ? .unverified
                : .unavailable
        case .googleGenerativeLanguage:
            return AISecretStore.shared.providerAPIKey(for: configuration.id) != nil
                || AISecretStore.shared.configuredGemmaWebReaderAPIKey() != nil
                ? .unverified
                : .missingCredential
        case .openAICompatible, .anthropic:
            return AISecretStore.shared.providerAPIKey(for: configuration.id) != nil
                ? .unverified
                : .missingCredential
        }
    }

    private func registryConnectionStatusLabel(_ configuration: AIModelConfiguration) -> String {
        switch registryConnectionStatus(configuration) {
        case .unverified:
            return KizunaCopy.text(japanese: "未確認", english: "Not verified")
        case .checking:
            return KizunaCopy.text(japanese: "確認中", english: "Checking")
        case .available:
            return KizunaCopy.text(japanese: "接続確認済み", english: "Verified")
        case .disabled:
            return KizunaCopy.text(japanese: "無効", english: "Disabled")
        case .missingCredential:
            return KizunaCopy.text(japanese: "認証情報なし", english: "Credential missing")
        case .invalidEndpoint:
            return KizunaCopy.text(japanese: "Endpoint不正", english: "Invalid endpoint")
        case .unavailable:
            return KizunaCopy.text(japanese: "接続不可", english: "Unavailable")
        }
    }

    private func registryConnectionStatusIcon(_ configuration: AIModelConfiguration) -> String {
        switch registryConnectionStatus(configuration) {
        case .unverified: return "questionmark.circle"
        case .checking: return "arrow.triangle.2.circlepath"
        case .available: return "checkmark.circle.fill"
        case .disabled: return "pause.circle"
        case .missingCredential, .invalidEndpoint, .unavailable: return "exclamationmark.triangle"
        }
    }

    private func registryConnectionStatusColor(_ configuration: AIModelConfiguration) -> Color {
        switch registryConnectionStatus(configuration) {
        case .available: return .green
        case .checking, .unverified: return .secondary
        case .disabled: return .secondary
        case .missingCredential, .invalidEndpoint, .unavailable: return .orange
        }
    }

    private func verifyRegistryConfiguration(_ configuration: AIModelConfiguration) {
        guard registryConnectionStatus(configuration) != .checking else { return }
        registryConnectionStatuses[configuration.id] = .checking
        Task { @MainActor in
            let request = AIGenerationRequest(
                systemPrompt: "You are testing an AI provider connection. Reply with one short confirmation.",
                userPrompt: "Reply with OK.",
                temperature: 0,
                maxOutputTokens: 8
            )
            do {
                _ = try await AIModelRouter.shared.generate(
                    request: request,
                    configurationID: configuration.id
                )
                registryConnectionStatuses[configuration.id] = .available
                registryMessage = KizunaCopy.text(
                    japanese: "「\(configuration.identity.displayName)」の接続を確認しました。",
                    english: "Connection verified for \(configuration.identity.displayName)."
                )
            } catch let error as AIProviderError {
                switch error {
                case .configurationDisabled:
                    registryConnectionStatuses[configuration.id] = .disabled
                case .missingCredential:
                    registryConnectionStatuses[configuration.id] = .missingCredential
                case .invalidEndpoint:
                    registryConnectionStatuses[configuration.id] = .invalidEndpoint
                case .localArtifactUnavailable, .httpStatus, .invalidResponse, .emptyResponse, .generationTruncated, .noProviderForRole:
                    registryConnectionStatuses[configuration.id] = .unavailable
                }
                registryMessage = KizunaCopy.text(
                    japanese: "「\(configuration.identity.displayName)」へ接続できませんでした。設定と認証情報を確認してください。",
                    english: "Could not connect to \(configuration.identity.displayName). Check its settings and credentials."
                )
            } catch {
                registryConnectionStatuses[configuration.id] = .unavailable
                registryMessage = KizunaCopy.text(
                    japanese: "「\(configuration.identity.displayName)」へ接続できませんでした。EndpointとモデルIDを確認してください。",
                    english: "Could not connect to \(configuration.identity.displayName). Check the endpoint and model ID."
                )
            }
        }
    }

    private func registryRoutingSummary(_ configuration: AIModelConfiguration) -> String {
        let enabled = configuration.isEnabled
            ? KizunaCopy.text(japanese: "有効", english: "Enabled")
            : KizunaCopy.text(japanese: "無効", english: "Disabled")
        let endpoint = configuration.endpoint.map { " · \($0)" } ?? ""
        return registryRoleNames(configuration.roles)
            + " · priority \(configuration.priority) · "
            + enabled
            + endpoint
    }

    private func providerDisplayName(_ provider: AIProviderID) -> String {
        switch provider {
        case .localRuntime: return "Local runtime"
        case .googleGenerativeLanguage: return "Google Generative Language"
        case .openAICompatible: return "OpenAI-compatible"
        case .anthropic: return "Anthropic"
        }
    }

    private func registryDefaultEndpoint(for provider: AIProviderID) -> String {
        switch provider {
        case .localRuntime:
            return ""
        case .googleGenerativeLanguage:
            return "https://generativelanguage.googleapis.com/v1beta"
        case .openAICompatible:
            return "https://api.openai.com/v1"
        case .anthropic:
            return "https://api.anthropic.com/v1/messages"
        }
    }

    private func registryRequiresAPIKey(for provider: AIProviderID, endpoint: String?) -> Bool {
        AIEndpointPolicy.requiresAPIKey(providerID: provider, endpoint: endpoint)
    }

    private func registryEndpointValidationError(
        provider: AIProviderID,
        endpoint: String?
    ) -> String? {
        guard provider != .localRuntime else { return nil }
        let normalized = (endpoint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return KizunaCopy.text(
                japanese: "Endpointを入力してください。",
                english: "Enter an endpoint."
            )
        }
        guard AIEndpointPolicy.allowsEndpoint(providerID: provider, endpoint: normalized) else {
            return KizunaCopy.text(
                japanese: "EndpointはHTTPSを使用してください。HTTPはlocalhost / 127.0.0.1 / ::1だけ利用できます。",
                english: "Use HTTPS for endpoints. HTTP is allowed only for localhost, 127.0.0.1, or ::1."
            )
        }
        return nil
    }

    private func roleDisplayName(_ role: AIModelRole) -> String {
        switch role {
        case .persona: return "Persona"
        case .story: return "Story"
        case .classifier: return "Classifier"
        case .memoryExtraction: return "Memory extraction"
        case .memoryRetrieval: return "Memory retrieval"
        case .sceneCharacterSelection: return "Scene character selection"
        case .sceneSummary: return "Scene summary"
        case .nextSceneSuggestion: return "Next scene suggestion"
        case .safety: return "Safety"
        }
    }

    private func registryRoleNames(_ roles: Set<AIModelRole>) -> String {
        roles.sorted { $0.rawValue < $1.rawValue }.map(roleDisplayName).joined(separator: ", ")
    }

    private var standardModelOptions: [LocalAssistantModelProfile.DownloadOption] {
        LocalAssistantModelProfile.standardDownloadOptions
    }

    private func localizedModelDetail(_ option: LocalAssistantModelProfile.DownloadOption) -> String {
        KizunaCopy.text(japanese: option.detail, english: option.englishDetail)
    }

    private var selectedStandardModelRequiresToken: Bool {
        selectedStandardModelURL.contains("google/gemma-3n")
    }

    private func simplePresetName(_ preset: AISimpleModelPreset) -> String {
        switch preset {
        case .automatic:
            return KizunaCopy.text(japanese: "おまかせ", english: "Automatic")
        case .stable:
            return KizunaCopy.text(japanese: "安定", english: "Stable")
        case .balanced:
            return KizunaCopy.text(japanese: "バランス", english: "Balanced")
        case .creative:
            return KizunaCopy.text(japanese: "自由", english: "Creative")
        case .fast:
            return KizunaCopy.text(japanese: "高速", english: "Fast")
        }
    }

    private func simplePresetDetail(_ preset: AISimpleModelPreset) -> String {
        switch preset {
        case .automatic:
            return KizunaCopy.text(
                japanese: "端末・モデル・用途に合わせてKizunaが推奨値を選びます。",
                english: "Kizuna chooses recommended values for the device, model, and use case."
            )
        case .stable:
            return KizunaCopy.text(
                japanese: "回答の揺らぎを抑え、安定性を優先します。",
                english: "Reduces variation and prioritizes consistent replies."
            )
        case .balanced:
            return KizunaCopy.text(
                japanese: "安定性と表現の幅を両立します。",
                english: "Balances consistency with expressive range."
            )
        case .creative:
            return KizunaCopy.text(
                japanese: "表現の幅と意外性を広げます。",
                english: "Allows broader and less predictable expression."
            )
        case .fast:
            return KizunaCopy.text(
                japanese: "短めの応答と軽い設定で速度を優先します。",
                english: "Prioritizes speed with shorter replies and lighter settings."
            )
        }
    }

    private func simpleModelRouteName(_ route: AISimpleModelRoute) -> String {
        switch route {
        case .automatic:
            return KizunaCopy.text(japanese: "おまかせ", english: "Automatic")
        case .onDevice:
            return KizunaCopy.text(japanese: "端末内を優先", english: "Prefer on-device")
        case .online:
            return KizunaCopy.text(japanese: "オンラインを優先", english: "Prefer online")
        }
    }

    private func simpleModelRouteDetail(_ route: AISimpleModelRoute) -> String {
        switch route {
        case .automatic:
            return KizunaCopy.text(
                japanese: "用途と利用可能なモデルから、Kizunaが互換性の高い経路を選びます。",
                english: "Kizuna chooses a compatible route from the use case and available models."
            )
        case .onDevice:
            return KizunaCopy.text(
                japanese: "会話データを端末内で処理できるモデルを優先します。",
                english: "Prefer a model that can process the conversation on this device."
            )
        case .online:
            return KizunaCopy.text(
                japanese: "オンラインProviderを優先します。利用できない場合は安全にfallbackします。",
                english: "Prefer an online provider and fall back safely when it is unavailable."
            )
        }
    }
}

private struct AIAdvancedModelSettingsView: View {
    @State private var resetMessage: String? = nil

    var body: some View {
        Form {
            Section {
                ForEach(AIModelTuningScope.allCases, id: \.self) { scope in
                    NavigationLink {
                        if scope == .auxiliary {
                            AIAdvancedAuxiliaryModelSettingsView()
                        } else {
                            AIAdvancedScopeSettingsView(scope: scope)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(scopeName(scope))
                            Text(scopeDetail(scope))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text(KizunaCopy.text(japanese: "用途別設定", english: "Settings by use case"))
            } footer: {
                Text(KizunaCopy.text(
                    japanese: "未指定の値はKizunaの安全な内蔵Presetを継承します。モデルを切り替えても用途別設定は保持され、非対応の値は送信されません。",
                    english: "Unset values inherit Kizuna's built-in recommendations. Use-case settings survive model changes, and unsupported values are not sent."
                ))
            }

            Section {
                Button {
                    _ = AIModelTuningStore.shared.resetAdvancedOverrides()
                    resetMessage = KizunaCopy.text(
                        japanese: "すべての詳細設定をKizuna推奨値へ戻しました。",
                        english: "All advanced overrides were restored to Kizuna recommendations."
                    )
                } label: {
                    Label(
                        KizunaCopy.text(japanese: "Kizuna推奨設定に戻す", english: "Restore Kizuna recommendations"),
                        systemImage: "arrow.counterclockwise"
                    )
                }
                if let resetMessage {
                    Text(resetMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(KizunaCopy.text(japanese: "詳細なモデル設定", english: "Advanced model settings"))
    }

    private func scopeName(_ scope: AIModelTuningScope) -> String {
        switch scope {
        case .persona: return "Persona"
        case .story: return "Story"
        case .auxiliary: return KizunaCopy.text(japanese: "補助AI / Memory", english: "Auxiliary / Memory")
        }
    }

    private func scopeDetail(_ scope: AIModelTuningScope) -> String {
        switch scope {
        case .persona:
            return KizunaCopy.text(japanese: "キャラクター会話", english: "Character conversations")
        case .story:
            return KizunaCopy.text(japanese: "物語本文と雛形生成", english: "Story turns and template generation")
        case .auxiliary:
            return KizunaCopy.text(japanese: "分類・記憶・Scene補助", english: "Classification, memory, and scene helpers")
        }
    }
}

private struct AIAdvancedAuxiliaryModelSettingsView: View {
    @State private var resetMessage: String?

    var body: some View {
        Form {
            Section {
                ForEach(AIModelRole.auxiliaryCases, id: \.self) { role in
                    AIAuxiliaryRoleModelSelectionRow(role: role)
                }
            } header: {
                Text(KizunaCopy.text(
                    japanese: "補助AIの用途別モデル",
                    english: "Models by auxiliary role"
                ))
            } footer: {
                Text(KizunaCopy.text(
                    japanese: "Memory、Scene、Safetyなどは、それぞれのRoleに登録されたモデルから選びます。未指定なら優先度順のおまかせです。",
                    english: "Memory, Scene, and Safety roles choose from their own registered models. Unset roles use automatic priority order."
                ))
            }

            Section {
                Button {
                    for role in AIModelRole.auxiliaryCases {
                        _ = AIModelTuningStore.shared.setPreferredConfigurationID(nil, for: role)
                    }
                    resetMessage = KizunaCopy.text(
                        japanese: "補助AIのモデル選択をおまかせに戻しました。",
                        english: "Auxiliary model selections were restored to automatic."
                    )
                } label: {
                    Label(
                        KizunaCopy.text(japanese: "補助AIをおまかせに戻す", english: "Restore auxiliary automatic routing"),
                        systemImage: "arrow.counterclockwise"
                    )
                }
                if let resetMessage {
                    Text(resetMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(KizunaCopy.text(japanese: "補助AIモデル", english: "Auxiliary models"))
    }
}

private struct AIAuxiliaryRoleModelSelectionRow: View {
    let role: AIModelRole
    private let candidateConfigurations: [AIModelConfiguration]
    @State private var selectedConfigurationID: UUID?

    init(role: AIModelRole) {
        self.role = role
        let candidates = AIModelRegistry.shared.configurations(for: role)
        candidateConfigurations = candidates
        let stored = AIModelTuningStore.shared.preferredConfigurationID(for: role)
        _selectedConfigurationID = State(
            initialValue: candidates.contains(where: { $0.id == stored }) ? stored : nil
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker(roleName, selection: $selectedConfigurationID) {
                Text(KizunaCopy.text(japanese: "自動（優先度順）", english: "Automatic (priority order)"))
                    .tag(Optional<UUID>.none)
                ForEach(candidateConfigurations) { configuration in
                    Text("\(configuration.identity.displayName) · \(providerName(configuration.identity.providerID))")
                        .tag(Optional(configuration.id))
                }
            }
            .onChange(of: selectedConfigurationID) { _, newValue in
                _ = AIModelTuningStore.shared.setPreferredConfigurationID(newValue, for: role)
            }
            if candidateConfigurations.isEmpty {
                Text(KizunaCopy.text(
                    japanese: "このRoleに登録されたモデルはありません。",
                    english: "No model is registered for this role."
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var roleName: String {
        switch role {
        case .classifier: return "Classifier"
        case .memoryExtraction: return "Memory extraction"
        case .memoryRetrieval: return "Memory retrieval"
        case .sceneCharacterSelection: return "Scene character selection"
        case .sceneSummary: return "Scene summary"
        case .nextSceneSuggestion: return "Next scene suggestion"
        case .safety: return "Safety"
        case .persona, .story: return role.rawValue
        }
    }

    private func providerName(_ provider: AIProviderID) -> String {
        switch provider {
        case .localRuntime: return "Local"
        case .googleGenerativeLanguage: return "Google"
        case .openAICompatible: return "OpenAI-compatible"
        case .anthropic: return "Anthropic"
        }
    }
}

private struct AIAdvancedScopeSettingsView: View {
    let scope: AIModelTuningScope
    private let candidateConfigurations: [AIModelConfiguration]
    @State private var selectedConfigurationID: UUID?
    @State private var overrides: AIGenerationOverrides

    init(scope: AIModelTuningScope) {
        self.scope = scope
        let configurations = AIModelRegistry.shared.configurations(for: scope.routingRole)
        candidateConfigurations = configurations
        let storedSelection = AIModelTuningStore.shared.preferredConfigurationID(for: scope)
        _selectedConfigurationID = State(
            initialValue: configurations.contains(where: { $0.id == storedSelection })
                ? storedSelection
                : nil
        )
        _overrides = State(
            initialValue: AIModelTuningStore.shared.preferences.overrides(for: scope)
        )
    }

    private var configuration: AIModelConfiguration? {
        if let selectedConfigurationID,
           let selected = candidateConfigurations.first(where: { $0.id == selectedConfigurationID }) {
            return selected
        }
        return candidateConfigurations.first
    }

    private var providerID: AIProviderID {
        configuration?.identity.providerID ?? .localRuntime
    }

    private var capabilities: AIProviderParameterCapabilities {
        if let configuration {
            return .capabilities(for: configuration)
        }
        return .capabilities(for: providerID)
    }

    private var temperatureMaximum: Double {
        providerID == .anthropic ? 1.0 : 2.0
    }

    var body: some View {
        Form {
            Section(KizunaCopy.text(japanese: "現在の経路", english: "Current route")) {
                LabeledContent(
                    KizunaCopy.text(japanese: "用途", english: "Use case"),
                    value: scopeDisplayName
                )
                if !candidateConfigurations.isEmpty {
                    Picker(
                        KizunaCopy.text(japanese: "使用モデル", english: "Selected model"),
                        selection: $selectedConfigurationID
                    ) {
                        Text(KizunaCopy.text(
                            japanese: "自動（優先度順）",
                            english: "Automatic (priority order)"
                        ))
                            .tag(Optional<UUID>.none)
                        ForEach(candidateConfigurations) { candidate in
                            Text(modelSelectionLabel(candidate))
                                .tag(Optional(candidate.id))
                        }
                    }
                    .onChange(of: selectedConfigurationID) { _, newValue in
                        _ = AIModelTuningStore.shared.setPreferredConfigurationID(newValue, for: scope)
                    }
                }
                if let configuration {
                    LabeledContent("Provider", value: providerDisplayName(configuration.identity.providerID))
                    LabeledContent(
                        KizunaCopy.text(japanese: "モデル", english: "Model"),
                        value: configuration.identity.displayName
                    )
                } else {
                    Text(KizunaCopy.text(
                        japanese: "この用途に有効なモデルがありません。先にAI model registryで追加してください。",
                        english: "No enabled model is configured for this use case. Add one in the AI model registry first."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                parameterToggle(
                    KizunaCopy.text(japanese: "Temperatureを上書き", english: "Override temperature"),
                    parameter: .temperature,
                    isOn: optionalEnabled(\.temperature, defaultValue: 0.72)
                )
                if overrides.temperature != nil {
                    Slider(
                        value: optionalValue(\.temperature, defaultValue: 0.72),
                        in: 0...temperatureMaximum,
                        step: 0.05
                    )
                    LabeledContent("Temperature", value: String(format: "%.2f", overrides.temperature ?? 0.72))
                }

                if capabilities.supports(.topP) {
                    parameterToggle("Top P", parameter: .topP, isOn: optionalEnabled(\.topP, defaultValue: 0.92))
                    if overrides.topP != nil {
                        Slider(value: optionalValue(\.topP, defaultValue: 0.92), in: 0...1, step: 0.01)
                        LabeledContent("Top P", value: String(format: "%.2f", overrides.topP ?? 0.92))
                    }
                } else {
                    unsupportedRow("Top P")
                }

                if capabilities.supports(.topK) {
                    parameterToggle("Top K", parameter: .topK, isOn: optionalEnabled(\.topK, defaultValue: 40))
                    if overrides.topK != nil {
                        Stepper(value: optionalValue(\.topK, defaultValue: 40), in: 1...200) {
                            LabeledContent("Top K", value: "\(overrides.topK ?? 40)")
                        }
                    }
                } else {
                    unsupportedRow("Top K")
                }

                parameterToggle(
                    KizunaCopy.text(japanese: "最大出力Token", english: "Maximum output tokens"),
                    parameter: .maxOutputTokens,
                    isOn: optionalEnabled(\.maxOutputTokens, defaultValue: 1_024)
                )
                if overrides.maxOutputTokens != nil {
                    Stepper(
                        value: optionalValue(\.maxOutputTokens, defaultValue: 1_024),
                        in: 64...32_768,
                        step: 64
                    ) {
                        LabeledContent(
                            KizunaCopy.text(japanese: "最大出力", english: "Maximum output"),
                            value: "\(overrides.maxOutputTokens ?? 1_024)"
                        )
                    }
                }

                if capabilities.supports(.seed) {
                    parameterToggle("Seed", parameter: .seed, isOn: optionalEnabled(\.seed, defaultValue: 24))
                    if overrides.seed != nil {
                        Stepper(value: optionalValue(\.seed, defaultValue: 24), in: 0...999_999) {
                            LabeledContent("Seed", value: "\(overrides.seed ?? 24)")
                        }
                    }
                } else {
                    unsupportedRow("Seed")
                }
            } header: {
                Text(KizunaCopy.text(japanese: "生成", english: "Generation"))
            } footer: {
                Text(KizunaCopy.text(
                    japanese: "上書きをOFFにすると、その用途に合わせた内蔵値へ戻ります。",
                    english: "Turn an override off to inherit the built-in value for that use case."
                ))
            }

            if providerID == .localRuntime {
                Section {
                    runtimeParameterToggle(
                        KizunaCopy.text(japanese: "Context sizeを上書き", english: "Override context size"),
                        parameter: .contextSize,
                        isOn: runtimeEnabled(\.contextSize, defaultValue: 8_192)
                    )
                    if overrides.localRuntime?.contextSize != nil {
                        Stepper(
                            value: runtimeValue(\.contextSize, defaultValue: 8_192),
                            in: 1_024...131_072,
                            step: 1_024
                        ) {
                            LabeledContent("Context", value: "\(overrides.localRuntime?.contextSize ?? 8_192)")
                        }
                    }

                    runtimeParameterToggle(
                        KizunaCopy.text(japanese: "Batch sizeを上書き", english: "Override batch size"),
                        parameter: .batchSize,
                        isOn: runtimeEnabled(\.batchSize, defaultValue: 128)
                    )
                    if overrides.localRuntime?.batchSize != nil {
                        Stepper(
                            value: runtimeValue(\.batchSize, defaultValue: 128),
                            in: 1...2_048,
                            step: 16
                        ) {
                            LabeledContent("Batch", value: "\(overrides.localRuntime?.batchSize ?? 128)")
                        }
                    }

                    runtimeParameterToggle(
                        KizunaCopy.text(japanese: "Threadsを上書き", english: "Override threads"),
                        parameter: .threads,
                        isOn: runtimeEnabled(\.threadCount, defaultValue: 4)
                    )
                    if overrides.localRuntime?.threadCount != nil {
                        Stepper(value: runtimeValue(\.threadCount, defaultValue: 4), in: 1...64) {
                            LabeledContent("Threads", value: "\(overrides.localRuntime?.threadCount ?? 4)")
                        }
                    }

                    runtimeParameterToggle(
                        KizunaCopy.text(japanese: "GPU layersを上書き", english: "Override GPU layers"),
                        parameter: .gpuLayers,
                        isOn: runtimeEnabled(\.gpuLayers, defaultValue: 24)
                    )
                    if overrides.localRuntime?.gpuLayers != nil {
                        Stepper(value: runtimeValue(\.gpuLayers, defaultValue: 24), in: 0...999) {
                            LabeledContent("GPU layers", value: "\(overrides.localRuntime?.gpuLayers ?? 24)")
                        }
                    }

                    runtimeParameterToggle(
                        KizunaCopy.text(japanese: "Flash Attentionを上書き", english: "Override Flash Attention"),
                        parameter: .flashAttention,
                        isOn: runtimeEnabled(\.flashAttentionEnabled, defaultValue: true)
                    )
                    if overrides.localRuntime?.flashAttentionEnabled != nil {
                        Toggle(
                            "Flash Attention",
                            isOn: runtimeValue(\.flashAttentionEnabled, defaultValue: true)
                        )
                    }
                } header: {
                    Text(KizunaCopy.text(japanese: "ローカル実行", english: "Local runtime"))
                } footer: {
                    Text(KizunaCopy.text(
                        japanese: "Context / Batch / Threads / GPU設定は、選択中のローカルエンジンが対応する場合だけ適用されます。LiteRT-LMなど非対応の項目は安全に無視されます。",
                        english: "Context, batch, thread, and GPU values apply only when the selected local engine supports them. Unsupported fields, including some LiteRT-LM options, are safely ignored."
                    ))
                }
            }

            Section {
                Button {
                    overrides = AIGenerationOverrides()
                    _ = AIModelTuningStore.shared.setOverrides(overrides, for: scope)
                } label: {
                    Label(
                        KizunaCopy.text(japanese: "この用途をKizuna推奨値に戻す", english: "Restore recommendations for this use case"),
                        systemImage: "arrow.counterclockwise"
                    )
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(scopeDisplayName)
        .onChange(of: overrides) { _, newValue in
            _ = AIModelTuningStore.shared.setOverrides(newValue, for: scope)
        }
    }

    @ViewBuilder
    private func parameterToggle(
        _ title: String,
        parameter: AIModelTuningParameter,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(title, isOn: isOn)
            .disabled(!capabilities.supports(parameter))
    }

    @ViewBuilder
    private func runtimeParameterToggle(
        _ title: String,
        parameter: AIModelTuningParameter,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(title, isOn: isOn)
            .disabled(!capabilities.supports(parameter))
    }

    @ViewBuilder
    private func unsupportedRow(_ name: String) -> some View {
        LabeledContent(
            name,
            value: KizunaCopy.text(japanese: "このProviderでは非対応", english: "Not supported by this provider")
        )
            .foregroundStyle(.secondary)
    }

    private func optionalEnabled<Value>(
        _ keyPath: WritableKeyPath<AIGenerationOverrides, Value?>,
        defaultValue: Value
    ) -> Binding<Bool> {
        Binding(
            get: { overrides[keyPath: keyPath] != nil },
            set: { enabled in
                overrides[keyPath: keyPath] = enabled ? defaultValue : nil
            }
        )
    }

    private func optionalValue<Value>(
        _ keyPath: WritableKeyPath<AIGenerationOverrides, Value?>,
        defaultValue: Value
    ) -> Binding<Value> {
        Binding(
            get: { overrides[keyPath: keyPath] ?? defaultValue },
            set: { overrides[keyPath: keyPath] = $0 }
        )
    }

    private func runtimeEnabled<Value>(
        _ keyPath: WritableKeyPath<AILocalRuntimeOverrides, Value?>,
        defaultValue: Value
    ) -> Binding<Bool> {
        Binding(
            get: {
                guard let runtime = overrides.localRuntime else { return false }
                return runtime[keyPath: keyPath] != nil
            },
            set: { enabled in
                var runtime = overrides.localRuntime ?? AILocalRuntimeOverrides()
                runtime[keyPath: keyPath] = enabled ? defaultValue : nil
                overrides.localRuntime = runtime.isEmpty ? nil : runtime
            }
        )
    }

    private func runtimeValue<Value>(
        _ keyPath: WritableKeyPath<AILocalRuntimeOverrides, Value?>,
        defaultValue: Value
    ) -> Binding<Value> {
        Binding(
            get: {
                guard let runtime = overrides.localRuntime else { return defaultValue }
                return runtime[keyPath: keyPath] ?? defaultValue
            },
            set: { value in
                var runtime = overrides.localRuntime ?? AILocalRuntimeOverrides()
                runtime[keyPath: keyPath] = value
                overrides.localRuntime = runtime
            }
        )
    }

    private var scopeDisplayName: String {
        switch scope {
        case .persona: return "Persona"
        case .story: return "Story"
        case .auxiliary: return KizunaCopy.text(japanese: "補助AI / Memory", english: "Auxiliary / Memory")
        }
    }

    private func providerDisplayName(_ provider: AIProviderID) -> String {
        switch provider {
        case .localRuntime: return "Local runtime"
        case .googleGenerativeLanguage: return "Google Generative Language"
        case .openAICompatible: return "OpenAI-compatible"
        case .anthropic: return "Anthropic"
        }
    }

    private func modelSelectionLabel(_ configuration: AIModelConfiguration) -> String {
        let provider = providerDisplayName(configuration.identity.providerID)
        return "\(configuration.identity.displayName) · \(provider)"
    }

    private static func fallbackConfiguration(for scope: AIModelTuningScope) -> AIModelConfiguration? {
        let registry = AIModelRegistry.shared
        switch scope {
        case .persona:
            return registry.configurations(for: .persona).first
        case .story:
            return registry.configurations(for: .story).first
        case .auxiliary:
            return registry.configurations(for: .memoryExtraction).first
                ?? registry.configurations(for: .sceneSummary).first
                ?? registry.configurations(for: .safety).first
        }
    }
}

private struct AIModelRegistryEditorView: View {
    let configuration: AIModelConfiguration
    let onSave: (AIModelConfiguration, String) -> String?

    @ObservedObject private var modelManager = LocalAssistantModelManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var provider: AIProviderID
    @State private var modelID: String
    @State private var artifactID: String?
    @State private var displayName: String
    @State private var endpoint: String
    @State private var apiKey = ""
    @State private var roles: Set<AIModelRole>
    @State private var priority: Int
    @State private var isEnabled: Bool
    @State private var disabledCompatibilityParameters: Set<AIModelTuningParameter>
    @State private var validationMessage: String?

    init(
        configuration: AIModelConfiguration,
        onSave: @escaping (AIModelConfiguration, String) -> String?
    ) {
        self.configuration = configuration
        self.onSave = onSave
        let initialProvider = configuration.identity.providerID
        _provider = State(initialValue: initialProvider)
        _modelID = State(initialValue: configuration.identity.modelID)
        _artifactID = State(initialValue: configuration.identity.artifactID)
        _displayName = State(initialValue: configuration.identity.displayName)
        _endpoint = State(initialValue: configuration.endpoint ?? Self.defaultEndpoint(for: initialProvider))
        _roles = State(initialValue: configuration.roles)
        _priority = State(initialValue: configuration.priority)
        _isEnabled = State(initialValue: configuration.isEnabled)
        _disabledCompatibilityParameters = State(
            initialValue: configuration.compatibility?.disabledParameters ?? []
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(KizunaCopy.text(japanese: "モデル", english: "Model")) {
                    Picker(
                        KizunaCopy.text(japanese: "Provider", english: "Provider"),
                        selection: $provider
                    ) {
                        ForEach(AIProviderID.allCases, id: \.self) { item in
                            Text(Self.providerDisplayName(item)).tag(item)
                        }
                    }
                    .onChange(of: provider) { oldProvider, newProvider in
                        let currentEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                        if currentEndpoint.isEmpty || currentEndpoint == Self.defaultEndpoint(for: oldProvider) {
                            endpoint = Self.defaultEndpoint(for: newProvider)
                        }
                        if newProvider != .localRuntime {
                            artifactID = nil
                        }
                        disabledCompatibilityParameters.removeAll()
                    }
                    TextField(
                        KizunaCopy.text(japanese: "Model ID", english: "Model ID"),
                        text: $modelID
                    )
                    .autocorrectionDisabled()
                    TextField(
                        KizunaCopy.text(japanese: "表示名", english: "Display name"),
                        text: $displayName
                    )
                    if provider == .localRuntime {
                        Text(KizunaCopy.text(
                            japanese: "ローカルランタイムではEndpointは必要ありません。",
                            english: "Local runtime does not require an endpoint."
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker(
                            KizunaCopy.text(japanese: "使用するインストール済みモデル", english: "Installed model to use"),
                            selection: $artifactID
                        ) {
                            Text(KizunaCopy.text(
                                japanese: "現在のアクティブモデルに追従",
                                english: "Follow active local model"
                            ))
                            .tag(Optional<String>.none)
                            ForEach(modelManager.installedModels) { model in
                                Text("\(model.displayName) · \(model.fileName)")
                                    .tag(Optional(model.id))
                            }
                        }
                        if let artifactID,
                           !modelManager.installedModels.contains(where: { $0.id == artifactID }) {
                            Text(KizunaCopy.text(
                                japanese: "この構成が参照していたモデルは見つかりません。別のモデルを選ぶか、active modelに追従へ変更してください。",
                                english: "The artifact referenced by this configuration is missing. Choose another model or follow the active model."
                            ))
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    } else {
                        TextField(
                            KizunaCopy.text(japanese: "Endpoint", english: "Endpoint"),
                            text: $endpoint
                        )
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                    }
                }

                Section(KizunaCopy.text(japanese: "互換性", english: "Compatibility")) {
                    Text(KizunaCopy.text(
                        japanese: "モデルが受け付けない任意パラメータをOFFにすると、その値をリクエストから除外できます。",
                        english: "Turn off optional parameters that this model rejects to omit them from requests."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(
                        AIModelTuningParameter.allCases.filter {
                            AIProviderParameterCapabilities.capabilities(for: provider).supports($0)
                        },
                        id: \.self
                    ) { parameter in
                        Toggle(
                            Self.compatibilityParameterName(parameter),
                            isOn: Binding(
                                get: { !disabledCompatibilityParameters.contains(parameter) },
                                set: { enabled in
                                    if enabled {
                                        disabledCompatibilityParameters.remove(parameter)
                                    } else {
                                        disabledCompatibilityParameters.insert(parameter)
                                    }
                                }
                            )
                        )
                    }
                }

                Section(KizunaCopy.text(japanese: "用途", english: "Roles")) {
                    ForEach(AIModelRole.allCases, id: \.self) { role in
                        Toggle(
                            Self.roleDisplayName(role),
                            isOn: Binding(
                                get: { roles.contains(role) },
                                set: { isSelected in
                                    if isSelected {
                                        roles.insert(role)
                                    } else {
                                        roles.remove(role)
                                    }
                                }
                            )
                        )
                    }
                }

                Section(KizunaCopy.text(japanese: "Routing", english: "Routing")) {
                    Stepper(value: $priority, in: -100...100) {
                        LabeledContent(
                            KizunaCopy.text(japanese: "優先度（小さいほど先）", english: "Priority (lower first)"),
                            value: "\(priority)"
                        )
                    }
                    Toggle(
                        KizunaCopy.text(japanese: "有効", english: "Enabled"),
                        isOn: $isEnabled
                    )
                }

                Section(KizunaCopy.text(japanese: "認証", english: "Credentials")) {
                    SecureField(
                        Self.requiresAPIKey(for: provider, endpoint: endpoint)
                            ? KizunaCopy.text(japanese: "APIキー（必須・変更時のみ入力）", english: "API key (required; enter only to change)")
                            : KizunaCopy.text(japanese: "APIキー（変更時のみ入力）", english: "API key (enter only to change)"),
                        text: $apiKey
                    )
                    .textContentType(.password)
                    Text(KizunaCopy.text(
                        japanese: "空欄のまま保存すると、既存のAPIキーを保持します。",
                        english: "Leave this empty to keep the existing API key."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(KizunaCopy.text(japanese: "モデル構成を編集", english: "Edit model configuration"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(KizunaCopy.text(japanese: "キャンセル", english: "Cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(KizunaCopy.text(japanese: "保存", english: "Save")) {
                        save()
                    }
                }
            }
        }
    }

    private func save() {
        let trimmedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelID.isEmpty else {
            validationMessage = KizunaCopy.text(japanese: "Model IDを入力してください。", english: "Enter a model ID.")
            return
        }
        guard !roles.isEmpty else {
            validationMessage = KizunaCopy.text(
                japanese: "少なくとも1つの用途を選択してください。",
                english: "Select at least one role."
            )
            return
        }

        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider == .localRuntime,
           let artifactID,
           !modelManager.installedModels.contains(where: { $0.id == artifactID }) {
            validationMessage = KizunaCopy.text(
                japanese: "選択したローカルモデルが見つかりません。別のモデルを選ぶか、active modelに追従へ変更してください。",
                english: "The selected local model is missing. Choose another model or follow the active model."
            )
            return
        }
        let hasExistingAPIKey = AISecretStore.shared.providerAPIKey(for: configuration.id) != nil
        if Self.requiresAPIKey(for: provider, endpoint: trimmedEndpoint)
            && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !hasExistingAPIKey {
            validationMessage = KizunaCopy.text(
                japanese: "このProviderにはAPIキーが必要です。",
                english: "This provider requires an API key."
            )
            return
        }

        let compatibility = disabledCompatibilityParameters.isEmpty
            ? nil
            : AIModelCompatibilitySettings(
                disabledParameters: disabledCompatibilityParameters
            )
        let updated = AIModelConfiguration(
            id: configuration.id,
            identity: AIModelIdentity(
                providerID: provider,
                modelID: trimmedModelID,
                displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? trimmedModelID
                    : displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                artifactID: provider == .localRuntime ? artifactID : nil
            ),
            roles: roles,
            endpoint: provider == .localRuntime || trimmedEndpoint.isEmpty ? nil : trimmedEndpoint,
            priority: priority,
            isEnabled: isEnabled,
            compatibility: compatibility
        )
        if let error = onSave(updated, apiKey) {
            validationMessage = error
        } else {
            dismiss()
        }
    }

    private static func providerDisplayName(_ provider: AIProviderID) -> String {
        switch provider {
        case .localRuntime: return "Local runtime"
        case .googleGenerativeLanguage: return "Google Generative Language"
        case .openAICompatible: return "OpenAI-compatible"
        case .anthropic: return "Anthropic"
        }
    }

    private static func compatibilityParameterName(_ parameter: AIModelTuningParameter) -> String {
        switch parameter {
        case .temperature: return "Temperature"
        case .topP: return "Top P"
        case .topK: return "Top K"
        case .maxOutputTokens: return KizunaCopy.text(japanese: "最大出力Token", english: "Maximum output tokens")
        case .seed: return "Seed"
        case .contextSize: return KizunaCopy.text(japanese: "Context size", english: "Context size")
        case .batchSize: return "Batch size"
        case .threads: return "Threads"
        case .gpuLayers: return "GPU layers"
        case .flashAttention: return "Flash Attention"
        }
    }

    private static func roleDisplayName(_ role: AIModelRole) -> String {
        switch role {
        case .persona: return "Persona"
        case .story: return "Story"
        case .classifier: return "Classifier"
        case .memoryExtraction: return "Memory extraction"
        case .memoryRetrieval: return "Memory retrieval"
        case .sceneCharacterSelection: return "Scene character selection"
        case .sceneSummary: return "Scene summary"
        case .nextSceneSuggestion: return "Next scene suggestion"
        case .safety: return "Safety"
        }
    }

    private static func defaultEndpoint(for provider: AIProviderID) -> String {
        switch provider {
        case .localRuntime:
            return ""
        case .googleGenerativeLanguage:
            return "https://generativelanguage.googleapis.com/v1beta"
        case .openAICompatible:
            return "https://api.openai.com/v1"
        case .anthropic:
            return "https://api.anthropic.com/v1/messages"
        }
    }

    private static func requiresAPIKey(for provider: AIProviderID, endpoint: String) -> Bool {
        AIEndpointPolicy.requiresAPIKey(providerID: provider, endpoint: endpoint)
    }
}

private enum LocalModelSourceSelection: String, CaseIterable, Identifiable {
    case standard
    case huggingFace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return KizunaCopy.text(japanese: "標準モデル", english: "Standard model")
        case .huggingFace: return KizunaCopy.text(japanese: "Hugging Faceから選択", english: "Choose from Hugging Face")
        }
    }

    var icon: String {
        switch self {
        case .standard: return "shippingbox.fill"
        case .huggingFace: return "arrow.down.circle"
        }
    }
}
