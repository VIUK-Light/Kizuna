import SwiftUI

/// プロフィールは「入力フォーム」ではなく、会話の雰囲気を選ぶ小さな設定画面。
/// 保存形式は既存のKizunaUserProfileと互換にしている。
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
                // 旧バージョンのdisplayNameも更新し、古い画面に戻っても表示がずれないようにする。
                draft.displayName = String($0.prefix(60))
            }
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    profileHeader
                    nameCard
                    storyCard
                    aboutCard
                    privacyCard
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 20)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .background(Color.appCanvasBackground.ignoresSafeArea())
            .navigationTitle(KizunaCopy.text(japanese: "あなたの設定", english: "Your settings"))
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

    private var profileHeader: some View {
        HStack(spacing: 14) {
            KizunaAvatarView(symbol: draft.avatarSymbol, size: 72)

            VStack(alignment: .leading, spacing: 5) {
                Text(draft.visibleName.isEmpty
                     ? KizunaCopy.text(japanese: "まだ名前はありません", english: "No name yet")
                     : draft.visibleName)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                Text(KizunaCopy.text(
                    japanese: "ここで選んだ内容は、会話をあなた向けに整えるためだけに使います。",
                    english: "These choices only tune the conversation to you."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(cardBackground)
    }

    private var nameCard: some View {
        profileCard(
            title: KizunaCopy.text(japanese: "どう呼ばれたい？", english: "How should kizuna address you?"),
            subtitle: KizunaCopy.text(
                japanese: "本名でなくて大丈夫。空欄のままでも使えます。",
                english: "A nickname is fine. You can leave it blank."
            ),
            icon: "person.crop.circle"
        ) {
            TextField(
                KizunaCopy.text(japanese: "呼ばれたい名前（任意）", english: "Name or nickname (optional)"),
                text: nameBinding
            )
            .textFieldStyle(.roundedBorder)

            Text(KizunaCopy.text(japanese: "プロフィールアイコン", english: "Profile icon"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            KizunaAvatarPicker(selection: $draft.avatarSymbol)
        }
    }

    private var storyCard: some View {
        profileCard(
            title: KizunaCopy.text(japanese: "どんな物語から始める？", english: "What kind of story sounds good?"),
            subtitle: KizunaCopy.text(
                japanese: "おすすめの並びと、物語の空気に反映します。",
                english: "This shapes recommendations and story atmosphere."
            ),
            icon: "sparkles.rectangle.stack"
        ) {
            preferenceChoiceGrid(
                choices: KizunaStoryPreference.allCases,
                selection: $draft.storyPreference
            ) { preference in
                (preference.displayName, preference.detail)
            }
        }
    }

    private var aboutCard: some View {
        profileCard(
            title: KizunaCopy.text(japanese: "会話で伝えておきたいこと", english: "Anything to keep in mind?"),
            subtitle: KizunaCopy.text(
                japanese: "好きなもの、苦手な話題、話し方の希望など。",
                english: "Interests, topics to avoid, or how you like to talk."
            ),
            icon: "note.text"
        ) {
            TextEditor(text: $draft.about)
                .frame(minHeight: 92)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                }
            Text(KizunaCopy.text(
                japanese: "住所・連絡先・パスワードなどの秘密は入力しないでください。",
                english: "Do not enter addresses, contact details, passwords, or secrets."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var privacyCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 4) {
                Text(KizunaCopy.text(japanese: "保存と共有について", english: "Storage and sharing"))
                    .font(.system(size: 13, weight: .bold))
                Text(KizunaCopy.text(
                    japanese: "プロフィールはこのアプリの端末内設定に保存されます。生成時は、入力した項目のうち会話に必要な範囲だけを選択中のモデルへ渡します。不要なら空欄のままで大丈夫です。",
                    english: "Your profile stays in this app's local settings. During generation, only relevant fields are included in the selected model request. Leave anything blank if you do not need it."
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

    private func profileCard<Content: View>(
        title: String,
        subtitle: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.accentColor)
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

    private func preferenceChoiceGrid<Choice: Hashable>(
        choices: [Choice],
        selection: Binding<Choice>,
        labels: @escaping (Choice) -> (String, String)
    ) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 8)], spacing: 8) {
            ForEach(choices, id: \.self) { choice in
                let label = labels(choice)
                Button {
                    selection.wrappedValue = choice
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(label.0)
                            .font(.system(size: 13, weight: .bold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(label.1)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(2)
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(selection.wrappedValue == choice
                                  ? Color.accentColor.opacity(0.13)
                                  : Color.primary.opacity(0.035))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(
                                selection.wrappedValue == choice ? Color.accentColor : Color.primary.opacity(0.08),
                                lineWidth: selection.wrappedValue == choice ? 1.5 : 1
                            )
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
