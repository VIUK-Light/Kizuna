import SwiftUI

/// The first workspace destination: resume a relationship or choose a
/// character. Story browsing intentionally lives in the Story tab so the
/// user's next action is obvious when they open Kizuna.
struct KizunaConversationHomeView: View {
    @StateObject private var store = PersonaChatStore.shared
    @State private var presentedThread: PersonaThread?
    @State private var isShowingAllConversations = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if store.isPersistenceRecoveryRequired {
                recoveryPrompt
                Divider()
            }

            if let latestThread = store.threads.first {
                latestConversation(latestThread)
                if store.threads.count > 1 {
                    recentConversations
                }
            } else {
                emptyConversationIntro
            }

            Divider()
            CharacterLibraryView(
                showsDismissButton: false,
                startsChatImmediately: true,
                onStartChat: startConversation(with:)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.appCanvasBackground.ignoresSafeArea())
#if os(iOS)
        .fullScreenCover(item: $presentedThread) { thread in
            PersonaChatView(initialThreadID: thread.id, showsStoryActions: false)
        }
        .fullScreenCover(isPresented: $isShowingAllConversations) {
            PersonaChatView(showsStoryActions: false)
        }
#else
        .sheet(item: $presentedThread) { thread in
            PersonaChatView(initialThreadID: thread.id, showsStoryActions: false)
                .viukAdaptiveSheetSizing(minWidth: 880, minHeight: 700)
        }
        .sheet(isPresented: $isShowingAllConversations) {
            PersonaChatView(showsStoryActions: false)
                .viukAdaptiveSheetSizing(minWidth: 880, minHeight: 700)
        }
#endif
        .accessibilityIdentifier("workspace.conversation")
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(KizunaCopy.text(japanese: "会話", english: "Conversations"))
                    .font(.title2.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("workspace.conversation.heading")
                Text(KizunaCopy.text(
                    japanese: "キャラクターを選ぶと、すぐに会話を始められます。",
                    english: "Choose a character to start talking right away."
                ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if !store.threads.isEmpty {
                Button {
                    isShowingAllConversations = true
                } label: {
                    Label(
                        KizunaCopy.text(japanese: "すべての会話", english: "All conversations"),
                        systemImage: "bubble.left.and.bubble.right"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .accessibilityIdentifier("conversation.all")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.thinMaterial)
        .accessibilityElement(children: .contain)
    }

    private func latestConversation(_ thread: PersonaThread) -> some View {
        Button {
            open(thread)
        } label: {
            HStack(spacing: 12) {
                PersonaAvatarView(profile: thread.personaSnapshot, size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(KizunaCopy.text(japanese: "続きから", english: "Continue"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                    Text(thread.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(thread.messages.last?.text ?? KizunaCopy.text(
                        japanese: "新しい会話",
                        english: "New conversation"
                    ))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("conversation.latest")
        .accessibilityHint(KizunaCopy.text(
            japanese: "最新の会話を開きます",
            english: "Opens the latest conversation"
        ))
    }

    private var recentConversations: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(KizunaCopy.text(japanese: "最近の会話", english: "Recent conversations"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(store.threads.dropFirst()) { thread in
                        Button {
                            open(thread)
                        } label: {
                            HStack(spacing: 8) {
                                PersonaAvatarView(profile: thread.personaSnapshot, size: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(thread.title)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                    Text(thread.updatedAt, style: .relative)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(minWidth: 155, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(Color.primary.opacity(0.055))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
        }
        .padding(.top, 10)
    }

    private var emptyConversationIntro: some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .foregroundStyle(.tint)
            Text(KizunaCopy.text(
                japanese: "まだ会話はありません。下からキャラクターを選んでください。",
                english: "No conversations yet. Choose a character below."
            ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.accentColor.opacity(0.07))
        .accessibilityIdentifier("conversation.empty")
    }

    private var recoveryPrompt: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(KizunaCopy.text(
                    japanese: "Persona履歴の復旧が必要です",
                    english: "Persona history recovery is required"
                ))
                    .font(.subheadline.weight(.semibold))
                Text(KizunaCopy.text(
                    japanese: "保存データは保持されています。復旧画面からバックアップまたはリセットを選べます。",
                    english: "Your saved data is preserved. Open recovery to export a backup or reset it."
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            Button(KizunaCopy.text(japanese: "復旧を開く", english: "Open recovery")) {
                isShowingAllConversations = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.10))
        .accessibilityElement(children: .contain)
    }

    private func open(_ thread: PersonaThread) {
        store.selectThread(id: thread.id)
        presentedThread = store.thread(id: thread.id) ?? thread
    }

    @MainActor
    private func startConversation(with character: CharacterProfile) {
        // A character card is a resume-or-create entry point. Reusing the
        // newest non-empty thread preserves the relationship instead of
        // presenting a fresh conversation that looks like lost memory.
        if let existing = store.threads.first(where: {
            $0.characterID == character.id && !$0.messages.isEmpty
        }) {
            open(existing)
            return
        }

        let persona = PersonaProfile(
            name: character.displayName.isEmpty ? character.name : character.displayName,
            age: nil,
            personality: character.personality,
            tone: .casual,
            relation: .friend,
            freeFormAddendum: [
                character.shortDescription,
                character.background,
                character.relationshipToUser,
                character.scenario
            ]
                .filter { !$0.isEmpty }
                .joined(separator: " / ")
        )
        guard let thread = store.createThread(with: persona, characterID: character.id) else {
            // The recovery screen owns export/reset. Do not drop the tap
            // silently when corrupted data has intentionally blocked writes.
            if store.isPersistenceRecoveryRequired {
                isShowingAllConversations = true
            }
            return
        }
        if thread.messages.isEmpty, !character.firstMessage.isEmpty {
            store.appendMessage(
                PersonaMessage(role: .assistant, text: character.firstMessage),
                toThread: thread.id
            )
        }
        presentedThread = store.thread(id: thread.id) ?? thread
    }
}
