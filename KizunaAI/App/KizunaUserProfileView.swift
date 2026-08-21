import SwiftUI

/// 名前、プロフィール画像、年齢に合わせた安全設定を編集する画面。
@MainActor
struct KizunaUserProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store: KizunaUserProfileStore
    @State private var draft: KizunaUserProfile
    @State private var ageContext: UserAgeSafetyContext
    @State private var isLoadingPhoto = false
    @State private var saveError: String?
    @State private var languageRevision = 0

    init(store: KizunaUserProfileStore) {
        self.store = store
        _draft = State(initialValue: store.profile)
        _ageContext = State(initialValue: UserAgeSafetyStore.shared.context)
    }

    private var ageTierBinding: Binding<UserAgeTier> {
        Binding(
            get: { ageContext.tier },
            set: { ageContext = .selfDeclared($0) }
        )
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { draft.visibleName },
            set: {
                draft.nickname = String($0.prefix(60))
                draft.displayName = String($0.prefix(60))
            }
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if store.recoveryDataAvailable {
                        Label {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(store.loadError ?? KizunaCopy.text(
                                    japanese: "プロフィールの復旧が必要です。",
                                    english: "Profile recovery is required."
                                ))
                                    .font(.caption)
                                Button(KizunaCopy.text(
                                    japanese: "壊れたプロフィールをリセット",
                                    english: "Reset damaged profile"
                                )) {
                                    store.resetCorruptedProfile()
                                    draft = store.profile
                                }
                                .buttonStyle(.bordered)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .padding(12)
                        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if let saveError {
                        Label(saveError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    KizunaProfileCard(
                        title: KizunaCopy.text(japanese: "名前と画像", english: "Name and photo"),
                        icon: "person.crop.circle",
                        spacing: 12,
                        showsBorder: false
                    ) {
                        TextField(
                            KizunaCopy.text(japanese: "呼ばれたい名前（任意）", english: "Name or nickname (optional)"),
                            text: nameBinding
                        )
                        .textFieldStyle(.roundedBorder)

                        KizunaAvatarPicker(
                            selection: $draft.avatarSymbol,
                            imageData: $draft.avatarImageData,
                            isLoadingPhoto: $isLoadingPhoto
                        )
                    }

                    KizunaProfileCard(
                        title: KizunaCopy.text(japanese: "安全設定", english: "Safety settings"),
                        icon: "checkmark.shield",
                        spacing: 12,
                        showsBorder: false
                    ) {
                        Picker(
                            KizunaCopy.text(japanese: "年齢層", english: "Age range"),
                            selection: ageTierBinding
                        ) {
                            ForEach(UserAgeTier.allCases) { tier in
                                Text(tier.localizedDisplayName).tag(tier)
                            }
                        }
                        Text(KizunaCopy.text(
                            japanese: "年齢に合う安全設定を選ぶため、粗い区分だけをこの端末に保存します。生年月日は保存せず、自己申告は本人確認済み年齢として扱いません。",
                            english: "Only this coarse range is stored on this device to choose age-appropriate safety settings. No birth date is stored, and self-declaration is not treated as verified age."
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 20)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .background(Color.appCanvasBackground.ignoresSafeArea())
            .navigationTitle(KizunaCopy.text(japanese: "プロフィール", english: "Profile"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(KizunaCopy.text(japanese: "キャンセル", english: "Cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(KizunaCopy.text(japanese: "保存", english: "Save")) {
                        _ = UserAgeSafetyStore.shared.update(ageContext)
                        switch store.update(draft) {
                        case .success:
                            dismiss()
                        case let .failure(error):
                            saveError = error.localizedDescription
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(isLoadingPhoto)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: KizunaCopy.languageDidChangeNotification)) { _ in
            languageRevision &+= 1
        }
    }
}

struct KizunaProfileCard<Content: View>: View {
    let title: String
    let icon: String
    let spacing: CGFloat
    let showsBorder: Bool
    private let content: () -> Content

    init(
        title: String,
        icon: String,
        spacing: CGFloat = 12,
        showsBorder: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.spacing = spacing
        self.showsBorder = showsBorder
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.accentColor.opacity(0.12)))
                Text(title)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
            }
            content()
        }
        .padding(15)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay {
            if showsBorder {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
    }
}
