/*
仕様:
- 役割: VIUK 絆を AI Studio から独立したアプリ入口として表示する。
- 主な型: `VIUKKizunaWorkspaceView`.
- 編集ポイント: 絆アプリ単体のトップ、ライブラリー、キャラ導線、単体チャット導線。
*/

import SwiftUI

struct VIUKKizunaWorkspaceView: View {
    @State private var selectedSection: KizunaWorkspaceSection = .stories
    @StateObject private var storyLibraryViewModel = StoryWorldLibraryViewModel()
    @State private var activeStoryWorld: StoryWorld?
    @State private var activeStorySessionID: UUID?
    /// Storyカードを連続タップした時、先に予約された古い遷移が後から
    /// sheetを開いて別Worldを表示しないよう、遷移Taskを一つに限定する。
    @State private var pendingStoryOpenTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            sectionPicker
            Divider()
            sectionContent
        }
        .background(Color.appCanvasBackground.ignoresSafeArea())
        // 設定画面はStoryの外側にあるため、デバッグ要求時はStoryを自動で開く。
        // これで「設定を閉じる → Storyを探す」の間に予約が消えることを防ぐ。
        .onReceive(NotificationCenter.default.publisher(for: KizunaDebugOptions.restSuggestionRequestNotification)) { _ in
            openDebugStory()
        }
        .onReceive(NotificationCenter.default.publisher(for: KizunaDebugOptions.safetyConcernRequestNotification)) { _ in
            openDebugStory()
        }
#if os(iOS)
        .fullScreenCover(item: $activeStoryWorld) { world in
            StorySessionChatView(world: world, initialSessionID: activeStorySessionID)
        }
#else
        .sheet(item: $activeStoryWorld) { world in
            StorySessionChatView(world: world, initialSessionID: activeStorySessionID)
        }
#endif
        .onDisappear {
            pendingStoryOpenTask?.cancel()
            pendingStoryOpenTask = nil
        }
    }

    private var myPageButton: some View {
        Button {
            selectedSection = .myPage
        } label: {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 15, weight: .bold))
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel(KizunaCopy.text(japanese: "マイページ", english: "My page"))
    }

    private func openDebugStory() {
        guard activeStoryWorld == nil else { return }
        pendingStoryOpenTask?.cancel()
        pendingStoryOpenTask = Task { @MainActor in
            // 設定シートのdismiss完了を待ってからStoryを表示する。
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            guard activeStoryWorld == nil else { return }
            let repository = LocalJSONStoryWorldRepository()
            // ライブラリーの初期化がまだ終わっていない起動直後でも対象を取得できるようにする。
            await CharacterLibrarySeed.seedIfNeeded(
                characterRepo: LocalJSONCharacterRepository(),
                worldRepo: repository
            )
            guard let world = (try? await repository.fetchWorlds())?.first else { return }
            activeStoryWorld = world
            pendingStoryOpenTask = nil
        }
    }

    private var sectionPicker: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(KizunaWorkspaceSection.allCases) { section in
                        Button {
                            selectedSection = section
                        } label: {
                            Label(section.title, systemImage: section.icon)
                                .font(.system(size: 12, weight: .bold))
                                .labelStyle(.titleAndIcon)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule()
                                        .fill(selectedSection == section ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
                                )
                                .foregroundStyle(selectedSection == section ? Color.accentColor : Color.primary.opacity(0.82))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            myPageButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.appSecondaryBackground.opacity(0.18))
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selectedSection {
        case .stories:
            StoryWorldLibraryView(
                viewModel: storyLibraryViewModel,
                showsDismissButton: false,
                onStartSession: { world in
                    scheduleStoryOpen(world: world, sessionID: nil)
                },
                onResumeSession: { world, sessionID in
                    scheduleStoryOpen(world: world, sessionID: sessionID)
                }
            )
        case .chat:
            PersonaChatView()
        case .myPage:
            KizunaMyPageView()
        }
    }

    private func scheduleStoryOpen(world: StoryWorld, sessionID: UUID?) {
        pendingStoryOpenTask?.cancel()
        pendingStoryOpenTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, selectedSection == .stories else {
                pendingStoryOpenTask = nil
                return
            }
            activeStorySessionID = sessionID
            activeStoryWorld = world
            pendingStoryOpenTask = nil
        }
    }
}

private enum KizunaWorkspaceSection: String, CaseIterable, Identifiable {
    case stories
    case chat
    case myPage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stories: return KizunaCopy.text(japanese: "ストーリー", english: "Stories")
        case .chat: return KizunaCopy.text(japanese: "あなたの物語", english: "Your story")
        case .myPage: return KizunaCopy.text(japanese: "マイページ", english: "My page")
        }
    }

    var icon: String {
        switch self {
        case .stories: return "sparkles.rectangle.stack.fill"
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .myPage: return "person.crop.circle.fill"
        }
    }
}
