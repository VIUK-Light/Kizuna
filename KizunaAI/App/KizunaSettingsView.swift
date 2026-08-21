import SwiftUI
import UniformTypeIdentifiers

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
    @State private var registryDisplayName = ""
    @State private var registryEndpoint = "https://api.openai.com/v1"
    @State private var registryAPIKey = ""
    @State private var registryRole: AIModelRole = .persona
    @State private var registryMessage: String?
    @State private var modelSourceSelection: LocalModelSourceSelection = .standard
    @State private var selectedStandardModelURL = LocalAssistantModelProfile.defaultDownloadURL
    @State private var selectedActiveModelID = ""
    @State private var selectedAuxiliaryModelID = "__automatic__"
    @State private var saveMessage: String?
    @State private var saveMessageIsError = false
    @State private var showDeleteAlert = false
    @State private var showClearProfileAlert = false
    @State private var showResetLaunchAlert = false
    @State private var showUnsavedChangesAlert = false
    @State private var isShowingProfile = false
    @State private var isImportingLocalModel = false
    @AppStorage("kizuna.language") private var languageRawValue = KizunaLanguage.japanese.rawValue
#if DEBUG
    @AppStorage("kizuna.debug.restSuggestion.enabled") private var debugRestSuggestionEnabled = false
#endif

    private var canDownload: Bool {
        modelSourceSelection == .standard
            || !modelSourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                    if profileStore.profile.hasUsefulContent {
                        Button(KizunaCopy.text(japanese: "プロフィールを消去", english: "Clear profile"), role: .destructive) {
                            showClearProfileAlert = true
                        }
                    }
                } header: {
                    Text(KizunaCopy.text(japanese: "プロフィール", english: "Profile"))
                }

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
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(configuration.identity.displayName)
                                    .font(.headline)
                                Spacer()
                                Button(role: .destructive) {
                                    removeRegistryConfiguration(configuration)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                            Text(configuration.identity.stableID)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(
                                registryRoleNames(configuration.roles)
                                    + (configuration.endpoint.map { " · " + $0 } ?? "")
                            )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
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
                    TextField(
                        KizunaCopy.text(japanese: "Model ID", english: "Model ID"),
                        text: $registryModelID
                    )
                    .autocorrectionDisabled()
                    TextField(
                        KizunaCopy.text(japanese: "表示名", english: "Display name"),
                        text: $registryDisplayName
                    )
                    TextField(
                        KizunaCopy.text(japanese: "Base URL（必要なProviderのみ）", english: "Base URL (when required)"),
                        text: $registryEndpoint
                    )
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    if registryProvider != .localRuntime {
                        SecureField(
                            KizunaCopy.text(japanese: "APIキー（任意）", english: "API key (optional)"),
                            text: $registryAPIKey
                        )
                        .textContentType(.password)
                    }
                    Picker(
                        KizunaCopy.text(japanese: "用途", english: "Role"),
                        selection: $registryRole
                    ) {
                        ForEach(AIModelRole.allCases, id: \.self) { role in
                            Text(roleDisplayName(role)).tag(role)
                        }
                    }
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
                            Button(modelManager.installedModelURL == nil
                                   ? KizunaCopy.text(japanese: "モデルをダウンロード", english: "Download model")
                                   : KizunaCopy.text(japanese: "再ダウンロード", english: "Download again")) {
                                saveSecretsAndModelSource()
                                modelManager.startDownload()
                            }
                            .buttonStyle(.bordered)
                            .disabled(!canDownload)
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

                    if modelManager.installedModelURL != nil {
                        Button(KizunaCopy.text(japanese: "ローカルモデルを削除", english: "Delete local model"), role: .destructive) {
                            showDeleteAlert = true
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
        .alert(KizunaCopy.text(japanese: "ローカルモデルを削除しますか？", english: "Delete the local model?"), isPresented: $showDeleteAlert) {
            Button(KizunaCopy.text(japanese: "削除", english: "Delete"), role: .destructive) {
                modelManager.removeInstalledModel()
            }
            Button(KizunaCopy.text(japanese: "キャンセル", english: "Cancel"), role: .cancel) {}
        } message: {
            Text(KizunaCopy.text(japanese: "この操作は取り消せません。", english: "This action cannot be undone."))
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
                japanese: "名前、プロフィール画像、標準アバターの選択、会話設定が消去されます。この操作は取り消せません。",
                english: "Your name, profile photo, standard avatar selection, and conversation preference will be reset. This cannot be undone."
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
        .sheet(isPresented: $isShowingProfile) {
            KizunaUserProfileView(store: KizunaUserProfileStore.shared)
                .viukAdaptiveSheetSizing(minWidth: 520, minHeight: 620)
        }
        .onAppear {
            nagiAPIKey = AISecretStore.shared.string(for: .gemmaWebReaderAPIKey) ?? ""
            nagiAvailability = StoryGemma31BAPIService.shared.availability
            registryConfigurations = AIModelRegistry.shared.configurations
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
            allowedContentTypes: [.data],
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
        let modelID = registryModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = registryDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else {
            registryMessage = KizunaCopy.text(japanese: "Model IDを入力してください。", english: "Enter a model ID.")
            return
        }
        let configuration = AIModelConfiguration(
            identity: AIModelIdentity(
                providerID: registryProvider,
                modelID: modelID,
                displayName: displayName.isEmpty ? modelID : displayName
            ),
            roles: [registryRole],
            endpoint: registryProvider == .localRuntime
                ? nil
                : registryEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : registryEndpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            priority: 20
        )
        guard AIModelRegistry.shared.register(configuration) else {
            registryMessage = KizunaCopy.text(japanese: "モデル構成を保存できませんでした。", english: "The model configuration could not be saved.")
            return
        }
        if !registryAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = AISecretStore.shared.setProviderAPIKey(registryAPIKey, for: configuration.id)
        }
        registryConfigurations = AIModelRegistry.shared.configurations
        registryModelID = ""
        registryDisplayName = ""
        registryAPIKey = ""
        registryMessage = KizunaCopy.text(japanese: "モデル構成を追加しました。", english: "Model configuration added.")
    }

    private func removeRegistryConfiguration(_ configuration: AIModelConfiguration) {
        _ = AIModelRegistry.shared.remove(id: configuration.id)
        _ = AISecretStore.shared.removeProviderAPIKey(for: configuration.id)
        registryConfigurations = AIModelRegistry.shared.configurations
        registryMessage = KizunaCopy.text(japanese: "モデル構成を削除しました。", english: "Model configuration removed.")
    }

    private func providerDisplayName(_ provider: AIProviderID) -> String {
        switch provider {
        case .localRuntime: return "Local runtime"
        case .googleGenerativeLanguage: return "Google Generative Language"
        case .openAICompatible: return "OpenAI-compatible"
        case .anthropic: return "Anthropic"
        }
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
