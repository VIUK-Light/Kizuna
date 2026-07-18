/*
仕様:
- 役割: StoryWorld の新規作成/編集 + Cast (登場キャラ) の追加・役割設定。
- 主な型: `StoryWorldCreateView`.
- 編集ポイント: 入力フィールド追加、キャラ選択 UI、保存時 Cast 連動。
*/

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
private typealias StoryPlatformImage = NSImage
#elseif canImport(UIKit)
private typealias StoryPlatformImage = UIImage
#endif

private extension Image {
    init(storyPlatformImage: StoryPlatformImage) {
        #if canImport(AppKit)
        self.init(nsImage: storyPlatformImage)
        #elseif canImport(UIKit)
        self.init(uiImage: storyPlatformImage)
        #else
        self.init(systemName: "person.crop.square")
        #endif
    }
}

struct StoryWorldCreateView: View {
    var existing: StoryWorld? = nil
    var onSaved: ((StoryWorld) -> Void)?
    var onStartSession: ((StoryWorld) -> Void)?

    @StateObject private var vm: StoryWorldCreateViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var newTag = ""
    @State private var showCharacterPicker = false
    @State private var showCharacterCreator = false
    @FocusState private var generationBriefFocused: Bool

    init(
        existing: StoryWorld? = nil,
        onSaved: ((StoryWorld) -> Void)? = nil,
        onStartSession: ((StoryWorld) -> Void)? = nil
    ) {
        self.existing = existing
        self.onSaved = onSaved
        self.onStartSession = onStartSession
        _vm = StateObject(wrappedValue: StoryWorldCreateViewModel(existing: existing))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if existing == nil {
                        creatorHero
                        aiTemplateSection
                        generatedPreviewSection
                    }
                    basicSection
                    settingSection
                    openingSceneSection
                    castSection
                    relationshipSection
                    tagsSection
                    if let err = vm.saveError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(18)
            }
            Divider()
            footer
        }
        .background(Color.appCanvasBackground.ignoresSafeArea())
        .task { await vm.load() }
        .sheet(isPresented: $showCharacterPicker) {
            CharacterPickerForStory(
                available: vm.availableCharacters,
                excluded: vm.castDrafts.map(\.characterId),
                onPick: { profile in
                    vm.addCharacter(profile)
                    showCharacterPicker = false
                }
            )
            .viukAdaptiveSheetSizing(minWidth: 480, minHeight: 600)
        }
        .sheet(isPresented: $showCharacterCreator) {
            CharacterCreateView { profile in
                vm.addCharacter(profile)
                showCharacterCreator = false
            }
            .viukAdaptiveSheetSizing(minWidth: 560, minHeight: 720)
        }
    }

    private var header: some View {
        HStack {
            Button("キャンセル") { dismiss() }.buttonStyle(.plain).foregroundStyle(.secondary)
            Spacer()
            Text(existing == nil ? "ストーリーを作る" : "ストーリーを編集")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            if existing == nil {
                Label("31B Thinking", systemImage: "sparkles")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            } else {
                Color.clear.frame(width: 60)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.thinMaterial)
    }

    private var footer: some View {
        HStack {
            if existing == nil {
                Button {
                    Task {
                        if let saved = await vm.save() {
                            onSaved?(saved)
                            onStartSession?(saved)
                            dismiss()
                        }
                    }
                } label: {
                    Label("保存して試す", systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
            }
            Spacer()
            Button("保存") {
                Task {
                    if let saved = await vm.save() {
                        onSaved?(saved)
                        dismiss()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.thinMaterial)
    }

    private var aiTemplateSection: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("何を作りたい？")
                            .font(.system(size: 18, weight: .heavy))
                        Text("短い一文から、世界観・初期シーン・キャラ・ルールまで自動で組み立てます。")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if vm.isGeneratingTemplate {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                TextField("例: BL系。弓道部の無口な先輩と、放課後に少しずつ距離が近づく話", text: $vm.generationBrief, axis: .vertical)
                    .font(.system(size: 16, weight: .semibold))
                    .textFieldStyle(.plain)
                    .focused($generationBriefFocused)
                    .lineLimit(3...7)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.appSecondaryBackground.opacity(0.82))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.38), lineWidth: 1)
                    }

                quickPromptChips

                if vm.isGeneratingTemplate || vm.generationStatus != nil || vm.saveError != nil {
                    generationStatusBanner
                }

                HStack(spacing: 10) {
                    Button {
                        generationBriefFocused = false
                        Task { await vm.generateTemplateWith31BThinking() }
                    } label: {
                        Label(vm.isGeneratingTemplate ? "生成中" : "31B Thinkingでテンプレート作成", systemImage: "sparkles")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(vm.isGeneratingTemplate || vm.generationBrief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Spacer()
                }
            }
        }
    }

    private var generationStatusBanner: some View {
        HStack(alignment: .top, spacing: 9) {
            if vm.isGeneratingTemplate {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 1)
            } else {
                Image(systemName: vm.saveError == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(vm.saveError == nil ? .green : .orange)
            }
            Text(vm.saveError ?? vm.generationStatus ?? "生成中...")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(vm.saveError == nil ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill((vm.saveError == nil ? Color.accentColor : Color.orange).opacity(0.10))
        )
    }

    private var creatorHero: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.18, green: 0.21, blue: 0.30),
                            Color(red: 0.12, green: 0.12, blue: 0.15)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(minHeight: 150)
            VStack(alignment: .leading, spacing: 8) {
                Label("Custom Story Builder", systemImage: "wand.and.stars")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.72))
                Text("一文から、すぐ動く物語を作る")
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundStyle(.white)
                Text("生成後にキャラ画像、話し方、初期シーン、進行ルールをそのまま確認して試せます。")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.74))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(22)
        }
    }

    private var quickPromptChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                quickPromptButton("BL 部活") { "BL。放課後の部活で、無口な先輩と少しずつ信頼を深める青春ストーリー" }
                quickPromptButton("GL 寮生活") { "GL。女子寮の夜、同室の先輩と秘密を共有して距離が近づく日常ストーリー" }
                quickPromptButton("幻想図書館") { "夜だけ開く魔法図書館で、契約者と秘密の本を探すファンタジー" }
                quickPromptButton("夏祭り") { "BL。幼なじみと夏祭りで再会し、昔の約束を少しずつ思い出す話" }
            }
        }
    }

    private func quickPromptButton(_ title: String, prompt: @escaping () -> String) -> some View {
        Button {
            vm.generationBrief = prompt()
            generationBriefFocused = false
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
        .foregroundStyle(Color.accentColor)
    }

    private var generatedPreviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("生成プレビュー")
            if vm.draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text("31B Thinkingで作ると、ここにタイトル・キャスト・初期シーンが表示されます。")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.035)))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                    previewTile("タイトル", vm.draft.title, icon: "text.book.closed.fill")
                    previewTile("キャスト", "\(vm.castDrafts.count)人", icon: "person.2.fill")
                    previewTile("初期シーン", vm.sceneDraft.title.isEmpty ? "未設定" : vm.sceneDraft.title, icon: "sparkles.rectangle.stack")
                }
            }
        }
    }

    private func previewTile(_ title: String, _ value: String, icon: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.tertiary)
                Text(value)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.045)))
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11, weight: .bold))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }

    private func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { c() }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private var basicSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("基本情報")
            card {
                TextField("タイトル", text: $vm.draft.title).textFieldStyle(.roundedBorder)
                TextField("ひとこと説明", text: $vm.draft.shortDescription).textFieldStyle(.roundedBorder)

                HStack {
                    Text("ジャンル").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                    Menu {
                        ForEach(CategoryGroup.allCases) { g in
                            Menu(g.displayName) {
                                ForEach(CharacterCategory.allCases.filter { $0.group == g }) { c in
                                    Button(c.displayName) { vm.draft.genre = c }
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: vm.draft.genre.group.iconName).foregroundStyle(.tint)
                            Text(vm.draft.genre.displayName)
                            Image(systemName: "chevron.down").font(.system(size: 9))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.15)))
                    }
                    .menuStyle(.borderlessButton)
                }

                HStack {
                    Text("関係性").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                    Picker("", selection: $vm.draft.relationshipGenre) {
                        ForEach(RelationshipGenre.allCases) { g in Text(g.displayName).tag(g) }
                    }.labelsHidden().pickerStyle(.menu)
                }

                HStack {
                    Text("公開状態").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                    Picker("", selection: $vm.draft.visibility) {
                        ForEach(CharacterVisibility.allCases) { v in Label(v.displayName, systemImage: v.iconName).tag(v) }
                    }.labelsHidden().pickerStyle(.menu)
                }
            }
        }
    }

    private var settingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("世界観 & 物語")
            card {
                multilineField("世界観", $vm.draft.worldSetting, hint: "例: 平凡な現代の高校に魔法が存在する世界")
                multilineField("ユーザーの役", $vm.draft.userRole, hint: "例: 新しく転校してきた生徒")
                multilineField("オープニングシーン", $vm.draft.openingScene, hint: "物語の幕開け。最初のナレーション。")
                multilineField("物語の目標", $vm.draft.storyGoal, hint: "例: 卒業までに気持ちを伝える")
                TextField("ムード (例: 切ない、爽やか、緊張感)", text: $vm.draft.mood).textFieldStyle(.roundedBorder)
            }
        }
    }

    private var openingSceneSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("初期シーン")
            card {
                TextField("シーン名", text: $vm.sceneDraft.title)
                    .textFieldStyle(.roundedBorder)
                TextField("場所 (例: 閉鎖された記憶駅)", text: $vm.sceneDraft.location)
                    .textFieldStyle(.roundedBorder)
                TextField("時間 (例: 深夜 / 放課後 / 雨上がり)", text: $vm.sceneDraft.timeOfDay)
                    .textFieldStyle(.roundedBorder)
                TextField("空気 (例: 静かで透明な不安)", text: $vm.sceneDraft.mood)
                    .textFieldStyle(.roundedBorder)
                multilineField("このシーンの目的", $vm.sceneDraft.sceneGoal, hint: "例: ノアがユーザーに最初の違和感を伝える")
                multilineField("葛藤", Binding(
                    get: { vm.sceneDraft.conflict ?? "" },
                    set: { vm.sceneDraft.conflict = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                ), hint: "例: 端末は真実を示すが、ノアはそれを隠したがっている")
                multilineField("ここまでの要約 / 初期状況", $vm.sceneDraft.summary, hint: "最初の会話前に共有しておく状況")
            }
        }
    }

    private var castSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionTitle("登場キャラ")
                Spacer()
                Button {
                    showCharacterCreator = true
                } label: {
                    Label("作る", systemImage: "person.crop.circle.badge.plus")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.bordered)
                Button {
                    showCharacterPicker = true
                } label: {
                    Label("選ぶ", systemImage: "plus").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.bordered)
            }
            card {
                if vm.castDrafts.isEmpty {
                    Text("キャラを作るか選ぶと、物語の登場人物として参加します。最初の 1 名はメインキャラとして登録されます。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(vm.castDrafts) { member in
                        if let profile = vm.availableCharacters.first(where: { $0.id == member.characterId }) {
                            castRow(member: member, profile: profile)
                        }
                    }
                }
            }
        }
    }

    private func castRow(member: CastMember, profile: CharacterProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                characterAvatar(profile, size: 34)
                Image(systemName: member.roleInStory.iconName).foregroundStyle(.tint)
                Text(profile.displayName.isEmpty ? profile.name : profile.displayName)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Menu {
                    ForEach(CastRole.allCases, id: \.self) { r in
                        Button(r.displayName) { vm.setRole(r, for: member.characterId) }
                    }
                } label: {
                    Text(member.roleInStory.displayName).font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        .foregroundStyle(Color.accentColor)
                }
                .menuStyle(.borderlessButton)

                Button(role: .destructive) {
                    vm.removeCharacter(characterID: member.characterId)
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            if !profile.shortDescription.isEmpty {
                Text(profile.shortDescription).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 8) {
                Toggle("初期シーンに出す", isOn: Binding(
                    get: { vm.sceneDraft.activeCharacterIds.contains(member.characterId) },
                    set: { vm.setActiveInOpeningScene($0, for: member.characterId) }
                ))
                .font(.system(size: 11, weight: .medium))

                Menu {
                    ForEach(IntroductionTiming.allCases, id: \.self) { timing in
                        Button(timing.displayName) {
                            vm.setIntroductionTiming(timing, for: member.characterId)
                        }
                    }
                } label: {
                    Label(member.introductionTiming.displayName, systemImage: "clock")
                        .font(.system(size: 10, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
            }
            TextField("この物語でのユーザーとの関係", text: Binding(
                get: { member.relationshipToUser },
                set: { vm.setStoryRelationshipToUser($0, for: member.characterId) }
            ))
            .textFieldStyle(.roundedBorder)
            HStack(spacing: 6) {
                Text("重要度").font(.system(size: 10)).foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { member.importance },
                    set: { vm.setImportance($0, for: member.characterId) }
                ), in: 0...1)
                Text(String(format: "%.1f", member.importance)).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
    }

    private var relationshipSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("キャラ同士の関係")
            card {
                let pairs = relationshipPairs
                if pairs.isEmpty {
                    Text("2人以上のキャラを追加すると、キャラ同士の関係を設定できます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pairs, id: \.id) { pair in
                        relationshipRow(pair)
                    }
                }
            }
        }
    }

    private var relationshipPairs: [StoryRelationshipPair] {
        var out: [StoryRelationshipPair] = []
        for from in vm.castDrafts {
            for to in vm.castDrafts where from.characterId != to.characterId {
                guard let fromProfile = vm.availableCharacters.first(where: { $0.id == from.characterId }),
                      let toProfile = vm.availableCharacters.first(where: { $0.id == to.characterId }) else { continue }
                out.append(StoryRelationshipPair(from: from, to: to, fromProfile: fromProfile, toProfile: toProfile))
            }
        }
        return out
    }

    private func relationshipRow(_ pair: StoryRelationshipPair) -> some View {
        let rel = vm.relationship(from: pair.from.characterId, to: pair.to.characterId)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                characterAvatar(pair.fromProfile, size: 24)
                Text(pair.fromName)
                    .font(.system(size: 12, weight: .bold))
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                characterAvatar(pair.toProfile, size: 24)
                Text(pair.toName)
                    .font(.system(size: 12, weight: .bold))
                Spacer()
                Picker("", selection: Binding(
                    get: { rel.relationshipType },
                    set: { vm.updateRelationship(from: pair.from.characterId, to: pair.to.characterId, type: $0) }
                )) {
                    ForEach(RelationshipType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            TextField("関係メモ (例: 古い相棒だが、互いに秘密を持っている)", text: Binding(
                get: { rel.description },
                set: { vm.updateRelationship(from: pair.from.characterId, to: pair.to.characterId, description: $0) }
            ))
            .textFieldStyle(.roundedBorder)
            HStack(spacing: 10) {
                Text("信頼")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { rel.trust },
                    set: { vm.updateRelationship(from: pair.from.characterId, to: pair.to.characterId, trust: $0) }
                ), in: 0...1)
                Text(String(format: "%.1f", rel.trust))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("緊張")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { rel.tension },
                    set: { vm.updateRelationship(from: pair.from.characterId, to: pair.to.characterId, tension: $0) }
                ), in: 0...1)
                Text(String(format: "%.1f", rel.tension))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
    }

    @ViewBuilder
    private func characterAvatar(_ profile: CharacterProfile, size: CGFloat) -> some View {
        if let data = profile.avatarImageData, let image = storyPlatformImage(from: data) {
            Image(storyPlatformImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else if let key = profile.imageKey, !key.isEmpty {
            Image(key)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            let name = profile.displayName.isEmpty ? profile.name : profile.displayName
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.16))
                .frame(width: size, height: size)
                .overlay {
                    Text(String(name.prefix(1)).isEmpty ? "?" : String(name.prefix(1)))
                        .font(.system(size: max(11, size * 0.36), weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
        }
    }

    private func storyPlatformImage(from data: Data) -> StoryPlatformImage? {
        #if canImport(AppKit)
        return NSImage(data: data)
        #elseif canImport(UIKit)
        return UIImage(data: data)
        #else
        return nil
        #endif
    }

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("タグ")
            card {
                if !vm.draft.tags.isEmpty {
                    let columns = [GridItem(.adaptive(minimum: 90), spacing: 6)]
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                        ForEach(Array(vm.draft.tags.enumerated()), id: \.offset) { idx, t in
                            HStack(spacing: 4) {
                                Text(t).font(.system(size: 11))
                                Button { vm.draft.tags.remove(at: idx) } label: {
                                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                            .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                HStack {
                    TextField("タグを追加", text: $newTag).textFieldStyle(.roundedBorder)
                        .onSubmit { addTag() }
                    Button("追加") { addTag() }.buttonStyle(.bordered)
                        .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func addTag() {
        let t = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !vm.draft.tags.contains(t) else { return }
        vm.draft.tags.append(t)
        newTag = ""
    }

    private func multilineField(_ label: String, _ binding: Binding<String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            TextField(hint, text: binding, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
        }
    }
}

// MARK: - Character picker for story

private struct CharacterPickerForStory: View {
    let available: [CharacterProfile]
    let excluded: [UUID]
    let onPick: (CharacterProfile) -> Void
    @Environment(\.dismiss) private var dismiss

    var filtered: [CharacterProfile] {
        let set = Set(excluded)
        return available.filter { !set.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("閉じる") { dismiss() }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Text("キャラを追加").font(.system(size: 14, weight: .semibold))
                Spacer()
                Color.clear.frame(width: 48)
            }
            .padding(.horizontal, 14).padding(.vertical, 12).background(.thinMaterial)
            Divider()
            if filtered.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.questionmark").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text("追加できるキャラがいません").font(.system(size: 13))
                    Text("先に「キャラライブラリー」でキャラを作ってください。").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(filtered) { c in
                            Button { onPick(c) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.displayName.isEmpty ? c.name : c.displayName)
                                        .font(.system(size: 13, weight: .semibold))
                                    Text(c.category.displayName + " ・ " + c.relationshipGenre.displayName)
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                    if !c.shortDescription.isEmpty {
                                        Text(c.shortDescription).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(2)
                                    }
                                }
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .background(Color.appCanvasBackground.ignoresSafeArea())
    }
}

private struct StoryRelationshipPair: Identifiable {
    let from: CastMember
    let to: CastMember
    let fromProfile: CharacterProfile
    let toProfile: CharacterProfile

    var id: String {
        from.characterId.uuidString + "->" + to.characterId.uuidString
    }

    var fromName: String {
        fromProfile.displayName.isEmpty ? fromProfile.name : fromProfile.displayName
    }

    var toName: String {
        toProfile.displayName.isEmpty ? toProfile.name : toProfile.displayName
    }
}
