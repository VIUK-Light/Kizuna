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
    @AppStorage(KizunaStorageKeys.launchCompleted) private var launchCompleted = false

    var body: some View {
        Group {
            if isReady {
                if launchCompleted {
                    VIUKKizunaWorkspaceView()
                } else {
                    KizunaLaunchView {
                        launchCompleted = true
                    }
                }
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "infinity.circle.fill")
                        .font(.system(size: 54, weight: .bold))
                        .foregroundStyle(.tint)
                    ProgressView()
                    Text(KizunaCopy.text(japanese: "Kizunaのデータを準備しています", english: "Preparing Kizuna"))
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
            }
        }
        .task {
            guard !isReady else { return }
            await Task.detached(priority: .userInitiated) {
                KizunaDataMigration.performIfNeeded()
            }.value
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
            guard phase == .background else { return }
            LocalAssistantRuntimeBridge.shared.cancelActiveGeneration()
            LocalAssistantLiteRTLMRuntime.shared.releaseResourcesForBackground()
        }
    }
}
