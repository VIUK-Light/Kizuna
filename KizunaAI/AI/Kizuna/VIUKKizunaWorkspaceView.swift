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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            sectionPicker
            Divider()
            sectionContent
        }
        .background(Color.appCanvasBackground.ignoresSafeArea())
        .sheet(isPresented: $isShowingSettings) {
            KizunaSettingsView()
                .viukAdaptiveSheetSizing(minWidth: 560, minHeight: 680)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.50, green: 0.27, blue: 0.96),
                                Color(red: 0.13, green: 0.63, blue: 0.78)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "infinity.circle.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text("VIUK 絆")
                    .font(.system(size: 22, weight: .bold))
                Text("キャラ、世界観、物語セッションをまとめた関係性アプリ")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

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
            .accessibilityLabel("絆の設定")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.thinMaterial)
    }

    private var sectionPicker: some View {
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
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color.appSecondaryBackground.opacity(0.18))
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selectedSection {
        case .stories:
            StoryWorldLibraryView()
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
