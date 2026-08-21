import SwiftUI

/// 初回起動ではプロフィールと安全設定を扱う。物語の好みはここで選ばせない。
struct KizunaLaunchView: View {
    @ObservedObject private var profileStore = KizunaUserProfileStore.shared
    @State private var draft: KizunaUserProfile
    @State private var ageContext: UserAgeSafetyContext
    @State private var isLoadingPhoto = false
    @State private var saveError: String?

    var onFinished: () -> Void

    init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
        _draft = State(initialValue: KizunaUserProfileStore.shared.profile)
        _ageContext = State(initialValue: UserAgeSafetyStore.shared.context)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(KizunaCopy.text(japanese: "プロフィール", english: "Profile"))
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)

                    profileCard
                    ageSafetyCard
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 24)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            bottomBar
        }
        .background(Color.appCanvasBackground.ignoresSafeArea())
    }

    private var ageTierBinding: Binding<UserAgeTier> {
        Binding(
            get: { ageContext.tier },
            set: { ageContext = .selfDeclared($0) }
        )
    }

    private var ageSafetyCard: some View {
        KizunaProfileCard(
            title: KizunaCopy.text(japanese: "安全設定", english: "Safety settings"),
            icon: "checkmark.shield",
            spacing: 12
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
                japanese: "安全設定のための区分だけを端末に保存します。生年月日は保存しません。未指定では安全側の設定を使います。",
                english: "Only the range used for safety settings is stored on this device. No birth date is stored. Not specified uses the safer default."
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var profileCard: some View {
        KizunaProfileCard(
            title: KizunaCopy.text(japanese: "あなたのプロフィール", english: "Your profile"),
            icon: "person.crop.circle",
            spacing: 14
        ) {
            TextField(
                KizunaCopy.text(japanese: "呼ばれたい名前（任意）", english: "Name or nickname (optional)"),
                text: Binding(
                    get: { draft.visibleName },
                    set: {
                        draft.nickname = String($0.prefix(60))
                        draft.displayName = String($0.prefix(60))
                    }
                )
            )
            .textFieldStyle(.roundedBorder)

            KizunaAvatarPicker(
                selection: $draft.avatarSymbol,
                imageData: $draft.avatarImageData,
                isLoadingPhoto: $isLoadingPhoto
            )
        }
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack(spacing: 12) {
                Button(KizunaCopy.text(japanese: "あとで", english: "Not now")) {
                    onFinished()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    _ = UserAgeSafetyStore.shared.update(ageContext)
                    switch profileStore.update(draft) {
                    case .success:
                        onFinished()
                    case let .failure(error):
                        saveError = error.localizedDescription
                    }
                } label: {
                    Text(KizunaCopy.text(japanese: "始める", english: "Start"))
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isLoadingPhoto)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .background(.thinMaterial)
    }

}
