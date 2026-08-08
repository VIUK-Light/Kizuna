import SwiftUI

/// 初回起動は説明を読む画面ではなく、プロフィールと物語の入口を
/// 30秒以内に選べる2ステップのセットアップにする。
struct KizunaLaunchView: View {
    @ObservedObject private var profileStore = KizunaUserProfileStore.shared
    @State private var draft: KizunaUserProfile
    @State private var step = 0

    var onFinished: () -> Void

    init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
        _draft = State(initialValue: KizunaUserProfileStore.shared.profile)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    brandHeader
                    if step == 0 {
                        profileStep
                    } else {
                        storyStep
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 24)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            bottomBar
        }
        .background(Color.appCanvasBackground.ignoresSafeArea())
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "infinity.circle.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.tint)
            Text(KizunaCopy.appName)
                .font(.system(size: 15, weight: .bold, design: .rounded))
            Spacer()
            Text("\(step + 1) / 2")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
            ProgressView(value: Double(step + 1), total: 2)
                .frame(width: 90)
                .tint(.accentColor)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .background(.thinMaterial)
    }

    private var brandHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(KizunaCopy.text(
                japanese: step == 0 ? "まず、あなたのペースを教えてください。" : "次に、物語の入口を選びましょう。",
                english: step == 0 ? "First, set your pace." : "Now choose a story entrance."
            ))
            .font(.system(size: 28, weight: .heavy, design: .rounded))
            .fixedSize(horizontal: false, vertical: true)
            Text(KizunaCopy.text(
                japanese: "どちらも後から変更できます。決めずに始めても大丈夫です。",
                english: "Both choices can be changed later. You can also skip them."
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var profileStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            setupCard(title: KizunaCopy.text(japanese: "呼ばれたい名前", english: "Name or nickname"),
                      subtitle: KizunaCopy.text(japanese: "本名でなくて大丈夫。空欄でも使えます。", english: "A nickname is fine. Leave it blank if you prefer."),
                      icon: "person.crop.circle") {
                TextField(
                    KizunaCopy.text(japanese: "例: ひくま / きみ / 呼び名なし", english: "e.g. Alex / a nickname / leave blank"),
                    text: Binding(
                        get: { draft.visibleName },
                        set: {
                            draft.nickname = String($0.prefix(60))
                            draft.displayName = String($0.prefix(60))
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)

                HStack(spacing: 8) {
                    ForEach(["🙂", "😊", "😌", "🌱", "⭐️", "🌙", "🎧", "🧭"], id: \.self) { symbol in
                        Button {
                            draft.avatarSymbol = symbol
                        } label: {
                            Text(symbol)
                                .font(.title3)
                                .frame(width: 34, height: 34)
                                .background(
                                    Circle().fill(
                                        draft.avatarSymbol == symbol
                                            ? Color.accentColor.opacity(0.18)
                                            : Color.primary.opacity(0.05)
                                    )
                                )
                                .overlay {
                                    Circle().stroke(
                                        draft.avatarSymbol == symbol ? Color.accentColor : .clear,
                                        lineWidth: 1.5
                                    )
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            setupCard(title: KizunaCopy.text(japanese: "会話のテンポ", english: "Conversation pace"),
                      subtitle: KizunaCopy.text(japanese: "短く、標準、少し詳しく。", english: "Short, balanced, or a little more detail."),
                      icon: "bubble.left.and.bubble.right") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 8)], spacing: 8) {
                    ForEach(KizunaConversationPreference.allCases) { preference in
                        setupChoice(
                            title: preference.displayName,
                            detail: preference.promptHint,
                            icon: preference == .short ? "bolt.fill" : preference == .balanced ? "waveform" : "text.alignleft",
                            isSelected: draft.conversationPreference == preference
                        ) {
                            draft.conversationPreference = preference
                        }
                    }
                }
            }
        }
    }

    private var storyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            setupCard(title: KizunaCopy.text(japanese: "好きな世界観", english: "Story atmosphere"),
                      subtitle: KizunaCopy.text(
                          japanese: "一覧のおすすめと、生成される物語の空気に反映します。",
                          english: "Shapes recommendations and the atmosphere of generated stories."
                      ),
                      icon: "sparkles.rectangle.stack") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                    ForEach(KizunaStoryPreference.allCases) { preference in
                        setupChoice(
                            title: preference.displayName,
                            detail: preference.detail,
                            icon: preference.iconName,
                            isSelected: draft.storyPreference == preference
                        ) {
                            draft.storyPreference = preference
                        }
                    }
                }
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.green)
                Text(KizunaCopy.text(
                    japanese: "プロフィールは端末内に保存され、会話に必要な項目だけが選択中のモデルへ渡ります。空欄の情報は送られません。",
                    english: "Your profile stays on this device. Only relevant fields are included in a request; blank fields are not sent."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(13)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.green.opacity(0.08))
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

            if step > 0 {
                Button(KizunaCopy.text(japanese: "戻る", english: "Back")) {
                    withAnimation(.easeInOut(duration: 0.2)) { step -= 1 }
                }
                .buttonStyle(.bordered)
            }

            Button {
                if step == 0 {
                    withAnimation(.easeInOut(duration: 0.2)) { step = 1 }
                } else {
                    profileStore.update(draft)
                    onFinished()
                }
            } label: {
                Text(KizunaCopy.text(
                    japanese: step == 0 ? "次へ" : "この設定で始める",
                    english: step == 0 ? "Next" : "Start with these settings"
                ))
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
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func setupChoice(
        title: String,
        detail: String,
        icon: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 26, height: 26)
                    .background(
                        Circle().fill(
                            isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05)
                        )
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .bold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(detail)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(2)
                }
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
        }
        .buttonStyle(.plain)
    }
}
