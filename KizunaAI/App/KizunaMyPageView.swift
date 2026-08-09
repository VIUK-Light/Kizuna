import SwiftUI

/// プロフィールと、日常的に触るアプリ設定をまとめたマイページ。
/// Story画面と同じ情報密度にせず、プロフィール・物語の入口・環境設定の順に整理する。
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
            VStack(alignment: .leading, spacing: 22) {
                pageHeader
                profileHero
                storyPreferenceCard
                settingsGrid
                privacyCard
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .frame(maxWidth: 1_100)
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
            Text(KizunaCopy.appName)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.3)
                .foregroundStyle(.tint)
            Text(KizunaCopy.text(japanese: "マイページ", english: "My page"))
                .font(.system(size: 32, weight: .heavy, design: .rounded))
            Text(KizunaCopy.text(
                japanese: "あなたの設定を、必要なものだけここに。",
                english: "Your essentials, in one calm place."
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var profileHero: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 18) {
                KizunaAvatarView(symbol: profileStore.profile.avatarSymbol, size: 88)
                profileSummary
                Spacer(minLength: 16)
                profileEditButton
            }

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 18) {
                    KizunaAvatarView(symbol: profileStore.profile.avatarSymbol, size: 76)
                    profileSummary
                }
                profileEditButton
            }
        }
        .padding(22)
        .background(
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.20),
                    Color.indigo.opacity(0.14),
                    Color.primary.opacity(0.035)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
    }

    private var profileSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(profileStore.profile.visibleName.isEmpty
                 ? KizunaCopy.text(japanese: "名前を決めずに始めています", english: "No profile name yet")
                 : profileStore.profile.visibleName)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .lineLimit(2)

            Text(profileStore.profile.hasUsefulContent
                 ? KizunaCopy.text(japanese: "あなた向けの設定が保存されています", english: "Your preferences are saved")
                 : KizunaCopy.text(japanese: "プロフィールは任意です", english: "A profile is optional"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !profileStore.profile.about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(profileStore.profile.about)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var profileEditButton: some View {
        Button {
            isShowingProfileEditor = true
        } label: {
            Label(
                KizunaCopy.text(japanese: "プロフィールを編集", english: "Edit profile"),
                systemImage: "pencil"
            )
            .font(.system(size: 13, weight: .semibold))
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private var storyPreferenceCard: some View {
        surface {
            HStack(spacing: 16) {
                iconBadge(profileStore.profile.storyPreference.iconName, color: .orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text(KizunaCopy.text(japanese: "物語の入口", english: "Story atmosphere"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(profileStore.profile.storyPreference.displayName)
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                    Text(profileStore.profile.storyPreference.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Button {
                    isShowingProfileEditor = true
                } label: {
                    Label(
                        KizunaCopy.text(japanese: "変更", english: "Change"),
                        systemImage: "arrow.up.right"
                    )
                    .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var settingsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 14)], spacing: 14) {
            languageCard
            runtimeCard
            launchCard
        }
    }

    private var languageCard: some View {
        settingsCard(
            title: KizunaCopy.text(japanese: "表示言語", english: "Display language"),
            subtitle: KizunaCopy.text(
                japanese: "アプリ内の表示だけを切り替えます。",
                english: "Changes kizuna's interface only."
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
            .labelsHidden()
        }
    }

    private var runtimeCard: some View {
        settingsCard(
            title: KizunaCopy.text(japanese: "AIと実行環境", english: "AI and runtime"),
            subtitle: KizunaCopy.text(
                japanese: "モデルの状態を確認します。",
                english: "Check the model status."
            ),
            icon: "cpu"
        ) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(modelManager.runtimeAvailability == .executable ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(modelManager.runtimeStatusSummary)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Button {
                isShowingDetailedSettings = true
            } label: {
                Label(
                    KizunaCopy.text(japanese: "詳細設定", english: "Details"),
                    systemImage: "slider.horizontal.3"
                )
                .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.bordered)
        }
    }

    private var launchCard: some View {
        settingsCard(
            title: KizunaCopy.text(japanese: "初期設定", english: "Welcome setup"),
            subtitle: KizunaCopy.text(
                japanese: "世界観とプロフィールを選び直します。",
                english: "Choose your story atmosphere again."
            ),
            icon: "sparkles.rectangle.stack"
        ) {
            Button {
                isShowingResetLaunchAlert = true
            } label: {
                Label(
                    KizunaCopy.text(japanese: "初期設定を開く", english: "Open setup"),
                    systemImage: "arrow.counterclockwise"
                )
                .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.bordered)
        }
    }

    private var privacyCard: some View {
        HStack(alignment: .top, spacing: 12) {
            iconBadge("lock.shield.fill", color: .green)
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
        .padding(16)
        .background(Color.green.opacity(0.075), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.green.opacity(0.16), lineWidth: 1)
        }
    }

    private func settingsCard<Content: View>(
        title: String,
        subtitle: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        surface {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    iconBadge(icon)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                content()
            }
            .frame(maxWidth: .infinity, minHeight: 122, alignment: .topLeading)
        }
    }

    private func surface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(17)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
            }
    }

    private func iconBadge(_ icon: String, color: Color = .accentColor) -> some View {
        Image(systemName: icon)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 32, height: 32)
            .background(color.opacity(0.12), in: Circle())
    }
}
