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
    @State private var pendingDeletion: CharacterProfile?
    @State private var deletionError: String?
    @Environment(\.dismiss) private var dismiss

    /// チャット開始時に呼ばれる (PersonaChatView 側で受け取って sheet を閉じ、スレッド作成)。
    var onStartChat: ((CharacterProfile) -> Void)?
    /// When embedded in the Conversation tab, selecting a card should start
    /// the conversation directly. The default remains the detail sheet so
    /// existing library callers keep their current behavior.
    private let startsChatImmediately: Bool
    private let showsDismissButton: Bool

    init(
        showsDismissButton: Bool = true,
        startsChatImmediately: Bool = false,
        onStartChat: ((CharacterProfile) -> Void)? = nil
    ) {
        self.showsDismissButton = showsDismissButton
        self.startsChatImmediately = startsChatImmediately
        self.onStartChat = onStartChat
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            if let issue = vm.loadError, vm.didLoadCharacters {
                loadErrorBanner(issue)
            }
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
                        // 詳細画面が関連データを含めて削除済み。ここで再度
                        // delete(id:) を呼ぶと二重削除・失敗表示の原因になる。
                        await vm.reload()
                        selected = nil
                    }
                }
            )
            .viukAdaptiveSheetSizing(minWidth: 560, minHeight: 700)
        }
        .sheet(isPresented: $showTemplatePicker) {
            TemplatePickerSheet(
                templates: vm.templates,
                isLoading: vm.isLoading && !vm.didLoadTemplates,
                loadError: vm.templateLoadError,
                didLoadTemplates: vm.didLoadTemplates,
                onPick: { template in
                    showTemplatePicker = false
                    // template から draft を作って Create に遷移
                    showCreateFromTemplate(template)
                },
                onRetry: {
                    Task { await vm.retryLoad() }
                }
            )
            .viukAdaptiveSheetSizing(minWidth: 480, minHeight: 560)
        }
        .alert(item: $pendingDeletion) { character in
            Alert(
                title: Text(KizunaCopy.text(
                    japanese: "「\(character.visibleName)」を削除しますか？",
                    english: "Delete \"\(character.visibleName)\"?"
                )),
                message: Text(KizunaCopy.text(
                    japanese: "メモリーも一緒に削除されます。元には戻せません。",
                    english: "This also deletes the character's memories. This cannot be undone."
                )),
                primaryButton: .destructive(Text(KizunaCopy.text(japanese: "削除", english: "Delete"))) {
                    Task {
                        await vm.delete(id: character.id)
                        if let message = vm.deleteErrorMessage {
                            deletionError = message
                        }
                    }
                },
                secondaryButton: .cancel(Text(KizunaCopy.text(japanese: "キャンセル", english: "Cancel")))
            )
        }
        .alert(
            KizunaCopy.text(japanese: "削除に失敗しました", english: "Deletion failed"),
            isPresented: Binding(
                get: { deletionError != nil },
                set: { if !$0 { deletionError = nil } }
            )
        ) {
            Button(KizunaCopy.text(japanese: "閉じる", english: "Close"), role: .cancel) {
                deletionError = nil
            }
        } message: {
            Text(deletionError ?? "")
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
            if showsDismissButton {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .help(KizunaCopy.text(japanese: "閉じる", english: "Close"))
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(KizunaCopy.text(japanese: "キャラライブラリー", english: "Character library"))
                    .font(.system(size: 15, weight: .semibold))
                Text(vm.loadError != nil && !vm.didLoadCharacters
                     ? KizunaCopy.text(japanese: "読み込みエラー", english: "Load error")
                     : "\(vm.allCharacters.count) " + KizunaCopy.text(japanese: "件", english: "characters"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                showTemplatePicker = true
            } label: {
                Label(KizunaCopy.text(japanese: "テンプレート", english: "Templates"), systemImage: "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .disabled(vm.loadError != nil && !vm.didLoadCharacters)

            Button {
                prefillTemplate = nil
                showCreate = true
            } label: {
                Label(
                    startsChatImmediately
                        ? KizunaCopy.text(japanese: "キャラを作る", english: "Create a character")
                        : KizunaCopy.text(japanese: "作成", english: "Create"),
                    systemImage: "plus"
                )
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.loadError != nil && !vm.didLoadCharacters)
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
                TextField(
                    KizunaCopy.text(japanese: "検索 (名前・説明・タグ)", english: "Search (name, description, tags)"),
                    text: $vm.searchText
                )
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
                        label: KizunaCopy.text(japanese: "グループ", english: "Group"),
                        icon: "square.grid.2x2",
                        selection: vm.groupFilter?.localizedDisplayName
                    ) {
                        Button(KizunaCopy.text(japanese: "すべて", english: "All")) { vm.groupFilter = nil; vm.categoryFilter = nil }
                        Divider()
                        ForEach(CategoryGroup.allCases) { g in
                            Button(action: { vm.groupFilter = g; vm.categoryFilter = nil }) {
                                Label(g.localizedDisplayName, systemImage: g.iconName)
                            }
                        }
                    }

                    if let group = vm.groupFilter {
                        let cats = CharacterCategory.allCases.filter { $0.group == group }
                        pickerChip(
                            label: KizunaCopy.text(japanese: "カテゴリー", english: "Category"),
                            icon: "tag",
                            selection: vm.categoryFilter?.localizedDisplayName
                        ) {
                            Button(KizunaCopy.text(japanese: "すべて", english: "All")) { vm.categoryFilter = nil }
                            Divider()
                            ForEach(cats) { c in
                                Button(c.localizedDisplayName) { vm.categoryFilter = c }
                            }
                        }
                    }

                    pickerChip(
                        label: KizunaCopy.text(japanese: "ジャンル", english: "Genre"),
                        icon: "heart.text.square",
                        selection: vm.genreFilter?.localizedDisplayName
                    ) {
                        Button(KizunaCopy.text(japanese: "すべて", english: "All")) { vm.genreFilter = nil }
                        Divider()
                        ForEach(RelationshipGenre.allCases) { g in
                            Button(g.localizedDisplayName) { vm.genreFilter = g }
                        }
                    }

                    if !vm.availableTags.isEmpty {
                        pickerChip(
                            label: KizunaCopy.text(japanese: "タグ", english: "Tags"),
                            icon: "number",
                            selection: vm.tagFilter
                        ) {
                            Button(KizunaCopy.text(japanese: "すべて", english: "All")) { vm.tagFilter = nil }
                            Divider()
                            ForEach(vm.availableTags, id: \.self) { t in
                                Button(t) { vm.tagFilter = t }
                            }
                        }
                    }

                    if vm.groupFilter != nil || vm.categoryFilter != nil || vm.genreFilter != nil || vm.tagFilter != nil {
                        Button {
                            vm.groupFilter = nil
                            vm.categoryFilter = nil
                            vm.genreFilter = nil
                            vm.tagFilter = nil
                        } label: {
                            Label(KizunaCopy.text(japanese: "クリア", english: "Clear"), systemImage: "xmark.circle.fill")
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
        Menu {
            content()
        } label: {
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
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .accessibilityLabel(
            KizunaCopy.text(japanese: "\(label)のフィルター", english: "Filter by \(label)")
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if vm.loadError != nil && !vm.didLoadCharacters {
            loadErrorState
        } else if vm.isLoading && vm.allCharacters.isEmpty {
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

    private var loadErrorState: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 42))
                .foregroundStyle(.orange)
            Text(KizunaCopy.text(
                japanese: "キャラライブラリーを読み込めません",
                english: "Can't load the character library"
            ))
                .font(.system(size: 15, weight: .semibold))
            if let issue = vm.loadError {
                Text(issue.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            Button {
                Task { await vm.retryLoad() }
            } label: {
                Label(KizunaCopy.text(japanese: "再読み込み", english: "Retry"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.isLoading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func loadErrorBanner(_ issue: CharacterLibraryLoadIssue) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(issue.message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button {
                Task { await vm.retryLoad() }
            } label: {
                Label(KizunaCopy.text(japanese: "再試行", english: "Retry"), systemImage: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(vm.isLoading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.3.sequence.fill")
                .font(.system(size: 42))
                .foregroundStyle(.tertiary)
            Text(vm.allCharacters.isEmpty
                 ? KizunaCopy.text(japanese: "まだキャラがいません", english: "No characters yet")
                 : KizunaCopy.text(japanese: "条件に合うキャラがいません", english: "No characters match these filters"))
                .font(.system(size: 15, weight: .semibold))
            if vm.allCharacters.isEmpty {
                Text(KizunaCopy.text(
                    japanese: "テンプレートから始めるか、新規作成してみよう。",
                    english: "Start from a template or create a character from scratch."
                ))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        showTemplatePicker = true
                    } label: {
                        Label(KizunaCopy.text(japanese: "テンプレートから作る", english: "Use a template"), systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        showCreate = true
                    } label: {
                        Label(
                            startsChatImmediately
                                ? KizunaCopy.text(japanese: "キャラを作る", english: "Create a character")
                                : KizunaCopy.text(japanese: "ゼロから作る", english: "Create from scratch"),
                            systemImage: "plus"
                        )
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
            if startsChatImmediately, onStartChat != nil {
                onStartChat?(c)
            } else {
                selected = c
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    avatar(for: c, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.visibleName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(c.category.localizedDisplayName + "・" + c.relationshipGenre.localizedDisplayName)
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
        .accessibilityHint(startsChatImmediately
                           ? KizunaCopy.text(
                               japanese: "タップするとこのキャラクターとの会話を始めます",
                               english: "Starts a conversation with this character"
                           )
                           : KizunaCopy.text(
                               japanese: "タップすると詳細を表示します",
                               english: "Shows character details"
                           ))
        .contextMenu {
            if startsChatImmediately {
                Button { selected = c } label: {
                    Label(KizunaCopy.text(japanese: "詳細を見る", english: "View details"), systemImage: "info.circle")
                }
            }
            Button { editing = c } label: {
                Label(KizunaCopy.text(japanese: "編集", english: "Edit"), systemImage: "pencil")
            }
            if c.isSystemProtected != true {
                Button(role: .destructive) {
                    pendingDeletion = c
                } label: {
                    Label(KizunaCopy.text(japanese: "削除", english: "Delete"), systemImage: "trash")
                }
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
        if let key = c.imageKey,
           !key.isEmpty,
           let image = characterLibraryPlatformImage(named: key) {
            return AnyView(
                Image(characterLibraryPlatformImage: image)
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
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.42, weight: .semibold))
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

    // 未登録の画像名をSwiftUIへ渡さず、既存のイニシャル表示へフォールバックする。
    private func characterLibraryPlatformImage(named name: String) -> CharacterLibraryPlatformImage? {
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

// MARK: - Template Picker Sheet

private struct TemplatePickerSheet: View {
    let templates: [CharacterTemplate]
    let isLoading: Bool
    let loadError: String?
    let didLoadTemplates: Bool
    let onPick: (CharacterTemplate) -> Void
    let onRetry: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(KizunaCopy.text(japanese: "閉じる", english: "Close")) { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(KizunaCopy.text(japanese: "テンプレートから作る", english: "Use a template"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Color.clear.frame(width: 48)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.thinMaterial)
            Divider()
            if isLoading && templates.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(KizunaCopy.text(japanese: "テンプレートを読み込み中…", english: "Loading templates…"))
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                VStack(spacing: 12) {
                    Image(systemName: "doc.badge.exclamationmark")
                        .font(.system(size: 32))
                        .foregroundStyle(.orange)
                    Text(loadError)
                        .font(.system(size: 13, weight: .semibold))
                        .multilineTextAlignment(.center)
                    Button {
                        onRetry()
                    } label: {
                        Label(KizunaCopy.text(japanese: "再試行", english: "Retry"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(30)
            } else if templates.isEmpty && didLoadTemplates {
                VStack(spacing: 10) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text(KizunaCopy.text(japanese: "テンプレートはまだありません", english: "No templates yet"))
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
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
        }
        .background(Color.appCanvasBackground.ignoresSafeArea())
    }
}
