/*
仕様:
- 役割: VIUK 絆を AI Studio から独立したアプリ入口として表示する。
- 主な型: `VIUKKizunaWorkspaceView`.
- 編集ポイント: 絆アプリ単体のトップ、ライブラリー、キャラ導線、単体チャット導線。
*/

import SwiftUI

struct VIUKKizunaWorkspaceView: View {
    @State private var selectedSection: KizunaWorkspaceSection = .stories
    @State private var isShowingSettings = false
    @State private var activeStoryWorld: StoryWorld?

    var body: some View {
        VStack(spacing: 0) {
            sectionPicker
            Divider()
            sectionContent
        }
        .background(Color.appCanvasBackground.ignoresSafeArea())
        .sheet(isPresented: $isShowingSettings) {
            KizunaSettingsView()
                .viukAdaptiveSheetSizing(minWidth: 560, minHeight: 680)
        }
#if os(iOS)
        .fullScreenCover(item: $activeStoryWorld) { world in
            StorySessionChatView(world: world)
        }
#else
        .sheet(item: $activeStoryWorld) { world in
            StorySessionChatView(world: world)
        }
#endif
    }

    private var settingsButton: some View {
        Button {
            isShowingSettings = true
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 15, weight: .bold))
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel("設定")
    }

    private var sectionPicker: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(KizunaWorkspaceSection.allCases) { section in
                        Button {
                            selectedSection = section
                        } label: {
                            Label(section.title, systemImage: section.icon)
                                .font(.system(size: 12, weight: .bold))
                                .labelStyle(.titleAndIcon)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule()
                                        .fill(selectedSection == section ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
                                )
                                .foregroundStyle(selectedSection == section ? Color.accentColor : Color.primary.opacity(0.82))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            settingsButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.appSecondaryBackground.opacity(0.18))
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selectedSection {
        case .stories:
            StoryWorldLibraryView { world in
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    activeStoryWorld = world
                }
            }
        case .characters:
            CharacterLibraryView()
        case .chat:
            PersonaChatView()
        }
    }
}

private enum KizunaWorkspaceSection: String, CaseIterable, Identifiable {
    case stories
    case characters
    case chat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stories: return "ストーリー"
        case .characters: return "キャラ"
        case .chat: return "単体チャット"
        }
    }

    var icon: String {
        switch self {
        case .stories: return "sparkles.rectangle.stack.fill"
        case .characters: return "person.2.crop.square.stack.fill"
        case .chat: return "bubble.left.and.bubble.right.fill"
        }
    }
}
