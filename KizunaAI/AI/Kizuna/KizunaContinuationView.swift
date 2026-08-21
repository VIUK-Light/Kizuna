/*
仕様:
- 役割: Persona / Story の継続ルートを1つの一覧で表示する。
- 制約: カード選択後のチャット画面は仕様差を維持し、PersonaChatView / StorySessionChatView
  へ別々に遷移する。
- 編集ポイント: 継続カードの情報設計、モード表示、遷移先を変えるときに触る。
*/

import SwiftUI

struct KizunaContinuationView: View {
    @ObservedObject private var personaStore = PersonaChatStore.shared
    @StateObject private var viewModel = KizunaContinuationViewModel()
    @State private var selectedFilter: ContinuationFilter = .all
    @State private var selectedRoute: KizunaConversationRoute?

    private enum ContinuationFilter: String, CaseIterable, Identifiable {
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

    private var items: [KizunaContinuationItem] {
        let personaItems = personaStore.threads.map(viewModel.personaItem(for:))
        let combined = personaItems + viewModel.storyItems
        return combined
            .filter { item in
                switch selectedFilter {
                case .all: return true
                case .persona: return item.kind == .persona
                case .story: return item.kind == .story
                }
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()

            if let loadError = viewModel.loadError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(loadError)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.orange.opacity(0.10))
            }

            if viewModel.loadError != nil && items.isEmpty {
                loadErrorState
            } else if items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(items) { item in
                            KizunaContinuationCard(
                                item: item,
                                character: item.storyWorld.flatMap { world in
                                    world.mainCharacterId.flatMap { viewModel.currentCharacters[$0] }
                                },
                                onSelect: { selectedRoute = item.route }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                }
            }
        }
        .background(Color.appCanvasBackground.ignoresSafeArea())
        .accessibilityIdentifier("workspace.continuations")
        .task {
            await viewModel.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .characterLibraryDidChange)) { _ in
            reload()
        }
#if os(iOS)
        .fullScreenCover(item: $selectedRoute, onDismiss: reload) { route in
            destination(for: route)
        }
#else
        .sheet(item: $selectedRoute, onDismiss: reload) { route in
            destination(for: route)
                .viukAdaptiveSheetSizing(minWidth: 760, minHeight: 700)
        }
#endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(KizunaCopy.text(japanese: "続きから", english: "Continue"))
                .font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("workspace.continuations.heading")
            Text(KizunaCopy.text(
                japanese: "PersonaとStoryの続きを、ここから選べます。",
                english: "Resume Persona and Story from one place."
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach(ContinuationFilter.allCases) { filter in
                Button {
                    selectedFilter = filter
                } label: {
                    Text(filter.title)
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .frame(minWidth: 44, minHeight: 44)
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
                .contentShape(Rectangle())
                .accessibilityAddTraits(selectedFilter == filter ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.resume")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(KizunaCopy.text(japanese: "続きはまだありません", english: "Nothing to resume yet"))
                .font(.headline)
            Text(KizunaCopy.text(
                japanese: "ホームからキャラクターかストーリーを選んで始められます。",
                english: "Choose a character or story from Home to get started."
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var loadErrorState: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.orange)
            Text(KizunaCopy.text(
                japanese: "続きの履歴を表示できません。",
                english: "Your continuation history could not be displayed."
            ))
                .font(.headline)
            Text(KizunaCopy.text(
                japanese: "データが存在しないのではなく、読み込みに失敗しています。",
                english: "This may be a loading problem, not an empty history."
            ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(KizunaCopy.text(japanese: "再読み込み", english: "Reload")) {
                reload()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    @ViewBuilder
    private func destination(for route: KizunaConversationRoute) -> some View {
        switch route {
        case .persona(let threadID):
            PersonaChatView(initialThreadID: threadID, showsStoryActions: false)
        case .story(_, let sessionID):
            if let world = viewModel.storyWorld(for: route) {
                StorySessionChatView(
                    world: world,
                    initialSessionID: sessionID,
                    startsNewSession: false
                )
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                        .foregroundStyle(.orange)
                    Text(KizunaCopy.text(
                        japanese: "ストーリーを読み込めませんでした。",
                        english: "The story could not be loaded."
                    ))
                    .font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.appCanvasBackground)
            }
        }
    }

    private func reload() {
        Task { await viewModel.reload() }
    }
}

private struct KizunaContinuationCard: View {
    let item: KizunaContinuationItem
    let character: CharacterProfile?
    let onSelect: () -> Void

    private var kindTitle: String {
        switch item.kind {
        case .persona: return "Persona"
        case .story: return "Story"
        }
    }

    private var kindColor: Color {
        switch item.kind {
        case .persona: return .blue
        case .story: return .purple
        }
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                thumbnail
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(kindTitle)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(kindColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(kindColor.opacity(0.14)))
                        Text(item.updatedAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Text(item.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(item.preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(kindColor.opacity(0.18), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("continuation.\(kindTitle.lowercased()).\(item.id)")
        .accessibilityHint(KizunaCopy.text(japanese: "専用のチャット画面を開きます", english: "Opens the dedicated chat screen"))
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch item.kind {
        case .persona:
            if let profile = item.personaProfile {
                PersonaAvatarView(profile: profile, size: 54)
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
                    .frame(width: 54, height: 54)
            }
        case .story:
            if let world = item.storyWorld {
                StoryCoverView(world: world, character: character)
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 34))
                    .foregroundStyle(.purple)
                    .frame(width: 54, height: 54)
            }
        }
    }
}
