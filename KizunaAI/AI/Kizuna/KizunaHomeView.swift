/*
仕様:
- 役割: Persona / Story の開始導線を一覧でまとめるホーム。
- 制約: 遷移先の PersonaChatView と StorySessionChatView は仕様が異なるため統合しない。
- 編集ポイント: 一覧の検索・絞り込み、行の情報量、各ライブラリーへの遷移を変えるときに触る。
*/

import SwiftUI

struct KizunaHomeView: View {
    @StateObject private var personaStore = PersonaChatStore.shared
    @StateObject private var characterLibraryVM = CharacterLibraryViewModel()
    @StateObject private var storyLibraryVM = StoryWorldLibraryViewModel()

    @State private var searchText = ""
    @State private var selectedFilter: HomeFilter = .all
    @State private var showCharacterLibrary = false
    @State private var showStoryLibrary = false
    @State private var pendingPersonaThread: PersonaThread?
    @State private var pendingPersonaRecovery = false
    @State private var presentedThread: PersonaThread?
    @State private var selectedStoryWorld: StoryWorld?
    @State private var editingStoryWorld: StoryWorld?
    @State private var pendingStoryOpen: PendingStoryOpen?
    @State private var activeStoryWorld: StoryWorld?
    @State private var activeStorySessionID: UUID?
    @State private var activeStoryStartsNewSession = false
    @State private var isShowingRecovery = false

    private enum HomeFilter: String, CaseIterable, Identifiable {
        case all
        case persona
        case story

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return KizunaCopy.text(japanese: "すべて", english: "All")
            case .persona: return "Persona"
            case .story: return "Story"
            }
        }
    }

    private enum HomeCatalogItem: Identifiable {
        case persona(CharacterProfile)
        case story(StoryWorld)

        var id: String {
            switch self {
            case .persona(let character): return "persona:\(character.id.uuidString)"
            case .story(let world): return "story:\(world.id.uuidString)"
            }
        }

        var updatedAt: Date {
            switch self {
            case .persona(let character): return character.updatedAt
            case .story(let world): return world.updatedAt
            }
        }

        var kind: KizunaConversationKind {
            switch self {
            case .persona: return .persona
            case .story: return .story
            }
        }
    }

    private struct PendingStoryOpen {
        let world: StoryWorld
        let sessionID: UUID?
        let startsNewSession: Bool
    }

    private var catalogItems: [HomeCatalogItem] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let characters = characterLibraryVM.filtered.filter { character in
            guard !needle.isEmpty else { return true }
            return character.visibleName.lowercased().contains(needle)
                || character.shortDescription.lowercased().contains(needle)
                || character.tags.contains(where: { $0.lowercased().contains(needle) })
        }
        let worlds = storyLibraryVM.filtered.filter { world in
            guard !needle.isEmpty else { return true }
            let displayed = world.localizedForCurrentLanguage
            return displayed.title.lowercased().contains(needle)
                || displayed.shortDescription.lowercased().contains(needle)
                || displayed.tags.contains(where: { $0.lowercased().contains(needle) })
        }
        var items = characters.map(HomeCatalogItem.persona)
            + worlds.map(HomeCatalogItem.story)
        if selectedFilter != .all {
            let kind: KizunaConversationKind = selectedFilter == .persona ? .persona : .story
            items = items.filter { $0.kind == kind }
        }
        return items.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                //managementBar
                //ここはUIとして邪魔なため削除
                filterBar
                searchField

                if characterLibraryVM.isLoading || storyLibraryVM.isBootstrapping {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else if catalogItems.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(catalogItems) { item in
                            catalogRow(item)
                        }
                    }
                }

                //explanation
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: 1_100)
            .frame(maxWidth: .infinity)
        }
        .background(Color.appCanvasBackground.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.home")
        .task {
            await bootstrapCatalog()
        }
        .sheet(isPresented: $showCharacterLibrary, onDismiss: {
            Task { await characterLibraryVM.reload() }
            presentPendingPersona()
        }) {
            CharacterLibraryView(
                showsDismissButton: true,
                startsChatImmediately: true,
                onStartChat: startConversation(with:)
            )
            .viukAdaptiveSheetSizing(minWidth: 720, minHeight: 720)
        }
        .sheet(isPresented: $showStoryLibrary, onDismiss: {
            Task { await storyLibraryVM.reload() }
            presentPendingStory()
        }) {
            StoryWorldLibraryView(
                showsDismissButton: true,
                onStartSession: { world in
                    pendingStoryOpen = PendingStoryOpen(world: world, sessionID: nil, startsNewSession: false)
                    showStoryLibrary = false
                },
                onResumeSession: { world, sessionID in
                    pendingStoryOpen = PendingStoryOpen(world: world, sessionID: sessionID, startsNewSession: false)
                    showStoryLibrary = false
                },
                onStartNewSession: { world in
                    pendingStoryOpen = PendingStoryOpen(world: world, sessionID: nil, startsNewSession: true)
                    showStoryLibrary = false
                }
            )
            .viukAdaptiveSheetSizing(minWidth: 820, minHeight: 720)
        }
        .sheet(item: $selectedStoryWorld, onDismiss: {
            Task { await storyLibraryVM.reload() }
            presentPendingStory()
        }) { world in
            StoryWorldDetailView(
                world: world,
                onStartSession: { selectedStoryWorld = nil; pendingStoryOpen = PendingStoryOpen(world: $0, sessionID: nil, startsNewSession: false) },
                onResumeSession: { selectedStoryWorld = nil; pendingStoryOpen = PendingStoryOpen(world: $0, sessionID: $1, startsNewSession: false) },
                onStartNewSession: { selectedStoryWorld = nil; pendingStoryOpen = PendingStoryOpen(world: $0, sessionID: nil, startsNewSession: true) },
                onEdit: { world in
                    selectedStoryWorld = nil
                    editingStoryWorld = world
                },
                onDelete: {
                    try await storyLibraryVM.delete(id: world.id)
                    selectedStoryWorld = nil
                }
            )
            .viukAdaptiveSheetSizing(minWidth: 620, minHeight: 720)
        }
        .sheet(item: $editingStoryWorld, onDismiss: {
            Task { await storyLibraryVM.reload() }
        }) { world in
            StoryWorldCreateView(
                existing: world,
                onSaved: { _ in
                    Task {
                        await storyLibraryVM.reload()
                        editingStoryWorld = nil
                    }
                }
            )
            .viukAdaptiveSheetSizing(minWidth: 680, minHeight: 720)
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
        VStack(alignment: .leading, spacing: 6) {
            Text(KizunaCopy.appName)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .tracking(1.4)
                .foregroundStyle(.tint)
            Text(KizunaCopy.text(japanese: "ホーム", english: "Home"))
                .font(.largeTitle.weight(.heavy))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("workspace.home.heading")
        }
    }

    private var managementBar: some View {//ここはUIとして重複する可能性があり、削除する、
        HStack(spacing: 8) {
            Button {
                showCharacterLibrary = true
            } label: {
                Label(KizunaCopy.text(japanese: "キャラクター管理", english: "Manage characters"), systemImage: "person.2")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                showStoryLibrary = true
            } label: {
                Label(KizunaCopy.text(japanese: "ストーリー管理", english: "Manage stories"), systemImage: "sparkles.rectangle.stack")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Spacer(minLength: 0)
        }
    }
    
    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach(HomeFilter.allCases) { filter in
                Button {
                    selectedFilter = filter
                } label: {
                    Text(filter.title)
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .frame(minHeight: 34)
                        .background(
                            Capsule().fill(
                                selectedFilter == filter
                                    ? Color.accentColor.opacity(0.18)
                                    : Color.primary.opacity(0.06)
                            )
                        )
                        .foregroundStyle(selectedFilter == filter ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedFilter == filter ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(
                KizunaCopy.text(japanese: "キャラクターや物語を検索", english: "Search characters or stories"),
                text: $searchText
            )
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func catalogRow(_ item: HomeCatalogItem) -> some View {
        switch item {
        case .persona(let character):
            KizunaHomeCatalogRow(
                kind: .persona,
                title: character.visibleName,
                subtitle: character.shortDescription.isEmpty
                    ? KizunaCopy.text(japanese: "キャラクターと会話を始める", english: "Start a character conversation")
                    : character.shortDescription,
                thumbnail: { PersonaAvatarView(profile: PersonaProfile(character: character), size: 56) },
                action: { startConversation(with: character) }
            )
            .accessibilityIdentifier("home.persona.\(character.id.uuidString)")
        case .story(let world):
            KizunaHomeCatalogRow(
                kind: .story,
                title: world.localizedForCurrentLanguage.title,
                subtitle: world.localizedForCurrentLanguage.shortDescription.isEmpty
                    ? KizunaCopy.text(japanese: "この世界で物語を始める", english: "Start a story in this world")
                    : world.localizedForCurrentLanguage.shortDescription,
                thumbnail: {
                    StoryCoverView(world: world, character: storyLibraryVM.coverCharacter(for: world))
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                },
                action: { selectedStoryWorld = world }
            )
            .accessibilityIdentifier("home.story.\(world.id.uuidString)")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(KizunaCopy.text(japanese: "該当する項目がありません", english: "No matching items"))
                .font(.headline)
            Text(KizunaCopy.text(
                japanese: hasActiveHomeFilter
                    ? "検索条件を変えるか、フィルタを解除してください。"
                    : "キャラクターかストーリーを追加すると、ここから始められます。",
                english: hasActiveHomeFilter
                    ? "Change your search or clear the active filter."
                    : "Add a character or story to get started from here."
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            if hasActiveHomeFilter {
                Button {
                    searchText = ""
                    selectedFilter = .all
                } label: {
                    Label(
                        KizunaCopy.text(japanese: "検索条件をクリア", english: "Clear filters"),
                        systemImage: "line.3.horizontal.decrease.circle"
                    )
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("home.empty.clearFilters")
            }

            HStack(spacing: 10) {
                Button {
                    showCharacterLibrary = true
                } label: {
                    Label(
                        KizunaCopy.text(japanese: "キャラクターを追加", english: "Add character"),
                        systemImage: "person.badge.plus"
                    )
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("home.empty.addCharacter")

                Button {
                    showStoryLibrary = true
                } label: {
                    Label(
                        KizunaCopy.text(japanese: "ストーリーを追加", english: "Add story"),
                        systemImage: "sparkles.rectangle.stack"
                    )
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("home.empty.addStory")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 42)
    }

    private var hasActiveHomeFilter: Bool {
        selectedFilter != .all
            || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var explanation: some View {//ここはUIとして邪魔なので廃止
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(KizunaCopy.text(
                japanese: "PersonaとStoryは専用チャット画面が分かれています。ホームでは一覧から選び、選択後はそれぞれの体験へ進みます。",
                english: "Persona and Story open separate dedicated chat screens. Choose from the list here, then continue into the experience you selected."
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func bootstrapCatalog() async {
        await characterLibraryVM.bootstrap()
        await storyLibraryVM.bootstrap()
    }

    @MainActor
    private func startConversation(with character: CharacterProfile) {
        let shouldDismissCharacterLibrary = showCharacterLibrary
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
            if shouldDismissCharacterLibrary {
                showCharacterLibrary = false
            } else {
                presentPendingPersona()
            }
            return
        }

        let persona = PersonaProfile(character: character)
        guard let thread = personaStore.createThread(with: persona, characterID: character.id) else {
            if personaStore.isPersistenceRecoveryRequired {
                if shouldDismissCharacterLibrary {
                    pendingPersonaRecovery = true
                    showCharacterLibrary = false
                } else {
                    isShowingRecovery = true
                }
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
        if shouldDismissCharacterLibrary {
            showCharacterLibrary = false
        } else {
            presentPendingPersona()
        }
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

private struct KizunaHomeCatalogRow<Thumbnail: View>: View {
    let kind: KizunaConversationKind
    let title: String
    let subtitle: String
    @ViewBuilder let thumbnail: () -> Thumbnail
    let action: () -> Void

    private var kindTitle: String {
        switch kind {
        case .persona: return "Persona"
        case .story: return "Story"
        }
    }

    private var accent: Color {
        switch kind {
        case .persona: return .blue
        case .story: return .purple
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                thumbnail()
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(kindTitle)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(accent.opacity(0.14), in: Capsule())
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(accent)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(accent.opacity(0.18), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(kindTitle): \(title)")
        .accessibilityHint(KizunaCopy.text(japanese: "専用画面を開きます", english: "Opens the dedicated screen"))
    }
}
