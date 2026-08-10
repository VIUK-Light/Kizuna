/*
仕様:
- 役割: StoryWorld のライブラリー一覧画面。CharacterLibraryView とは独立。
- 主な型: `StoryWorldLibraryView`.
*/

import SwiftUI

struct StoryWorldLibraryView: View {
    // The library owns its default ViewModel. `View` is a value type and SwiftUI
    // may recreate it whenever the surrounding sheet/workspace changes; using
    // `StateObject` keeps the loaded worlds, search text, and filters alive
    // across those recreations. The injected initializer below still accepts
    // a parent-owned instance, but stores that instance through the same
    // observation wrapper so updates continue to flow into this view.
    @StateObject private var vm: StoryWorldLibraryViewModel
    @Environment(\.dismiss) private var dismiss
    private let showsDismissButton: Bool
    @State private var showCreate = false
    @State private var editing: StoryWorld? = nil
    @State private var selected: StoryWorld? = nil

    /// セッション開始時に呼ぶ。呼び出し側 (PersonaChatView 等) がシート閉じてセッション画面へ。
    var onStartSession: ((StoryWorld) -> Void)?
    /// 履歴行から既存セッションを指定して再開する。
    var onResumeSession: ((StoryWorld, UUID) -> Void)?

    @MainActor
    init(
        viewModel: StoryWorldLibraryViewModel,
        showsDismissButton: Bool = true,
        onStartSession: ((StoryWorld) -> Void)? = nil,
        onResumeSession: ((StoryWorld, UUID) -> Void)? = nil
    ) {
        _vm = StateObject(wrappedValue: viewModel)
        self.showsDismissButton = showsDismissButton
        self.onStartSession = onStartSession
        self.onResumeSession = onResumeSession
    }

    @MainActor
    init(
        showsDismissButton: Bool = true,
        onStartSession: ((StoryWorld) -> Void)? = nil,
        onResumeSession: ((StoryWorld, UUID) -> Void)? = nil
    ) {
        self.init(
            viewModel: StoryWorldLibraryViewModel(),
            showsDismissButton: showsDismissButton,
            onStartSession: onStartSession,
            onResumeSession: onResumeSession
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            if vm.seedError != nil {
                seedErrorBanner
                Divider()
            }
            if vm.loadError != nil {
                loadErrorBanner
                Divider()
            }
            if vm.migrationError != nil {
                migrationErrorBanner
                Divider()
            }
            content
        }
        .background(Color.appCanvasBackground.ignoresSafeArea())
        .task { await vm.bootstrap() }
        .sheet(isPresented: $showCreate) {
            StoryWorldCreateView(onSaved: { _ in
                Task { await vm.reload() }
                showCreate = false
            }, onStartSession: { world in
                onStartSession?(world)
                dismiss()
            })
            .viukAdaptiveSheetSizing(minWidth: 680, minHeight: 720)
        }
        .sheet(item: $editing) { w in
            StoryWorldCreateView(existing: w, onSaved: { _ in
                Task { await vm.reload() }
                editing = nil
            })
            .viukAdaptiveSheetSizing(minWidth: 680, minHeight: 720)
        }
        .sheet(item: $selected) { w in
            StoryWorldDetailView(
                world: w,
                onStartSession: { world in
                    selected = nil
                    onStartSession?(world)
                    dismiss()
                },
                onResumeSession: { world, sessionID in
                    selected = nil
                    onResumeSession?(world, sessionID)
                    dismiss()
                },
                onEdit: { world in
                    selected = nil
                    editing = world
                },
                onDelete: {
                    try await vm.delete(id: w.id)
                    selected = nil
                }
            )
            .viukAdaptiveSheetSizing(minWidth: 600, minHeight: 720)
        }
    }

    private var header: some View {
        HStack {
            if showsDismissButton {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down").frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(KizunaCopy.text(japanese: "ストーリーライブラリー", english: "Story library"))
                    .font(.system(size: 15, weight: .semibold))
                Text(vm.isBootstrapping && vm.worlds.isEmpty
                     ? KizunaCopy.text(japanese: "初期ストーリーを準備中…", english: "Preparing stories…")
                     : KizunaCopy.language == .english
                        ? "Choose a world · \(vm.worlds.count)"
                        : "世界観から選ぶ ・ \(vm.worlds.count) 件")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showCreate = true
            } label: {
                Label(KizunaCopy.text(japanese: "ストーリーを作る", english: "Create a story"), systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(KizunaCopy.text(japanese: "ストーリー・世界観・タグ検索", english: "Search stories, worlds, or tags"), text: $vm.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))

            Menu {
                Button(KizunaCopy.text(japanese: "すべて", english: "All")) { vm.groupFilter = nil }
                Divider()
                ForEach(CategoryGroup.allCases) { g in
                    Button { vm.groupFilter = g } label: {
                        Label(g.localizedDisplayName, systemImage: g.iconName)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 10))
                        Text(vm.groupFilter?.localizedDisplayName ?? KizunaCopy.text(japanese: "グループ", english: "Group"))
                        .font(.system(size: 11, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var seedErrorBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(KizunaCopy.text(japanese: "一部の初期ストーリーを読み込めませんでした", english: "Some starter stories could not be loaded"))
                    .font(.system(size: 11, weight: .semibold))
                if let error = vm.seedError {
                    Text(LocalizedStringKey(error.messageKey))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Button(KizunaCopy.text(japanese: "再試行", english: "Retry")) {
                Task { await vm.retryBootstrap() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }

    private var loadErrorBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .foregroundStyle(.orange)
            Text(KizunaCopy.text(
                japanese: "最新のストーリー一覧を読み込めませんでした。表示中の一覧は削除されていません。",
                english: "The latest story list could not be loaded. The displayed list was not deleted."
            ))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(KizunaCopy.text(japanese: "再試行", english: "Retry")) {
                Task { await vm.retryBootstrap() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(vm.isBootstrapping)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }

    private var migrationErrorBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .foregroundStyle(.orange)
            Text(vm.migrationError ?? KizunaCopy.text(
                japanese: "保存データの整理を完了できませんでした。",
                english: "Saved-data cleanup could not be completed."
            ))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(KizunaCopy.text(japanese: "再試行", english: "Retry")) {
                Task { await vm.retryBootstrap() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(vm.isBootstrapping)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }

    @ViewBuilder
    private var content: some View {
        if vm.isBootstrapping && vm.worlds.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                Text(KizunaCopy.text(japanese: "ストーリーを準備しています…", english: "Preparing stories…"))
                    .font(.system(size: 14, weight: .semibold))
                Text(KizunaCopy.text(
                    japanese: "初回だけ少し時間がかかります。画面を閉じずにお待ちください。",
                    english: "This may take a little longer the first time. You can keep this screen open."
                ))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        } else if vm.worlds.isEmpty, vm.loadError != nil || vm.seedError != nil {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 34))
                    .foregroundStyle(.orange)
                Text(KizunaCopy.text(japanese: "ストーリーを読み込めませんでした", english: "Stories could not be loaded"))
                    .font(.system(size: 14, weight: .semibold))
                if let loadError = vm.loadError {
                    Text(LocalizedStringKey(loadError.messageKey))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else if let seedError = vm.seedError {
                    Text(LocalizedStringKey(seedError.messageKey))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button(KizunaCopy.text(japanese: "もう一度読み込む", english: "Load again")) {
                    Task { await vm.retryBootstrap() }
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        } else if vm.filtered.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(.tertiary)
                Text(vm.worlds.isEmpty
                     ? KizunaCopy.text(japanese: "ストーリーはまだありません", english: "No stories yet")
                     : KizunaCopy.text(japanese: "条件に合うストーリーがありません", english: "No stories match your filters"))
                    .font(.system(size: 14, weight: .semibold))
                if vm.worlds.isEmpty {
                    Button {
                        showCreate = true
                    } label: {
                        Label(KizunaCopy.text(japanese: "最初のストーリーを作る", english: "Create your first story"), systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) {
                    ForEach(vm.filtered) { w in
                        worldCard(w)
                    }
                }
                .padding(16)
            }
        }
    }

    private func worldCard(_ w: StoryWorld) -> some View {
        let displayedWorld = w.localizedForCurrentLanguage
        let coverCharacter = vm.coverCharacter(for: w)
        return Button { selected = w } label: {
            VStack(alignment: .leading, spacing: 12) {
                ZStack(alignment: .bottomLeading) {
                    StoryCoverView(world: displayedWorld, character: coverCharacter)
                        .frame(maxWidth: .infinity)
                        .frame(height: 230)
                        .clipped()

                    LinearGradient(
                        colors: [.black.opacity(0.04), .black.opacity(0.66)],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .bottom) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(displayedWorld.title)
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                Text(coverCharacter?.visibleName ?? displayedWorld.genre.group.localizedDisplayName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.86))
                            }
                            Spacer()
                            Image(systemName: w.visibility.iconName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.84))
                        }
                        Text(displayedWorld.mood.isEmpty ? displayedWorld.genre.group.localizedDisplayName : displayedWorld.mood)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1)
                    }
                    .padding(14)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                if !displayedWorld.shortDescription.isEmpty {
                    Text(displayedWorld.shortDescription)
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(2)
                }
                if !displayedWorld.openingScene.isEmpty {
                    Text("「\(displayedWorld.openingScene)」")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.82))
                        .lineLimit(3)
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.045))
                        )
                }
                HStack(spacing: 4) {
                    Text(displayedWorld.genre.localizedDisplayName)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        .foregroundStyle(Color.accentColor)
                    Text(displayedWorld.relationshipGenre.localizedDisplayName)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.purple.opacity(0.12)))
                        .foregroundStyle(.purple)
                    Spacer()
                    Label(
                        KizunaCopy.language == .english ? "\(w.characterIds.count) people" : "\(w.characterIds.count)人",
                        systemImage: "person.3.fill"
                    )
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                if !displayedWorld.tags.isEmpty {
                    Text(displayedWorld.tags.prefix(4).map { "#\($0)" }.joined(separator: "  "))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

}
