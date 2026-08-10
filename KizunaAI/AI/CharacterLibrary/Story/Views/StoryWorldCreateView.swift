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
    // Lorebook入力は物語作成画面に集約し、独立キャラ管理を増やさない。
    @State private var newLorebookTitle = ""
    @State private var newLorebookKeywords = ""
    @State private var newLorebookContent = ""
    @State private var showCharacterPicker = false
    @State private var showCharacterCreator = false
    @State private var showAdvancedSettings: Bool
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
        _showAdvancedSettings = State(initialValue: existing != nil)
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
                    advancedSettingsSection
                    if let err = vm.saveError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(18)
            }
            // 初期スナップショットの読込が終わる前に編集すると、完了後の
            // cast/lorebook/scene代入で入力を巻き戻すため、フォーム自体を
            // ロックする。キャンセルと再試行はヘッダー側で引き続き可能。
            .disabled(!vm.isReadyToSave || vm.isGeneratingTemplate || vm.isSaving)
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
            Button(KizunaCopy.text(japanese: "キャンセル", english: "Cancel")) {
                Task {
                    await vm.discardPendingGeneratedCharacters()
                    dismiss()
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            Spacer()
            Text(existing == nil
                 ? KizunaCopy.text(japanese: "ストーリーを作る", english: "Create a story")
                 : KizunaCopy.text(japanese: "ストーリーを編集", english: "Edit story"))
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            if existing == nil {
                Label(KizunaCopy.text(japanese: "31B Thinking", english: "31B Thinking"), systemImage: "sparkles")
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
                    Label(KizunaCopy.text(japanese: "保存して試す", english: "Save and try"), systemImage: "play.fill")
            }
            .buttonStyle(.bordered)
            .disabled(!vm.isReadyToSave || vm.isGeneratingTemplate || vm.isSaving)
            }
            Spacer()
            Button(KizunaCopy.text(japanese: "保存", english: "Save")) {
                Task {
                    if let saved = await vm.save() {
                        onSaved?(saved)
                        dismiss()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!vm.isReadyToSave || vm.isGeneratingTemplate)
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
                        Text(KizunaCopy.text(japanese: "何を作りたい？", english: "What would you like to make?"))
                            .font(.system(size: 18, weight: .heavy))
                        Text(KizunaCopy.text(
                            japanese: "短い一文から、世界観・初期シーン・キャラ・ルールまで自動で組み立てます。",
                            english: "Turn one short idea into a world, opening scene, cast, and rules."
                        ))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if vm.isGeneratingTemplate {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                TextField(KizunaCopy.text(
                    japanese: "例: BL系。弓道部の無口な先輩と、放課後に少しずつ距離が近づく話",
                    english: "e.g. A quiet archery club senior and a slow after-school connection"
                ), text: $vm.generationBrief, axis: .vertical)
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
                        Label(vm.isGeneratingTemplate
                              ? KizunaCopy.text(japanese: "生成中", english: "Generating")
                              : KizunaCopy.text(japanese: "31B Thinkingでテンプレート作成", english: "Build with 31B Thinking"), systemImage: "sparkles")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(vm.isGeneratingTemplate || vm.isSaving || vm.generationBrief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

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
            Text(vm.saveError ?? vm.generationStatus ?? KizunaCopy.text(japanese: "生成中…", english: "Generating…"))
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
                Label(KizunaCopy.text(japanese: "カスタムストーリービルダー", english: "Custom story builder"), systemImage: "wand.and.stars")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.72))
                Text(KizunaCopy.text(japanese: "一文から、すぐ動く物語を作る", english: "Build a playable story from one idea"))
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundStyle(.white)
                Text(KizunaCopy.text(
                    japanese: "生成後にキャラ画像、話し方、初期シーン、進行ルールをそのまま確認して試せます。",
                    english: "Review the cast art, voices, opening scene, and story rules before you play."
                ))
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
                quickPromptButton(KizunaCopy.text(japanese: "BL 部活", english: "BL · Club")) {
                    KizunaCopy.text(
                        japanese: "BL。放課後の部活で、無口な先輩と少しずつ信頼を深める青春ストーリー",
                        english: "BL. A coming-of-age story where a quiet senior and the new club member slowly build trust after school."
                    )
                }
                quickPromptButton(KizunaCopy.text(japanese: "GL 寮生活", english: "GL · Dorm")) {
                    KizunaCopy.text(
                        japanese: "GL。女子寮の夜、同室の先輩と秘密を共有して距離が近づく日常ストーリー",
                        english: "GL. A slice-of-life story where roommates in a girls' dorm share a secret late at night and grow closer."
                    )
                }
                quickPromptButton(KizunaCopy.text(japanese: "幻想図書館", english: "Fantasy library")) {
                    KizunaCopy.text(
                        japanese: "夜だけ開く魔法図書館で、契約者と秘密の本を探すファンタジー",
                        english: "A fantasy story about searching for a secret book with a contractor in a magic library that opens only at night."
                    )
                }
                quickPromptButton(KizunaCopy.text(japanese: "夏祭り", english: "Summer festival")) {
                    KizunaCopy.text(
                        japanese: "BL。幼なじみと夏祭りで再会し、昔の約束を少しずつ思い出す話",
                        english: "BL. Childhood friends reunite at a summer festival and slowly remember the promise they made long ago."
                    )
                }
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
            sectionTitle(KizunaCopy.text(japanese: "生成プレビュー", english: "Generation preview"))
            if vm.draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text(KizunaCopy.text(
                        japanese: "31B Thinkingで作ると、ここにタイトル・キャスト・初期シーンが表示されます。",
                        english: "Your title, cast, and opening scene will appear here after generation."
                    ))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.035)))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                    previewTile(KizunaCopy.text(japanese: "タイトル", english: "Title"), vm.draft.title, icon: "text.book.closed.fill")
                    previewTile(KizunaCopy.text(japanese: "キャスト", english: "Cast"), KizunaCopy.language == .english ? "\(vm.castDrafts.count)" : "\(vm.castDrafts.count)人", icon: "person.2.fill")
                    previewTile(KizunaCopy.text(japanese: "初期シーン", english: "Opening scene"), vm.sceneDraft.title.isEmpty ? KizunaCopy.text(japanese: "未設定", english: "Not set") : vm.sceneDraft.title, icon: "sparkles.rectangle.stack")
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
            sectionTitle(KizunaCopy.text(japanese: "基本情報", english: "Basics"))
            card {
                TextField(KizunaCopy.text(japanese: "タイトル", english: "Title"), text: $vm.draft.title).textFieldStyle(.roundedBorder)
                TextField(KizunaCopy.text(japanese: "ひとこと説明", english: "Short description"), text: $vm.draft.shortDescription).textFieldStyle(.roundedBorder)

                HStack {
                    Text(KizunaCopy.text(japanese: "ジャンル", english: "Genre")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                    Menu {
                        ForEach(CategoryGroup.allCases) { g in
                            Menu(g.localizedDisplayName) {
                                ForEach(CharacterCategory.allCases.filter { $0.group == g }) { c in
                                    Button(c.localizedDisplayName) { vm.draft.genre = c }
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: vm.draft.genre.group.iconName).foregroundStyle(.tint)
                            Text(vm.draft.genre.localizedDisplayName)
                            Image(systemName: "chevron.down").font(.system(size: 9))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.15)))
                    }
                    .menuStyle(.borderlessButton)
                }

                HStack {
                    Text(KizunaCopy.text(japanese: "関係性", english: "Relationship")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                    Picker("", selection: $vm.draft.relationshipGenre) {
                        ForEach(RelationshipGenre.allCases) { g in Text(g.localizedDisplayName).tag(g) }
                    }.labelsHidden().pickerStyle(.menu)
                }

                HStack(alignment: .top) {
                    Text(KizunaCopy.text(japanese: "物語形式", english: "Story format")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                    Picker(
                        "",
                        selection: Binding(
                            get: { vm.draft.resolvedCastMode },
                            set: { vm.setCastMode($0) }
                        )
                    ) {
                        ForEach(StoryCastMode.allCases) { mode in
                            Text(mode.localizedDisplayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vm.draft.resolvedCastMode.localizedDetail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text(KizunaCopy.text(japanese: "公開状態", english: "Visibility")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                    Picker("", selection: $vm.draft.visibility) {
                        ForEach(CharacterVisibility.allCases) { v in Label(v.localizedDisplayName, systemImage: v.iconName).tag(v) }
                    }.labelsHidden().pickerStyle(.menu)
                }
            }
        }
    }

    // MARK: - Lorebook

    /// キーワードが出た時だけAIへ渡す設定カード。
    private var lorebookSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(KizunaCopy.text(japanese: "Lorebook / キーワード設定", english: "Lorebook / keyword rules"))
            card {
                Text(KizunaCopy.text(
                    japanese: "世界観・場所・秘密などを登録すると、関連する会話の時だけAIへ渡します。",
                    english: "World details, places, and secrets are sent to the model only when relevant."
                ))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField(KizunaCopy.text(japanese: "タイトル（例: 夜の図書館のルール）", english: "Title (e.g. rules for the night library)"), text: $newLorebookTitle)
                    .textFieldStyle(.roundedBorder)
                TextField(KizunaCopy.text(japanese: "キーワード（例: 図書館、禁書、夜）", english: "Keywords (e.g. library, forbidden book, night)"), text: $newLorebookKeywords)
                    .textFieldStyle(.roundedBorder)
                TextEditor(text: $newLorebookContent)
                    .frame(minHeight: 74)
                    .padding(6)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
                HStack {
                    Spacer()
                    Button {
                        vm.addLorebookEntry(
                            title: newLorebookTitle,
                            keywordsText: newLorebookKeywords,
                            content: newLorebookContent
                        )
                        newLorebookTitle = ""
                        newLorebookKeywords = ""
                        newLorebookContent = ""
                    } label: {
                        Label(KizunaCopy.text(japanese: "設定を追加", english: "Add rule"), systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .disabled(newLorebookTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newLorebookContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                ForEach(vm.lorebookDrafts) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.title).font(.system(size: 12, weight: .bold))
                            Text(entry.keywords.joined(separator: " / "))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(entry.content)
                                .font(.system(size: 11))
                                .lineLimit(3)
                        }
                        Spacer(minLength: 0)
                        Button {
                            vm.removeLorebookEntry(id: entry.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.035)))
                }
            }
        }
    }

    private var settingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(KizunaCopy.text(japanese: "世界観 & 物語", english: "World & story"))
            card {
                multilineField(KizunaCopy.text(japanese: "世界観", english: "World setting"), $vm.draft.worldSetting, hint: KizunaCopy.text(japanese: "例: 平凡な現代の高校に魔法が存在する世界", english: "e.g. a normal modern high school where magic exists"))
                multilineField(KizunaCopy.text(japanese: "ユーザーの役", english: "Your role"), $vm.draft.userRole, hint: KizunaCopy.text(japanese: "例: 新しく転校してきた生徒", english: "e.g. a new transfer student"))
                multilineField(KizunaCopy.text(japanese: "オープニングシーン", english: "Opening scene"), $vm.draft.openingScene, hint: KizunaCopy.text(japanese: "物語の幕開け。最初のナレーション。", english: "The opening narration for the story."))
                multilineField(KizunaCopy.text(japanese: "物語の目標", english: "Story goal"), $vm.draft.storyGoal, hint: KizunaCopy.text(japanese: "例: 卒業までに気持ちを伝える", english: "e.g. share your feelings before graduation"))
                TextField(KizunaCopy.text(japanese: "ムード (例: 切ない、爽やか、緊張感)", english: "Mood (e.g. tender, bright, tense)"), text: $vm.draft.mood).textFieldStyle(.roundedBorder)
            }
        }
    }

    private var openingSceneSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(KizunaCopy.text(japanese: "初期シーン", english: "Opening scene"))
            card {
                TextField(KizunaCopy.text(japanese: "シーン名", english: "Scene name"), text: $vm.sceneDraft.title)
                    .textFieldStyle(.roundedBorder)
                TextField(KizunaCopy.text(japanese: "場所 (例: 閉鎖された記憶駅)", english: "Location (e.g. an abandoned memory station)"), text: $vm.sceneDraft.location)
                    .textFieldStyle(.roundedBorder)
                TextField(KizunaCopy.text(japanese: "時間 (例: 深夜 / 放課後 / 雨上がり)", english: "Time (e.g. midnight / after school / after rain)"), text: $vm.sceneDraft.timeOfDay)
                    .textFieldStyle(.roundedBorder)
                TextField(KizunaCopy.text(japanese: "空気 (例: 静かで透明な不安)", english: "Mood (e.g. quiet, clear unease)"), text: $vm.sceneDraft.mood)
                    .textFieldStyle(.roundedBorder)
                multilineField(KizunaCopy.text(japanese: "このシーンの目的", english: "Scene goal"), $vm.sceneDraft.sceneGoal, hint: KizunaCopy.text(japanese: "例: ノアがユーザーに最初の違和感を伝える", english: "e.g. Noa shares the first unsettling clue"))
                multilineField(KizunaCopy.text(japanese: "葛藤", english: "Conflict"), Binding(
                    get: { vm.sceneDraft.conflict ?? "" },
                    set: { vm.sceneDraft.conflict = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                ), hint: KizunaCopy.text(japanese: "例: 端末は真実を示すが、ノアはそれを隠したがっている", english: "e.g. the device shows the truth, but Noa wants to hide it"))
                multilineField(KizunaCopy.text(japanese: "ここまでの要約 / 初期状況", english: "Summary / starting situation"), $vm.sceneDraft.summary, hint: KizunaCopy.text(japanese: "最初の会話前に共有しておく状況", english: "Context to share before the first exchange"))
            }
        }
    }

    private var castSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionTitle(KizunaCopy.text(japanese: "登場キャラ", english: "Cast"))
                Spacer()
                Button {
                    showCharacterCreator = true
                } label: {
                    Label(KizunaCopy.text(japanese: "作る", english: "Create"), systemImage: "person.crop.circle.badge.plus")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.bordered)
                Button {
                    showCharacterPicker = true
                } label: {
                    Label(KizunaCopy.text(japanese: "選ぶ", english: "Choose"), systemImage: "plus").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.bordered)
            }
            card {
                if vm.castDrafts.isEmpty {
                    Text(KizunaCopy.text(
                        japanese: "キャラを作るか選ぶと、物語の登場人物として参加します。最初の1名はメインキャラとして登録されます。",
                        english: "Create or choose characters to add them to the story. The first one becomes the main character."
                    ))
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

    private var advancedSettingsSection: some View {
        DisclosureGroup(isExpanded: $showAdvancedSettings) {
            VStack(alignment: .leading, spacing: 18) {
                lorebookSection
                relationshipSection
                tagsSection
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.accentColor.opacity(0.12)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(KizunaCopy.text(japanese: "詳細設定", english: "Advanced settings"))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text(KizunaCopy.text(japanese: "Lorebook・キャラ同士の関係・タグ（必要なときだけ）", english: "Lorebook, character relationships, and tags (optional)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .tint(.primary)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func castRow(member: CastMember, profile: CharacterProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                characterAvatar(profile, size: 34)
                Image(systemName: member.roleInStory.iconName).foregroundStyle(.tint)
                Text(profile.visibleName)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Menu {
                    ForEach(CastRole.allCases, id: \.self) { r in
                        Button(r.localizedDisplayName) { vm.setRole(r, for: member.characterId) }
                    }
                } label: {
                    Text(member.roleInStory.localizedDisplayName).font(.system(size: 10, weight: .semibold))
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
                Toggle(KizunaCopy.text(japanese: "初期シーンに出す", english: "Show in opening scene"), isOn: Binding(
                    get: { vm.sceneDraft.activeCharacterIds.contains(member.characterId) },
                    set: { vm.setActiveInOpeningScene($0, for: member.characterId) }
                ))
                .font(.system(size: 11, weight: .medium))

                Menu {
                    ForEach(IntroductionTiming.allCases, id: \.self) { timing in
                        Button(timing.localizedDisplayName) {
                            vm.setIntroductionTiming(timing, for: member.characterId)
                        }
                    }
                } label: {
                    Label(member.introductionTiming.localizedDisplayName, systemImage: "clock")
                        .font(.system(size: 10, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
            }
            TextField(KizunaCopy.text(japanese: "この物語でのユーザーとの関係", english: "Relationship to the user in this story"), text: Binding(
                get: { member.relationshipToUser },
                set: { vm.setStoryRelationshipToUser($0, for: member.characterId) }
            ))
            .textFieldStyle(.roundedBorder)
            HStack(spacing: 6) {
                Text(KizunaCopy.text(japanese: "重要度", english: "Importance")).font(.system(size: 10)).foregroundStyle(.secondary)
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
            sectionTitle(KizunaCopy.text(japanese: "キャラ同士の関係", english: "Character relationships"))
            card {
                let pairs = relationshipPairs
                if pairs.isEmpty {
                    Text(KizunaCopy.text(japanese: "2人以上のキャラを追加すると、キャラ同士の関係を設定できます。", english: "Add at least two characters to define their relationships."))
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
                        Text(type.localizedDisplayName).tag(type)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            TextField(KizunaCopy.text(japanese: "関係メモ (例: 古い相棒だが、互いに秘密を持っている)", english: "Relationship note (e.g. old partners with secrets)"), text: Binding(
                get: { rel.description },
                set: { vm.updateRelationship(from: pair.from.characterId, to: pair.to.characterId, description: $0) }
            ))
            .textFieldStyle(.roundedBorder)
            HStack(spacing: 10) {
                Text(KizunaCopy.text(japanese: "信頼", english: "Trust"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { rel.trust },
                    set: { vm.updateRelationship(from: pair.from.characterId, to: pair.to.characterId, trust: $0) }
                ), in: 0...1)
                Text(String(format: "%.1f", rel.trust))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(KizunaCopy.text(japanese: "緊張", english: "Tension"))
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
        } else if let key = profile.imageKey,
                  !key.isEmpty,
                  let image = storyPlatformImage(named: key) {
            Image(storyPlatformImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.16))
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: "person.fill")
                        .font(.system(size: max(16, size * 0.36), weight: .semibold))
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

    // 未登録の画像名をSwiftUIへ渡さず、イニシャルのフォールバックを使う。
    private func storyPlatformImage(named name: String) -> StoryPlatformImage? {
        #if canImport(AppKit)
        return NSImage(named: name)
        #elseif canImport(UIKit)
        return UIImage(named: name)
        #else
        return nil
        #endif
    }

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(KizunaCopy.text(japanese: "タグ", english: "Tags"))
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
                    TextField(KizunaCopy.text(japanese: "タグを追加", english: "Add a tag"), text: $newTag).textFieldStyle(.roundedBorder)
                        .onSubmit { addTag() }
                    Button(KizunaCopy.text(japanese: "追加", english: "Add")) { addTag() }.buttonStyle(.bordered)
                        .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func addTag() {
        let t = newTag
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .joined(separator: " ")
        let key = t.localizedLowercase
        guard !t.isEmpty,
              !vm.draft.tags.contains(where: {
                  $0.split(whereSeparator: { $0.isWhitespace })
                      .map(String.init)
                      .joined(separator: " ")
                      .localizedLowercase == key
              }) else { return }
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
                Button(KizunaCopy.text(japanese: "閉じる", english: "Close")) { dismiss() }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Text(KizunaCopy.text(japanese: "キャラを追加", english: "Add character")).font(.system(size: 14, weight: .semibold))
                Spacer()
                Color.clear.frame(width: 48)
            }
            .padding(.horizontal, 14).padding(.vertical, 12).background(.thinMaterial)
            Divider()
            if filtered.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.questionmark").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text(KizunaCopy.text(japanese: "追加できるキャラがいません", english: "No characters available")).font(.system(size: 13))
                    Text(KizunaCopy.text(japanese: "先に「キャラライブラリー」でキャラを作ってください。", english: "Create a character in the character library first.")).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(filtered) { c in
                            Button { onPick(c) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.visibleName)
                                        .font(.system(size: 13, weight: .semibold))
                                    Text(c.category.localizedDisplayName + KizunaCopy.text(japanese: " ・ ", english: " · ") + c.relationshipGenre.localizedDisplayName)
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
        fromProfile.visibleName
    }

    var toName: String {
        toProfile.visibleName
    }
}
