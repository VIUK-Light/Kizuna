import SwiftUI

struct KizunaLaunchView: View {
    @ObservedObject private var profileStore = KizunaUserProfileStore.shared
    @State private var isShowingProfile = false

    var onFinished: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "infinity.circle.fill")
                .font(.system(size: 72, weight: .bold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text(KizunaCopy.appName)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text(KizunaCopy.text(
                    japanese: "物語と会話を、あなたのペースで。",
                    english: "Stories and conversations, at your pace."
                ))
                .font(.title3)
                .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            Text(KizunaCopy.text(
                japanese: "最初にプロフィールを設定できます。後から設定で変更・削除できます。",
                english: "You can set up a profile now and change or remove it later in Settings."
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 430)

            VStack(spacing: 10) {
                Button {
                    onFinished()
                } label: {
                    Label(
                        KizunaCopy.text(japanese: "ストーリーを始める", english: "Start a story"),
                        systemImage: "sparkles"
                    )
                    .frame(maxWidth: 300)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    isShowingProfile = true
                } label: {
                    Label(
                        profileStore.profile.hasUsefulContent
                            ? KizunaCopy.text(japanese: "プロフィールを編集", english: "Edit profile")
                            : KizunaCopy.text(japanese: "プロフィールを設定", english: "Set up profile"),
                        systemImage: "person.crop.circle"
                    )
                    .frame(maxWidth: 300)
                }
                .buttonStyle(.bordered)

                Button(KizunaCopy.text(japanese: "あとで", english: "Not now")) {
                    onFinished()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appCanvasBackground.ignoresSafeArea())
        .sheet(isPresented: $isShowingProfile) {
            KizunaUserProfileView(store: KizunaUserProfileStore.shared)
                .viukAdaptiveSheetSizing(minWidth: 520, minHeight: 620)
        }
    }
}
