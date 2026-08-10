/*
仕様:
- 役割: キャラクター詳細画面。概要 + Lorebook + メモリー + ルール + アクション。
- 主な型: `CharacterDetailView`.
- 編集ポイント: 表示順、メモリー一覧の表現、アクションボタンの増減。
*/

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
private typealias CharacterDetailPlatformImage = NSImage
#elseif canImport(UIKit)
private typealias CharacterDetailPlatformImage = UIImage
#endif

private extension Image {
    init(characterDetailPlatformImage: CharacterDetailPlatformImage) {
        #if canImport(AppKit)
        self.init(nsImage: characterDetailPlatformImage)
        #elseif canImport(UIKit)
        self.init(uiImage: characterDetailPlatformImage)
        #else
        self.init(systemName: "person.crop.square")
        #endif
    }
}

struct CharacterDetailView: View {
    let character: CharacterProfile
    var onStartChat: ((CharacterProfile) -> Void)?
    var onEdit: ((CharacterProfile) -> Void)?
    var onDelete: (() -> Void)?

    @StateObject private var vm: CharacterDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showReport = false
    @State private var showDeleteConfirm = false
    @State private var deleteError: String?
    @State private var isDeleting = false

    init(
        character: CharacterProfile,
        onStartChat: ((CharacterProfile) -> Void)? = nil,
        onEdit: ((CharacterProfile) -> Void)? = nil,
        onDelete: (() -> Void)? = nil
    ) {
        self.character = character
        self.onStartChat = onStartChat
        self.onEdit = onEdit
        self.onDelete = onDelete
        _vm = StateObject(wrappedValue: CharacterDetailViewModel(character: character))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summarySection
                    if let lore = vm.lorebook, !lore.isEmpty { lorebookSection(lore) }
                    if !vm.memories.isEmpty { memoriesSection }
                    if !character.rules.isEmpty || !character.resolvedSafetyRules.isEmpty {
                        rulesSection
                    }
                    if let deletionStatus = deletionStatus {
                        HStack(spacing: 8) {
                            if isDeleting { ProgressView().controlSize(.small) }
                            Text(deletionStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            Divider()
            actionsBar
        }
        .background(Color.appCanvasBackground.ignoresSafeArea())
        .task { await vm.reload() }
        .sheet(isPresented: $showReport) {
            ReportCharacterView(character: character)
                .viukAdaptiveSheetSizing(minWidth: 420, minHeight: 460)
        }
        .alert(KizunaCopy.text(japanese: "このキャラを削除しますか?", english: "Delete this character?"), isPresented: $showDeleteConfirm) {
            Button(KizunaCopy.text(japanese: "キャンセル", english: "Cancel"), role: .cancel) {}
            Button(KizunaCopy.text(japanese: "削除", english: "Delete"), role: .destructive) {
                performDelete()
            }
        } message: {
            Text(KizunaCopy.text(
                japanese: "メモリーも一緒に削除されます。元には戻せません。",
                english: "This also deletes the character's memories. This cannot be undone."
            ))
        }
        .alert(KizunaCopy.text(japanese: "削除に失敗しました", english: "Deletion failed"), isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button(KizunaCopy.text(japanese: "再試行", english: "Retry")) {
                deleteError = nil
                performDelete()
            }
            Button(KizunaCopy.text(japanese: "閉じる", english: "Close"), role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    private var deletionStatus: String? {
        switch vm.deletionPhase {
        case .idle, .completed:
            return nil
        case .removingReferences:
            return KizunaCopy.text(japanese: "関連する物語データを整理しています…", english: "Removing story references…")
        case .deletingMemories:
            return KizunaCopy.text(japanese: "キャラのメモリーを削除しています…", english: "Deleting character memories…")
        case .deletingProfile:
            return KizunaCopy.text(japanese: "キャラ本体を削除しています…", english: "Deleting the character profile…")
        case .partiallyCompleted:
            return KizunaCopy.text(
                japanese: "削除処理が途中で止まりました。関連データが一部変更されている可能性があります。再試行してください。",
                english: "Deletion stopped partway through. Some related data may have changed. Retry to finish."
            )
        }
    }

    private func performDelete() {
        guard !isDeleting else { return }
        isDeleting = true
        Task { @MainActor in
            defer { isDeleting = false }
            do {
                try await vm.delete()
                onDelete?()
                dismiss()
            } catch {
                let message = KizunaCopy.text(
                    japanese: "キャラの削除が途中で失敗しました。関連データが一部変更されている可能性があります。再試行してください。",
                    english: "Character deletion stopped partway through. Some related data may have changed. Retry to finish."
                )
                // NSErrorの詳細は保存層やOSの言語に依存するため、英語UIへ
                // 日本語の内部診断を混ぜない。日本語UIでは再試行に役立つ
                // ローカル診断を残し、ログにも同じ原因を記録する。
                deleteError = KizunaCopy.language == .japanese
                    ? "\(message)\n\(error.localizedDescription)"
                    : message
                NSLog("[CharacterDetailView] delete failed: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button(KizunaCopy.text(japanese: "閉じる", english: "Close")) { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Spacer()
            Text(KizunaCopy.text(japanese: "キャラ詳細", english: "Character details"))
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Color.clear.frame(width: 48, height: 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.thinMaterial)
    }

    // MARK: - Summary

    private var summarySection: some View {
        HStack(alignment: .top, spacing: 14) {
            avatar(for: character, size: 64)
            VStack(alignment: .leading, spacing: 6) {
                Text(character.visibleName)
                    .font(.system(size: 18, weight: .bold))
                Text(character.category.localizedDisplayName + " ・ " + character.relationshipGenre.localizedDisplayName)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if !character.shortDescription.isEmpty {
                    Text(character.shortDescription)
                        .font(.system(size: 13))
                }
                if !character.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(character.tags, id: \.self) { t in
                                Text("#" + t)
                                    .font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
                HStack(spacing: 8) {
                    badge(character.safetyRating.localizedDisplayName, icon: character.safetyRating.iconName, color: safetyTint(character.safetyRating))
                    badge(character.visibility.localizedDisplayName, icon: character.visibility.iconName, color: .gray)
                }
                if !character.scenario.isEmpty {
                    Text(KizunaCopy.text(japanese: "シナリオ: ", english: "Scenario: ") + character.scenario)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                if !character.firstMessage.isEmpty {
                    Text(KizunaCopy.text(japanese: "初回: ", english: "First message: ") + character.firstMessage)
                        .font(.system(size: 12))
                        .italic()
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    // MARK: - Lorebook

    private func lorebookSection(_ lb: CharacterLorebook) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(KizunaCopy.text(japanese: "ロアブック", english: "Lorebook"))
            VStack(alignment: .leading, spacing: 8) {
                if !lb.worldSetting.isEmpty {
                    keyValue(KizunaCopy.text(japanese: "世界観", english: "World setting"), lb.worldSetting)
                }
                if !lb.importantPeople.isEmpty {
                    keyValue(KizunaCopy.text(japanese: "人物", english: "People"), lb.importantPeople.joined(separator: ", "))
                }
                if !lb.importantPlaces.isEmpty {
                    keyValue(KizunaCopy.text(japanese: "場所", english: "Places"), lb.importantPlaces.joined(separator: ", "))
                }
                if !lb.importantEvents.isEmpty {
                    keyValue(KizunaCopy.text(japanese: "出来事", english: "Events"), lb.importantEvents.joined(separator: ", "))
                }
                if !lb.worldRules.isEmpty {
                    keyValueList(KizunaCopy.text(japanese: "世界のルール", english: "World rules"), lb.worldRules)
                }
                if !lb.forbiddenBreaks.isEmpty {
                    keyValueList(KizunaCopy.text(japanese: "壊さない約束", english: "Boundaries"), lb.forbiddenBreaks)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05))
            )
        }
    }

    // MARK: - Memories

    private var memoriesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(KizunaCopy.text(
                japanese: "全体メモリー (\(vm.memories.count))",
                english: "Shared memories (\(vm.memories.count))"
            ))
            Text(KizunaCopy.text(
                japanese: "このキャラに紐づき、物語をまたいで使われる思い出",
                english: "Memories linked to this character and used across stories"
            ))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(vm.memories.prefix(8)) { m in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.text)
                                .font(.system(size: 12))
                            Text(m.category.localizedDisplayName + KizunaCopy.text(japanese: " ・ 重要度 ", english: " · Importance ") + String(format: "%.2f", m.importance))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                if vm.memories.count > 8 {
                    Text(KizunaCopy.text(
                        japanese: "ほか \(vm.memories.count - 8) 件",
                        english: "and \(vm.memories.count - 8) more"
                    ))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05))
            )
        }
    }

    // MARK: - Rules

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(KizunaCopy.text(japanese: "ルール", english: "Rules"))
            VStack(alignment: .leading, spacing: 4) {
                if !character.rules.isEmpty {
                    // 同じルールを複数回登録した旧データでは、文字列をIDにすると
                    // SwiftUIのForEachが同一IDを持つ。表示順のインデックスを
                    // 一時的なUI IDにして、重複ルールも安全に表示する。
                    ForEach(Array(character.rules.enumerated()), id: \.offset) { _, r in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 6))
                                .foregroundStyle(.blue)
                            Text(r).font(.system(size: 12))
                        }
                    }
                }
                ForEach(Array(character.resolvedSafetyRules.enumerated()), id: \.offset) { _, r in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                        Text(r).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05))
            )
        }
    }

    // MARK: - Actions

    private var actionsBar: some View {
        ViewThatFits(in: .horizontal) {
            fullActionsBar
            compactActionsBar
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.thinMaterial)
    }

    private var fullActionsBar: some View {
        HStack(spacing: 8) {
            Button {
                onEdit?(character)
            } label: { Label(KizunaCopy.text(japanese: "編集", english: "Edit"), systemImage: "pencil") }
                .buttonStyle(.bordered)

            if character.isSystemProtected != true {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: { Label(KizunaCopy.text(japanese: "削除", english: "Delete"), systemImage: "trash") }
                    .buttonStyle(.bordered)
                    .disabled(isDeleting)
            } else {
                Label(KizunaCopy.text(japanese: "標準", english: "Built-in"), systemImage: "lock.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Button {
                showReport = true
            } label: { Label(KizunaCopy.text(japanese: "通報", english: "Report"), systemImage: "flag") }
                .buttonStyle(.bordered)

            Spacer()

            Button {
                onStartChat?(character)
            } label: {
                Label(KizunaCopy.text(japanese: "絆チャットを始める", english: "Start kizuna chat"), systemImage: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var compactActionsBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button {
                    onEdit?(character)
                } label: {
                    Label(KizunaCopy.text(japanese: "編集", english: "Edit"), systemImage: "pencil")
                }
                if character.isSystemProtected != true {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label(KizunaCopy.text(japanese: "削除", english: "Delete"), systemImage: "trash")
                    }
                    .disabled(isDeleting)
                }
                Button {
                    showReport = true
                } label: {
                    Label(KizunaCopy.text(japanese: "通報", english: "Report"), systemImage: "flag")
                }
            } label: {
                Label(KizunaCopy.text(japanese: "その他", english: "More"), systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.bordered)

            Spacer(minLength: 0)

            Button {
                onStartChat?(character)
            } label: {
                Label(KizunaCopy.text(japanese: "絆チャット", english: "Kizuna chat"), systemImage: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Reusable

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11, weight: .bold))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }

    private func keyValue(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(k).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(v).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func keyValueList(_ k: String, _ items: [String]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(k).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items, id: \.self) { i in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                        Text(i)
                    }
                    .font(.system(size: 12))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func badge(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.18)))
        .foregroundStyle(color)
    }

    private func avatar(for c: CharacterProfile, size: CGFloat) -> some View {
        if let data = c.avatarImageData, let image = characterDetailPlatformImage(from: data) {
            return AnyView(
                Image(characterDetailPlatformImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            )
        }
        if let key = c.imageKey,
           !key.isEmpty,
           let image = characterDetailPlatformImage(named: key) {
            return AnyView(
                Image(characterDetailPlatformImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            )
        }
        let name = c.visibleName
        var sum = 0
        for s in name.unicodeScalars { sum &+= Int(s.value) }
        let hue = Double(sum % 360) / 360.0
        return AnyView(
            ZStack {
                Circle().fill(
                    LinearGradient(
                        colors: [
                            Color(hue: hue, saturation: 0.55, brightness: 0.95),
                            Color(hue: hue, saturation: 0.4, brightness: 0.85)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
        )
    }

    private func characterDetailPlatformImage(from data: Data) -> CharacterDetailPlatformImage? {
        #if canImport(AppKit)
        return NSImage(data: data)
        #elseif canImport(UIKit)
        return UIImage(data: data)
        #else
        return nil
        #endif
    }

    // 未登録の画像名をSwiftUIへ渡さず、既存のイニシャル表示へフォールバックする。
    private func characterDetailPlatformImage(named name: String) -> CharacterDetailPlatformImage? {
        #if canImport(AppKit)
        return NSImage(named: name)
        #elseif canImport(UIKit)
        return UIImage(named: name)
        #else
        return nil
        #endif
    }

    private func safetyTint(_ r: SafetyRating) -> Color {
        switch r {
        case .general: return .green
        case .teen: return .blue
        case .sensitive: return .orange
        case .restricted: return .red
        }
    }
}
