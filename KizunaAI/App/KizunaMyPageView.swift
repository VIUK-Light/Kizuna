import SwiftUI

/// プロフィールと、日常的に触るアプリ設定をまとめたマイページ。
/// 必要なプロフィールと環境設定だけを置く。
@MainActor
struct KizunaMyPageView: View {
    @ObservedObject private var profileStore = KizunaUserProfileStore.shared
    @ObservedObject private var modelManager = LocalAssistantModelManager.shared
    @AppStorage("kizuna.language") private var languageRawValue = KizunaLanguage.japanese.rawValue
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isShowingProfileEditor = false
    @State private var isShowingDetailedSettings = false
    @State private var isShowingDataManagement = false
    @State private var isShowingResetLaunchAlert = false
    @State private var languageRevision = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeader
                profileHero
                settingsGrid
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .frame(maxWidth: 1_100)
            .frame(maxWidth: .infinity)
        }
        .background(Color.appCanvasBackground.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $isShowingProfileEditor) {
            KizunaUserProfileView(store: KizunaUserProfileStore.shared)
                .viukAdaptiveSheetSizing(minWidth: 520, minHeight: 620)
        }
        .sheet(isPresented: $isShowingDetailedSettings, onDismiss: {
            NotificationCenter.default.post(name: KizunaDebugOptions.settingsDismissedNotification, object: nil)
        }) {
            KizunaSettingsView()
                .viukAdaptiveSheetSizing(minWidth: 560, minHeight: 680)
        }
        .sheet(isPresented: $isShowingDataManagement) {
            KizunaPersonaDataManagementView()
                .viukAdaptiveSheetSizing(minWidth: 560, minHeight: 620)
        }
        .alert(
            KizunaCopy.text(japanese: "初期設定を今すぐ開きますか？", english: "Open the welcome setup now?"),
            isPresented: $isShowingResetLaunchAlert
        ) {
            Button(KizunaCopy.text(japanese: "開く", english: "Open")) {
                UserDefaults.standard.set(false, forKey: KizunaStorageKeys.launchCompleted)
            }
            Button(KizunaCopy.text(japanese: "キャンセル", english: "Cancel"), role: .cancel) {}
        } message: {
            Text(KizunaCopy.text(
                japanese: "プロフィール設定を開きます。",
                english: "Open profile setup."
            ))
        }
        .onAppear {
            modelManager.refreshEnvironment()
        }
        .onChange(of: languageRawValue) { _, _ in
            KizunaCopy.notifyLanguageDidChange()
            languageRevision &+= 1
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(KizunaCopy.appName)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.3)
                .foregroundStyle(.tint)
            Text(KizunaCopy.text(japanese: "My", english: "My"))
                .font(.system(size: 32, weight: .heavy, design: .rounded))
                .accessibilityIdentifier("workspace.myPage.heading")
            
        }
    }

    private var profileHero: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 18) {
                KizunaAvatarView(
                    symbol: profileStore.profile.avatarSymbol,
                    imageData: profileStore.profile.avatarImageData,
                    size: 88
                )
                profileSummary
                Spacer(minLength: 16)
                profileEditButton
            }

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 18) {
                    KizunaAvatarView(
                        symbol: profileStore.profile.avatarSymbol,
                        imageData: profileStore.profile.avatarImageData,
                        size: 76
                    )
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
                 ? KizunaCopy.text(japanese: "未設定", english: "No profile name yet")
                 : profileStore.profile.visibleName)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .lineLimit(2)

            Text(profileStore.profile.hasUsefulContent
                 ? KizunaCopy.text(japanese: "あなた向けの設定が保存されています", english: "Your preferences are saved")
                 : KizunaCopy.text(japanese: "プロフィールは任意です", english: "A profile is optional"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

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
            .font(.system(size: 15, weight: .semibold))
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private var settingsGrid: some View {
        let columns = horizontalSizeClass == .compact
            ? [GridItem(.flexible(minimum: 0), spacing: 14)]
            : [GridItem(.adaptive(minimum: 290), spacing: 14)]
        return LazyVGrid(columns: columns, spacing: 14) {
            languageCard
            runtimeCard
            launchCard
            dataManagementCard
        }
    }

    private var languageCard: some View {
        settingsCard(
            title: KizunaCopy.text(japanese: "表示言語", english: "Display language"),
            subtitle: KizunaCopy.text(
                japanese: "",
                english: ""
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
                .font(.system(size: 17, weight: .semibold))
            }
            .buttonStyle(.bordered)
        }
    }

    private var launchCard: some View {
        settingsCard(
            title: KizunaCopy.text(japanese: "初期設定", english: "Welcome setup"),
            subtitle: KizunaCopy.text(
                japanese: "プロフィールを設定し直します。",
                english: "Set up your profile again."
            ),
            icon: "person.crop.circle"
        ) {
            Button {
                isShowingResetLaunchAlert = true
            } label: {
                Label(
                    KizunaCopy.text(japanese: "初期設定を開く", english: "Open setup"),
                    systemImage: "arrow.counterclockwise"
                )
                .font(.system(size: 17, weight: .semibold))
            }
            .buttonStyle(.bordered)
        }
    }

    private var dataManagementCard: some View {
        settingsCard(
            title: KizunaCopy.text(japanese: "データ管理", english: "Data management"),
            subtitle: KizunaCopy.text(
                japanese: "Persona会話を保存・書き出し・削除します。",
                english: "Export or delete Persona conversations."
            ),
            icon: "externaldrive"
        ) {
            Button {
                isShowingDataManagement = true
            } label: {
                Label(
                    KizunaCopy.text(japanese: "データ管理を開く", english: "Open data management"),
                    systemImage: "arrow.up.doc"
                )
                .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("myPage.dataManagement")
        }
    }

    private func settingsCard<Content: View>(
        title: String,
        subtitle: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        surface {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 10) {
                    iconBadge(icon)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
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

#Preview{
    KizunaMyPageView()
}
