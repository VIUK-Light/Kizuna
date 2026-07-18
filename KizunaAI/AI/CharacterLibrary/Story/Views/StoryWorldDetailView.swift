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
    var onEdit: ((StoryWorld) -> Void)?
    var onDelete: (() -> Void)?

    @StateObject private var vm: StoryWorldDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showDeleteConfirmation = false
    @State private var spotlightCharacter: CharacterProfile?

    init(
        world: StoryWorld,
        onStartSession: ((StoryWorld) -> Void)? = nil,
        onEdit: ((StoryWorld) -> Void)? = nil,
        onDelete: (() -> Void)? = nil
    ) {
        self.world = world
        self.onStartSession = onStartSession
        self.onEdit = onEdit
        self.onDelete = onDelete
        _vm = StateObject(wrappedValue: StoryWorldDetailViewModel(world: world))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
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
        }
        .background(Color.appCanvasBackground.ignoresSafeArea())
        .task { await vm.reload() }
        .alert("この世界を削除しますか？", isPresented: $showDeleteConfirmation) {
            Button("削除", role: .destructive) {
                onDelete?()
                dismiss()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("キャスト、シーン、保存済みセッションも削除対象になります。")
        }
        .sheet(item: $spotlightCharacter) { character in
            StoryDetailCharacterSpotlight(character: character)
                .presentationDetents([.medium, .large])
        }
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
                Text(world.title)
                    .font(.system(size: 18, weight: .bold))
                    .lineLimit(1)
                Text(world.genre.displayName + " ・ " + world.relationshipGenre.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if horizontalSizeClass == .compact {
                Menu {
                    Button {
                        onStartSession?(world)
                    } label: {
                        Label("絆チャット開始", systemImage: "play.fill")
                    }
                    if world.isSystemProtected != true {
                        Button {
                            onEdit?(world)
                        } label: {
                            Label("編集", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Label("削除", systemImage: "trash")
                        }
                    } else {
                        Button {
                        } label: {
                            Label("標準ストーリー", systemImage: "lock.fill")
                        }
                        .disabled(true)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.bordered)
            } else {
                if world.isSystemProtected != true {
                    Button {
                        onEdit?(world)
                    } label: {
                        Label("編集", systemImage: "pencil")
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("削除", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Label("標準", systemImage: "lock.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }

                Button {
                    onStartSession?(world)
                } label: {
                    Label("絆チャット開始", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.thinMaterial)
    }

    private var relationshipHero: some View {
        VStack(alignment: .leading, spacing: 18) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.40, green: 0.46, blue: 0.70),
                            Color(red: 0.12, green: 0.13, blue: 0.18)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .aspectRatio(1.22, contentMode: .fit)
                .overlay(alignment: .topLeading) {
                    Image(systemName: world.genre.group.iconName)
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))
                        .padding(24)
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(vm.characterIndex[world.mainCharacterId ?? UUID()]?.displayName ?? world.genre.group.displayName)
                            .font(.system(size: 15, weight: .bold))
                        Text(world.mood.isEmpty ? world.relationshipGenre.displayName : world.mood)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    .foregroundStyle(.white)
                    .padding(20)
                }

            VStack(alignment: .leading, spacing: 10) {
                Text(world.title)
                    .font(.system(size: 34, weight: .heavy))
                    .lineLimit(2)
                if !world.shortDescription.isEmpty {
                    Text(world.shortDescription)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !world.tags.isEmpty {
                    Text(world.tags.prefix(8).map { "#\($0)" }.joined(separator: " "))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Label("\(vm.sessions.reduce(0) { $0 + $1.messages.count })", systemImage: "bubble.left.fill")
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                    Spacer()
                    Button {
                        onStartSession?(world)
                    } label: {
                        Label("トークを続ける", systemImage: "play.fill")
                            .font(.system(size: 15, weight: .bold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
    }

    private var overviewCard: some View {
        detailCard(title: "概要", icon: "book.closed.fill") {
            if !world.shortDescription.isEmpty {
                detailText(world.shortDescription)
            }
            detailPair("ユーザーの役割", world.userRole)
            detailPair("ムード", world.mood)
            detailPair("物語の目的", world.storyGoal)
            if !world.tags.isEmpty {
                FlowTagRow(tags: world.tags)
                    .padding(.top, 2)
            }
        }
    }

    private var progressCard: some View {
        let session = vm.sessions.first
        let messageCount = session?.messages.count ?? 0
        let progress = min(1.0, Double(max(messageCount, 1)) / 24.0)
        let sceneTitle = session?.currentSceneId.flatMap { id in vm.scenes.first(where: { $0.id == id })?.title } ?? vm.scenes.first?.title ?? "第1場面"
        let objective = session?.currentObjective ?? vm.scenes.first?.sceneGoal ?? world.storyGoal
        let stage = session?.relationshipStage ?? (session == nil ? "未開始" : "進行中")
        return detailCard(title: "物語状態", icon: "chart.line.uptrend.xyaxis") {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.10), lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 13, weight: .heavy).monospacedDigit())
                }
                .frame(width: 58, height: 58)

                VStack(alignment: .leading, spacing: 5) {
                    Text(session == nil ? "まだ始まっていません" : "再開できます")
                        .font(.system(size: 16, weight: .heavy))
                    Text("\(sceneTitle) ・ \(stage)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(objective)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text("\(messageCount)件のやり取り ・ \(vm.cast.count)人のキャスト ・ \(vm.scenes.count)シーン")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    onStartSession?(world)
                } label: {
                    Label(session == nil ? "開始" : "続きから", systemImage: "play.fill")
                        .font(.system(size: 13, weight: .bold))
                }
                .buttonStyle(.borderedProminent)
            }

            if let summary = session?.lastSceneSummary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.top, 4)
            } else if let last = session?.messages.last {
                Text(last.text)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.top, 4)
            }
        }
    }

    private var castCard: some View {
        detailCard(title: "キャスト", icon: "person.3.fill") {
            if vm.cast.isEmpty {
                emptyLine("まだキャストが設定されていません。")
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
                            Label(member.roleInStory.displayName, systemImage: member.roleInStory.iconName)
                                .font(.system(size: 11, weight: .bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.white.opacity(0.16)))
                            Spacer()
                            Text("\(Int(member.importance * 100))%")
                                .font(.system(size: 11, weight: .bold).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.86))
                        }
                        Text(character?.displayName ?? "未登録キャラ")
                            .font(.system(size: 20, weight: .heavy))
                            .lineLimit(1)
                        Text(member.introductionTiming.displayName)
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
                .scaledToFill()
        } else if let key = character?.imageKey, !key.isEmpty {
            Image(key)
                .resizable()
                .scaledToFill()
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

    private var scenesCard: some View {
        detailCard(title: "シーン", icon: "sparkles.rectangle.stack.fill") {
            if vm.scenes.isEmpty {
                emptyLine("まだシーンがありません。")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(vm.scenes) { scene in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(scene.title.isEmpty ? "無題のシーン" : scene.title)
                                .font(.system(size: 13, weight: .semibold))
                            HStack(spacing: 8) {
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
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
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

    private var rulesCard: some View {
        detailCard(title: "ルール / 安全", icon: "shield.lefthalf.filled") {
            detailPair("公開状態", world.visibility.displayName)
            if !world.worldSetting.isEmpty {
                detailPair("世界観", world.worldSetting)
            }
            if !world.openingScene.isEmpty {
                detailPair("オープニング", world.openingScene)
            }
            let outputRules = world.safetyRules.filter(isOutputFormatRule)
            let safetyRules = world.safetyRules.filter { !isOutputFormatRule($0) }
            if !outputRules.isEmpty {
                ruleGroup("出力形式", outputRules)
            }
            if safetyRules.isEmpty {
                emptyLine("追加安全ルールはありません。")
            } else {
                ruleGroup("安全", safetyRules)
            }
        }
    }

    private func ruleGroup(_ title: String, _ rules: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.tertiary)
            ForEach(rules, id: \.self) { rule in
                Label(rule, systemImage: title == "出力形式" ? "text.quote" : "checkmark.seal")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func isOutputFormatRule(_ rule: String) -> Bool {
        [
            "ナレーション",
            "1ターン",
            "キャラ発話",
            "複数キャラ",
            "active",
            "会話だけ",
            "思考過程",
            "場面",
            "描写",
            "段階的"
        ].contains { rule.localizedCaseInsensitiveContains($0) }
    }

    private var historyCard: some View {
        detailCard(title: "セッション", icon: "bubble.left.and.bubble.right.fill") {
            if vm.sessions.isEmpty {
                emptyLine("まだ会話セッションはありません。")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(vm.sessions.prefix(5)) { session in
                        HStack {
                            Text(session.updatedAt, style: .date)
                            Text(session.updatedAt, style: .time)
                            Spacer()
                            Text("\(session.messages.count) 件")
                                .font(.system(size: 10, weight: .bold).monospacedDigit())
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
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
        HStack(spacing: 6) {
            ForEach(tags.prefix(8), id: \.self) { tag in
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
                                Text(character.displayName)
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
                    info("口調", character.speakingStyle)
                    info("性格", character.personality)
                    info("ユーザーとの関係", character.relationshipToUser)
                    info("背景", character.background)
                    info("初回の一言", character.firstMessage)
                }
                .padding(18)
            }
            .navigationTitle(character.displayName)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
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
        } else if let key = character.imageKey, !key.isEmpty {
            Image(key)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(colors: [Color.accentColor.opacity(0.75), Color.primary.opacity(0.24)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(String(character.displayName.prefix(1)))
                    .font(.system(size: 58, weight: .heavy))
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
