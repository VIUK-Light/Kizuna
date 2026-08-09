import SwiftUI

/// プロフィールと、日常的に触るアプリ設定をまとめたマイページ。
/// 低頻度のモデル診断や保存先は詳細設定へ分離し、Story画面の入口を軽く保つ。
@MainActor
struct KizunaMyPageView: View {
    @ObservedObject private var profileStore = KizunaUserProfileStore.shared
    @ObservedObject private var modelManager = LocalAssistantModelManager.shared
    @AppStorage("kizuna.language") private var languageRawValue = KizunaLanguage.japanese.rawValue
    @State private var isShowingProfileEditor = false
    @State private var isShowingDetailedSettings = false
    @State private var isShowingResetLaunchAlert = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                pageHeader
                profileHero
                preferenceSummary
                languageCard
                runtimeCard
                launchCard
                privacyCard
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .background(Color.appCanvasBackground.ignoresSafeArea())
        .sheet(isPresented: $isShowingProfileEditor) {
            KizunaUserProfileView(store: KizunaUserProfileStore.shared)
                .viukAdaptiveSheetSizing(minWidth: 520, minHeight: 620)
        }
        .sheet(isPresented: $isShowingDetailedSettings) {
            KizunaSettingsView()
                .viukAdaptiveSheetSizing(minWidth: 560, minHeight: 680)
        }
        .alert(
            KizunaCopy.text(japanese: "初回設定をやり直しますか？", english: "Show the welcome setup again?"),
            isPresented: $isShowingResetLaunchAlert
        ) {
            Button(KizunaCopy.text(japanese: "表示する", english: "Show")) {
                UserDefaults.standard.set(false, forKey: "kizuna.launch.completed")
            }
            Button(KizunaCopy.text(japanese: "キャンセル", english: "Cancel"), role: .cancel) {}
        } message: {
            Text(KizunaCopy.text(
                japanese: "保存済みのプロフィールやモデル設定は変更されません。",
                english: "Your profile and model settings will not be changed."
            ))
        }
        .onAppear {
            modelManager.refreshEnvironment()
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(KizunaCopy.text(japanese: "マイページ", english: "My page"))
                .font(.system(size: 28, weight: .heavy, design: .rounded))
            Text(KizunaCopy.text(
                japanese: "あなたの好みとKizunaの設定を、ここでまとめて管理できます。",
                english: "Manage your preferences and Kizuna settings in one place."
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var profileHero: some View {
        HStack(spacing: 14) {
            Text(profileStore.profile.avatarSymbol)
                .font(.system(size: 40))
                .frame(width: 76, height: 76)
                .background(
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.25), Color.purple.opacity(0.18)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )

            VStack(alignment: .leading, spacing: 5) {
                Text(profileStore.profile.visibleName.isEmpty
                     ? KizunaCopy.text(japanese: "まだ名前はありません", english: "No name yet")
                     : profileStore.profile.visibleName)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                Text(profileStore.profile.hasUsefulContent
                     ? KizunaCopy.text(japanese: "プロフィール設定済み", english: "Profile configured")
                     : KizunaCopy.text(japanese: "プロフィールは任意です", english: "Profile is optional"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button {
                isShowingProfileEditor = true
            } label: {
                Label(
                    KizunaCopy.text(japanese: "プロフィールを編集", english: "Edit profile"),
                    systemImage: "pencil"
                )
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(17)
        .background(cardBackground)
    }

    private var preferenceSummary: some View {
        HStack(spacing: 10) {
            summaryTile(
                title: KizunaCopy.text(japanese: "会話のテンポ", english: "Conversation pace"),
                value: profileStore.profile.conversationPreference.displayName,
                icon: "bubble.left.and.bubble.right"
            )
            summaryTile(
                title: KizunaCopy.text(japanese: "物語の入口", english: "Story atmosphere"),
                value: profileStore.profile.storyPreference.displayName,
                icon: profileStore.profile.storyPreference.iconName
            )
        }
    }

    private func summaryTile(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.tint)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
        .padding(14)
        .background(cardBackground)
    }

    private var languageCard: some View {
        settingsCard(
            title: KizunaCopy.text(japanese: "表示言語", english: "Display language"),
            subtitle: KizunaCopy.text(
                japanese: "Kizuna内の表示だけを切り替えます。",
                english: "Changes Kizuna's interface only."
            ),
            icon: "globe"
        ) {
            Picker(
                KizunaCopy.text(japanese: "言語", english: "Language"),
                selection: $languageRawValue
            ) {
                ForEach(KizunaLanguage.allCases) { language in
                    Text(language.displayName).tag(language.rawValue)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var runtimeCard: some View {
        settingsCard(
            title: KizunaCopy.text(japanese: "AIと実行環境", english: "AI and runtime"),
            subtitle: KizunaCopy.text(
                japanese: "モデルの状態と詳細設定を確認します。",
                english: "Check model status and detailed settings."
            ),
            icon: "cpu"
        ) {
            VStack(alignment: .leading, spacing: 9) {
                LabeledContent(
                    KizunaCopy.text(japanese: "状態", english: "Status"),
                    value: modelManager.runtimeStatusSummary
                )
                if let installedFileName = modelManager.installedFileName {
                    LabeledContent(
                        KizunaCopy.text(japanese: "モデル", english: "Model"),
                        value: installedFileName
                    )
                }
                Button {
                    isShowingDetailedSettings = true
                } label: {
                    Label(
                        KizunaCopy.text(japanese: "詳細設定を開く", english: "Open detailed settings"),
                        systemImage: "slider.horizontal.3"
                    )
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var launchCard: some View {
        settingsCard(
            title: KizunaCopy.text(japanese: "初期設定", english: "Welcome setup"),
            subtitle: KizunaCopy.text(
                japanese: "世界観やプロフィールの入口をもう一度選び直せます。",
                english: "Choose your story atmosphere and profile again."
            ),
            icon: "sparkles.rectangle.stack"
        ) {
            Button {
                isShowingResetLaunchAlert = true
            } label: {
                Label(
                    KizunaCopy.text(japanese: "初回設定をやり直す", english: "Show setup again"),
                    systemImage: "arrow.counterclockwise"
                )
            }
            .buttonStyle(.bordered)
        }
    }

    private var privacyCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 4) {
                Text(KizunaCopy.text(japanese: "端末内で管理", english: "Stored on this device"))
                    .font(.system(size: 13, weight: .bold))
                Text(KizunaCopy.text(
                    japanese: "プロフィールは端末内に保存されます。入力した情報は、会話に必要な範囲だけ選択中のモデルへ渡されます。",
                    english: "Your profile stays on this device. Only relevant fields are included in model requests."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.green.opacity(0.08))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.green.opacity(0.18), lineWidth: 1)
        }
    }

    private func settingsCard<Content: View>(
        title: String,
        subtitle: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.tint)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.accentColor.opacity(0.12)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            content()
        }
        .padding(15)
        .background(cardBackground)
    }

    private var cardBackground: some ShapeStyle {
        Color.primary.opacity(0.045)
    }
}
