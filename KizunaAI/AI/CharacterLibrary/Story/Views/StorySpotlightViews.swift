/*
仕様:
- 役割: ストーリー会話のキャラクター選択シートとヒーロー表示。
- 主な型: `StoryCharacterSpotlightSheet`, `StoryCharacterHero`.
- 編集ポイント: キャラクター選択UI・アバター表示を変えるときに触る。
- 構成: StorySessionChatView.swift から機械的に分割 (#286)。
*/

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

struct StoryCharacterSpotlightSheet: View {
    let characters: [CharacterProfile]
    let selectedCharacterID: UUID?
    var onSelect: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    private var selected: CharacterProfile? {
        characters.first(where: { $0.id == selectedCharacterID }) ?? characters.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let selected {
                        StoryCharacterHero(character: selected)
                    }
                    if characters.count > 1 {
                        Text(storyCopy("登場キャラ", "Characters"))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            ForEach(characters) { character in
                                Button {
                                    onSelect(character.id)
                                } label: {
                                    VStack(spacing: 7) {
                                        StoryCharacterHero.image(for: character)
                                            .frame(width: 72, height: 72)
                                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                        Text(character.visibleName)
                                            .font(.caption.weight(.bold))
                                            .lineLimit(1)
                                    }
                                    .padding(7)
                                    .background(
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .fill(character.id == selected?.id ? storyPurple.opacity(0.18) : Color.primary.opacity(0.045))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .stroke(character.id == selected?.id ? storyPurple.opacity(0.72) : Color.clear, lineWidth: 2)
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(character.id == selected?.id ? .isSelected : [])
                            }
                        }
                    }
                }
                .padding(18)
            }
            .navigationTitle(selected?.visibleName ?? storyCopy("登場キャラ", "Characters"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(storyCopy("閉じる", "Close")) { dismiss() }
                }
            }
        }
    }
}

struct StoryCharacterHero: View {
    let character: CharacterProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Self.image(for: character)
                .frame(maxWidth: .infinity)
                .frame(height: 360)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 5) {
                Text(character.visibleName)
                    .font(.largeTitle.weight(.heavy))
                    .foregroundStyle(storyText)
                if !character.shortDescription.isEmpty {
                    Text(character.shortDescription)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(storyMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            info(storyCopy("口調", "Speaking style"), character.speakingStyle)
            info(storyCopy("性格", "Personality"), character.personality)
            info(storyCopy("ユーザーとの関係", "Relationship to you"), character.relationshipToUser)
            info(storyCopy("背景", "Background"), character.background)
        }
    }

    @ViewBuilder
    static func image(for character: CharacterProfile) -> some View {
        if let data = character.avatarImageData, let image = storySpotlightPlatformImage(from: data) {
            Image(storyChatPlatformImage: image)
                .resizable()
                .scaledToFill()
        } else if let key = character.imageKey,
                  !key.isEmpty,
                  let image = storySpotlightPlatformImage(named: key) {
            Image(storyChatPlatformImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(colors: [storyPurple.opacity(0.75), Color.black.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "person.fill")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }

    private func info(_ title: String, _ value: String) -> some View {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return Group {
            if !trimmed.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(trimmed)
                        .font(.body.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private func storySpotlightPlatformImage(from data: Data) -> StoryChatPlatformImage? {
    #if canImport(AppKit)
    return NSImage(data: data)
    #elseif canImport(UIKit)
    return UIImage(data: data)
    #else
    return nil
    #endif
}

private func storySpotlightPlatformImage(named name: String) -> StoryChatPlatformImage? {
    #if canImport(AppKit)
    return NSImage(named: name)
    #elseif canImport(UIKit)
    return UIImage(named: name)
    #else
    return nil
    #endif
}
