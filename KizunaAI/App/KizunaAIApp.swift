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
    @State private var isReady = false

    var body: some View {
        Group {
            if isReady {
                VIUKKizunaWorkspaceView()
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "infinity.circle.fill")
                        .font(.system(size: 54, weight: .bold))
                        .foregroundStyle(.tint)
                    ProgressView()
                    Text("絆のデータを準備しています")
                        .font(.headline)
                    Text("初回はVIUK Oneのキャラクターとローカルモデルをコピーするため、数分かかる場合があります。")
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
            LocalAssistantRuntimeBridge.shared.prewarmIfPossible()
        }
    }
}
