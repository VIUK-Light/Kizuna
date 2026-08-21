/*
仕様:
- 役割: キャラクターの新規作成/編集 UI。SafetyPipeline.evaluateCharacter を経由して保存。
- 主な型: `CharacterCreateView`.
- 編集ポイント: フィールド追加、テンプレ適用、安全判定 UI フィードバック。
*/

import SwiftUI
import PhotosUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
private typealias CharacterCreatePlatformImage = NSImage
#elseif canImport(UIKit)
private typealias CharacterCreatePlatformImage = UIImage
#endif

private extension Image {
    init(characterCreatePlatformImage: CharacterCreatePlatformImage) {
        #if canImport(AppKit)
        self.init(nsImage: characterCreatePlatformImage)
        #elseif canImport(UIKit)
        self.init(uiImage: characterCreatePlatformImage)
        #else
        self.init(systemName: "person.crop.square")
        #endif
    }
}

private enum CharacterAvatarLoadError: Error {
    case missingData
    case unsupportedImage
}

struct CharacterCreateView: View {
    /// 既存編集モード時に渡す。
    var existing: CharacterProfile? = nil
    /// テンプレを使った新規作成の場合に渡す。
    var template: CharacterTemplate? = nil
    var onSaved: ((CharacterProfile) -> Void)?

    @StateObject private var vm: CharacterCreateViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var newTagText = ""
    @State private var newRuleText = ""
    @State private var newSafetyRuleText = ""
    @State private var selectedAvatarItem: PhotosPickerItem?
    /// PhotosPickerの選択ごとに世代を進める。古いloadTransferableが遅れて
    /// 完了しても、新しい画像を上書きしない。
    @State private var avatarLoadGeneration = 0
    @State private var isLoadingAvatar = false
    @State private var avatarLoadError: String?
    /// The draft captured after the editor's initial template (if any) is
    /// applied. Keeping a value snapshot makes every editable field,
    /// including tags, rules, and the avatar, participate in dirty tracking.
    @State private var initialDraft: CharacterProfile?
    @State private var isShowingDiscardConfirmation = false
    @State private var pendingTemplate: CharacterTemplate?

    init(
        existing: CharacterProfile? = nil,
        template: CharacterTemplate? = nil,
        onSaved: ((CharacterProfile) -> Void)? = nil
    ) {
        self.existing = existing
        self.template = template
        self.onSaved = onSaved
        _vm = StateObject(wrappedValue: CharacterCreateViewModel(existing: existing))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if vm.availableTemplates.isEmpty == false && existing == nil {
                        templateSection
                    }
                    avatarSection
                    taxonomySection
                    identitySection
                    personaSection
                    sceneSection
                    tagsSection
                    rulesSection
                    safetyRulesSection
                    visibilitySection
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .disabled(isFormLocked)
            Divider()
            footer
        }
        .background(Color.appCanvasBackground.ignoresSafeArea())
        // SwiftUI does not expose an "interactive dismiss attempted" callback
        // on all supported platforms. Blocking the gesture while dirty avoids
        // silently losing the form; the Cancel button provides the explicit
        // discard confirmation.
        .interactiveDismissDisabled(isFormLocked || isDirty)
        .task {
            // 親画面から渡されたテンプレートは同期的に先に適用する。
            // テンプレート一覧のI/Oを待ってから適用すると、その待機中に
            // ユーザーが編集したフォームを後からテンプレートで上書きしてしまう。
            if initialDraft == nil {
                if let t = template { vm.applyTemplate(t) }
                initialDraft = vm.draft
            }
            await vm.loadTemplates()
        }
        .alert(
            KizunaCopy.text(japanese: "確認が必要です", english: "Review required"),
            isPresented: warnAlertBinding
        ) {
            Button(KizunaCopy.text(japanese: "修正に戻る", english: "Edit"), role: .cancel) { vm.resetState() }
            Button(KizunaCopy.text(japanese: "このまま保存", english: "Save anyway")) {
                Task { await vm.attemptSave(force: true) }
            }
        } message: {
            if case let .warned(decision) = vm.state {
                Text(decision.localizedReasons.joined(separator: "\n"))
            }
        }
        .alert(
            KizunaCopy.text(japanese: "保存できません", english: "Cannot save"),
            isPresented: blockedAlertBinding
        ) {
            Button(KizunaCopy.text(japanese: "修正に戻る", english: "Edit"), role: .cancel) { vm.resetState() }
        } message: {
            if case let .blocked(decision) = vm.state {
                Text(decision.localizedReasons.joined(separator: "\n"))
            }
        }
        .alert(
            KizunaCopy.text(japanese: "変更を破棄しますか？", english: "Discard changes?"),
            isPresented: $isShowingDiscardConfirmation
        ) {
            Button(KizunaCopy.text(japanese: "編集を続ける", english: "Keep editing"), role: .cancel) { }
            Button(KizunaCopy.text(japanese: "破棄して閉じる", english: "Discard and close"), role: .destructive) {
                dismiss()
            }
        } message: {
            Text(KizunaCopy.text(
                japanese: "保存していない入力は失われます。",
                english: "Your unsaved changes will be lost."
            ))
        }
        .alert(
            KizunaCopy.text(japanese: "テンプレートを適用しますか？", english: "Apply template?"),
            isPresented: pendingTemplateAlertBinding
        ) {
            Button(KizunaCopy.text(japanese: "キャンセル", english: "Cancel"), role: .cancel) {
                pendingTemplate = nil
            }
            Button(KizunaCopy.text(japanese: "適用", english: "Apply")) {
                if let pendingTemplate {
                    vm.applyTemplate(pendingTemplate)
                }
                self.pendingTemplate = nil
            }
        } message: {
            Text(
                KizunaCopy.text(
                    japanese: "現在の入力を「\(pendingTemplate?.displayName ?? "このテンプレート")」で置き換えます。",
                    english: "This will replace the current draft with “\(pendingTemplate?.displayName ?? "this template")”."
                )
            )
        }
        .onChange(of: vm.state) { _, new in
            if case let .saved(c) = new {
                initialDraft = c
                onSaved?(c)
                dismiss()
            }
        }
        .onDisappear {
            // A parent may dismiss the sheet programmatically. Invalidate any
            // in-flight safety task so it cannot persist after this editor is
            // gone. Interactive dismissal and the header button are blocked
            // while validation is active, but this is the final race guard.
            vm.cancelPendingSave()
            avatarLoadGeneration &+= 1
            isLoadingAvatar = false
        }
        .onChange(of: selectedAvatarItem) { _, item in
            avatarLoadGeneration &+= 1
            let generation = avatarLoadGeneration
            Task { await loadAvatar(from: item, generation: generation) }
        }
    }

    // MARK: - Header / Footer

    @ViewBuilder
    private var header: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button(KizunaCopy.text(japanese: "キャンセル", english: "Cancel")) { requestDismiss() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(isFormLocked)
                    Spacer()
                }
                Text(existing == nil
                     ? KizunaCopy.text(japanese: "キャラを作る", english: "Create character")
                     : KizunaCopy.text(japanese: "キャラを編集", english: "Edit character"))
                    .font(.system(size: 15, weight: .semibold))
            }
        } else {
            HStack {
                Button(KizunaCopy.text(japanese: "キャンセル", english: "Cancel")) { requestDismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(isFormLocked)
                Spacer()
                Text(existing == nil
                     ? KizunaCopy.text(japanese: "キャラを作る", english: "Create character")
                     : KizunaCopy.text(japanese: "キャラを編集", english: "Edit character"))
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Color.clear.frame(width: 80, height: 1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.thinMaterial)
    }

    private var footer: some View {
        HStack {
            if case .validating = vm.state {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(KizunaCopy.text(japanese: "安全性をチェック中…", english: "Checking safety…"))
                        .font(.system(size: 11))
                }
            }
            Spacer()
            Button(KizunaCopy.text(japanese: "保存", english: "Save")) {
                Task { await vm.attemptSave() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(canSave == false)
            .disabled(isFormLocked)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.thinMaterial)
    }

    private var canSave: Bool {
        !isLoadingAvatar
            && !vm.draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isFormLocked: Bool {
        if case .validating = vm.state { return true }
        return false
    }

    private var isDirty: Bool {
        guard let initialDraft else { return false }
        return vm.draft != initialDraft
    }

    private func requestDismiss() {
        guard !isFormLocked else { return }
        if isDirty {
            isShowingDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    private func selectTemplate(_ template: CharacterTemplate) {
        if isDirty {
            pendingTemplate = template
        } else {
            vm.applyTemplate(template)
        }
    }

    // MARK: - Sections

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11, weight: .bold))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }

    private var templateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(KizunaCopy.text(japanese: "テンプレ", english: "Templates"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(vm.availableTemplates) { t in
                        Button {
                            selectTemplate(t)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Image(systemName: t.category.group.iconName)
                                    .foregroundStyle(.tint)
                                Text(t.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                Text(t.category.localizedDisplayName)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .frame(width: 150, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.10))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.accentColor.opacity(0.30), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var taxonomySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(KizunaCopy.text(japanese: "ジャンル", english: "Genre"))
            card {
                labeledField(KizunaCopy.text(japanese: "カテゴリー", english: "Category")) {
                    categoryMenu
                }
                labeledField(KizunaCopy.text(japanese: "関係性", english: "Relationship")) {
                    Picker("", selection: $vm.draft.relationshipGenre) {
                        ForEach(RelationshipGenre.allCases) { g in
                            Text(g.localizedDisplayName).tag(g)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }
        }
    }

    private var avatarSection: some View {
        let hasAvatar = vm.draft.avatarImageData != nil
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle(KizunaCopy.text(japanese: "画像", english: "Image"))
            card {
                HStack(alignment: .center, spacing: 14) {
                    characterAvatarPreview
                    VStack(alignment: .leading, spacing: 8) {
                        PhotosPicker(selection: $selectedAvatarItem, matching: .images) {
                            Label(
                                hasAvatar
                                    ? KizunaCopy.text(japanese: "画像を変更", english: "Change image")
                                    : KizunaCopy.text(japanese: "画像を入れる", english: "Add image"),
                                systemImage: "photo"
                            )
                        }
                        .buttonStyle(.bordered)

                        if isLoadingAvatar {
                            Label(
                                KizunaCopy.text(japanese: "画像を読み込み中…", english: "Loading image…"),
                                systemImage: "arrow.triangle.2.circlepath"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        if let avatarLoadError {
                            Text(avatarLoadError)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if hasAvatar {
                            Button(role: .destructive) {
                                removeAvatar()
                            } label: {
                                Label(KizunaCopy.text(japanese: "画像を削除", english: "Remove image"), systemImage: "trash")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private var characterAvatarPreview: some View {
        if let data = vm.draft.avatarImageData, let image = platformImage(from: data) {
            Image(characterCreatePlatformImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.35), Color.primary.opacity(0.10)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 76, height: 76)
                .overlay {
                    Image(systemName: "person.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                }
        }
    }

    private var categoryMenu: some View {
        Menu {
            ForEach(CategoryGroup.allCases) { g in
                Menu(g.localizedDisplayName) {
                    ForEach(CharacterCategory.allCases.filter { $0.group == g }) { c in
                        Button(c.localizedDisplayName) { vm.draft.category = c }
                    }
                }
            }
        } label: {
            HStack {
                Image(systemName: vm.draft.category.group.iconName)
                    .foregroundStyle(.tint)
                Text(vm.draft.category.localizedDisplayName)
                Spacer()
                Image(systemName: "chevron.down").font(.system(size: 10))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.15)))
        }
        .menuStyle(.borderlessButton)
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(KizunaCopy.text(japanese: "基本情報", english: "Basic information"))
            card {
                labeledField(KizunaCopy.text(japanese: "名前", english: "Name")) {
                    TextField(KizunaCopy.text(japanese: "例: アオイ", english: "e.g. Aoi"), text: $vm.draft.name)
                        .textFieldStyle(.roundedBorder)
                }
                labeledField(KizunaCopy.text(japanese: "表示名", english: "Display name")) {
                    TextField(KizunaCopy.text(japanese: "空欄なら名前を使う", english: "Leave blank to use the name"), text: $vm.draft.displayName)
                        .textFieldStyle(.roundedBorder)
                }
                labeledField(KizunaCopy.text(japanese: "ひとこと説明", english: "Short description")) {
                    TextField(KizunaCopy.text(japanese: "例: 落ち着いた幼なじみ", english: "e.g. A calm childhood friend"), text: $vm.draft.shortDescription)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var personaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(KizunaCopy.text(japanese: "人物像", english: "Character"))
            card {
                multilineField(KizunaCopy.text(japanese: "性格", english: "Personality"), $vm.draft.personality,
                               hint: KizunaCopy.text(japanese: "例: 落ち着いていて聞き上手。少し天然。", english: "e.g. Calm, a good listener, and a little absent-minded."))
                multilineField(KizunaCopy.text(japanese: "口調", english: "Speaking style"), $vm.draft.speakingStyle,
                               hint: KizunaCopy.text(japanese: "例: 柔らかく、少し甘い。", english: "e.g. Gentle and a little sweet."))
                multilineField(KizunaCopy.text(japanese: "背景", english: "Background"), $vm.draft.background,
                               hint: KizunaCopy.text(japanese: "例: 大学生。バイトで知り合った。", english: "e.g. A university student you met at a part-time job."))
                multilineField(KizunaCopy.text(japanese: "相手との関係", english: "Relationship to user"), $vm.draft.relationshipToUser,
                               hint: KizunaCopy.text(japanese: "例: 幼なじみ。最近距離が近い。", english: "e.g. Childhood friends who have grown closer recently."))
            }
        }
    }

    private var sceneSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(KizunaCopy.text(japanese: "シーンと初回メッセージ", english: "Scene and first message"))
            card {
                multilineField(KizunaCopy.text(japanese: "シナリオ", english: "Scenario"), $vm.draft.scenario,
                               hint: KizunaCopy.text(japanese: "例: 放課後、雨の教室で二人きり。", english: "e.g. Alone together in a classroom after school while it rains."))
                multilineField(KizunaCopy.text(japanese: "初回メッセージ", english: "First message"), $vm.draft.firstMessage,
                               hint: KizunaCopy.text(japanese: "ユーザーへの最初の一言。", english: "The character's opening line to the user."))
            }
        }
    }

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(KizunaCopy.text(japanese: "タグ", english: "Tags"))
            card {
                if !vm.draft.tags.isEmpty {
                    chipList(vm.draft.tags, accent: .accentColor) { idx in
                        vm.draft.tags.remove(at: idx)
                    }
                }
                HStack {
                    TextField(KizunaCopy.text(japanese: "タグを追加 (Enter で確定)", english: "Add a tag (press Enter to commit)"), text: $newTagText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitTag() }
                    Button(KizunaCopy.text(japanese: "追加", english: "Add")) { commitTag() }
                        .buttonStyle(.bordered)
                        .disabled(newTagText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func commitTag() {
        let t = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !vm.draft.tags.contains(t) else { return }
        vm.draft.tags.append(t)
        newTagText = ""
    }

    /// Invalidate an in-flight PhotosPicker load before removing the preview.
    /// `loadTransferable` may still resume after the user taps remove; the
    /// generation check in `loadAvatar` must therefore advance for this path
    /// too, otherwise the removed image can reappear when the old load wins.
    private func removeAvatar() {
        avatarLoadGeneration &+= 1
        selectedAvatarItem = nil
        isLoadingAvatar = false
        avatarLoadError = nil
        vm.draft.avatarImageData = nil
    }

    @MainActor
    private func loadAvatar(from item: PhotosPickerItem?, generation: Int) async {
        guard let item else {
            isLoadingAvatar = false
            avatarLoadError = nil
            return
        }

        isLoadingAvatar = true
        avatarLoadError = nil

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw CharacterAvatarLoadError.missingData
            }
            let normalized = await Task.detached(priority: .userInitiated) {
                KizunaAvatarImage.normalizedData(from: data)
            }.value
            guard generation == avatarLoadGeneration else { return }
            guard let normalized else {
                throw CharacterAvatarLoadError.unsupportedImage
            }
            vm.draft.avatarImageData = normalized
            isLoadingAvatar = false
        } catch {
            guard generation == avatarLoadGeneration else { return }
            isLoadingAvatar = false
            avatarLoadError = KizunaCopy.text(
                japanese: "画像を読み込めませんでした。別の画像を選ぶか、画像を削除してください。",
                english: "We couldn't load that image. Choose another image or remove it."
            )
            AppLog.error("[CharacterCreateView] avatar load failed: %@", error.localizedDescription)
        }
    }

    private func platformImage(from data: Data) -> CharacterCreatePlatformImage? {
        #if canImport(AppKit)
        return NSImage(data: data)
        #elseif canImport(UIKit)
        return UIImage(data: data)
        #else
        return nil
        #endif
    }

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(KizunaCopy.text(japanese: "会話ルール (任意)", english: "Conversation rules (optional)"))
            card {
                if !vm.draft.rules.isEmpty {
                    chipList(vm.draft.rules, accent: .blue) { idx in
                        vm.draft.rules.remove(at: idx)
                    }
                }
                HStack {
                    TextField(KizunaCopy.text(japanese: "ルールを追加", english: "Add a conversation rule"), text: $newRuleText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitRule() }
                    Button(KizunaCopy.text(japanese: "追加", english: "Add")) { commitRule() }
                        .buttonStyle(.bordered)
                        .disabled(newRuleText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func commitRule() {
        let t = newRuleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty,
              !vm.draft.rules.contains(where: { normalizedRule($0) == normalizedRule(t) }) else { return }
        vm.draft.rules.append(t)
        newRuleText = ""
    }

    private var safetyRulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(KizunaCopy.text(japanese: "安全ルール (このキャラ専用)", english: "Safety rules (for this character)"))
            card {
                // 自動推奨ルール (group + genre + category)
                let recommended = (vm.draft.category.defaultSafetyRules
                                    + vm.draft.relationshipGenre.safetyRules)
                if !recommended.isEmpty {
                    Text(KizunaCopy.text(
                        japanese: "カテゴリー/関係性に基づき自動で適用される推奨ルール:",
                        english: "Recommended rules based on the category and relationship:"
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(Set(recommended)).sorted(), id: \.self) { r in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.green)
                            Text(SafetyReasonLocalization.localized(r))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                }
                if !vm.draft.safetyRules.isEmpty {
                    chipList(vm.draft.safetyRules, accent: .green) { idx in
                        vm.draft.safetyRules.remove(at: idx)
                    }
                }
                HStack {
                    TextField(KizunaCopy.text(japanese: "追加の安全ルール", english: "Add a safety rule"), text: $newSafetyRuleText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitSafetyRule() }
                    Button(KizunaCopy.text(japanese: "追加", english: "Add")) { commitSafetyRule() }
                        .buttonStyle(.bordered)
                        .disabled(newSafetyRuleText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func commitSafetyRule() {
        let t = newSafetyRuleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty,
              !vm.draft.safetyRules.contains(where: { normalizedRule($0) == normalizedRule(t) }) else { return }
        vm.draft.safetyRules.append(t)
        newSafetyRuleText = ""
    }

    /// 余分な空白や大文字小文字だけが違うルールを同一視する。
    /// 保存済みの旧データはそのまま表示できるが、新規登録では重複を増やさない。
    private func normalizedRule(_ value: String) -> String {
        value
            .precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private var visibilitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(KizunaCopy.text(japanese: "公開設定", english: "Visibility"))
            card {
                labeledField(KizunaCopy.text(japanese: "公開状態", english: "Visibility")) {
                    Picker("", selection: $vm.draft.visibility) {
                        ForEach(CharacterVisibility.allCases) { v in
                            Label(v.localizedDisplayName, systemImage: v.iconName).tag(v)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                labeledField(KizunaCopy.text(japanese: "安全レーティング", english: "Safety rating")) {
                    Picker("", selection: $vm.draft.safetyRating) {
                        ForEach(SafetyRating.allCases) { r in
                            Label(r.localizedDisplayName, systemImage: r.iconName).tag(r)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }
        }
    }

    // MARK: - Reusable

    @ViewBuilder
    private func labeledField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(alignment: .center, spacing: 12) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func multilineField(_ label: String, _ binding: Binding<String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField(hint, text: binding, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
        }
    }

    private func chipList(_ items: [String], accent: Color, onRemove: @escaping (Int) -> Void) -> some View {
        let columns = [GridItem(.adaptive(minimum: 100), spacing: 6)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, t in
                HStack(spacing: 4) {
                    Text(t)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Button { onRemove(idx) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel(
                        KizunaCopy.text(japanese: "(t)を削除", english: "Remove (t)")
                    )
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(accent.opacity(0.12)))
                .foregroundStyle(accent)
            }
        }
    }

    // MARK: - Alert bindings

    private var warnAlertBinding: Binding<Bool> {
        Binding(
            get: { if case .warned = vm.state { return true } else { return false } },
            set: { if !$0 { vm.resetState() } }
        )
    }
    private var blockedAlertBinding: Binding<Bool> {
        Binding(
            get: { if case .blocked = vm.state { return true } else { return false } },
            set: { if !$0 { vm.resetState() } }
        )
    }

    private var pendingTemplateAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingTemplate != nil },
            set: { if !$0 { pendingTemplate = nil } }
        )
    }
}
