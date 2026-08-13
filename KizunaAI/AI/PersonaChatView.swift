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
    private let initialThreadID: UUID?
    private let showsStoryActions: Bool
    @StateObject private var store = PersonaChatStore.shared
    @StateObject private var service = PersonaChatService.shared
    @StateObject private var settings = PersonaSettings.shared
    @State private var showConfig = false
    @State private var showLibrary = false
    @State private var showWorldLibrary = false
    @State private var activeStoryWorld: StoryWorld?
    @State private var activeStorySessionID: UUID?
    @State private var activeStoryStartsNewSession = false
    @State private var compactShowsChat = false
    @State private var storyHistoryItems: [StoryHistoryItem] = []
    @State private var storyHistoryLoadError: String?
    @State private var personaRecoveryExportURL: URL?
    @State private var personaRecoveryErrorMessage: String?
    @State private var isShowingPersonaRecoveryResetConfirmation = false
    /// SwiftUIが履歴ロードの世代を管理する。シートの再表示や画面破棄時に
    /// 未完了のロードを置き去りにせず、古い結果を次の一覧へ適用しない。
    @State private var storyHistoryReloadID = UUID()
    @State private var isPersonaChatNearBottom = true
    @State private var unreadPersonaMessageCount = 0
    @State private var pendingThreadDeletion: PersonaThread?
    @State private var pendingThreadRename: PersonaThread?
    @State private var threadRenameText = ""
    /// スレッドを切り替えても入力途中の本文が別スレッドへ移らないよう、
    /// 下書きをスレッドIDごとに保持する。会話本文とは別の一時UI状態であり、
    /// 永続化は行わない。
    @State private var personaDrafts: [UUID: String] = [:]
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.dismiss) private var dismiss

    private let storyWorldRepo: StoryWorldRepository = LocalJSONStoryWorldRepository()
    private let storySessionRepo: StorySessionRepository = LocalJSONStorySessionRepository()

    init(initialThreadID: UUID? = nil, showsStoryActions: Bool = true) {
        self.initialThreadID = initialThreadID
        self.showsStoryActions = showsStoryActions
        _store = StateObject(wrappedValue: PersonaChatStore.shared)
        _service = StateObject(wrappedValue: PersonaChatService.shared)
        _settings = StateObject(wrappedValue: PersonaSettings.shared)
    }

    var body: some View {
        VStack(spacing: 0) {
            topSwitchBar
            Divider()
            if store.isPersistenceRecoveryRequired {
                personaRecoveryBanner
                Divider()
            }
            if horizontalSizeClass == .compact {
                if compactShowsChat, store.activeThread != nil {
                    compactChat
                } else if showsStoryActions {
                    compactStoryList
                } else {
                    compactConversationList
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
                    // A library card resumes the latest non-empty thread for
                    // this character before falling back to a draft/new thread.
                    // This keeps the relationship continuous across entry points.
                    if let existing = store.threads.first(where: {
                        $0.characterID == character.id && !$0.messages.isEmpty
                    }) {
                        store.selectThread(id: existing.id)
                        if horizontalSizeClass == .compact {
                            compactShowsChat = true
                        }
                        showLibrary = false
                        return
                    }

                    // CharacterProfile を Persona 用の簡易プロファイルに変換する。
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
                        if store.isPersistenceRecoveryRequired {
                            // Character Library is presented as a sheet. Close it
                            // before showing the recovery confirmation so the
                            // existing banner/export path remains reachable
                            // instead of failing silently behind the sheet.
                            showLibrary = false
                            isShowingPersonaRecoveryResetConfirmation = true
                        }
                        return
                    }
                    // 初回メッセージがあればアシスタント発として入れておく。
                    if thread.messages.isEmpty, !character.firstMessage.isEmpty {
                        store.appendMessage(
                            PersonaMessage(role: .assistant, text: character.firstMessage),
                            toThread: thread.id
                        )
                    }
                    if horizontalSizeClass == .compact {
                        compactShowsChat = true
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
                    activeStoryStartsNewSession = false
                    activeStoryWorld = world
                    showWorldLibrary = false
                },
                onResumeSession: { world, sessionID in
                    activeStorySessionID = sessionID
                    activeStoryStartsNewSession = false
                    activeStoryWorld = world
                    showWorldLibrary = false
                },
                onStartNewSession: { world in
                    activeStorySessionID = nil
                    activeStoryStartsNewSession = true
                    activeStoryWorld = world
                    showWorldLibrary = false
                }
            )
            .viukAdaptiveSheetSizing(minWidth: 820, minHeight: 720)
        }
        .sheet(item: $activeStoryWorld, onDismiss: {
            activeStorySessionID = nil
            activeStoryStartsNewSession = false
            storyHistoryReloadID = UUID()
        }) { world in
            StorySessionChatView(
                world: world,
                initialSessionID: activeStorySessionID,
                startsNewSession: activeStoryStartsNewSession
            )
                .viukAdaptiveSheetSizing(minWidth: 760, minHeight: 720)
        }
        .confirmationDialog(
            KizunaCopy.text(japanese: "この会話を削除しますか？", english: "Delete this conversation?"),
            isPresented: Binding(
                get: { pendingThreadDeletion != nil },
                set: { if !$0 { pendingThreadDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(KizunaCopy.text(japanese: "削除", english: "Delete"), role: .destructive) {
                if let thread = pendingThreadDeletion {
                    store.deleteThread(id: thread.id)
                }
                pendingThreadDeletion = nil
            }
            Button(KizunaCopy.text(japanese: "キャンセル", english: "Cancel"), role: .cancel) {
                pendingThreadDeletion = nil
            }
        } message: {
            Text(KizunaCopy.text(
                japanese: "会話本文もこの端末から削除されます。",
                english: "The conversation text will also be deleted from this device."
            ))
        }
        .alert(
            KizunaCopy.text(japanese: "会話名を変更", english: "Rename conversation"),
            isPresented: Binding(
                get: { pendingThreadRename != nil },
                set: { if !$0 { pendingThreadRename = nil } }
            )
        ) {
            TextField(
                KizunaCopy.text(japanese: "会話名", english: "Conversation name"),
                text: $threadRenameText
            )
            Button(KizunaCopy.text(japanese: "保存", english: "Save")) {
                let title = threadRenameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let thread = pendingThreadRename, !title.isEmpty {
                    store.renameThread(id: thread.id, title: title)
                }
                pendingThreadRename = nil
            }
            Button(KizunaCopy.text(japanese: "キャンセル", english: "Cancel"), role: .cancel) {
                pendingThreadRename = nil
            }
        }
        .task(id: storyHistoryReloadID) {
            if showsStoryActions {
                await loadStoryHistory()
            }
        }
        .task(id: initialThreadID) {
            guard let initialThreadID else { return }
            store.selectThread(id: initialThreadID)
            if horizontalSizeClass == .compact {
                compactShowsChat = true
            }
        }
        .onChange(of: store.activeThreadID) { _, _ in
            isPersonaChatNearBottom = true
            unreadPersonaMessageCount = 0
        }
        .confirmationDialog(
            KizunaCopy.text(
                japanese: "壊れたPersona履歴をリセットしますか？",
                english: "Reset the corrupted Persona history?"
            ),
            isPresented: $isShowingPersonaRecoveryResetConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                KizunaCopy.text(japanese: "履歴をリセット", english: "Reset history"),
                role: .destructive
            ) {
                resetPersonaRecoveryState()
            }
            Button(KizunaCopy.text(japanese: "キャンセル", english: "Cancel"), role: .cancel) {}
        } message: {
            Text(
                KizunaCopy.text(
                    japanese: "先にバックアップを書き出してください。リセットすると、読み込めなかったPersona履歴は新しい空状態に置き換わります。",
                    english: "Export a backup first. Resetting replaces the unreadable Persona history with a new empty state."
                )
            )
        }
        .alert(
            KizunaCopy.text(japanese: "バックアップを書き出せませんでした", english: "Could not export the backup"),
            isPresented: Binding(
                get: { personaRecoveryErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        personaRecoveryErrorMessage = nil
                    }
                }
            )
        ) {
            Button(KizunaCopy.text(japanese: "閉じる", english: "Close"), role: .cancel) {}
        } message: {
            Text(personaRecoveryErrorMessage ?? "")
        }
    }

    private var personaRecoveryBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(
                    KizunaCopy.text(
                        japanese: "Persona履歴を読み込めません",
                        english: "Persona history could not be loaded"
                    )
                )
                .font(.subheadline.weight(.semibold))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            Text(
                KizunaCopy.text(
                    japanese: "元の保存データは保持されています。変更は一時停止中です。バックアップを書き出すか、内容を確認してからリセットしてください。",
                    english: "The original saved data is preserved and changes are paused. Export a backup or review it before resetting."
                )
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            // Keep recovery actions vertically stacked so Japanese labels and
            // larger Dynamic Type sizes never squeeze three controls into a
            // single compact-width row.
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    exportPersonaRecoveryData()
                } label: {
                    Label(
                        KizunaCopy.text(japanese: "バックアップを書き出す", english: "Export backup"),
                        systemImage: "arrow.down.doc"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                if let personaRecoveryExportURL {
                    ShareLink(item: personaRecoveryExportURL) {
                        Label(
                            KizunaCopy.text(japanese: "共有／保存", english: "Share / Save"),
                            systemImage: "square.and.arrow.up"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }

                Button(
                    KizunaCopy.text(japanese: "リセット…", english: "Reset…"),
                    role: .destructive
                ) {
                    isShowingPersonaRecoveryResetConfirmation = true
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 44, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.10))
        .accessibilityElement(children: .contain)
    }

    private func exportPersonaRecoveryData() {
        do {
            personaRecoveryExportURL = try store.exportCorruptPersistedThreads()
            personaRecoveryErrorMessage = nil
        } catch {
            personaRecoveryErrorMessage = error.localizedDescription
        }
    }

    private func resetPersonaRecoveryState() {
        guard store.discardCorruptPersistedThreads() else {
            personaRecoveryErrorMessage = KizunaCopy.text(
                japanese: "復旧状態を変更できませんでした。画面を再度開いて確認してください。",
                english: "The recovery state could not be changed. Reopen this screen and try again."
            )
            return
        }
        personaRecoveryExportURL = nil
        personaRecoveryErrorMessage = nil
    }

    private var compactChat: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    compactShowsChat = false
                } label: {
                    Label(KizunaCopy.text(japanese: "一覧", english: "List"), systemImage: "chevron.left")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                Spacer()
                Text(showsStoryActions
                     ? KizunaCopy.text(japanese: "あなたの物語", english: "Your story")
                     : KizunaCopy.text(japanese: "会話", english: "Conversations"))
                    .font(.headline.weight(.bold))
                Spacer()
                if !showsStoryActions {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(KizunaCopy.text(japanese: "閉じる", english: "Close"))
                } else {
                    Color.clear.frame(width: 44, height: 44)
                }
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
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)
                Text(KizunaCopy.text(japanese: "会話を続ける", english: "Continue a conversation"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if showsStoryActions {
                Button {
                    showWorldLibrary = true
                } label: {
                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.accentColor.opacity(0.16)))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(KizunaCopy.text(japanese: "kizunaライブラリー", english: "kizuna library"))
            }

            Menu {
                if showsStoryActions {
                    Button {
                        showWorldLibrary = true
                    } label: {
                        Label(KizunaCopy.text(japanese: "シナリオを探す", english: "Browse scenarios"), systemImage: "sparkles.rectangle.stack.fill")
                    }
                }
                Button {
                    showLibrary = true
                } label: {
                    Label(KizunaCopy.text(japanese: "キャラライブラリー", english: "Character library"), systemImage: "person.2.fill")
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
                    .frame(width: 44, height: 44)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel(KizunaCopy.text(japanese: "kizunaメニュー", english: "kizuna menu"))

            if !showsStoryActions {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(KizunaCopy.text(japanese: "閉じる", english: "Close"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    private var compactConversationList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(KizunaCopy.text(japanese: "会話", english: "Conversations"))
                    .font(.headline)
                Spacer()
                Text(KizunaCopy.text(japanese: "タップして再開", english: "Tap to resume"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()

            if store.threads.isEmpty {
                noActiveThreadState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(store.threads) { thread in
                            threadRow(thread)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                }
            }
        }
        .background(Color.appCanvasBackground)
    }

    private var regularTopSwitchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "infinity.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text(KizunaCopy.appName)
                    .font(.subheadline.weight(.bold))
            }
            .foregroundStyle(Color.accentColor)

            Spacer()

            if showsStoryActions {
                Button {
                    showWorldLibrary = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles.rectangle.stack.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text(KizunaCopy.text(japanese: "シナリオライブラリー", english: "Scenario library"))
                            .font(.callout.weight(.semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(minHeight: 44)
                    .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help(KizunaCopy.text(japanese: "関係性を続けられるシナリオを開く", english: "Open scenarios that continue your relationship"))
            }

            Menu {
                if showsStoryActions {
                    Button {
                        showWorldLibrary = true
                    } label: {
                        Label(KizunaCopy.text(japanese: "シナリオを探す", english: "Browse scenarios"), systemImage: "sparkles.rectangle.stack.fill")
                    }
                }
                Button {
                    showLibrary = true
                } label: {
                    Label(KizunaCopy.text(japanese: "キャラライブラリー", english: "Character library"), systemImage: "person.2.fill")
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
                    .frame(width: 44, height: 44)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel(KizunaCopy.text(japanese: "キャラクター操作メニュー", english: "Character actions menu"))
            .help(KizunaCopy.text(japanese: "キャラクターなどの補助メニュー", english: "More character options"))

            if !showsStoryActions {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(KizunaCopy.text(japanese: "閉じる", english: "Close"))
            }

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
                    .font(.caption.weight(.bold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
                if showsStoryActions {
                    Button {
                        showWorldLibrary = true
                    } label: {
                        Image(systemName: "books.vertical.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(KizunaCopy.text(japanese: "シナリオライブラリーを開く", english: "Open scenario library"))
                    .help(KizunaCopy.text(japanese: "kizunaライブラリーを開く", english: "Open the kizuna library"))
                }
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
            if showsStoryActions {
                Button {
                    showWorldLibrary = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles.rectangle.stack.fill")
                            .font(.system(size: 12, weight: .semibold))
                        Text(KizunaCopy.text(japanese: "シナリオを探す", english: "Browse scenarios"))
                            .font(.callout.weight(.semibold))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.appSecondaryBackground.opacity(0.22))
    }

    private var compactStoryList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(KizunaCopy.text(japanese: "続きのある物語", english: "Stories in progress"))
                    .font(.subheadline.weight(.bold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showWorldLibrary = true
                } label: {
                    Label(KizunaCopy.text(japanese: "探す", english: "Browse"), systemImage: "sparkles.rectangle.stack.fill")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(minHeight: 44)
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
        if showsStoryActions, !storyHistoryItems.isEmpty {
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
            .font(.caption.weight(.bold))
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
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(item.previewText)
                        .font(.caption)
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
                .font(.body)
                .foregroundStyle(.secondary)
            if showsStoryActions {
                Button {
                    showWorldLibrary = true
                } label: {
                    Text(KizunaCopy.text(japanese: "シナリオを選ぶ", english: "Choose a scenario"))
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(minWidth: 44, minHeight: 44)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
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
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                Text(thread.messages.last?.text ?? KizunaCopy.text(japanese: "新しい会話", english: "New conversation"))
                        .font(.caption)
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
            Button {
                threadRenameText = thread.title
                pendingThreadRename = thread
            } label: {
                Label(KizunaCopy.text(japanese: "名前を変更", english: "Rename"), systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                pendingThreadDeletion = thread
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
            // World側の重複や、複数の読み込み経路が同じセッションを返しても
            // 画面には1セッションだけ残す。失敗したWorldの既存表示を後から
            // 戻す経路も、この集合を共有して同じ規則で判定する。
            var seenSessionIDs = Set<UUID>()
            var failedWorldIDs = Set<UUID>()
            var successfulWorldIDs = Set<UUID>()
            for world in worlds {
                do {
                    let sessions = try await storySessionRepo.fetchSessions(storyWorldId: world.id)
                    successfulWorldIDs.insert(world.id)
                    failedWorldIDs.remove(world.id)
                    for session in sessions where seenSessionIDs.insert(session.id).inserted {
                        items.append(StoryHistoryItem(world: world, session: session))
                    }
                } catch {
                    // 1つの壊れたWorldで、正常に読めた他Worldの履歴まで消さない。
                    failedWorldIDs.insert(world.id)
                    NSLog("[PersonaChatView] story history session load failed for %@: %@", world.id.uuidString, error.localizedDescription)
                }
            }
            // 失敗したWorldについては、画面に表示済みだった履歴を残す。
            // 同じセッションを重複表示しないようIDで抑止する。
            for item in storyHistoryItems
                where failedWorldIDs.contains(item.world.id)
                && !successfulWorldIDs.contains(item.world.id)
                && seenSessionIDs.insert(item.session.id).inserted {
                items.append(item)
            }
            storyHistoryItems = items.sorted { $0.session.updatedAt > $1.session.updatedAt }
            storyHistoryLoadError = failedWorldIDs.isEmpty
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
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 6)
            Button {
                storyHistoryReloadID = UUID()
            } label: {
                Label(KizunaCopy.text(japanese: "再試行", english: "Retry"), systemImage: "arrow.clockwise")
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(minHeight: 44)
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
                // Composerの入力状態はスレッド単位。Viewを再利用すると
                // Stateに残った下書きが別スレッドの送信欄へ移るため、
                // Bindingもthread.id単位に分け、identityも切替時に更新する。
                PersonaComposer(thread: active, draft: draftBinding(for: active.id))
                    .id(active.id)
            }
            .background(personaChatBackground)
        } else {
            noActiveThreadState
        }
    }

    private func draftBinding(for threadID: UUID) -> Binding<String> {
        Binding(
            get: { personaDrafts[threadID] ?? "" },
            set: { value in
                if value.isEmpty {
                    personaDrafts.removeValue(forKey: threadID)
                } else {
                    personaDrafts[threadID] = value
                }
            }
        )
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
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)
                    Text(thread.personaSnapshot.relation.localizedDisplayName)
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(style.primary.opacity(0.16)))
                        .foregroundStyle(style.primary)
                }
                Text(thread.personaSnapshot.tone.localizedDisplayName + KizunaCopy.text(japanese: " ・ ", english: " · ") + thread.personaSnapshot.personality)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Menu {
                if showsStoryActions {
                    Button {
                        showWorldLibrary = true
                    } label: {
                        Label(KizunaCopy.text(japanese: "シナリオライブラリー", english: "Scenario library"), systemImage: "sparkles.rectangle.stack.fill")
                    }
                }
                Button {
                    showConfig = true
                } label: {
                    Label(KizunaCopy.text(japanese: "新しい会話の設定", english: "New conversation settings"), systemImage: "slider.horizontal.3")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel(KizunaCopy.text(japanese: "会話メニュー", english: "Conversation menu"))
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
            Image(systemName: showsStoryActions ? "sparkles.rectangle.stack.fill" : "bubble.left.and.bubble.right.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(KizunaCopy.text(japanese: "始めましょう", english: "Let’s begin"))
                .font(.title3.weight(.semibold))

            if showsStoryActions {
                Button {
                    showWorldLibrary = true
                } label: {
                    Text(KizunaCopy.text(japanese: "物語を見つける", english: "Find a story"))
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .frame(minHeight: 44)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(personaChatBackground)
    }

    private func messageList(for thread: PersonaThread) -> some View {
        // ストリーミングプレビューはサービスが一時表示し、完成後にだけ
        // 保存済み本文を通常のメッセージとして表示する。旧バージョンの
        // 空assistant枠も本文がないため、同じ条件で表示しない。
        // `phase` はサービス全体の状態だが、表示対象は thread ID と組み合わせる。
        // IDだけが一瞬残る遷移でも、別スレッドへプレビューを漏らさない。
        let isGeneratingThisThread = service.activeGenerationThreadID == thread.id
            && service.phase == .thinking
        let isErrorThisThread = service.lastErrorThreadID == thread.id
            && isGenerationError
        let visibleMessages = thread.messages.filter { msg in
            return !(msg.role == .assistant && PersonaMessage.isPendingAssistantText(msg.text))
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
                        withAnimation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.2)) {
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
                        withAnimation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.2)) {
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
                        .font(.body.weight(.bold))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .frame(minHeight: 44)
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
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(KizunaCopy.text(japanese: "生成中…", english: "Writing…"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tertiary)
                }
                if preview.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(preview)
                        .font(.body)
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
        .accessibilityValue(Text(preview))
    }

    private func generationError(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(KizunaCopy.text(japanese: "応答を生成できませんでした", english: "Could not generate a reply"))
                    .font(.headline.weight(.bold))
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(KizunaCopy.text(
                    japanese: "入力欄からもう一度送信できます。",
                    english: "You can send the message again from the composer."
                ))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                HStack(spacing: 8) {
                    Button(KizunaCopy.text(japanese: "同じ内容を再送信", english: "Try again")) {
                        service.retryLastMessage()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .frame(minHeight: 44)
                    Button(KizunaCopy.text(japanese: "閉じる", english: "Dismiss")) {
                        service.dismissError()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(minHeight: 44)
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

struct PersonaAvatarView: View {
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
        Group {
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
                                    .font(.subheadline.weight(.bold))
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(Text(message.createdAt, style: .time))
    }

    private var accessibilityLabel: String {
        let speaker: String
        if message.role == .assistant {
            speaker = personaProfile.name
        } else if message.role == .narrator {
            speaker = KizunaCopy.text(japanese: "ナレーション", english: "Narration")
        } else {
            speaker = KizunaCopy.text(japanese: "あなた", english: "You")
        }
        let body = message.text.isEmpty
            ? KizunaCopy.text(japanese: "待機中", english: "Waiting")
            : message.text
        return "\(speaker): \(body)"
    }

    private var avatar: some View {
        PersonaAvatarView(profile: personaProfile, size: 34)
    }

    private func bubble(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            if message.role == .narrator {
                Label(message.text, systemImage: "sparkles")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(bubbleBackground)
                    .textSelection(.enabled)
            } else if message.text.isEmpty {
                // ストリーム前の空メッセージ
                Text(KizunaCopy.text(japanese: "…", english: "…"))
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleBackground)
            } else {
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(message.role == .user ? .white : .primary)
                    .frame(maxWidth: message.role == .assistant ? .infinity : nil, alignment: .leading)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(bubbleBackground)
                    .textSelection(.enabled)
            }
            Text(timestamp)
                .font(.caption2)
                // Timestamps are visible content, not decorative metadata.
                // Use the semantic secondary color so they remain readable
                // against both message bubble backgrounds in light/dark mode.
                .foregroundStyle(.secondary)
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
                          ? Color(red: 0.18, green: 0.48, blue: 0.22)
                          : Color(red: 0.15, green: 0.46, blue: 0.20))
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
    @ObservedObject private var store = PersonaChatStore.shared
    @StateObject private var service = PersonaChatService.shared
    @Binding private var text: String
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var colorScheme

    init(thread: PersonaThread, draft: Binding<String>) {
        self.thread = thread
        _text = draft
    }

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
                        .font(.body.weight(.medium))
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
                        .frame(width: 44, height: 44)
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
            && !store.isPersistenceRecoveryRequired
            && !isGeneratingAnotherThread
    }

    private func submit() {
        guard canSubmit else { return }
        let toSend = text
        guard service.send(toSend, to: thread) else { return }
        text = ""
        focused = false
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
