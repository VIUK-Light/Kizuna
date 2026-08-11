import SwiftUI

/// 初回起動ではプロフィールだけを設定する。物語の好みはここで選ばせない。
struct KizunaLaunchView: View {
    @ObservedObject private var profileStore = KizunaUserProfileStore.shared
    @State private var draft: KizunaUserProfile

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
        setupCard(
            title: KizunaCopy.text(japanese: "あなたのプロフィール", english: "Your profile"),
            icon: "person.crop.circle"
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
                imageData: $draft.avatarImageData
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
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .background(.thinMaterial)
    }

    private func setupCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
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
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}
