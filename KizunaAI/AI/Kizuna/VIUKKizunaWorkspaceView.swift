/*
仕様:
- 役割: Kizunaを「ホーム / 続きから / My」の3つの標準タブで表示する。
- 主な型: `VIUKKizunaWorkspaceView`.
- 方針: ホームはPersona/Storyの開始導線、続きからは共通ルート一覧、Myは設定を担当する。
*/

import SwiftUI

struct VIUKKizunaWorkspaceView: View {
    @AppStorage(KizunaStorageKeys.workspaceSection)
    private var selectedSectionRawValue = KizunaWorkspaceSection.home.rawValue
    @State private var activeStoryWorld: StoryWorld?
    @State private var activeStorySessionID: UUID?
    @State private var activeStoryStartsNewSession = false
    /// Storyカードを連続タップした時、先に予約された古い遷移が後から
    /// sheetを開いて別Worldを表示しないよう、遷移Taskを一つに限定する。
    @State private var pendingStoryOpenTask: Task<Void, Never>?
    @State private var pendingStoryRequestID: UUID?
    /// デバッグ要求は設定シートの dismiss 完了後に Story を開く。dismiss 完了通知が
    /// 届くまで「開く予約」だけを保持する。
    @State private var pendingDebugStoryOpen = false

    private var selectedSectionBinding: Binding<KizunaWorkspaceSection> {
        Binding(
            get: { KizunaWorkspaceSection(rawValue: selectedSectionRawValue) },
            set: { selectedSectionRawValue = $0.rawValue }
        )
    }

    var body: some View {
        TabView(selection: selectedSectionBinding) {
            KizunaHomeView()
                .tabItem {
                    Label(
                        KizunaWorkspaceSection.home.title,
                        systemImage: KizunaWorkspaceSection.home.icon
                    )
                }
                .tag(KizunaWorkspaceSection.home)
                .accessibilityIdentifier("workspace.home")

            KizunaContinuationView()
                .tabItem {
                    Label(
                        KizunaWorkspaceSection.continuations.title,
                        systemImage: KizunaWorkspaceSection.continuations.icon
                    )
                }
                .tag(KizunaWorkspaceSection.continuations)
                .accessibilityIdentifier("workspace.continuations")

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
        // 設定画面のデバッグ要求時はStoryを自動で開く。
        .onReceive(NotificationCenter.default.publisher(for: KizunaDebugOptions.restSuggestionRequestNotification)) { _ in
            openDebugStory()
        }
        .onReceive(NotificationCenter.default.publisher(for: KizunaDebugOptions.safetyConcernRequestNotification)) { _ in
            openDebugStory()
        }
        .onReceive(NotificationCenter.default.publisher(for: KizunaDebugOptions.settingsDismissedNotification)) { _ in
            flushPendingDebugStoryOpen()
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
            // `chat` / `conversation` / `stories` were old persisted values.
            // Normalize them to Home so no removed tab becomes a dead destination.
            let normalized = KizunaWorkspaceSection(rawValue: selectedSectionRawValue).rawValue
            if selectedSectionRawValue != normalized {
                selectedSectionRawValue = normalized
            }
        }
        .onDisappear {
            pendingStoryOpenTask?.cancel()
            pendingStoryOpenTask = nil
            pendingStoryRequestID = nil
            pendingDebugStoryOpen = false
        }
    }

    /// デバッグ要求を受け取った時点では設定シートがまだ dismiss 中のため、
    /// 「開く予約」だけを立てる。実際の遷移は設定シートの dismiss 完了通知
    /// （KizunaMyPageView の onDismiss）で実行する。
    private func openDebugStory() {
        guard activeStoryWorld == nil else { return }
        pendingDebugStoryOpen = true
    }

    private func flushPendingDebugStoryOpen() {
        guard pendingDebugStoryOpen else { return }
        pendingDebugStoryOpen = false
        performDebugStoryOpen()
    }

    private func performDebugStoryOpen() {
        guard activeStoryWorld == nil else { return }
        pendingStoryOpenTask?.cancel()
        let requestID = UUID()
        pendingStoryRequestID = requestID
        pendingStoryOpenTask = Task { @MainActor in
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
    case home
    case continuations
    case myPage

    init(rawValue: String) {
        switch rawValue {
        case Self.home.rawValue, "conversation", "chat", "stories": self = .home
        case Self.continuations.rawValue: self = .continuations
        case Self.myPage.rawValue: self = .myPage
        default: self = .home
        }
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return KizunaCopy.text(japanese: "ホーム", english: "Home")
        case .continuations: return KizunaCopy.text(japanese: "続きから", english: "Continue")
        case .myPage: return KizunaCopy.text(japanese: "My", english: "My")
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .continuations: return "play"
        case .myPage: return "person.crop.circle.fill"
        }
    }
}
