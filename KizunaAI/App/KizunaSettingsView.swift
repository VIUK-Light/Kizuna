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
                Section("表示言語") {
                    Picker("言語", selection: $languageRawValue) {
                        ForEach(KizunaLanguage.allCases) { language in
                            Text(language.displayName).tag(language.rawValue)
                        }
                    }
                    Text("Kizuna内の表示だけが切り替わります。端末全体の言語は変更しません。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    HStack(spacing: 10) {
                        Text(profileStore.profile.avatarSymbol)
                            .font(.title2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profileStore.profile.visibleName.isEmpty
                                 ? KizunaCopy.text(japanese: "未設定", english: "Not set")
                                 : profileStore.profile.visibleName)
                                .font(.headline)
                            Text(profileStore.profile.hasUsefulContent
                                 ? KizunaCopy.text(japanese: "会話の好みを保存済み", english: "Conversation preferences saved")
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

                Section("NAGI（Gemma4 31B API）") {
                    SecureField("Google AI APIキー", text: $nagiAPIKey)
                        .textContentType(.password)

                    Text("APIキーはKeychainに保存されます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("ローカルAIモデル") {
                    LabeledContent("状態", value: modelManager.runtimeStatusSummary)

                    if let name = modelManager.installedFileName {
                        LabeledContent("モデル", value: name)
                    }

                    Picker("モデルの入手先", selection: $modelSourceSelection) {
                        ForEach(LocalModelSourceSelection.allCases) { source in
                            Label(source.title, systemImage: source.icon)
                                .tag(source)
                        }
                    }

                    if modelSourceSelection == .standard {
                        Picker("標準リンク", selection: $selectedStandardModelURL) {
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
                        Text("アプリに設定された標準リンクからダウンロードします。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        // 認証が必要な標準モデルだけ、トークン入力を表示する。
                        if selectedStandardModelRequiresToken {
                            SecureField("Hugging Faceアクセストークン（必要な場合）", text: $modelAccessToken)
                                .textContentType(.password)
                            Text("Gemma 3n E2BはHugging Faceで利用許諾を確認したアクセストークンが必要です。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        TextField("Hugging FaceのファイルURL", text: $modelSourceURL)
                            .textContentType(.URL)
                            .autocorrectionDisabled()

                        SecureField("アクセストークン（必要な場合）", text: $modelAccessToken)
                            .textContentType(.password)

                        Text("リポジトリページではなく、GGUFまたはLiteRT-LMファイルの直接ダウンロードURLを指定してください。")
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
                            Button("一時停止") {
                                modelManager.cancelDownload()
                            }
                            .buttonStyle(.bordered)
                        } else if modelManager.canResumeDownload {
                            Button("ダウンロードを再開") {
                                saveSecretsAndModelSource()
                                modelManager.resumeDownloadIfPossible()
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button(modelManager.installedModelURL == nil ? "モデルをダウンロード" : "再ダウンロード") {
                                saveSecretsAndModelSource()
                                modelManager.startDownload()
                            }
                            .buttonStyle(.bordered)
                            .disabled(!canDownload)
                        }

                        Label(
                            modelManager.runtimeAvailability == .checking
                                ? "端末内で実行確認中"
                                : "端末内の実行確認は自動で行われます",
                            systemImage: modelManager.runtimeAvailability == .checking
                                ? "arrow.triangle.2.circlepath"
                                : "checkmark.seal"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    if modelManager.installedModelURL != nil {
                        Button("ローカルモデルを削除", role: .destructive) {
                            showDeleteAlert = true
                        }
                    }
                    }

                Section("デバッグ") {
                    Toggle(
                        "デバッグオプションを有効化",
                        isOn: $debugRestSuggestionEnabled
                    )
                    Button("休憩提案を30秒後に表示") {
                        KizunaDebugOptions.requestRestSuggestionUI()
                        dismiss()
                    }
                    .disabled(!debugRestSuggestionEnabled)
                    Text("押すと設定を閉じ、最初のストーリーを開いて30秒後に画面内カードを表示します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("危険相談サポートを30秒後に表示") {
                        KizunaDebugOptions.requestSafetyConcernUI()
                        dismiss()
                    }
                    .disabled(!debugRestSuggestionEnabled)
                    Text("押すと設定を閉じ、最初のストーリーを開いて30秒後に相談サポートカードを表示します。")
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

                Section("データ保存先") {
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
            .navigationTitle("設定")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveSecretsAndModelSource()
                    }
                }
            }
        }
        .alert("ローカルモデルを削除しますか？", isPresented: $showDeleteAlert) {
            Button("削除", role: .destructive) {
                modelManager.removeInstalledModel()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("この操作は取り消せません。")
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
        saveMessage = "設定を保存しました"
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
        case .standard: return "標準モデル"
        case .huggingFace: return "Hugging Faceから選択"
        }
    }

    var icon: String {
        switch self {
        case .standard: return "shippingbox.fill"
        case .huggingFace: return "arrow.down.circle"
        }
    }
}
