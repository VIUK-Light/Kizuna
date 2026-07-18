import SwiftUI

/// 独立版「VIUK 絆」から秘密情報とローカルモデルを管理する画面。
/// APIキーとアクセストークンはKeychainにだけ保存する。
struct KizunaSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var modelManager = LocalAssistantModelManager.shared

    @State private var nagiAPIKey = ""
    @State private var modelSourceURL = ""
    @State private var modelAccessToken = ""
    @State private var saveMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("NAGI（Gemma4 31B API）") {
                    SecureField("Google AI APIキー", text: $nagiAPIKey)
                        .textContentType(.password)
                    Text("物語テンプレート生成とNAGI会話に使います。値はKeychainにのみ保存されます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("APIキーを保存") {
                        saveSecretsAndModelSource()
                    }
                }

                Section("ローカルAIモデル（iori）") {
                    LabeledContent("状態", value: modelManager.runtimeStatusSummary)
                    if let name = modelManager.installedFileName {
                        LabeledContent("モデル", value: name)
                    }

                    TextField("モデルのダウンロードURL", text: $modelSourceURL)
                        .textContentType(.URL)
                    SecureField("Hugging Faceアクセストークン（必要な場合）", text: $modelAccessToken)
                        .textContentType(.password)

                    if let progress = modelManager.progressValue {
                        ProgressView(value: progress)
                    } else if modelManager.isDownloading {
                        ProgressView()
                    }

                    Text(modelManager.statusMessage)
                        .font(.caption)
                        .foregroundStyle(modelManager.lastErrorMessage == nil ? Color.secondary : Color.red)

                    HStack {
                        if modelManager.isDownloading {
                            Button("一時停止") {
                                modelManager.cancelDownload()
                            }
                        } else if modelManager.canResumeDownload {
                            Button("ダウンロードを再開") {
                                saveSecretsAndModelSource()
                                modelManager.resumeDownloadIfPossible()
                            }
                        } else {
                            Button(modelManager.installedModelURL == nil ? "モデルをダウンロード" : "再ダウンロード") {
                                saveSecretsAndModelSource()
                                modelManager.startDownload()
                            }
                        }

                        Button("起動確認") {
                            saveSecretsAndModelSource()
                            modelManager.recheckRuntimeAvailability()
                        }
                        .disabled(modelManager.installedModelURL == nil || modelManager.isDownloading)
                    }

                    if modelManager.installedModelURL != nil {
                        Button("ローカルモデルを削除", role: .destructive) {
                            modelManager.removeInstalledModel()
                        }
                    }
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
            .navigationTitle("絆の設定")
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
        .onAppear {
            nagiAPIKey = AISecretStore.shared.string(for: .gemmaWebReaderAPIKey) ?? ""
            modelSourceURL = modelManager.sourceURLString
            modelAccessToken = modelManager.accessToken
            modelManager.refreshEnvironment()
        }
    }

    private func saveSecretsAndModelSource() {
        AISecretStore.shared.setString(nagiAPIKey, for: .gemmaWebReaderAPIKey)
        modelManager.updateSourceURL(modelSourceURL)
        modelManager.updateAccessToken(modelAccessToken)
        saveMessage = "Keychainとモデル設定を更新しました"
    }
}
