import SwiftUI

@MainActor
struct KizunaUserProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store: KizunaUserProfileStore
    @State private var draft: KizunaUserProfile

    init(store: KizunaUserProfileStore) {
        self.store = store
        _draft = State(initialValue: store.profile)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Text(draft.avatarSymbol)
                            .font(.system(size: 42))
                            .frame(width: 64, height: 64)
                            .background(Circle().fill(Color.accentColor.opacity(0.14)))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(draft.visibleName.isEmpty
                                 ? KizunaCopy.text(japanese: "プロフィール未設定", english: "Profile not set")
                                 : draft.visibleName)
                                .font(.headline)
                            Text(KizunaCopy.text(
                                japanese: "入力した内容は端末内に保存されます。生成時は必要な項目だけ選択中のモデルへ渡ります。空欄のままでも使えます。",
                                english: "Your entries are stored in this app. Only relevant fields are sent with a generation request. You can leave everything blank."
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)

                    Picker(KizunaCopy.text(japanese: "アイコン", english: "Icon"), selection: $draft.avatarSymbol) {
                        ForEach(["🙂", "😊", "😌", "🌱", "⭐️", "🌙", "🎧", "🧭"], id: \.self) { symbol in
                            Text(symbol).tag(symbol)
                        }
                    }
                }

                Section(KizunaCopy.text(japanese: "呼ばれ方", english: "How to address you")) {
                    TextField(
                        KizunaCopy.text(japanese: "表示名（任意）", english: "Display name (optional)"),
                        text: $draft.displayName
                    )
                    TextField(
                        KizunaCopy.text(japanese: "呼び名（優先）", english: "Nickname (preferred)"),
                        text: $draft.nickname
                    )
                    Text(KizunaCopy.text(
                        japanese: "会話の中で呼ばれる名前です。実名でなくても構いません。",
                        english: "This is only used as a conversational name; it does not have to be your real name."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section(KizunaCopy.text(japanese: "共有メモ", english: "About you")) {
                    TextEditor(text: $draft.about)
                        .frame(minHeight: 90)
                    Text(KizunaCopy.text(
                        japanese: "好きなことや会話で配慮してほしいことなど。住所・連絡先・秘密は入力しないでください。",
                        english: "Add interests or conversation preferences. Do not enter addresses, contact details, or secrets."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section(KizunaCopy.text(japanese: "返答の長さ", english: "Reply length")) {
                    Picker(
                        KizunaCopy.text(japanese: "会話のテンポ", english: "Conversation pace"),
                        selection: $draft.conversationPreference
                    ) {
                        ForEach(KizunaConversationPreference.allCases) { preference in
                            Text(preference.displayName).tag(preference)
                        }
                    }
                    Text(draft.conversationPreference.promptHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(KizunaCopy.text(japanese: "プロフィール", english: "Profile"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(KizunaCopy.text(japanese: "キャンセル", english: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(KizunaCopy.text(japanese: "保存", english: "Save")) {
                        store.update(draft)
                        dismiss()
                    }
                }
            }
        }
    }
}
