/*
仕様:
- 役割: キャラクター一覧 + 検索 + フィルタ + 作成導線 を提供する絆ライブラリー画面。
- 主な型: `CharacterLibraryView`.
- 編集ポイント: グリッド/リスト切替、フィルタ UI、空状態のデザイン。
*/

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
private typealias CharacterLibraryPlatformImage = NSImage
#elseif canImport(UIKit)
private typealias CharacterLibraryPlatformImage = UIImage
#endif

private extension Image {
    init(characterLibraryPlatformImage: CharacterLibraryPlatformImage) {
        #if canImport(AppKit)
        self.init(nsImage: characterLibraryPlatformImage)
        #elseif canImport(UIKit)
        self.init(uiImage: characterLibraryPlatformImage)
        #else
        self.init(systemName: "person.crop.square")
        #endif
    }
}

struct CharacterLibraryView: View {
    @StateObject private var vm = CharacterLibraryViewModel()
    @State private var showCreate = false
    @State private var editing: CharacterProfile? = nil
    @State private var selected: CharacterProfile? = nil
    @State private var showTemplatePicker = false
    @Environment(\.dismiss) private var dismiss

    /// チャット開始時に呼ばれる (PersonaChatView 側で受け取って sheet を閉じ、スレッド作成)。
    var onStartChat: ((CharacterProfile) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            content
        }
        .background(Color.appCanvasBackground.ignoresSafeArea())
        .task { await vm.bootstrap() }
        .sheet(isPresented: $showCreate) {
            CharacterCreateView(
                template: prefillTemplate,
                onSaved: { newCharacter in
                    Task {
                        await vm.reload()
                        showCreate = false
                        prefillTemplate = nil
                        selected = newCharacter
                    }
                }
            )
            .viukAdaptiveSheetSizing(minWidth: 640, minHeight: 720)
        }
        .sheet(item: $editing) { c in
            CharacterCreateView(
                existing: c,
                onSaved: { _ in
                    Task {
                        await vm.reload()
                        editing = nil
                    }
                }
            )
            .viukAdaptiveSheetSizing(minWidth: 640, minHeight: 720)
        }
        .sheet(item: $selected) { c in
            CharacterDetailView(
                character: c,
                onStartChat: { character in
                    selected = nil
                    onStartChat?(character)
                    dismiss()
                },
                onEdit: { character in
                    selected = nil
                    editing = character
                },
                onDelete: {
                    Task {
                        await vm.delete(id: c.id)
                        selected = nil
                    }
                }
            )
            .viukAdaptiveSheetSizing(minWidth: 560, minHeight: 700)
        }
        .sheet(isPresented: $showTemplatePicker) {
            TemplatePickerSheet(
                templates: vm.templates,
                onPick: { template in
                    showTemplatePicker = false
                    // template から draft を作って Create に遷移
                    showCreateFromTemplate(template)
                }
            )
            .viukAdaptiveSheetSizing(minWidth: 480, minHeight: 560)
        }
    }

    @State private var prefillTemplate: CharacterTemplate? = nil

    private func showCreateFromTemplate(_ template: CharacterTemplate) {
        prefillTemplate = template
        showCreate = true
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .help("閉じる")

            VStack(alignment: .leading, spacing: 0) {
                Text("キャラライブラリー")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(vm.allCharacters.count) 件")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                showTemplatePicker = true
            } label: {
                Label("テンプレ", systemImage: "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.bordered)

            Button {
                prefillTemplate = nil
                showCreate = true
            } label: {
                Label("作成", systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    // MARK: - Filters

    private var filterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("検索 (名前・説明・タグ)", text: $vm.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    pickerChip(
                        label: "グループ",
                        icon: "square.grid.2x2",
                        selection: vm.groupFilter?.displayName
                    ) {
                        Menu {
                            Button("すべて") { vm.groupFilter = nil; vm.categoryFilter = nil }
                            Divider()
                            ForEach(CategoryGroup.allCases) { g in
                                Button(action: { vm.groupFilter = g; vm.categoryFilter = nil }) {
                                    Label(g.displayName, systemImage: g.iconName)
                                }
                            }
                        } label: { EmptyView() }
                    }

                    if let group = vm.groupFilter {
                        let cats = CharacterCategory.allCases.filter { $0.group == group }
                        pickerChip(
                            label: "カテゴリー",
                            icon: "tag",
                            selection: vm.categoryFilter?.displayName
                        ) {
                            Menu {
                                Button("すべて") { vm.categoryFilter = nil }
                                Divider()
                                ForEach(cats) { c in
                                    Button(c.displayName) { vm.categoryFilter = c }
                                }
                            } label: { EmptyView() }
                        }
                    }

                    pickerChip(
                        label: "ジャンル",
                        icon: "heart.text.square",
                        selection: vm.genreFilter?.displayName
                    ) {
                        Menu {
                            Button("すべて") { vm.genreFilter = nil }
                            Divider()
                            ForEach(RelationshipGenre.allCases) { g in
                                Button(g.displayName) { vm.genreFilter = g }
                            }
                        } label: { EmptyView() }
                    }

                    if !vm.availableTags.isEmpty {
                        pickerChip(
                            label: "タグ",
                            icon: "number",
                            selection: vm.tagFilter
                        ) {
                            Menu {
                                Button("すべて") { vm.tagFilter = nil }
                                Divider()
                                ForEach(vm.availableTags, id: \.self) { t in
                                    Button(t) { vm.tagFilter = t }
                                }
                            } label: { EmptyView() }
                        }
                    }

                    if vm.groupFilter != nil || vm.categoryFilter != nil || vm.genreFilter != nil || vm.tagFilter != nil {
                        Button {
                            vm.groupFilter = nil
                            vm.categoryFilter = nil
                            vm.genreFilter = nil
                            vm.tagFilter = nil
                        } label: {
                            Label("クリア", systemImage: "xmark.circle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.primary.opacity(0.06)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func pickerChip<Content: View>(
        label: String,
        icon: String,
        selection: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(selection ?? label)
                    .font(.system(size: 11, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(selection == nil ? Color.primary.opacity(0.06) : Color.accentColor.opacity(0.18))
            )
            .foregroundStyle(selection == nil ? .primary : Color.accentColor)
            content()
                .opacity(0.001) // メニュー本体を被せる
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if vm.isLoading && vm.allCharacters.isEmpty {
            VStack { ProgressView() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.filtered.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(vm.filtered) { c in
                        characterCard(c)
                    }
                }
                .padding(14)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.3.sequence.fill")
                .font(.system(size: 42))
                .foregroundStyle(.tertiary)
            Text(vm.allCharacters.isEmpty ? "まだキャラがいません" : "条件に合うキャラがいません")
                .font(.system(size: 15, weight: .semibold))
            if vm.allCharacters.isEmpty {
                Text("テンプレから始めるか、新規作成してみよう。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        showTemplatePicker = true
                    } label: {
                        Label("テンプレから作る", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        showCreate = true
                    } label: {
                        Label("ゼロから作る", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func characterCard(_ c: CharacterProfile) -> some View {
        Button {
            selected = c
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    avatar(for: c, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.displayName.isEmpty ? c.name : c.displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(c.category.displayName + "・" + c.relationshipGenre.displayName)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: c.safetyRating.iconName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(safetyTint(c.safetyRating))
                    Image(systemName: c.visibility.iconName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                if !c.shortDescription.isEmpty {
                    Text(c.shortDescription)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !c.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(c.tags.prefix(5), id: \.self) { tag in
                                Text("#" + tag)
                                    .font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.10)))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { editing = c } label: { Label("編集", systemImage: "pencil") }
            Button(role: .destructive) {
                Task { await vm.delete(id: c.id) }
            } label: {
                Label("削除", systemImage: "trash")
            }
        }
    }

    private func avatar(for c: CharacterProfile, size: CGFloat) -> some View {
        if let data = c.avatarImageData, let image = characterLibraryPlatformImage(from: data) {
            return AnyView(
                Image(characterLibraryPlatformImage: image)
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
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hue: hue, saturation: 0.55, brightness: 0.95),
                                Color(hue: hue, saturation: 0.4, brightness: 0.85)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text(initial)
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
        )
    }

    private func characterLibraryPlatformImage(from data: Data) -> CharacterLibraryPlatformImage? {
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

// MARK: - Template Picker Sheet

private struct TemplatePickerSheet: View {
    let templates: [CharacterTemplate]
    let onPick: (CharacterTemplate) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("閉じる") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("テンプレから作る")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Color.clear.frame(width: 48)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.thinMaterial)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(templates) { t in
                        Button {
                            onPick(t)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: t.category.group.iconName)
                                        .foregroundStyle(.tint)
                                    Text(t.displayName)
                                        .font(.system(size: 14, weight: .semibold))
                                }
                                Text(t.defaultPersonality)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                if !t.defaultTags.isEmpty {
                                    Text(t.defaultTags.map { "#" + $0 }.joined(separator: " "))
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(14)
            }
        }
        .background(Color.appCanvasBackground.ignoresSafeArea())
    }
}
