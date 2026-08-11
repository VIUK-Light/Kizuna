import SwiftUI

/// 名前とプロフィール画像だけを編集する画面。
@MainActor
struct KizunaUserProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store: KizunaUserProfileStore
    @State private var draft: KizunaUserProfile

    init(store: KizunaUserProfileStore) {
        self.store = store
        _draft = State(initialValue: store.profile)
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
                    profileCard(
                        title: KizunaCopy.text(japanese: "名前と画像", english: "Name and photo"),
                        icon: "person.crop.circle"
                    ) {
                        TextField(
                            KizunaCopy.text(japanese: "呼ばれたい名前（任意）", english: "Name or nickname (optional)"),
                            text: nameBinding
                        )
                        .textFieldStyle(.roundedBorder)

                        KizunaAvatarPicker(
                            selection: $draft.avatarSymbol,
                            imageData: $draft.avatarImageData
                        )
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
                        store.update(draft)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func profileCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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
    }
}
