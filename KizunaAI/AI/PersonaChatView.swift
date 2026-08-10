/*
仕様:
- 役割: ペルソナモード時に AI Studio のメインエリアに表示する絆専用チャット UI。
- 主な型: `PersonaChatView`, `PersonaThreadSidebar`, `PersonaMessageBubble`, `PersonaComposer`.
- 編集ポイント: バブル形状、配色、アバター、コンポーザー UI を変えるときに触る。
- 構成: 左サイドバー (ペルソナスレッド一覧) + 右側にチャット (ヘッダー + メッセージ + コンポーザー)。
*/

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

struct PersonaChatView: View {
    @StateObject private var store = PersonaChatStore.shared
    @StateObject private var service = PersonaChatService.shared
    @StateObject private var settings = PersonaSettings.shared
    @State private var showConfig = false
    @State private var showLibrary = false
    @State private var showWorldLibrary = false
    @State private var activeStoryWorld: StoryWorld?
    @State private var activeStorySessionID: UUID?
    @State private var compactShowsChat = false
    @State private var storyHistoryItems: [StoryHistoryItem] = []
    @State private var storyHistoryLoadError: String?
    @State private var isPersonaChatNearBottom = true
    @State private var unreadPersonaMessageCount = 0
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private let storyWorldRepo: StoryWorldRepository = LocalJSONStoryWorldRepository()
    private let storySessionRepo: StorySessionRepository = LocalJSONStorySessionRepository()

    var body: some View {
        VStack(spacing: 0) {
            topSwitchBar
            Divider()
            if horizontalSizeClass == .compact {
                if compactShowsChat, store.activeThread != nil {
                    compactChat
                } else {
                    compactStoryList
                }
            } else {
                HStack(spacing: 0) {
                    sidebar
                        .frame(width: 240)
                    Divider()
                    mainArea
                }
            }
        }
        .background(Color.appCanvasBackground.ignoresSafeArea())
        .sheet(isPresented: $showConfig) {
            PersonaConfigView()
                .viukAdaptiveSheetSizing(minWidth: 560, minHeight: 680)
        }
        .sheet(isPresented: $showLibrary) {
            CharacterLibraryView(
                onStartChat: { character in
                    // ライブラリーから「絆チャット開始」が押されたら、
                    // CharacterProfile を Persona 用の簡易プロファイルに変換し、新規スレッドを作る。
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
                    let thread = store.createThread(with: persona, characterID: character.id)
                    // 初回メッセージがあればアシスタント発として入れておく。
                    if !character.firstMessage.isEmpty {
                        store.appendMessage(
                            PersonaMessage(role: .assistant, text: character.firstMessage),
                            toThread: thread.id
                        )
                    }
                    showLibrary = false
                }
            )
            .viukAdaptiveSheetSizing(minWidth: 720, minHeight: 720)
        }
        .sheet(isPresented: $showWorldLibrary) {
            StoryWorldLibraryView(
                onStartSession: { world in
                    activeStorySessionID = nil
                    activeStoryWorld = world
                    showWorldLibrary = false
                },
                onResumeSession: { world, sessionID in
                    activeStorySessionID = sessionID
                    activeStoryWorld = world
                    showWorldLibrary = false
                }
            )
            .viukAdaptiveSheetSizing(minWidth: 820, minHeight: 720)
        }
        .sheet(item: $activeStoryWorld, onDismiss: {
            activeStorySessionID = nil
            Task { await loadStoryHistory() }
        }) { world in
            StorySessionChatView(world: world, initialSessionID: activeStorySessionID)
                .viukAdaptiveSheetSizing(minWidth: 760, minHeight: 720)
        }
        .task {
            await loadStoryHistory()
        }
        .onChange(of: store.activeThreadID) { _, _ in
            isPersonaChatNearBottom = true
            unreadPersonaMessageCount = 0
        }
    }

    private var compactChat: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    compactShowsChat = false
                } label: {
                    Label(KizunaCopy.text(japanese: "一覧", english: "List"), systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                Spacer()
                Text(KizunaCopy.text(japanese: "あなたの物語", english: "Your story"))
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Color.clear.frame(width: 48)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.thinMaterial)
            Divider()
            mainArea
        }
    }

    /// 上部の細いバー。AI Studio (通常モード) に戻る/モードを切り替える導線を必ず提供する。
    private var topSwitchBar: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactTopSwitchBar
            } else {
                regularTopSwitchBar
            }
        }
    }

    private var compactTopSwitchBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(KizunaCopy.appName)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.primary)
                Text(KizunaCopy.text(japanese: "会話を続ける", english: "Continue a conversation"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                showWorldLibrary = true
            } label: {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.accentColor.opacity(0.16)))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(KizunaCopy.text(japanese: "kizunaライブラリー", english: "kizuna library"))

            Menu {
                Button {
                    showWorldLibrary = true
                } label: {
                    Label(KizunaCopy.text(japanese: "シナリオを探す", english: "Browse scenarios"), systemImage: "sparkles.rectangle.stack.fill")
                }
                Divider()
                Button {
                    showConfig = true
                } label: {
                    Label(KizunaCopy.text(japanese: "キャラクター設定", english: "Character settings"), systemImage: "slider.horizontal.3")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel(KizunaCopy.text(japanese: "kizunaメニュー", english: "kizuna menu"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    private var regularTopSwitchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "infinity.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text(KizunaCopy.appName)
                    .font(.system(size: 13, weight: .bold))
            }
            .foregroundStyle(Color.accentColor)

            Spacer()

            Button {
                showWorldLibrary = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .font(.system(size: 11, weight: .semibold))
                Text(KizunaCopy.text(japanese: "シナリオライブラリー", english: "Scenario library"))
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(KizunaCopy.text(japanese: "関係性を続けられるシナリオを開く", english: "Open scenarios that continue your relationship"))

            Menu {
                Button {
                    showWorldLibrary = true
                } label: {
                    Label(KizunaCopy.text(japanese: "シナリオを探す", english: "Browse scenarios"), systemImage: "sparkles.rectangle.stack.fill")
                }
                Divider()
                Button {
                    showConfig = true
                } label: {
                    Label(KizunaCopy.text(japanese: "キャラクター設定", english: "Character settings"), systemImage: "slider.horizontal.3")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help(KizunaCopy.text(japanese: "キャラクターなどの補助メニュー", english: "More character options"))

        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tint)
                Text(KizunaCopy.appName)
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showWorldLibrary = true
                } label: {
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help(KizunaCopy.text(japanese: "kizunaライブラリーを開く", english: "Open the kizuna library"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if let storyHistoryLoadError {
                storyHistoryErrorBanner(storyHistoryLoadError)
                Divider()
            }

            if storyHistoryItems.isEmpty && store.threads.isEmpty {
                emptyThreadState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        storyListSections
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
            }

            Spacer(minLength: 0)

            Divider()
            Button {
                showWorldLibrary = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text(KizunaCopy.text(japanese: "シナリオを探す", english: "Browse scenarios"))
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(Color.appSecondaryBackground.opacity(0.22))
    }

    private var compactStoryList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(KizunaCopy.text(japanese: "続きのある物語", english: "Stories in progress"))
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showWorldLibrary = true
                } label: {
                    Label(KizunaCopy.text(japanese: "探す", english: "Browse"), systemImage: "sparkles.rectangle.stack.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if let storyHistoryLoadError {
                storyHistoryErrorBanner(storyHistoryLoadError)
                Divider()
            }

            if storyHistoryItems.isEmpty && store.threads.isEmpty {
                noActiveThreadState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        storyListSections
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                }
                .background(Color.appCanvasBackground)
            }
        }
        .background(Color.appCanvasBackground)
    }

    @ViewBuilder
    private var storyListSections: some View {
        if !storyHistoryItems.isEmpty {
            sidebarSectionTitle(KizunaCopy.text(japanese: "続きのある物語", english: "Stories in progress"))
            ForEach(storyHistoryItems) { item in
                storyHistoryRow(item)
            }
        }
        if !store.threads.isEmpty {
            sidebarSectionTitle(KizunaCopy.text(japanese: "あなたの物語", english: "Your stories"))
            ForEach(store.threads) { thread in
                threadRow(thread)
            }
        }
    }

    private func sidebarSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 4)
    }

    private func storyHistoryRow(_ item: StoryHistoryItem) -> some View {
        let isActive = activeStorySessionID == item.session.id
        return Button {
            activeStorySessionID = item.session.id
            activeStoryWorld = item.world
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.68, green: 0.16, blue: 0.26),
                                    Color(red: 0.20, green: 0.08, blue: 0.11)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "moon.stars.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.world.localizedForCurrentLanguage.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(item.previewText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(colorScheme == .dark ? 0.20 : 0.13) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isActive ? Color.accentColor.opacity(0.38) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyThreadState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(KizunaCopy.text(japanese: "会話はまだありません", english: "No conversations yet"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button {
                showWorldLibrary = true
            } label: {
                Text(KizunaCopy.text(japanese: "シナリオを選ぶ", english: "Choose a scenario"))
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 14)
    }

    private func threadRow(_ thread: PersonaThread) -> some View {
        let isActive = store.activeThreadID == thread.id
        let style = PersonaAvatarStyle(profile: thread.personaSnapshot)
        return Button {
            store.selectThread(id: thread.id)
            if horizontalSizeClass == .compact {
                compactShowsChat = true
            }
        } label: {
            HStack(spacing: 11) {
                PersonaAvatarView(profile: thread.personaSnapshot, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(thread.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                Text(thread.messages.last?.text ?? KizunaCopy.text(japanese: "新しい会話", english: "New conversation"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isActive ? style.primary.opacity(colorScheme == .dark ? 0.20 : 0.13) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isActive ? style.primary.opacity(0.38) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                store.deleteThread(id: thread.id)
            } label: {
                    Label(KizunaCopy.text(japanese: "削除", english: "Delete"), systemImage: "trash")
            }
        }
    }

    @MainActor
    private func loadStoryHistory() async {
        do {
            let worlds = try await storyWorldRepo.fetchWorlds()
            var items: [StoryHistoryItem] = []
            var failedWorlds = 0
            for world in worlds {
                do {
                    let sessions = try await storySessionRepo.fetchSessions(storyWorldId: world.id)
                    items.append(contentsOf: sessions.map { StoryHistoryItem(world: world, session: $0) })
                } catch {
                    // 1つの壊れたWorldで、正常に読めた他Worldの履歴まで消さない。
                    failedWorlds += 1
                    NSLog("[PersonaChatView] story history session load failed for %@: %@", world.id.uuidString, error.localizedDescription)
                }
            }
            storyHistoryItems = items.sorted { $0.session.updatedAt > $1.session.updatedAt }
            storyHistoryLoadError = failedWorlds == 0
                ? nil
                : KizunaCopy.text(
                    japanese: "一部のストーリー履歴を読み込めませんでした。表示中の履歴は削除されていません。",
                    english: "Some story history could not be loaded. The displayed history was not deleted."
                )
        } catch {
            // 読み込み失敗を空配列へ変換すると「履歴なし」と区別できず、
            // 既存表示も消えてデータ消失と誤認される。
            storyHistoryLoadError = KizunaCopy.text(
                japanese: "ストーリー履歴を読み込めませんでした。再試行してください。",
                english: "Story history could not be loaded. Try again."
            )
            NSLog("[PersonaChatView] story history world load failed: %@", error.localizedDescription)
        }
    }

    private func storyHistoryErrorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 6)
            Button {
                Task { await loadStoryHistory() }
            } label: {
                Label(KizunaCopy.text(japanese: "再試行", english: "Retry"), systemImage: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }

    // MARK: - Main chat area

    @ViewBuilder
    private var mainArea: some View {
        if let active = store.activeThread {
            VStack(spacing: 0) {
                chatHeader(active)
                Divider()
                messageList(for: active)
                Divider()
                PersonaComposer(thread: active)
            }
            .background(personaChatBackground)
        } else {
            noActiveThreadState
        }
    }

    @Environment(\.colorScheme) private var colorScheme

    private var personaChatBackground: some View {
        // ライト/ダーク両対応。絆モード専用の柔らかい背景。
        let colors: [Color] = colorScheme == .dark
            ? [
                Color(red: 0.10, green: 0.11, blue: 0.14),
                Color(red: 0.13, green: 0.13, blue: 0.18)
              ]
            : [
                Color(red: 0.96, green: 0.93, blue: 0.95),
                Color(red: 0.93, green: 0.95, blue: 0.97)
              ]
        return LinearGradient(
            colors: colors,
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private func chatHeader(_ thread: PersonaThread) -> some View {
        let style = PersonaAvatarStyle(profile: thread.personaSnapshot)
        return HStack(spacing: 12) {
            PersonaAvatarView(profile: thread.personaSnapshot, size: 56)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(thread.personaSnapshot.name)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.primary)
                    Text(thread.personaSnapshot.relation.localizedDisplayName)
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(style.primary.opacity(0.16)))
                        .foregroundStyle(style.primary)
                }
                Text(thread.personaSnapshot.tone.localizedDisplayName + KizunaCopy.text(japanese: " ・ ", english: " · ") + thread.personaSnapshot.personality)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Menu {
                Button {
                    showWorldLibrary = true
                } label: {
                    Label(KizunaCopy.text(japanese: "シナリオライブラリー", english: "Scenario library"), systemImage: "sparkles.rectangle.stack.fill")
                }
                Button {
                    showConfig = true
                } label: {
                    Label(KizunaCopy.text(japanese: "このキャラクターを編集", english: "Edit this character"), systemImage: "slider.horizontal.3")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help(KizunaCopy.text(japanese: "シナリオとキャラクターの操作", english: "Scenario and character actions"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            ZStack {
                LinearGradient(
                    colors: [
                        style.highlight.opacity(colorScheme == .dark ? 0.12 : 0.24),
                        Color.appSecondaryBackground.opacity(colorScheme == .dark ? 0.55 : 0.80)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .background(.thinMaterial)
                Circle()
                    .fill(style.primary.opacity(0.12))
                    .frame(width: 180, height: 180)
                    .blur(radius: 38)
                    .offset(x: -120, y: -55)
            }
        )
    }

    private var noActiveThreadState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(KizunaCopy.text(japanese: "始めましょう", english: "Let’s begin"))
                .font(.system(size: 16, weight: .semibold))
          
            Button {
                showWorldLibrary = true
            } label: {
                Text(KizunaCopy.text(japanese: "物語を見つける", english: "Find a story"))
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(personaChatBackground)
    }

    private func messageList(for thread: PersonaThread) -> some View {
        // 生成中の最新アシスタント枠は、ストリーミングプレビューと二重に描かない。
        // 完了後は保存された本文を通常のメッセージとして表示する。
        // `phase` はサービス全体の状態だが、表示対象は thread ID と組み合わせる。
        // IDだけが一瞬残る遷移でも、別スレッドへプレビューを漏らさない。
        let isGeneratingThisThread = service.activeGenerationThreadID == thread.id
            && service.phase == .thinking
        let isErrorThisThread = service.lastErrorThreadID == thread.id
            && isGenerationError
        let pendingAssistantID: UUID? = {
            guard isGeneratingThisThread else { return nil }
            return thread.messages.last(where: { $0.role == .assistant })?.id
        }()
        let visibleMessages = thread.messages.filter { msg in
            guard msg.id != pendingAssistantID else { return false }
            return !(msg.role == .assistant && msg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        return ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(visibleMessages) { msg in
                            PersonaMessageBubble(
                                message: msg,
                                personaProfile: thread.personaSnapshot
                            )
                            .id(msg.id)
                        }
                        if isGeneratingThisThread {
                            streamingPreview(personaProfile: thread.personaSnapshot)
                                .id("streaming-preview")
                        }
                        if isErrorThisThread, case let .error(message) = service.phase {
                            generationError(message)
                                .id("generation-error")
                        }
                        Color.clear.frame(height: 4).id("bottom")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    let distanceFromBottom = geometry.contentSize.height
                        - geometry.contentOffset.y
                        - geometry.containerSize.height
                    return distanceFromBottom < 72
                } action: { _, nearBottom in
                    isPersonaChatNearBottom = nearBottom
                    if nearBottom {
                        unreadPersonaMessageCount = 0
                    }
                }
                .onChange(of: thread.messages.count) { _, _ in
                    if isPersonaChatNearBottom {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    } else {
                        unreadPersonaMessageCount += 1
                    }
                }
                .onChange(of: service.streamingResponse) { _, _ in
                    guard isGeneratingThisThread, isPersonaChatNearBottom else { return }
                    proxy.scrollTo("bottom", anchor: .bottom)
                }

                if !isPersonaChatNearBottom {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                        isPersonaChatNearBottom = true
                        unreadPersonaMessageCount = 0
                    } label: {
                        Label(
                            unreadPersonaMessageCount > 0
                                ? "\(unreadPersonaMessageCount) " + KizunaCopy.text(japanese: "新しいメッセージ", english: "new messages")
                                : KizunaCopy.text(japanese: "最新へ", english: "Latest"),
                            systemImage: "arrow.down"
                        )
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Color.primary.opacity(0.14), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 16)
                    .padding(.bottom, 14)
                    .accessibilityLabel(KizunaCopy.text(japanese: "最新のメッセージへ移動", english: "Jump to the latest message"))
                }
            }
        }
    }

    private var isGenerationError: Bool {
        if case .error = service.phase { return true }
        return false
    }

    private func streamingPreview(personaProfile: PersonaProfile) -> some View {
        let preview = service.streamingResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(alignment: .bottom, spacing: 6) {
            PersonaAvatarView(profile: personaProfile, size: 34)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(personaProfile.name)
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(KizunaCopy.text(japanese: "生成中…", english: "Writing…"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                if preview.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(preview)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(colorScheme == .dark
                          ? Color(red: 0.22, green: 0.22, blue: 0.26)
                          : Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(PersonaAvatarStyle(profile: personaProfile).primary.opacity(0.22), lineWidth: 1)
            )
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(KizunaCopy.text(
            japanese: "\(personaProfile.name)が生成中です",
            english: "\(personaProfile.name) is writing"
        ))
    }

    private func generationError(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(KizunaCopy.text(japanese: "応答を生成できませんでした", english: "Could not generate a reply"))
                    .font(.system(size: 12, weight: .bold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(KizunaCopy.text(
                    japanese: "入力欄からもう一度送信できます。",
                    english: "You can send the message again from the composer."
                ))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                HStack(spacing: 8) {
                    Button(KizunaCopy.text(japanese: "同じ内容を再送信", english: "Try again")) {
                        service.retryLastMessage()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button(KizunaCopy.text(japanese: "閉じる", english: "Dismiss")) {
                        service.dismissError()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.orange.opacity(0.22), lineWidth: 1)
        }
    }

}

private struct StoryHistoryItem: Identifiable, Hashable {
    let world: StoryWorld
    let session: StorySession

    var id: UUID { session.id }

    var previewText: String {
        session.messages.last?.text.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "新しい物語"
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

// MARK: - Persona avatar

private struct PersonaAvatarView: View {
    let profile: PersonaProfile
    let size: CGFloat

    var body: some View {
        let style = PersonaAvatarStyle(profile: profile)
        ZStack {
            if let assetName = style.assetName {
                Image(assetName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size + 2, height: size + 2)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [style.highlight, style.primary, style.shadow],
                            center: .topLeading,
                            startRadius: 1,
                            endRadius: size
                        )
                    )
                // 画像未登録時はイニシャルや文字ではなく、人型アイコンを表示する。
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Circle()
                .strokeBorder(.white.opacity(0.58), lineWidth: max(1, size * 0.052))
            Circle()
                .strokeBorder(style.primary.opacity(0.34), lineWidth: max(1, size * 0.028))
                .padding(max(1, size * 0.045))
        }
        .frame(width: size, height: size)
        .background(
            Circle()
                .fill(style.highlight.opacity(0.22))
                .frame(width: size * 1.15, height: size * 1.15)
        )
        .shadow(color: style.shadow.opacity(0.26), radius: size * 0.12, y: size * 0.05)
        .accessibilityLabel(profile.name)
    }

}

private struct PersonaAvatarStyle {
    let primary: Color
    let highlight: Color
    let shadow: Color
    let assetName: String?

    init(profile: PersonaProfile) {
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "アオイ":
            primary = Color(red: 0.32, green: 0.50, blue: 0.86)
            highlight = Color(red: 0.70, green: 0.90, blue: 1.00)
            shadow = Color(red: 0.09, green: 0.16, blue: 0.34)
            assetName = "PersonaAoiAvatar"
        case "ハル":
            primary = Color(red: 1.00, green: 0.58, blue: 0.20)
            highlight = Color(red: 1.00, green: 0.91, blue: 0.38)
            shadow = Color(red: 0.57, green: 0.19, blue: 0.05)
            assetName = "PersonaHaruAvatar"
        case "ユイ":
            primary = Color(red: 0.95, green: 0.42, blue: 0.68)
            highlight = Color(red: 1.00, green: 0.78, blue: 0.88)
            shadow = Color(red: 0.46, green: 0.09, blue: 0.26)
            assetName = "PersonaYuiAvatar"
        case "カイ":
            primary = Color(red: 0.19, green: 0.25, blue: 0.35)
            highlight = Color(red: 0.53, green: 0.66, blue: 0.82)
            shadow = Color(red: 0.03, green: 0.05, blue: 0.09)
            assetName = "PersonaKaiAvatar"
        case "レン":
            primary = Color(red: 0.32, green: 0.58, blue: 0.47)
            highlight = Color(red: 0.74, green: 0.89, blue: 0.66)
            shadow = Color(red: 0.08, green: 0.25, blue: 0.19)
            assetName = "PersonaRenAvatar"
        case "ナカムラ先生":
            primary = Color(red: 0.45, green: 0.39, blue: 0.72)
            highlight = Color(red: 0.88, green: 0.79, blue: 1.00)
            shadow = Color(red: 0.17, green: 0.12, blue: 0.33)
            assetName = "PersonaNakamuraAvatar"
        case "ツバサ":
            primary = Color(red: 0.16, green: 0.68, blue: 0.76)
            highlight = Color(red: 0.75, green: 1.00, blue: 0.96)
            shadow = Color(red: 0.02, green: 0.28, blue: 0.35)
            assetName = "PersonaTsubasaAvatar"
        default:
            let hue = PersonaAvatarStyle.nameHue(name)
            primary = Color(hue: hue, saturation: 0.58, brightness: 0.92)
            highlight = Color(hue: hue, saturation: 0.30, brightness: 1.00)
            shadow = Color(hue: hue, saturation: 0.70, brightness: 0.38)
            assetName = nil
        }
    }

    private static func nameHue(_ name: String) -> Double {
        var sum: Int = 0
        for scalar in name.unicodeScalars { sum &+= Int(scalar.value) }
        return Double(sum % 360) / 360.0
    }

}

// MARK: - Message bubble

struct PersonaMessageBubble: View {
    let message: PersonaMessage
    let personaProfile: PersonaProfile
    @Environment(\.colorScheme) private var colorScheme
    private var style: PersonaAvatarStyle { PersonaAvatarStyle(profile: personaProfile) }

    var body: some View {
        if message.role == .narrator {
            HStack {
                Spacer(minLength: 34)
                bubble(alignment: .center)
                Spacer(minLength: 34)
            }
        } else {
            HStack(alignment: .bottom, spacing: 8) {
                if message.role == .assistant {
                    VStack(alignment: .leading, spacing: 4) {
                        // アイコンの横にキャラクター名を置く。
                        HStack(spacing: 6) {
                            avatar
                            Text(personaProfile.name)
                                .font(.system(size: 11.5, weight: .bold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        bubble(alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 40)
                    bubble(alignment: .trailing)
                }
            }
        }
    }

    private var avatar: some View {
        PersonaAvatarView(profile: personaProfile, size: 34)
    }

    private func bubble(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            if message.role == .narrator {
                Label(message.text, systemImage: "sparkles")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(bubbleBackground)
                    .textSelection(.enabled)
            } else if message.text.isEmpty {
                // ストリーム前の空メッセージ
                Text(KizunaCopy.text(japanese: "…", english: "…"))
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleBackground)
            } else {
                Text(message.text)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(message.role == .user ? .white : .primary)
                    .frame(maxWidth: message.role == .assistant ? .infinity : nil, alignment: .leading)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(bubbleBackground)
                    .textSelection(.enabled)
            }
            Text(timestamp)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .padding(message.role == .user ? .trailing : .leading, 4)
        }
        .contextMenu {
            if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    copyMessageText()
                } label: {
                    Label(KizunaCopy.text(japanese: "本文をコピー", english: "Copy text"), systemImage: "doc.on.doc")
                }
            }
        }
    }

    private func copyMessageText() {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = message.text
        #endif
    }

    private var bubbleBackground: some View {
        Group {
            if message.role == .narrator {
                Capsule()
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.055))
                    .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
            } else if message.role == .user {
                // ユーザーバブル: ダークは少し落とした緑、ライトは LINE 緑風。
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(colorScheme == .dark
                          ? Color(red: 0.30, green: 0.60, blue: 0.32)
                          : Color(red: 0.42, green: 0.78, blue: 0.40))
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(colorScheme == .dark
                          ? style.primary.opacity(0.16)
                          : style.highlight.opacity(0.26))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(style.primary.opacity(colorScheme == .dark ? 0.22 : 0.18), lineWidth: 1)
                    )
                    .shadow(color: style.shadow.opacity(colorScheme == .dark ? 0.0 : 0.08), radius: 5, y: 2)
            }
        }
    }

    private var timestamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: message.createdAt)
    }
}

// MARK: - Composer

struct PersonaComposer: View {
    let thread: PersonaThread
    @StateObject private var service = PersonaChatService.shared
    @State private var text: String = ""
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var isGeneratingThisThread: Bool {
        service.activeGenerationThreadID == thread.id && service.phase == .thinking
    }

    private var isGeneratingAnotherThread: Bool {
        guard let activeThreadID = service.activeGenerationThreadID,
              service.phase == .thinking else { return false }
        return activeThreadID != thread.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isGeneratingAnotherThread {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text(KizunaCopy.text(
                        japanese: "別のスレッドで生成中です。完了するまで送信できません。",
                        english: "Another thread is generating. You can send after it finishes."
                    ))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .accessibilityElement(children: .combine)
            }

            HStack(alignment: .bottom, spacing: 8) {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.18))
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 34, height: 34)
                .help(KizunaCopy.appName)

                TextField(KizunaCopy.text(japanese: "メッセージを送る…", english: "Message…"), text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .lineLimit(1...4)
                    .submitLabel(.send)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(colorScheme == .dark
                                  ? Color(red: 0.20, green: 0.20, blue: 0.24)
                                  : Color.white)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                    .onSubmit(submit)

                Button {
                    if isGeneratingThisThread {
                        service.cancel()
                    } else {
                        submit()
                    }
                } label: {
                    Image(systemName: isGeneratingThisThread ? "stop.fill" : "paperplane.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 38, height: 38)
                        .background(
                            Circle().fill(isGeneratingThisThread || canSubmit ? Color.accentColor : Color.secondary.opacity(0.25))
                        )
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(!isGeneratingThisThread && !canSubmit)
                .help(isGeneratingAnotherThread
                      ? KizunaCopy.text(japanese: "別のスレッドで生成中です", english: "Another thread is generating")
                      : "")
                .accessibilityLabel(isGeneratingThisThread
                                    ? KizunaCopy.text(japanese: "生成を停止", english: "Stop generating")
                                    : KizunaCopy.text(japanese: "送信", english: "Send"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.thinMaterial)
        .personaKeyboardDismissToolbar($focused)
    }

    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isGeneratingAnotherThread
    }

    private func submit() {
        guard canSubmit else { return }
        let toSend = text
        text = ""
        focused = false
        service.send(toSend, to: thread)
    }
}

private extension View {
    @ViewBuilder
    func personaKeyboardDismissToolbar(_ focused: FocusState<Bool>.Binding) -> some View {
        #if canImport(UIKit)
        self.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(KizunaCopy.text(japanese: "閉じる", english: "Done")) { focused.wrappedValue = false }
            }
        }
        #else
        self
        #endif
    }
}
