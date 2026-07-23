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

struct CharacterCreateView: View {
    /// 既存編集モード時に渡す。
    var existing: CharacterProfile? = nil
    /// テンプレを使った新規作成の場合に渡す。
    var template: CharacterTemplate? = nil
    var onSaved: ((CharacterProfile) -> Void)?

    @StateObject private var vm: CharacterCreateViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var newTagText = ""
    @State private var newRuleText = ""
    @State private var newSafetyRuleText = ""
    @State private var selectedAvatarItem: PhotosPickerItem?

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
            Divider()
            footer
        }
        .background(Color.appCanvasBackground.ignoresSafeArea())
        .task {
            await vm.loadTemplates()
            if let t = template { vm.applyTemplate(t) }
        }
        .alert("確認が必要です", isPresented: warnAlertBinding) {
            Button("修正に戻る", role: .cancel) { vm.resetState() }
            Button("このまま保存") {
                Task { await vm.attemptSave(force: true) }
            }
        } message: {
            if case let .warned(decision) = vm.state {
                Text(decision.reasons.joined(separator: "\n"))
            }
        }
        .alert("保存できません", isPresented: blockedAlertBinding) {
            Button("修正に戻る", role: .cancel) { vm.resetState() }
        } message: {
            if case let .blocked(decision) = vm.state {
                Text(decision.reasons.joined(separator: "\n"))
            }
        }
        .onChange(of: vm.state) { _, new in
            if case let .saved(c) = new {
                onSaved?(c)
                dismiss()
            }
        }
        .onChange(of: selectedAvatarItem) { _, item in
            Task { await loadAvatar(from: item) }
        }
    }

    // MARK: - Header / Footer

    private var header: some View {
        HStack {
            Button("キャンセル") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Spacer()
            Text(existing == nil ? "キャラを作る" : "キャラを編集")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Color.clear.frame(width: 80, height: 1)
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
                    Text("安全性をチェック中…").font(.system(size: 11))
                }
            }
            Spacer()
            Button("保存") {
                Task { await vm.attemptSave() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(canSave == false)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.thinMaterial)
    }

    private var canSave: Bool {
        !vm.draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            sectionTitle("テンプレ")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(vm.availableTemplates) { t in
                        Button {
                            vm.applyTemplate(t)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Image(systemName: t.category.group.iconName)
                                    .foregroundStyle(.tint)
                                Text(t.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                Text(t.category.displayName)
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
            sectionTitle("ジャンル")
            card {
                labeledField("カテゴリー") {
                    categoryMenu
                }
                labeledField("関係性") {
                    Picker("", selection: $vm.draft.relationshipGenre) {
                        ForEach(RelationshipGenre.allCases) { g in
                            Text(g.displayName).tag(g)
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
            sectionTitle("画像")
            card {
                HStack(alignment: .center, spacing: 14) {
                    characterAvatarPreview
                    VStack(alignment: .leading, spacing: 8) {
                        PhotosPicker(selection: $selectedAvatarItem, matching: .images) {
                            Label(hasAvatar ? "画像を変更" : "画像を入れる", systemImage: "photo")
                        }
                        .buttonStyle(.bordered)

                        if hasAvatar {
                            Button(role: .destructive) {
                                vm.draft.avatarImageData = nil
                            } label: {
                                Label("画像を削除", systemImage: "trash")
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
                Menu(g.displayName) {
                    ForEach(CharacterCategory.allCases.filter { $0.group == g }) { c in
                        Button(c.displayName) { vm.draft.category = c }
                    }
                }
            }
        } label: {
            HStack {
                Image(systemName: vm.draft.category.group.iconName)
                    .foregroundStyle(.tint)
                Text(vm.draft.category.displayName)
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
            sectionTitle("基本情報")
            card {
                labeledField("名前") {
                    TextField("例: アオイ", text: $vm.draft.name)
                        .textFieldStyle(.roundedBorder)
                }
                labeledField("表示名") {
                    TextField("空欄なら名前を使う", text: $vm.draft.displayName)
                        .textFieldStyle(.roundedBorder)
                }
                labeledField("ひとこと説明") {
                    TextField("例: 落ち着いた幼なじみ", text: $vm.draft.shortDescription)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var personaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("人物像")
            card {
                multilineField("性格", $vm.draft.personality, hint: "例: 落ち着いていて聞き上手。少し天然。")
                multilineField("口調", $vm.draft.speakingStyle, hint: "例: 柔らかく、少し甘い。")
                multilineField("背景", $vm.draft.background, hint: "例: 大学生。バイトで知り合った。")
                multilineField("相手との関係", $vm.draft.relationshipToUser, hint: "例: 幼なじみ。最近距離が近い。")
            }
        }
    }

    private var sceneSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("シーンと初回メッセージ")
            card {
                multilineField("シナリオ", $vm.draft.scenario, hint: "例: 放課後、雨の教室で二人きり。")
                multilineField("初回メッセージ", $vm.draft.firstMessage, hint: "ユーザーへの最初の一言。")
            }
        }
    }

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("タグ")
            card {
                if !vm.draft.tags.isEmpty {
                    chipList(vm.draft.tags, accent: .accentColor) { idx in
                        vm.draft.tags.remove(at: idx)
                    }
                }
                HStack {
                    TextField("タグを追加 (Enter で確定)", text: $newTagText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitTag() }
                    Button("追加") { commitTag() }
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

    @MainActor
    private func loadAvatar(from item: PhotosPickerItem?) async {
        guard let item,
              let data = try? await item.loadTransferable(type: Data.self),
              let normalized = normalizedImageData(from: data) else { return }
        vm.draft.avatarImageData = normalized
    }

    private func normalizedImageData(from data: Data) -> Data? {
        #if canImport(AppKit)
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return data }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) ?? data
        #elseif canImport(UIKit)
        guard let image = UIImage(data: data) else { return data }
        return image.jpegData(compressionQuality: 0.82) ?? data
        #else
        return data
        #endif
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
            sectionTitle("会話ルール (任意)")
            card {
                if !vm.draft.rules.isEmpty {
                    chipList(vm.draft.rules, accent: .blue) { idx in
                        vm.draft.rules.remove(at: idx)
                    }
                }
                HStack {
                    TextField("ルールを追加", text: $newRuleText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitRule() }
                    Button("追加") { commitRule() }
                        .buttonStyle(.bordered)
                        .disabled(newRuleText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func commitRule() {
        let t = newRuleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        vm.draft.rules.append(t)
        newRuleText = ""
    }

    private var safetyRulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("安全ルール (このキャラ専用)")
            card {
                // 自動推奨ルール (group + genre + category)
                let recommended = (vm.draft.category.defaultSafetyRules
                                    + vm.draft.relationshipGenre.safetyRules)
                if !recommended.isEmpty {
                    Text("カテゴリー/関係性に基づき自動で適用される推奨ルール:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(Set(recommended)).sorted(), id: \.self) { r in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.green)
                            Text(r).font(.system(size: 11)).foregroundStyle(.secondary)
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
                    TextField("追加の安全ルール", text: $newSafetyRuleText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitSafetyRule() }
                    Button("追加") { commitSafetyRule() }
                        .buttonStyle(.bordered)
                        .disabled(newSafetyRuleText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func commitSafetyRule() {
        let t = newSafetyRuleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        vm.draft.safetyRules.append(t)
        newSafetyRuleText = ""
    }

    private var visibilitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("公開設定")
            card {
                labeledField("公開状態") {
                    Picker("", selection: $vm.draft.visibility) {
                        ForEach(CharacterVisibility.allCases) { v in
                            Label(v.displayName, systemImage: v.iconName).tag(v)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                labeledField("安全レーティング") {
                    Picker("", selection: $vm.draft.safetyRating) {
                        ForEach(SafetyRating.allCases) { r in
                            Label(r.displayName, systemImage: r.iconName).tag(r)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }
        }
    }

    // MARK: - Reusable

    private func labeledField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
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
}
