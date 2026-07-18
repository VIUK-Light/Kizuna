/*
仕様:
- 役割: StoryWorld のライブラリー一覧画面。CharacterLibraryView とは独立。
- 主な型: `StoryWorldLibraryView`.
*/

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
private typealias StoryLibraryPlatformImage = NSImage
#elseif canImport(UIKit)
private typealias StoryLibraryPlatformImage = UIImage
#endif

private extension Image {
    init(storyLibraryPlatformImage: StoryLibraryPlatformImage) {
        #if canImport(AppKit)
        self.init(nsImage: storyLibraryPlatformImage)
        #elseif canImport(UIKit)
        self.init(uiImage: storyLibraryPlatformImage)
        #else
        self.init(systemName: "person.crop.rectangle")
        #endif
    }
}

struct StoryWorldLibraryView: View {
    @StateObject private var vm = StoryWorldLibraryViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var showCreate = false
    @State private var editing: StoryWorld? = nil
    @State private var selected: StoryWorld? = nil

    /// セッション開始時に呼ぶ。呼び出し側 (PersonaChatView 等) がシート閉じてセッション画面へ。
    var onStartSession: ((StoryWorld) -> Void)?

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
            StoryWorldCreateView(onSaved: { _ in
                Task { await vm.reload() }
                showCreate = false
            }, onStartSession: { world in
                onStartSession?(world)
                dismiss()
            })
            .viukAdaptiveSheetSizing(minWidth: 680, minHeight: 720)
        }
        .sheet(item: $editing) { w in
            StoryWorldCreateView(existing: w, onSaved: { _ in
                Task { await vm.reload() }
                editing = nil
            })
            .viukAdaptiveSheetSizing(minWidth: 680, minHeight: 720)
        }
        .sheet(item: $selected) { w in
            StoryWorldDetailView(
                world: w,
                onStartSession: { world in
                    selected = nil
                    onStartSession?(world)
                    dismiss()
                },
                onEdit: { world in
                    selected = nil
                    editing = world
                },
                onDelete: {
                    Task { await vm.delete(id: w.id); selected = nil }
                }
            )
            .viukAdaptiveSheetSizing(minWidth: 600, minHeight: 720)
        }
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down").frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text("ストーリーライブラリー").font(.system(size: 15, weight: .semibold))
                Text("世界観から選ぶ ・ \(vm.worlds.count) 件").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showCreate = true
            } label: {
                Label("ストーリーを作る", systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("ストーリー・世界観・タグ検索", text: $vm.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))

            Menu {
                Button("すべて") { vm.groupFilter = nil }
                Divider()
                ForEach(CategoryGroup.allCases) { g in
                    Button { vm.groupFilter = g } label: {
                        Label(g.displayName, systemImage: g.iconName)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 10))
                    Text(vm.groupFilter?.displayName ?? "グループ")
                        .font(.system(size: 11, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if vm.filtered.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(.tertiary)
                Text(vm.worlds.isEmpty ? "ストーリーはまだありません" : "条件に合うストーリーがありません")
                    .font(.system(size: 14, weight: .semibold))
                if vm.worlds.isEmpty {
                    Button {
                        showCreate = true
                    } label: {
                        Label("最初のストーリーを作る", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) {
                    ForEach(vm.filtered) { w in
                        worldCard(w)
                    }
                }
                .padding(16)
            }
        }
    }

    private func worldCard(_ w: StoryWorld) -> some View {
        let coverCharacter = vm.coverCharacter(for: w)
        return Button { selected = w } label: {
            VStack(alignment: .leading, spacing: 12) {
                ZStack(alignment: .bottomLeading) {
                    coverImage(for: coverCharacter, genre: w.genre)
                        .frame(maxWidth: .infinity)
                        .frame(height: 230)
                        .clipped()

                    LinearGradient(
                        colors: [.black.opacity(0.04), .black.opacity(0.66)],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .bottom) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(w.title)
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                Text(coverCharacter?.displayName ?? w.genre.group.displayName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.86))
                            }
                            Spacer()
                            Image(systemName: w.visibility.iconName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.84))
                        }
                        Text(w.mood.isEmpty ? w.genre.group.displayName : w.mood)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1)
                    }
                    .padding(14)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                if !w.shortDescription.isEmpty {
                    Text(w.shortDescription)
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(2)
                }
                if !w.openingScene.isEmpty {
                    Text("「\(w.openingScene)」")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.82))
                        .lineLimit(3)
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.045))
                        )
                }
                HStack(spacing: 4) {
                    Text(w.genre.displayName)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        .foregroundStyle(Color.accentColor)
                    Text(w.relationshipGenre.displayName)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.purple.opacity(0.12)))
                        .foregroundStyle(.purple)
                    Spacer()
                    Label("\(w.characterIds.count)人", systemImage: "person.3.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                if !w.tags.isEmpty {
                    Text(w.tags.prefix(4).map { "#\($0)" }.joined(separator: "  "))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func coverImage(for character: CharacterProfile?, genre: CharacterCategory) -> some View {
        if let data = character?.avatarImageData,
           let image = storyLibraryPlatformImage(from: data) {
            Image(storyLibraryPlatformImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let key = character?.imageKey, !key.isEmpty {
            Image(key)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack {
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.72), Color.primary.opacity(0.18)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: genre.group.iconName)
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
            }
        }
    }

    private func storyLibraryPlatformImage(from data: Data) -> StoryLibraryPlatformImage? {
        #if canImport(AppKit)
        return NSImage(data: data)
        #elseif canImport(UIKit)
        return UIImage(data: data)
        #else
        return nil
        #endif
    }
}
