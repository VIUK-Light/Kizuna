import SwiftUI

@main
struct KizunaAIApp: App {
    // アプリ内設定。未設定時は元の設計どおり日本語を標準にする。
    @AppStorage("kizuna.language") private var languageRawValue = KizunaLanguage.japanese.rawValue

    var body: some Scene {
        WindowGroup {
            KizunaMigrationGateView()
                .viukMacWindowFrame(minWidth: 880, minHeight: 700)
                // SwiftUIのLocalizedStringKeyをアプリ内言語へ切り替える。
                .environment(\.locale, selectedLocale)
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 780)
        #endif
    }

    private var selectedLocale: Locale {
        KizunaLanguage(rawValue: languageRawValue)?.locale
            ?? KizunaLanguage.japanese.locale
    }
}

private struct KizunaMigrationGateView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var isReady = false
    @State private var migrationError: String?
    @State private var migrationAttempt = 0
    @AppStorage(KizunaStorageKeys.launchCompleted) private var launchCompleted = false

    var body: some View {
        ZStack {
            if isReady {
                if launchCompleted {
                    AnyView(VIUKKizunaWorkspaceView())
                } else {
                    AnyView(
                        KizunaLaunchView {
                            launchCompleted = true
                        }
                    )
                }
            } else if let errorMessage = migrationError {
                AnyView(
                    VStack(spacing: 16) {
                        Image(systemName: "externaldrive.badge.exclamationmark")
                            .font(.system(size: 48, weight: .semibold))
                            .foregroundStyle(.orange)
                        Text(KizunaCopy.text(
                            japanese: "保存領域を準備できませんでした",
                            english: "Storage could not be prepared"
                        ))
                            .font(.headline)
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 480)
                        Button(KizunaCopy.text(japanese: "再試行", english: "Retry")) {
                            migrationError = nil
                            migrationAttempt &+= 1
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(32)
                )
            } else {
                AnyView(
                    VStack(spacing: 18) {
                        Image(systemName: "infinity.circle.fill")
                            .font(.system(size: 54, weight: .bold))
                            .foregroundStyle(.tint)
                        ProgressView()
                        Text(KizunaCopy.text(japanese: "\(KizunaCopy.appName)のデータを準備しています", english: "Preparing \(KizunaCopy.appName)"))
                            .font(.headline)
                        Text(KizunaCopy.text(
                            japanese: "初回だけ、キャラクターとローカルモデルを準備するため数分かかる場合があります。",
                            english: "The first launch may take a few minutes while characters and the local model are prepared."
                        ))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 460)
                    }
                    .padding(32)
                )
            }
        }
        .task(id: migrationAttempt) {
            guard !isReady else { return }
            let didSucceed = await Task.detached(priority: .userInitiated) {
                KizunaDataMigration.performIfNeeded()
            }.value
            guard didSucceed else {
                migrationError = KizunaCopy.text(
                    japanese: "移行または保存先の準備に失敗しました。データ保護のためWorkspaceを開いていません。保存領域を確認して再試行してください。",
                    english: "Migration or storage preparation failed. The workspace is blocked to protect your data. Check the storage location and try again."
                )
                return
            }
            isReady = true
            PersonaSettings.shared.primeBridge()
            KizunaUserProfileStore.shared.primeBridge()
            // Do not wait for Settings or a Story view to instantiate the model
            // manager.  A saved local model must be discovered and checked as
            // soon as migration finishes, without asking the user to press a
            // separate confirmation button.
            LocalAssistantModelManager.shared.refreshEnvironment()
            LocalAssistantRuntimeBridge.shared.prewarmIfPossible()
        }
        .onChange(of: scenePhase) { _, phase in
            // iPhoneでアプリを離れたまま1GB級のモデルとKVキャッシュを保持しない。
            // 次回の端末内生成では必要時に再初期化する。
            guard phase == .background, isReady else { return }
            PersonaChatStore.shared.flushPendingPersistence()
            PersonaChatService.shared.cancel()
            StorySessionService.cancelAllActiveGenerations()
            LocalAssistantRuntimeBridge.shared.cancelActiveGeneration()
            LocalAssistantLiteRTLMRuntime.shared.releaseResourcesForBackground()
            // バックグラウンド中も平文シークレットをメモリに残さない。
            // iOSのロック時は保護データ利用不可能通知でも消去される（二重防线）。
            KeychainHelper.shared.clearInMemoryCaches()
        }
    }
}

