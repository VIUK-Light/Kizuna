/*
仕様:
- 役割: StoryWorld の詳細確認画面。Claude 停止で StoryWorldLibraryView から参照だけ残った
  `StoryWorldDetailView` を補完する。
- 主な型: `StoryWorldDetailView`。
- 方針: Story セッション画面にはまだ遷移せず、既存呼び出し口に合わせて
  「開始」「編集」「削除」だけを安全に返す。
*/

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
private typealias StoryDetailPlatformImage = NSImage
#elseif canImport(UIKit)
private typealias StoryDetailPlatformImage = UIImage
#endif

private extension Image {
    init(storyDetailPlatformImage: StoryDetailPlatformImage) {
        #if canImport(AppKit)
        self.init(nsImage: storyDetailPlatformImage)
        #elseif canImport(UIKit)
        self.init(uiImage: storyDetailPlatformImage)
        #else
        self.init(systemName: "person.crop.rectangle")
        #endif
    }
}

struct StoryWorldDetailView: View {
    let world: StoryWorld
    var onStartSession: ((StoryWorld) -> Void)?
    var onResumeSession: ((StoryWorld, UUID) -> Void)?
    var onStartNewSession: ((StoryWorld) -> Void)?
    var onEdit: ((StoryWorld) -> Void)?
    var onDelete: (() async throws -> Void)?

    @StateObject private var vm: StoryWorldDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showDeleteConfirmation = false
    @State private var deleteError: String?
    @State private var isDeleting = false
    @State private var isLoading = true
    @State private var reloadID = UUID()
    @State private var spotlightCharacter: CharacterProfile?

    init(
        world: StoryWorld,
        onStartSession: ((StoryWorld) -> Void)? = nil,
        onResumeSession: ((StoryWorld, UUID) -> Void)? = nil,
        onStartNewSession: ((StoryWorld) -> Void)? = nil,
        onEdit: ((StoryWorld) -> Void)? = nil,
        onDelete: (() async throws -> Void)? = nil
    ) {
        self.world = world
        self.onStartSession = onStartSession
        self.onResumeSession = onResumeSession
        self.onStartNewSession = onStartNewSession
        self.onEdit = onEdit
        self.onDelete = onDelete
        _vm = StateObject(wrappedValue: StoryWorldDetailViewModel(world: world))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isLoading {
                ProgressView(KizunaCopy.text(
                    japanese: "ストーリーの保存データを読み込んでいます…",
                    english: "Loading saved story data…"
                ))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if hasLoadFailure {
                loadFailureState
            } else {
                ScrollView {
                    detailContent
                }
            }
        }
        .background(Color.appCanvasBackground.ignoresSafeArea())
        .task(id: reloadID) {
            isLoading = true
            await vm.reload()
            isLoading = false
        }
        .alert(KizunaCopy.text(japanese: "この世界を削除しますか？", english: "Delete this story world?"), isPresented: $showDeleteConfirmation) {
            Button(KizunaCopy.text(japanese: "削除", english: "Delete"), role: .destructive) {
                guard !isDeleting else { return }
                isDeleting = true
                Task { @MainActor in
                    defer { isDeleting = false }
                    do {
                        // Library callers can inject their coordinated delete
                        // operation.  Standalone detail presentations still
                        // need to execute the throwing view-model path; an
                        // optional action must never turn Delete into a
                        // dismiss-only no-op.
                        if let onDelete {
                            try await onDelete()
                        } else {
                            try await vm.delete()
                        }
                        dismiss()
                    } catch {
                        NSLog("[StoryWorldDetailView] story world deletion failed: %@", error.localizedDescription)
                        deleteError = KizunaCopy.text(
                            japanese: "保存データを削除できませんでした。もう一度試してください。",
                            english: "The saved story could not be deleted. Try again."
                        )
                    }
                }
            }
            Button(KizunaCopy.text(japanese: "キャンセル", english: "Cancel"), role: .cancel) {}
        } message: {
            Text(KizunaCopy.text(
                japanese: "キャスト、シーン、保存済みセッションも削除対象になります。",
                english: "Characters, scenes, and saved sessions will also be deleted."
            ))
        }
        .alert(KizunaCopy.text(japanese: "削除できませんでした", english: "Could not delete"), isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button(KizunaCopy.text(japanese: "閉じる", english: "Close"), role: .cancel) {}
        } message: {
            Text(deleteError ?? KizunaCopy.text(japanese: "保存データを変更できませんでした。", english: "The saved data could not be changed."))
        }
        .sheet(item: $spotlightCharacter) { character in
            StoryDetailCharacterSpotlight(character: character)
                .presentationDetents([.medium, .large])
        }
    }

    private var displayedWorld: StoryWorld {
        world.localizedForCurrentLanguage
    }

    private var hasLoadFailure: Bool {
        vm.castLoadFailed || vm.sceneLoadFailed || vm.sessionLoadFailed || vm.characterLoadFailed
    }

    private var canStartSession: Bool {
        !isLoading && !hasLoadFailure
    }

    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            relationshipHero
            progressCard
            overviewCard
            castCard
            scenesCard
            rulesCard
            historyCard
        }
        .padding(18)
    }

    private var loadFailureState: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 34))
                .foregroundStyle(.orange)
            Text(KizunaCopy.text(
                japanese: "保存データを読み込めませんでした",
                english: "Saved story data could not be loaded"
            ))
                .font(.headline)
            Text(KizunaCopy.text(
                japanese: "データを空として扱っていません。保存内容は変更されていないので、再試行してください。",
                english: "The data was not treated as empty. Nothing was changed; try again."
            ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button {
                reloadID = UUID()
            } label: {
                Label(KizunaCopy.text(japanese: "再試行", english: "Retry"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var resumableSession: StorySession? {
        vm.sessions.first { session in
            guard let sceneID = session.currentSceneId else { return false }
            return vm.scenes.contains(where: { $0.id == sceneID })
        }
    }

    private var canResume: Bool { resumableSession != nil }

    /// StoryScene predates the presentation-localization catalog and therefore
    /// has no language-specific payload of its own. Standard worlds keep one
    /// durable seed scene as their first scene; localize that stable identity
    /// at the display boundary rather than comparing editable Japanese prose.
    /// User-authored worlds and later/unknown scenes always retain their own
    /// saved text.
    private func displayedScene(_ scene: StoryScene) -> StoryScene {
        guard KizunaCopy.language == .english,
              world.isSystemProtected == true,
              let initialSceneID = vm.scenes.first?.id,
              scene.id == initialSceneID,
              let localization = StoryEnglishCatalog.localization(for: world),
              let translatedOpening = localization.openingScene?.trimmingCharacters(in: .whitespacesAndNewlines),
              !translatedOpening.isEmpty
        else {
            return scene
        }

        var copy = scene
        copy.title = KizunaCopy.text(japanese: "オープニング", english: "Opening scene")
        copy.location = KizunaCopy.text(japanese: "物語の舞台", english: "Story setting")
        copy.timeOfDay = ""
        let localizedMood = localization.mood?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        copy.mood = localizedMood.isEmpty ? displayedWorld.mood : localizedMood
        let localizedGoal = localization.storyGoal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        copy.sceneGoal = localizedGoal.isEmpty ? displayedWorld.storyGoal : localizedGoal
        copy.conflict = nil
        copy.summary = translatedOpening
        return copy
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.accentColor.opacity(0.24),
                                Color.purple.opacity(0.16)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)
                Image(systemName: world.genre.group.iconName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(displayedWorld.title)
                    .font(.system(size: 18, weight: .bold))
                    .lineLimit(1)
                Text(displayedWorld.genre.localizedDisplayName + " ・ " + displayedWorld.relationshipGenre.localizedDisplayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if horizontalSizeClass == .compact {
                Menu {
                    Button {
                        if let session = resumableSession {
                            onResumeSession?(world, session.id)
                        } else {
                            onStartSession?(world)
                        }
                    } label: {
                        Label(
                            canResume
                                ? KizunaCopy.text(japanese: "続きから", english: "Continue")
                                : KizunaCopy.text(japanese: "始める", english: "Start"),
                            systemImage: "play.fill"
                        )
                    }
                    .disabled(!canStartSession)
                    if canResume {
                        Button {
                            onStartNewSession?(world)
                        } label: {
                            Label(KizunaCopy.text(japanese: "新しい物語", english: "New story"), systemImage: "plus")
                        }
                        .disabled(!canStartSession)
                    }
                    if world.isSystemProtected != true {
                        Button {
                            onEdit?(world)
                        } label: {
                            Label(KizunaCopy.text(japanese: "編集", english: "Edit"), systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Label(KizunaCopy.text(japanese: "削除", english: "Delete"), systemImage: "trash")
                        }
                    } else {
                        Button {
                        } label: {
                            Label(KizunaCopy.text(japanese: "標準ストーリー", english: "Starter story"), systemImage: "lock.fill")
                        }
                        .disabled(true)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
            } else {
                if world.isSystemProtected != true {
                    Button {
                        onEdit?(world)
                    } label: {
                        Label(KizunaCopy.text(japanese: "編集", english: "Edit"), systemImage: "pencil")
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label(KizunaCopy.text(japanese: "削除", english: "Delete"), systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Label(KizunaCopy.text(japanese: "標準", english: "Starter"), systemImage: "lock.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }

                if canResume {
                    Button {
                        onStartNewSession?(world)
                    } label: {
                        Label(KizunaCopy.text(japanese: "新しい物語", english: "New story"), systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canStartSession)
                }

                Button {
                    if let session = resumableSession {
                        onResumeSession?(world, session.id)
                    } else {
                        onStartSession?(world)
                    }
                } label: {
                    Label(
                        canResume
                            ? KizunaCopy.text(japanese: "続きから", english: "Continue")
                            : KizunaCopy.text(japanese: "始める", english: "Start"),
                        systemImage: "play.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStartSession)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.thinMaterial)
    }

    private var relationshipHero: some View {
        // mainCharacterIdが欠落/壊れていても、アプリ内の無関係なキャラを
        // Dictionaryの順序で拾わない。Worldが保持するcharacterIdsと、
        // 保存済みCastの順序だけをカバー候補にする。
        var orderedCharacterIDs: [UUID] = []
        for id in world.characterIds + vm.cast.map(\.characterId) where !orderedCharacterIDs.contains(id) {
            orderedCharacterIDs.append(id)
        }
        let coverCharacter: CharacterProfile? = {
            if let mainID = world.mainCharacterId,
               orderedCharacterIDs.contains(mainID),
               let main = vm.characterIndex[mainID] {
                return main
            }
            return orderedCharacterIDs.compactMap { vm.characterIndex[$0] }.first
        }()
        return VStack(alignment: .leading, spacing: 18) {
            StoryCoverView(world: displayedWorld, character: coverCharacter)
                .aspectRatio(1.22, contentMode: .fit)
                .overlay(alignment: .topLeading) {
                    Image(systemName: world.genre.group.iconName)
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))
                        .padding(24)
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(coverCharacter?.visibleName ?? displayedWorld.genre.group.localizedDisplayName)
                            .font(.system(size: 15, weight: .bold))
                        Text(displayedWorld.mood.isEmpty ? displayedWorld.relationshipGenre.localizedDisplayName : displayedWorld.mood)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    .foregroundStyle(.white)
                    .padding(20)
                }

            VStack(alignment: .leading, spacing: 10) {
                Text(displayedWorld.title)
                    .font(.system(size: 34, weight: .heavy))
                    .lineLimit(2)
                if !displayedWorld.shortDescription.isEmpty {
                    Text(displayedWorld.shortDescription)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !displayedWorld.tags.isEmpty {
                    // Keep the compact hero summary complete as well as the
                    // pill row below; fixedSize allows long tag lists to wrap
                    // instead of silently hiding the remaining tags.
                    Text(displayedWorld.tags.map { "#\($0)" }.joined(separator: " "))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Label(
                        canResume
                            ? KizunaCopy.text(japanese: "続きあり", english: "Ready to continue")
                            : KizunaCopy.text(japanese: "未開始", english: "Not started"),
                        systemImage: canResume ? "arrow.uturn.forward.circle.fill" : "play.circle"
                    )
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                    Spacer()
                    Button {
                        if let session = resumableSession {
                            onResumeSession?(world, session.id)
                        } else {
                            onStartSession?(world)
                        }
                    } label: {
                        Label(
                            canResume
                                ? KizunaCopy.text(japanese: "続きから", english: "Continue")
                                : KizunaCopy.text(japanese: "始める", english: "Start"),
                            systemImage: "play.fill"
                        )
                            .font(.system(size: 15, weight: .bold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                if canResume {
                    Button {
                        onStartNewSession?(world)
                    } label: {
                        Label(KizunaCopy.text(japanese: "新しい物語を始める", english: "Start a new story"), systemImage: "plus.circle")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canStartSession)
                }
            }
        }
    }

    private var overviewCard: some View {
        detailCard(title: KizunaCopy.text(japanese: "概要", english: "Overview"), icon: "book.closed.fill") {
            if !displayedWorld.shortDescription.isEmpty {
                detailText(displayedWorld.shortDescription)
            }
            detailPair(KizunaCopy.text(japanese: "ユーザーの役割", english: "Your role"), displayedWorld.userRole)
            detailPair(KizunaCopy.text(japanese: "物語形式", english: "Story format"), displayedWorld.resolvedCastMode.localizedDisplayName)
            detailPair(KizunaCopy.text(japanese: "ムード", english: "Mood"), displayedWorld.mood)
            detailPair(KizunaCopy.text(japanese: "物語の目的", english: "Story goal"), displayedWorld.storyGoal)
            if !displayedWorld.tags.isEmpty {
                FlowTagRow(tags: displayedWorld.tags)
                    .padding(.top, 2)
            }
        }
    }

    private var progressCard: some View {
        let session = resumableSession
        let currentScene = session?.currentSceneId.flatMap { id in vm.scenes.first(where: { $0.id == id }) }
        let presentationScene = currentScene.map { displayedScene($0) }
        let sceneTitle = presentationScene?.title
            ?? KizunaCopy.text(japanese: "最初の場面", english: "Opening scene")
        return detailCard(title: KizunaCopy.text(japanese: "物語状態", english: "Story status"), icon: "location.north.line") {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    session == nil
                        ? KizunaCopy.text(japanese: "まだ始まっていません", english: "Not started yet")
                        : sceneTitle,
                    systemImage: session == nil ? "play.circle" : "bookmark.fill"
                )
                    .font(.system(size: 16, weight: .bold))
                if session != nil, let updatedAt = session?.updatedAt {
                    Text(KizunaCopy.language == .english
                         ? "Last updated \(updatedAt, style: .relative)"
                         : "最終更新 \(updatedAt, style: .relative)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var castCard: some View {
        detailCard(title: KizunaCopy.text(japanese: "キャスト", english: "Cast"), icon: "person.3.fill") {
            if vm.cast.isEmpty {
                emptyLine(KizunaCopy.text(japanese: "まだキャストが設定されていません。", english: "No cast has been added yet."))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(vm.cast) { member in
                        let character = vm.characterIndex[member.characterId]
                        castMemberImageCard(member: member, character: character)
                    }
                }
            }
        }
    }

    private func castMemberImageCard(member: CastMember, character: CharacterProfile?) -> some View {
        Button {
            spotlightCharacter = character
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                ZStack(alignment: .bottomLeading) {
                    // 縦長の立ち絵を横長カードに無理にFillすると顔が中央トリミングされる。
                    // 背景を敷いた上でFitし、顔を含む全身を見える状態にする。
                    Color.black.opacity(0.18)
                    castImage(for: character, role: member.roleInStory)
                        .frame(maxWidth: .infinity)
                        .frame(height: 210)
                        .clipped()

                    LinearGradient(
                        colors: [.black.opacity(0.02), .black.opacity(0.72)],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Label(member.roleInStory.localizedDisplayName, systemImage: member.roleInStory.iconName)
                                .font(.system(size: 11, weight: .bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.white.opacity(0.16)))
                            Spacer()
                            Text("\(Int(member.importance * 100))%")
                                .font(.system(size: 11, weight: .bold).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.86))
                        }
                        Text(character?.visibleName ?? KizunaCopy.text(japanese: "未登録キャラ", english: "Unregistered character"))
                            .font(.system(size: 20, weight: .heavy))
                            .lineLimit(1)
                        Text(member.introductionTiming.localizedDisplayName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.78))
                    }
                    .foregroundStyle(.white)
                    .padding(12)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                if !member.relationshipToUser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(member.relationshipToUser)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
        .disabled(character == nil)
    }

    @ViewBuilder
    private func castImage(for character: CharacterProfile?, role: CastRole) -> some View {
        if let data = character?.avatarImageData,
           let image = storyDetailPlatformImage(from: data) {
            Image(storyDetailPlatformImage: image)
                .resizable()
                .scaledToFit()
        } else if let key = character?.imageKey,
                  !key.isEmpty,
                  let image = storyDetailPlatformImage(named: key) {
            Image(storyDetailPlatformImage: image)
                .resizable()
                .scaledToFit()
        } else {
            ZStack {
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.68), Color.primary.opacity(0.18)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: role.iconName)
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
            }
        }
    }

    private func storyDetailPlatformImage(from data: Data) -> StoryDetailPlatformImage? {
        #if canImport(AppKit)
        return NSImage(data: data)
        #elseif canImport(UIKit)
        return UIImage(data: data)
        #else
        return nil
        #endif
    }

    // 未登録の画像名をSwiftUIへ渡さず、役割アイコンへフォールバックする。
    private func storyDetailPlatformImage(named name: String) -> StoryDetailPlatformImage? {
        #if canImport(AppKit)
        return NSImage(named: name)
        #elseif canImport(UIKit)
        return UIImage(named: name)
        #else
        return nil
        #endif
    }

    private var scenesCard: some View {
        detailCard(title: KizunaCopy.text(japanese: "シーン", english: "Scenes"), icon: "sparkles.rectangle.stack.fill") {
            if vm.scenes.isEmpty {
                emptyLine(KizunaCopy.text(japanese: "まだシーンがありません。", english: "No scenes yet."))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(vm.scenes) { storedScene in
                        let scene = displayedScene(storedScene)
                        VStack(alignment: .leading, spacing: 4) {
                            StorySceneImageView(scene: scene, world: displayedWorld)
                                .frame(maxWidth: .infinity)
                                .frame(height: 150)
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            Text(scene.title.isEmpty
                                 ? KizunaCopy.text(japanese: "無題のシーン", english: "Untitled scene")
                                 : scene.title)
                                .font(.system(size: 13, weight: .semibold))
                            if !scene.location.isEmpty || !scene.timeOfDay.isEmpty || !scene.mood.isEmpty {
                                sceneMetadata(scene)
                            }
                            if !scene.sceneGoal.isEmpty {
                                detailText(scene.sceneGoal)
                            }
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.035))
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sceneMetadata(_ scene: StoryScene) -> some View {
        // 広い画面では1行、compact幅や長い英語/ユーザー入力では縦に折り返す。
        // HStack側はfixedSizeで必要幅を正しく申告し、ViewThatFitsが
        // 狭い提案幅でVStackへ切り替えられるようにする。
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                if !scene.location.isEmpty {
                    Label(scene.location, systemImage: "mappin.and.ellipse")
                        .fixedSize(horizontal: true, vertical: false)
                }
                if !scene.timeOfDay.isEmpty {
                    Label(scene.timeOfDay, systemImage: "clock")
                        .fixedSize(horizontal: true, vertical: false)
                }
                if !scene.mood.isEmpty {
                    Label(scene.mood, systemImage: "theatermasks")
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                if !scene.location.isEmpty {
                    Label(scene.location, systemImage: "mappin.and.ellipse")
                }
                if !scene.timeOfDay.isEmpty {
                    Label(scene.timeOfDay, systemImage: "clock")
                }
                if !scene.mood.isEmpty {
                    Label(scene.mood, systemImage: "theatermasks")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rulesCard: some View {
        detailCard(title: KizunaCopy.text(japanese: "ルール / 安全", english: "Rules / safety"), icon: "shield.lefthalf.filled") {
            detailPair(KizunaCopy.text(japanese: "公開状態", english: "Visibility"), world.visibility.localizedDisplayName)
            if !displayedWorld.worldSetting.isEmpty {
                detailPair(KizunaCopy.text(japanese: "世界観", english: "World setting"), displayedWorld.worldSetting)
            }
            if !displayedWorld.openingScene.isEmpty {
                detailPair(KizunaCopy.text(japanese: "オープニング", english: "Opening"), displayedWorld.openingScene)
            }
            let outputRules = displayedWorld.safetyRules.filter(isOutputFormatRule)
            let safetyRules = displayedWorld.safetyRules.filter { !isOutputFormatRule($0) }
            if !outputRules.isEmpty {
                ruleGroup(KizunaCopy.text(japanese: "出力形式", english: "Output format"), outputRules)
            }
            if safetyRules.isEmpty {
                emptyLine(KizunaCopy.text(japanese: "追加安全ルールはありません。", english: "No additional safety rules."))
            } else {
                ruleGroup(KizunaCopy.text(japanese: "安全", english: "Safety"), safetyRules)
            }
        }
    }

    private func ruleGroup(_ title: String, _ rules: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.tertiary)
            ForEach(rules, id: \.self) { rule in
                Label(rule, systemImage: title == KizunaCopy.text(japanese: "出力形式", english: "Output format") ? "text.quote" : "checkmark.seal")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func isOutputFormatRule(_ rule: String) -> Bool {
        StoryPromptBuilder.isOutputFormatRule(rule)
    }

    private var historyCard: some View {
        detailCard(title: KizunaCopy.text(japanese: "セッション", english: "Sessions"), icon: "bubble.left.and.bubble.right.fill") {
            if vm.sessions.isEmpty {
                emptyLine(KizunaCopy.text(japanese: "まだ会話セッションはありません。", english: "No conversation sessions yet."))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(vm.sessions) { session in
                        Button {
                            onResumeSession?(world, session.id)
                        } label: {
                            HStack {
                                Image(systemName: "play.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                                Text(session.updatedAt, style: .date)
                                Text(session.updatedAt, style: .time)
                                Spacer()
                                Text(KizunaCopy.language == .english
                                     ? "\(session.messages.count) messages"
                                     : "\(session.messages.count) 件")
                                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                            }
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func detailCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .bold))
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.appSecondaryBackground.opacity(0.68))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func detailPair(_ title: String, _ value: String) -> some View {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.tertiary)
                detailText(trimmed)
            }
        }
    }

    private func detailText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
    }
}

private struct FlowTagRow: View {
    let tags: [String]

    var body: some View {
        FlowTagLayout(horizontalSpacing: 6, verticalSpacing: 6) {
            // Do not silently drop tags: the wrapping layout keeps every tag
            // reachable on compact windows instead of hiding the ninth item.
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A small wrapping layout for tags. An HStack silently grows past the detail
/// card's width on compact windows, which made the last tags unreachable (and
/// could also push the card's content outside the scroll view).
private struct FlowTagLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widestRow: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let nextWidth = rowWidth == 0 ? size.width : rowWidth + horizontalSpacing + size.width
            if rowWidth > 0, nextWidth > maxWidth {
                widestRow = max(widestRow, rowWidth)
                totalHeight += rowHeight + verticalSpacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth = nextWidth
                rowHeight = max(rowHeight, size.height)
            }
        }

        widestRow = max(widestRow, rowWidth)
        totalHeight += rowHeight
        // The proposal is only an input to row wrapping. Return the actual
        // content width so a short row does not claim the entire parent width.
        let width = min(widestRow, proposal.width ?? widestRow)
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }

            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct StoryDetailCharacterSpotlight: View {
    let character: CharacterProfile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    image
                        .frame(maxWidth: .infinity)
                        .frame(height: 380)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(alignment: .bottomLeading) {
                            LinearGradient(colors: [.clear, .black.opacity(0.74)], startPoint: .top, endPoint: .bottom)
                                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(character.visibleName)
                                    .font(.system(size: 32, weight: .heavy))
                                if !character.shortDescription.isEmpty {
                                    Text(character.shortDescription)
                                        .font(.system(size: 14, weight: .semibold))
                                        .lineLimit(2)
                                }
                            }
                            .foregroundStyle(.white)
                            .padding(18)
                        }
                    info(KizunaCopy.text(japanese: "口調", english: "Speaking style"), character.speakingStyle)
                    info(KizunaCopy.text(japanese: "性格", english: "Personality"), character.personality)
                    info(KizunaCopy.text(japanese: "ユーザーとの関係", english: "Relationship with you"), character.relationshipToUser)
                    info(KizunaCopy.text(japanese: "背景", english: "Background"), character.background)
                    info(KizunaCopy.text(japanese: "初回の一言", english: "First message"), character.firstMessage)
                }
                .padding(18)
            }
            .navigationTitle(character.visibleName)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(KizunaCopy.text(japanese: "閉じる", english: "Close")) { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var image: some View {
        if let data = character.avatarImageData,
           let image = storyDetailSpotlightPlatformImage(from: data) {
            Image(storyDetailPlatformImage: image)
                .resizable()
                .scaledToFill()
        } else if let key = character.imageKey,
                  !key.isEmpty,
                  let image = storyDetailSpotlightPlatformImage(named: key) {
            Image(storyDetailPlatformImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(colors: [Color.accentColor.opacity(0.75), Color.primary.opacity(0.24)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "person.fill")
                    .font(.system(size: 58, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }

    private func info(_ title: String, _ value: String) -> some View {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return Group {
            if !trimmed.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(trimmed)
                        .font(.system(size: 14, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private func storyDetailSpotlightPlatformImage(from data: Data) -> StoryDetailPlatformImage? {
    #if canImport(AppKit)
    return NSImage(data: data)
    #elseif canImport(UIKit)
    return UIImage(data: data)
    #else
    return nil
    #endif
}

private func storyDetailSpotlightPlatformImage(named name: String) -> StoryDetailPlatformImage? {
    #if canImport(AppKit)
    return NSImage(named: name)
    #elseif canImport(UIKit)
    return UIImage(named: name)
    #else
    return nil
    #endif
}
