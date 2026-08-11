import SwiftUI

/// 初回起動ではプロフィールだけを設定する。物語の好みはここで選ばせない。
struct KizunaLaunchView: View {
    @ObservedObject private var profileStore = KizunaUserProfileStore.shared
    @State private var draft: KizunaUserProfile
    @State private var isLoadingPhoto = false

    var onFinished: () -> Void

    init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
        _draft = State(initialValue: KizunaUserProfileStore.shared.profile)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(KizunaCopy.text(japanese: "プロフィール", english: "Profile"))
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)

                    profileCard
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
        HStack(spacing: 12) {
            Button(KizunaCopy.text(japanese: "あとで", english: "Not now")) {
                onFinished()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            Button {
                profileStore.update(draft)
                onFinished()
            } label: {
                Text(KizunaCopy.text(japanese: "始める", english: "Start"))
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isLoadingPhoto)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .background(.thinMaterial)
    }

}
