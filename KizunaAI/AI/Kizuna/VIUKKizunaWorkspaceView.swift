/*
仕様:
- 役割: Kizunaを「会話 / ストーリー / マイページ」の3つの標準タブで表示する。
- 主な型: `VIUKKizunaWorkspaceView`.
- 方針: TabViewはiOS標準の操作として使い、会話・ストーリーの内容だけをKizuna固有の体験にする。
*/

import SwiftUI

struct VIUKKizunaWorkspaceView: View {
    @AppStorage(KizunaStorageKeys.workspaceSection)
    private var selectedSectionRawValue = KizunaWorkspaceSection.conversation.rawValue
    @StateObject private var storyLibraryViewModel = StoryWorldLibraryViewModel()
    @State private var activeStoryWorld: StoryWorld?
    @State private var activeStorySessionID: UUID?
    @State private var activeStoryStartsNewSession = false
    /// Storyカードを連続タップした時、先に予約された古い遷移が後から
    /// sheetを開いて別Worldを表示しないよう、遷移Taskを一つに限定する。
    @State private var pendingStoryOpenTask: Task<Void, Never>?
    @State private var pendingStoryRequestID: UUID?

    private var selectedSectionBinding: Binding<KizunaWorkspaceSection> {
        Binding(
            get: { KizunaWorkspaceSection(rawValue: selectedSectionRawValue) },
            set: { selectedSectionRawValue = $0.rawValue }
        )
    }

    var body: some View {
        TabView(selection: selectedSectionBinding) {
            KizunaConversationHomeView()
                .tabItem {
                    Label(
                        KizunaWorkspaceSection.conversation.title,
                        systemImage: KizunaWorkspaceSection.conversation.icon
                    )
                }
                .tag(KizunaWorkspaceSection.conversation)
                .accessibilityIdentifier("workspace.conversation")

            StoryWorldLibraryView(
                viewModel: storyLibraryViewModel,
                showsDismissButton: false,
                onStartSession: { world in
                    scheduleStoryOpen(world: world, sessionID: nil, startsNewSession: false)
                },
                onResumeSession: { world, sessionID in
                    scheduleStoryOpen(world: world, sessionID: sessionID, startsNewSession: false)
                },
                onStartNewSession: { world in
                    scheduleStoryOpen(world: world, sessionID: nil, startsNewSession: true)
                }
            )
            .tabItem {
                Label(
                    KizunaWorkspaceSection.stories.title,
                    systemImage: KizunaWorkspaceSection.stories.icon
                )
            }
            .tag(KizunaWorkspaceSection.stories)
            .accessibilityIdentifier("workspace.story")

            KizunaMyPageView()
                .tabItem {
                    Label(
                        KizunaWorkspaceSection.myPage.title,
                        systemImage: KizunaWorkspaceSection.myPage.icon
                    )
                }
                .tag(KizunaWorkspaceSection.myPage)
                .accessibilityIdentifier("workspace.myPage")
        }
        .background(Color.appCanvasBackground.ignoresSafeArea())
        // 設定画面はStoryの外側にあるため、デバッグ要求時はStoryを自動で開く。
        .onReceive(NotificationCenter.default.publisher(for: KizunaDebugOptions.restSuggestionRequestNotification)) { _ in
            openDebugStory()
        }
        .onReceive(NotificationCenter.default.publisher(for: KizunaDebugOptions.safetyConcernRequestNotification)) { _ in
            openDebugStory()
        }
#if os(iOS)
        .fullScreenCover(item: $activeStoryWorld, onDismiss: resetStoryPresentation) { world in
            StorySessionChatView(
                world: world,
                initialSessionID: activeStorySessionID,
                startsNewSession: activeStoryStartsNewSession
            )
        }
#else
        .sheet(item: $activeStoryWorld, onDismiss: resetStoryPresentation) { world in
            StorySessionChatView(
                world: world,
                initialSessionID: activeStorySessionID,
                startsNewSession: activeStoryStartsNewSession
            )
        }
#endif
        .onAppear {
            // `chat` was the old persisted value. Treating it as Conversation
            // preserves the user's last destination without leaving a dead tab.
            let normalized = KizunaWorkspaceSection(rawValue: selectedSectionRawValue).rawValue
            if selectedSectionRawValue != normalized {
                selectedSectionRawValue = normalized
            }
        }
        .onDisappear {
            pendingStoryOpenTask?.cancel()
            pendingStoryOpenTask = nil
            pendingStoryRequestID = nil
        }
    }

    private func openDebugStory() {
        guard activeStoryWorld == nil else { return }
        pendingStoryOpenTask?.cancel()
        let requestID = UUID()
        pendingStoryRequestID = requestID
        pendingStoryOpenTask = Task { @MainActor in
            // 設定シートのdismiss完了を待ってからStoryを表示する。
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled, pendingStoryRequestID == requestID else { return }
            guard activeStoryWorld == nil else { return }
            let repository = LocalJSONStoryWorldRepository()
            // ライブラリーの初期化がまだ終わっていない起動直後でも対象を取得できるようにする。
            await CharacterLibrarySeed.seedIfNeeded(
                characterRepo: LocalJSONCharacterRepository(),
                worldRepo: repository
            )
            guard let world = (try? await repository.fetchWorlds())?.first else { return }
            guard !Task.isCancelled, pendingStoryRequestID == requestID else { return }
            activeStorySessionID = nil
            activeStoryStartsNewSession = false
            activeStoryWorld = world
            if pendingStoryRequestID == requestID {
                pendingStoryRequestID = nil
                pendingStoryOpenTask = nil
            }
        }
    }

    private func scheduleStoryOpen(world: StoryWorld, sessionID: UUID?, startsNewSession: Bool) {
        pendingStoryOpenTask?.cancel()
        let requestID = UUID()
        pendingStoryRequestID = requestID
        pendingStoryOpenTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, pendingStoryRequestID == requestID else { return }
            activeStorySessionID = sessionID
            activeStoryStartsNewSession = startsNewSession
            activeStoryWorld = world
            if pendingStoryRequestID == requestID {
                pendingStoryRequestID = nil
                pendingStoryOpenTask = nil
            }
        }
    }

    private func resetStoryPresentation() {
        activeStorySessionID = nil
        activeStoryStartsNewSession = false
    }
}

private enum KizunaWorkspaceSection: String, CaseIterable, Identifiable {
    case conversation
    case stories
    case myPage

    init(rawValue: String) {
        switch rawValue {
        case Self.conversation.rawValue, "chat": self = .conversation
        case Self.stories.rawValue: self = .stories
        case Self.myPage.rawValue: self = .myPage
        default: self = .conversation
        }
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .conversation: return KizunaCopy.text(japanese: "会話", english: "Conversations")
        case .stories: return KizunaCopy.text(japanese: "ストーリー", english: "Stories")
        case .myPage: return KizunaCopy.text(japanese: "マイページ", english: "My page")
        }
    }

    var icon: String {
        switch self {
        case .conversation: return "bubble.left.and.bubble.right.fill"
        case .stories: return "sparkles.rectangle.stack.fill"
        case .myPage: return "person.crop.circle.fill"
        }
    }
}
