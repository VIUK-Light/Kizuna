import SwiftUI

struct KizunaSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var modelManager = LocalAssistantModelManager.shared
    @ObservedObject private var profileStore = KizunaUserProfileStore.shared

    @State private var nagiAPIKey = ""
    @State private var modelSourceURL = ""
    @State private var modelAccessToken = ""
    @State private var modelSourceSelection: LocalModelSourceSelection = .standard
    @State private var selectedStandardModelURL = LocalAssistantModelProfile.defaultDownloadURL
    @State private var saveMessage: String?
    @State private var showDeleteAlert = false
    @State private var showResetLaunchAlert = false
    @State private var isShowingProfile = false
    @AppStorage("kizuna.language") private var languageRawValue = KizunaLanguage.japanese.rawValue
    @AppStorage("kizuna.debug.restSuggestion.enabled") private var debugRestSuggestionEnabled = false

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
                        japanese: "kizuna内の表示だけが切り替わります。端末全体の言語は変更しません。",
                        english: "Only kizuna changes language. Your device language stays the same."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    HStack(spacing: 10) {
                        KizunaAvatarView(symbol: profileStore.profile.avatarSymbol, size: 42)
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
                            if profileStore.profile.hasUsefulContent {
                                Text(profileStore.profile.storyPreference.displayName)
                                    .font(.caption2)
                                    .foregroundStyle(.tint)
                            }
                        }
                        Spacer()
                        Button(KizunaCopy.text(japanese: "編集", english: "Edit")) {
                            isShowingProfile = true
                        }
                    }
                    if profileStore.profile.hasUsefulContent {
                        Button(KizunaCopy.text(japanese: "プロフィールを消去", english: "Clear profile"), role: .destructive) {
                            profileStore.reset()
                        }
                    }
                    Text(KizunaCopy.text(
                        japanese: "プロフィールは端末内の設定として保存されます。生成時は会話に必要な範囲だけ、選択中のモデル（NAGIを含む）へ渡されます。",
                        english: "Your profile is stored in this app. Only relevant fields are included in the selected model request, including NAGI."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                }

                Section(KizunaCopy.text(japanese: "ローカルAIモデル", english: "Local AI model")) {
                    LabeledContent(KizunaCopy.text(japanese: "状態", english: "Status"), value: modelManager.runtimeStatusSummary)

                    if let name = modelManager.installedFileName {
                        LabeledContent(KizunaCopy.text(japanese: "モデル", english: "Model"), value: name)
                    }

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
                                    Text(option.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .tag(option.url)
                            }
                        }
                        if let selectedOption = standardModelOptions.first(where: {
                            $0.url == selectedStandardModelURL
                        }) {
                            Text(selectedOption.detail)
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

                    Text(modelManager.statusMessage)
                        .font(.caption)
                        .foregroundStyle(modelManager.lastErrorMessage == nil ? Color.secondary : Color.red)

                    if let error = modelManager.supplementalLastErrorMessage {
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

                Section {
                    Button(KizunaCopy.text(japanese: "初回起動画面をもう一度表示", english: "Show the welcome screen again")) {
                        showResetLaunchAlert = true
                    }
                    Text(KizunaCopy.text(
                        japanese: "次回の起動時だけ、ストーリー開始とプロフィール設定の案内を表示します。",
                        english: "The welcome screen will appear once at the next launch."
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

                if let saveMessage {
                    Section {
                        Label(saveMessage, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(KizunaCopy.text(japanese: "設定", english: "Settings"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(KizunaCopy.text(japanese: "閉じる", english: "Close")) { dismiss() }
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
            KizunaCopy.text(japanese: "初回起動画面を表示しますか？", english: "Show the welcome screen again?"),
            isPresented: $showResetLaunchAlert
        ) {
            Button(KizunaCopy.text(japanese: "表示する", english: "Show")) {
                UserDefaults.standard.set(false, forKey: "kizuna.launch.completed")
            }
            Button(KizunaCopy.text(japanese: "キャンセル", english: "Cancel"), role: .cancel) {}
        } message: {
            Text(KizunaCopy.text(
                japanese: "保存済みのプロフィールやモデル設定は変更しません。",
                english: "Your profile and model settings will not be changed."
            ))
        }
        .sheet(isPresented: $isShowingProfile) {
            KizunaUserProfileView(store: KizunaUserProfileStore.shared)
                .viukAdaptiveSheetSizing(minWidth: 520, minHeight: 620)
        }
        .onAppear {
            nagiAPIKey = AISecretStore.shared.string(for: .gemmaWebReaderAPIKey) ?? ""
            modelSourceURL = modelManager.sourceURLString
            modelAccessToken = modelManager.accessToken
            selectedStandardModelURL = standardModelOptions.first(where: {
                $0.url == modelManager.resolvedSourceURLString
            })?.url ?? LocalAssistantModelProfile.defaultDownloadURL
            modelSourceSelection = standardModelOptions.contains(where: {
                $0.url == modelManager.resolvedSourceURLString
            }) ? .standard : .huggingFace
            modelManager.refreshEnvironment()
        }
    }

    private func saveSecretsAndModelSource() {
        AISecretStore.shared.setString(nagiAPIKey, for: .gemmaWebReaderAPIKey)

        if modelSourceSelection == .standard {
            modelManager.updateSourceURL(selectedStandardModelURL)
        } else {
            modelManager.updateSourceURL(modelSourceURL)
        }

        modelManager.updateAccessToken(modelAccessToken)
        saveMessage = KizunaCopy.text(japanese: "設定を保存しました", english: "Settings saved")
    }

    private var standardModelOptions: [LocalAssistantModelProfile.DownloadOption] {
        LocalAssistantModelProfile.standardDownloadOptions
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
