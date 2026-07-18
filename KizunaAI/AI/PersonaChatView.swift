/*
仕様:
- 役割: ペルソナモード時に AI Studio のメインエリアに表示する絆専用チャット UI。
- 主な型: `PersonaChatView`, `PersonaThreadSidebar`, `PersonaMessageBubble`, `PersonaComposer`.
- 編集ポイント: バブル形状、配色、アバター、コンポーザー UI を変えるときに触る。
- 構成: 左サイドバー (ペルソナスレッド一覧) + 右側にチャット (ヘッダー + メッセージ + コンポーザー)。
*/

import SwiftUI

struct PersonaChatView: View {
    @StateObject private var store = PersonaChatStore.shared
    @StateObject private var service = PersonaChatService.shared
    @StateObject private var settings = PersonaSettings.shared
    @State private var showConfig = false
    @State private var showLibrary = false
    @State private var showWorldLibrary = false
    @State private var activeStoryWorld: StoryWorld?
    @State private var activeStorySessionID: UUID?
    @State private var storyHistoryItems: [StoryHistoryItem] = []
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private let storyWorldRepo: StoryWorldRepository = LocalJSONStoryWorldRepository()
    private let storySessionRepo: StorySessionRepository = LocalJSONStorySessionRepository()

    var body: some View {
        VStack(spacing: 0) {
            topSwitchBar
            Divider()
            if horizontalSizeClass == .compact {
                compactStoryList
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
                Text("絆")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.primary)
                Text("続きから会話")
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
            .accessibilityLabel("絆ライブラリー")

            Menu {
                Button {
                    showWorldLibrary = true
                } label: {
                    Label("絆シナリオを探す", systemImage: "sparkles.rectangle.stack.fill")
                }
                Divider()
                Button {
                    showConfig = true
                } label: {
                    Label("単体キャラ設定", systemImage: "slider.horizontal.3")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel("絆メニュー")
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
                Text("VIUK 絆")
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
                    Text("絆ライブラリー")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("関係性を継続できる絆シナリオを開く")

            Menu {
                Button {
                    showWorldLibrary = true
                } label: {
                    Label("絆シナリオを探す", systemImage: "sparkles.rectangle.stack.fill")
                }
                Divider()
                Button {
                    showConfig = true
                } label: {
                    Label("単体キャラ設定", systemImage: "slider.horizontal.3")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("単体キャラなどの補助メニュー")

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
                Text("絆")
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
                .help("絆ライブラリーを開く")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

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
                    Text("絆を探す")
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
                Text("継続中の絆")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showWorldLibrary = true
                } label: {
                    Label("探す", systemImage: "sparkles.rectangle.stack.fill")
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
            sidebarSectionTitle("継続中の絆")
            ForEach(storyHistoryItems) { item in
                storyHistoryRow(item)
            }
        }
        if !store.threads.isEmpty {
            sidebarSectionTitle("単体チャット")
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
                    Text(item.world.title)
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
            Text("会話はまだありません")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button {
                showWorldLibrary = true
            } label: {
                Text("絆を選ぶ")
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
        } label: {
            HStack(spacing: 11) {
                PersonaAvatarView(profile: thread.personaSnapshot, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(thread.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(thread.messages.last?.text ?? "新しい会話")
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
                Label("削除", systemImage: "trash")
            }
        }
    }

    @MainActor
    private func loadStoryHistory() async {
        let worlds = (try? await storyWorldRepo.fetchWorlds()) ?? []
        var items: [StoryHistoryItem] = []
        for world in worlds {
            let sessions = (try? await storySessionRepo.fetchSessions(storyWorldId: world.id)) ?? []
            items.append(contentsOf: sessions.map { StoryHistoryItem(world: world, session: $0) })
        }
        storyHistoryItems = items.sorted { $0.session.updatedAt > $1.session.updatedAt }
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
                    Text(thread.personaSnapshot.relation.displayName)
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(style.primary.opacity(0.16)))
                        .foregroundStyle(style.primary)
                }
                Text(thread.personaSnapshot.tone.displayName + " ・ " + thread.personaSnapshot.personality)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Menu {
                Button {
                    showWorldLibrary = true
                } label: {
                    Label("絆ライブラリー", systemImage: "sparkles.rectangle.stack.fill")
                }
                Button {
                    showConfig = true
                } label: {
                    Label("この単体キャラを編集", systemImage: "slider.horizontal.3")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("絆シナリオ/単体キャラの操作")
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
            Text("絆を始めましょう")
                .font(.system(size: 16, weight: .semibold))
            Text("相手や場面を保ったまま、会話の続きを始められます。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                showWorldLibrary = true
            } label: {
                Text("絆ライブラリーを開く")
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
        // 空のアシスタント (まだストリーム前) はタイピングインジケーターと二重に出るので、
        // テキストが入るまで描画から除外する。
        let visibleMessages = thread.messages.filter { msg in
            !(msg.role == .assistant && msg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(visibleMessages) { msg in
                        PersonaMessageBubble(
                            message: msg,
                            personaProfile: thread.personaSnapshot
                        )
                        .id(msg.id)
                    }
                    // 生成中で、まだ最新アシスタント本文が空のときだけタイピング表示。
                    if service.phase == .thinking,
                       service.streamingResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        typingIndicator(personaProfile: thread.personaSnapshot)
                            .id("typing")
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onChange(of: thread.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: service.streamingResponse) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private func typingIndicator(personaProfile: PersonaProfile) -> some View {
        HStack(alignment: .bottom, spacing: 6) {
            PersonaAvatarView(profile: personaProfile, size: 34)
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Color.secondary.opacity(0.6))
                        .frame(width: 6, height: 6)
                        .scaleEffect(typingScale(i))
                        .animation(
                            .easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.15),
                            value: service.phase
                        )
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
            Spacer(minLength: 0)
        }
    }

    private func typingScale(_ index: Int) -> CGFloat {
        // 単なる視覚装飾 — 値は repeatForever のキーで切り替わるだけ
        return service.phase == .thinking ? 1.0 : 0.6
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
                avatarMotif(style)
                    .padding(size * 0.19)
                style.cornerGlyph
                    .font(.system(size: size * 0.22, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.78))
                    .offset(x: size * 0.25, y: -size * 0.25)
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

    @ViewBuilder
    private func avatarMotif(_ style: PersonaAvatarStyle) -> some View {
        switch style.motif {
        case .moon:
            Image(systemName: "moon.stars.fill")
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(.white)
        case .sun:
            Image(systemName: "sun.max.fill")
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(.white)
        case .ribbon:
            Image(systemName: "heart.fill")
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(.white)
        case .wave:
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: size * 0.42, weight: .heavy))
                .foregroundStyle(.white)
        case .leaf:
            Image(systemName: "leaf.fill")
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(.white)
        case .book:
            Image(systemName: "book.closed.fill")
                .font(.system(size: size * 0.43, weight: .semibold))
                .foregroundStyle(.white)
        case .spark:
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.46, weight: .heavy))
                .foregroundStyle(.white)
        }
    }
}

private struct PersonaAvatarStyle {
    enum Motif {
        case moon
        case sun
        case ribbon
        case wave
        case leaf
        case book
        case spark
    }

    let primary: Color
    let highlight: Color
    let shadow: Color
    let motif: Motif
    let cornerGlyph: Text
    let assetName: String?

    init(profile: PersonaProfile) {
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "アオイ":
            primary = Color(red: 0.32, green: 0.50, blue: 0.86)
            highlight = Color(red: 0.70, green: 0.90, blue: 1.00)
            shadow = Color(red: 0.09, green: 0.16, blue: 0.34)
            motif = .moon
            cornerGlyph = Text("A")
            assetName = "PersonaAoiAvatar"
        case "ハル":
            primary = Color(red: 1.00, green: 0.58, blue: 0.20)
            highlight = Color(red: 1.00, green: 0.91, blue: 0.38)
            shadow = Color(red: 0.57, green: 0.19, blue: 0.05)
            motif = .sun
            cornerGlyph = Text("H")
            assetName = "PersonaHaruAvatar"
        case "ユイ":
            primary = Color(red: 0.95, green: 0.42, blue: 0.68)
            highlight = Color(red: 1.00, green: 0.78, blue: 0.88)
            shadow = Color(red: 0.46, green: 0.09, blue: 0.26)
            motif = .ribbon
            cornerGlyph = Text("Y")
            assetName = "PersonaYuiAvatar"
        case "カイ":
            primary = Color(red: 0.19, green: 0.25, blue: 0.35)
            highlight = Color(red: 0.53, green: 0.66, blue: 0.82)
            shadow = Color(red: 0.03, green: 0.05, blue: 0.09)
            motif = .wave
            cornerGlyph = Text("K")
            assetName = "PersonaKaiAvatar"
        case "レン":
            primary = Color(red: 0.32, green: 0.58, blue: 0.47)
            highlight = Color(red: 0.74, green: 0.89, blue: 0.66)
            shadow = Color(red: 0.08, green: 0.25, blue: 0.19)
            motif = .leaf
            cornerGlyph = Text("R")
            assetName = "PersonaRenAvatar"
        case "ナカムラ先生":
            primary = Color(red: 0.45, green: 0.39, blue: 0.72)
            highlight = Color(red: 0.88, green: 0.79, blue: 1.00)
            shadow = Color(red: 0.17, green: 0.12, blue: 0.33)
            motif = .book
            cornerGlyph = Text("N")
            assetName = "PersonaNakamuraAvatar"
        case "ツバサ":
            primary = Color(red: 0.16, green: 0.68, blue: 0.76)
            highlight = Color(red: 0.75, green: 1.00, blue: 0.96)
            shadow = Color(red: 0.02, green: 0.28, blue: 0.35)
            motif = .spark
            cornerGlyph = Text("T")
            assetName = "PersonaTsubasaAvatar"
        default:
            let hue = PersonaAvatarStyle.nameHue(name)
            primary = Color(hue: hue, saturation: 0.58, brightness: 0.92)
            highlight = Color(hue: hue, saturation: 0.30, brightness: 1.00)
            shadow = Color(hue: hue, saturation: 0.70, brightness: 0.38)
            motif = PersonaAvatarStyle.motif(for: profile)
            cornerGlyph = Text(name.first.map(String.init) ?? "?")
            assetName = nil
        }
    }

    private static func nameHue(_ name: String) -> Double {
        var sum: Int = 0
        for scalar in name.unicodeScalars { sum &+= Int(scalar.value) }
        return Double(sum % 360) / 360.0
    }

    private static func motif(for profile: PersonaProfile) -> Motif {
        switch profile.tone {
        case .calm: return .moon
        case .cheerful: return .sun
        case .sweet: return .ribbon
        case .cool: return .wave
        case .polite: return profile.relation == .mentor ? .book : .leaf
        case .casual: return .spark
        }
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
                    avatar
                    bubble(alignment: .leading)
                    Spacer(minLength: 40)
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
                Text("…")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleBackground)
            } else {
                Text(message.text)
                    .font(.system(size: 14))
                    .foregroundStyle(message.role == .user ? .white : .primary)
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

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.18))
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 34, height: 34)
            .help("絆AI")

            TextField("メッセージを送る…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .focused($focused)
                .lineLimit(1...4)
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

            Button(action: submit) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .background(
                        Circle().fill(canSubmit ? Color.accentColor : Color.secondary.opacity(0.25))
                    )
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.thinMaterial)
        .personaKeyboardDismissToolbar($focused)
    }

    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && service.phase != .thinking
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
                Button("閉じる") { focused.wrappedValue = false }
            }
        }
        #else
        self
        #endif
    }
}
