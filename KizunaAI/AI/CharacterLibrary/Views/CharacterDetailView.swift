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
        .alert("このキャラを削除しますか?", isPresented: $showDeleteConfirm) {
            Button("キャンセル", role: .cancel) {}
            Button("削除", role: .destructive) {
                Task {
                    await vm.delete()
                    onDelete?()
                    dismiss()
                }
            }
        } message: {
            Text("メモリーも一緒に削除されます。元には戻せません。")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button("閉じる") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Spacer()
            Text("キャラ詳細").font(.system(size: 14, weight: .semibold))
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
                Text(character.displayName.isEmpty ? character.name : character.displayName)
                    .font(.system(size: 18, weight: .bold))
                Text(character.category.displayName + " ・ " + character.relationshipGenre.displayName)
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
                    badge(character.safetyRating.displayName, icon: character.safetyRating.iconName, color: safetyTint(character.safetyRating))
                    badge(character.visibility.displayName, icon: character.visibility.iconName, color: .gray)
                }
                if !character.scenario.isEmpty {
                    Text("シナリオ: " + character.scenario)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                if !character.firstMessage.isEmpty {
                    Text("初回: " + character.firstMessage)
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
            sectionTitle("ロアブック")
            VStack(alignment: .leading, spacing: 8) {
                if !lb.worldSetting.isEmpty {
                    keyValue("世界観", lb.worldSetting)
                }
                if !lb.importantPeople.isEmpty {
                    keyValue("人物", lb.importantPeople.joined(separator: ", "))
                }
                if !lb.importantPlaces.isEmpty {
                    keyValue("場所", lb.importantPlaces.joined(separator: ", "))
                }
                if !lb.importantEvents.isEmpty {
                    keyValue("出来事", lb.importantEvents.joined(separator: ", "))
                }
                if !lb.worldRules.isEmpty {
                    keyValueList("世界のルール", lb.worldRules)
                }
                if !lb.forbiddenBreaks.isEmpty {
                    keyValueList("壊さない約束", lb.forbiddenBreaks)
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
            sectionTitle("覚えていること (\(vm.memories.count))")
            VStack(alignment: .leading, spacing: 4) {
                ForEach(vm.memories.prefix(8)) { m in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.text)
                                .font(.system(size: 12))
                            Text(m.category.displayName + " ・ 重要度 \(String(format: "%.2f", m.importance))")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                if vm.memories.count > 8 {
                    Text("ほか \(vm.memories.count - 8) 件")
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
            sectionTitle("ルール")
            VStack(alignment: .leading, spacing: 4) {
                if !character.rules.isEmpty {
                    ForEach(character.rules, id: \.self) { r in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 6))
                                .foregroundStyle(.blue)
                            Text(r).font(.system(size: 12))
                        }
                    }
                }
                ForEach(character.resolvedSafetyRules, id: \.self) { r in
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
        HStack(spacing: 8) {
            Button {
                onEdit?(character)
            } label: { Label("編集", systemImage: "pencil") }
                .buttonStyle(.bordered)

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: { Label("削除", systemImage: "trash") }
                .buttonStyle(.bordered)

            Button {
                showReport = true
            } label: { Label("通報", systemImage: "flag") }
                .buttonStyle(.bordered)

            Spacer()

            Button {
                onStartChat?(character)
            } label: {
                Label("絆チャットを始める", systemImage: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.thinMaterial)
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
        if let key = c.imageKey, !key.isEmpty {
            return AnyView(
                Image(key)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            )
        }
        let name = c.displayName.isEmpty ? c.name : c.displayName
        let initial = name.first.map(String.init) ?? "?"
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
                Text(initial)
                    .font(.system(size: size * 0.45, weight: .bold))
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

    private func safetyTint(_ r: SafetyRating) -> Color {
        switch r {
        case .general: return .green
        case .teen: return .blue
        case .sensitive: return .orange
        case .restricted: return .red
        }
    }
}
