/*
仕様:
- 役割: Persona / Story の開始導線を1つにまとめるホーム。
- 制約: 遷移先の PersonaChatView と StorySessionChatView は仕様が異なるため統合しない。
- 編集ポイント: 2つの開始カード、説明文、各ライブラリーへの遷移を変えるときに触る。
*/

import SwiftUI

struct KizunaHomeView: View {
    @StateObject private var personaStore = PersonaChatStore.shared
    @State private var showCharacterLibrary = false
    @State private var showStoryLibrary = false
    @State private var pendingPersonaThread: PersonaThread?
    @State private var pendingPersonaRecovery = false
    @State private var pendingStoryOpen: PendingStoryOpen?
    @State private var presentedThread: PersonaThread?
    @State private var activeStoryWorld: StoryWorld?
    @State private var activeStorySessionID: UUID?
    @State private var activeStoryStartsNewSession = false
    @State private var isShowingRecovery = false

    private struct PendingStoryOpen {
        let world: StoryWorld
        let sessionID: UUID?
        let startsNewSession: Bool
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                routeSection
                explanation
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .frame(maxWidth: 1_100)
            .frame(maxWidth: .infinity)
        }
        .background(Color.appCanvasBackground.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.home")
        .sheet(isPresented: $showCharacterLibrary, onDismiss: presentPendingPersona) {
            CharacterLibraryView(
                showsDismissButton: true,
                startsChatImmediately: true,
                onStartChat: startConversation(with:)
            )
            .viukAdaptiveSheetSizing(minWidth: 720, minHeight: 720)
        }
        .sheet(isPresented: $showStoryLibrary, onDismiss: presentPendingStory) {
            StoryWorldLibraryView(
                showsDismissButton: true,
                onStartSession: { world in
                    pendingStoryOpen = PendingStoryOpen(
                        world: world,
                        sessionID: nil,
                        startsNewSession: false
                    )
                },
                onResumeSession: { world, sessionID in
                    pendingStoryOpen = PendingStoryOpen(
                        world: world,
                        sessionID: sessionID,
                        startsNewSession: false
                    )
                },
                onStartNewSession: { world in
                    pendingStoryOpen = PendingStoryOpen(
                        world: world,
                        sessionID: nil,
                        startsNewSession: true
                    )
                }
            )
            .viukAdaptiveSheetSizing(minWidth: 820, minHeight: 720)
        }
#if os(iOS)
        .fullScreenCover(item: $presentedThread) { thread in
            PersonaChatView(initialThreadID: thread.id, showsStoryActions: false)
        }
        .fullScreenCover(isPresented: $isShowingRecovery) {
            PersonaChatView(showsStoryActions: false)
        }
        .fullScreenCover(item: $activeStoryWorld, onDismiss: resetStoryPresentation) { world in
            StorySessionChatView(
                world: world,
                initialSessionID: activeStorySessionID,
                startsNewSession: activeStoryStartsNewSession
            )
        }
#else
        .sheet(item: $presentedThread) { thread in
            PersonaChatView(initialThreadID: thread.id, showsStoryActions: false)
                .viukAdaptiveSheetSizing(minWidth: 880, minHeight: 700)
        }
        .sheet(isPresented: $isShowingRecovery) {
            PersonaChatView(showsStoryActions: false)
                .viukAdaptiveSheetSizing(minWidth: 880, minHeight: 700)
        }
        .sheet(item: $activeStoryWorld, onDismiss: resetStoryPresentation) { world in
            StorySessionChatView(
                world: world,
                initialSessionID: activeStorySessionID,
                startsNewSession: activeStoryStartsNewSession
            )
            .viukAdaptiveSheetSizing(minWidth: 760, minHeight: 720)
        }
#endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(KizunaCopy.appName)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .tracking(1.4)
                .foregroundStyle(.tint)
            Text(KizunaCopy.text(japanese: "ホーム", english: "Home"))
                .font(.largeTitle.weight(.heavy))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("workspace.home.heading")
            Text(KizunaCopy.text(
                japanese: "キャラクターとの会話も、物語の世界も、ここから選べます。",
                english: "Choose a character conversation or a story world from here."
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var routeSection: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                personaEntryCard
                storyEntryCard
            }
            VStack(spacing: 14) {
                personaEntryCard
                storyEntryCard
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var personaEntryCard: some View {
        KizunaHomeRouteCard(
            kind: .persona,
            title: KizunaCopy.text(japanese: "キャラクターと話す", english: "Talk to a character"),
            subtitle: KizunaCopy.text(
                japanese: "キャラクターを選んで、自由な会話を始めます。",
                english: "Choose a character and start a free conversation."
            ),
            action: { showCharacterLibrary = true }
        )
        .accessibilityIdentifier("home.persona.entry")
    }

    private var storyEntryCard: some View {
        KizunaHomeRouteCard(
            kind: .story,
            title: KizunaCopy.text(japanese: "物語を始める", english: "Start a story"),
            subtitle: KizunaCopy.text(
                japanese: "世界とシーンを選んで、物語を進めます。",
                english: "Choose a world and move the story forward."
            ),
            action: { showStoryLibrary = true }
        )
        .accessibilityIdentifier("home.story.entry")
    }

    private var explanation: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(KizunaCopy.text(
                japanese: "PersonaとStoryは体験と生成の仕様が異なるため、チャット画面は分かれています。ホームでは入口だけをまとめ、選択後はそれぞれの専用画面へ進みます。",
                english: "Persona and Story have different interaction and generation rules, so their chat screens remain separate. Home brings the entry points together, then opens the dedicated screen you choose."
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @MainActor
    private func startConversation(with character: CharacterProfile) {
        if let existing = personaStore.threads.first(where: {
            $0.characterID == character.id && !$0.messages.isEmpty
        }) {
            personaStore.refreshCharacterAppearance(
                for: character.id,
                avatarStyleID: character.imageKey,
                avatarImageData: character.avatarImageData
            )
            personaStore.selectThread(id: existing.id)
            pendingPersonaThread = personaStore.thread(id: existing.id) ?? existing
            showCharacterLibrary = false
            return
        }

        let persona = PersonaProfile(character: character)
        guard let thread = personaStore.createThread(with: persona, characterID: character.id) else {
            if personaStore.isPersistenceRecoveryRequired {
                pendingPersonaThread = nil
                pendingPersonaRecovery = true
                showCharacterLibrary = false
            }
            return
        }
        if thread.messages.isEmpty, !character.firstMessage.isEmpty {
            personaStore.appendMessage(
                PersonaMessage(role: .assistant, text: character.firstMessage),
                toThread: thread.id
            )
        }
        pendingPersonaThread = personaStore.thread(id: thread.id) ?? thread
        showCharacterLibrary = false
    }

    private func presentPendingPersona() {
        if let thread = pendingPersonaThread {
            pendingPersonaThread = nil
            presentedThread = thread
            return
        }
        if pendingPersonaRecovery {
            pendingPersonaRecovery = false
            isShowingRecovery = true
        }
    }

    private func presentPendingStory() {
        guard let pending = pendingStoryOpen else { return }
        pendingStoryOpen = nil
        activeStorySessionID = pending.sessionID
        activeStoryStartsNewSession = pending.startsNewSession
        activeStoryWorld = pending.world
    }

    private func resetStoryPresentation() {
        activeStoryWorld = nil
        activeStorySessionID = nil
        activeStoryStartsNewSession = false
    }
}

private struct KizunaHomeRouteCard: View {
    let kind: KizunaConversationKind
    let title: String
    let subtitle: String
    let action: () -> Void

    private var icon: String {
        switch kind {
        case .persona: return "bubble.left.and.bubble.right.fill"
        case .story: return "sparkles.rectangle.stack.fill"
        }
    }

    private var accent: Color {
        switch kind {
        case .persona: return .blue
        case .story: return .purple
        }
    }

    private var kindLabel: String {
        switch kind {
        case .persona: return "Persona"
        case .story: return "Story"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 46, height: 46)
                        .background(accent.opacity(0.14), in: Circle())
                    Spacer()
                    Text(kindLabel)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(accent.opacity(0.12), in: Capsule())
                }
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.callout.weight(.bold))
                        .foregroundStyle(accent)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 190, alignment: .leading)
            .background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(accent.opacity(0.22), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(KizunaCopy.text(japanese: "専用の選択画面を開きます", english: "Opens the dedicated selection screen"))
    }
}
