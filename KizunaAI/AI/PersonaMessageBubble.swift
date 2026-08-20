/*
仕様:
- 役割: ペルソナチャットの1メッセージ分の吹き出し表示。
- 主な型: `PersonaMessageBubble`.
- 編集ポイント: 吹き出し形状、配色、コンテキストメニューを変えるときに触る。
- 構成: PersonaChatView.swift から機械的に分割 (#286)。
*/

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Message bubble

struct PersonaMessageBubble: View {
    let message: PersonaMessage
    let personaProfile: PersonaProfile
    @Environment(\.colorScheme) private var colorScheme
    private var style: PersonaAvatarStyle { PersonaAvatarStyle(profile: personaProfile) }

    var body: some View {
        Group {
            if message.role == .narrator {
                HStack {
                    Spacer(minLength: 34)
                    bubble(alignment: .center)
                    Spacer(minLength: 34)
                }
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    if message.role == .assistant {
                        VStack(alignment: .leading, spacing: 4) {
                            // アイコンの横にキャラクター名を置く。
                            HStack(spacing: 6) {
                                avatar
                                Text(personaProfile.name)
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            bubble(alignment: .leading)
                        }
                        .frame(maxWidth: 620, alignment: .leading)
                    } else {
                        Spacer(minLength: 40)
                        bubble(alignment: .trailing)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(Text(message.createdAt, style: .time))
    }

    private var accessibilityLabel: String {
        let speaker: String
        if message.role == .assistant {
            speaker = personaProfile.name
        } else if message.role == .narrator {
            speaker = KizunaCopy.text(japanese: "ナレーション", english: "Narration")
        } else {
            speaker = KizunaCopy.text(japanese: "あなた", english: "You")
        }
        let body = message.text.isEmpty
            ? KizunaCopy.text(japanese: "待機中", english: "Waiting")
            : message.text
        return "\(speaker): \(body)"
    }

    private var avatar: some View {
        PersonaAvatarView(profile: personaProfile, size: 34)
    }

    private func bubble(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            if message.role == .narrator {
                Label(message.text, systemImage: "sparkles")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(bubbleBackground)
                    .textSelection(.enabled)
            } else if message.text.isEmpty {
                // ストリーム前の空メッセージ
                Text(KizunaCopy.text(japanese: "…", english: "…"))
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleBackground)
            } else {
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(message.role == .user ? .white : .primary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(bubbleBackground)
                    .textSelection(.enabled)
            }
            Text(timestamp)
                .font(.caption2)
                // Timestamps are visible content, not decorative metadata.
                // Use the semantic secondary color so they remain readable
                // against both message bubble backgrounds in light/dark mode.
                .foregroundStyle(.secondary)
                .padding(message.role == .user ? .trailing : .leading, 4)
        }
        .contextMenu {
            if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    copyMessageText()
                } label: {
                    Label(KizunaCopy.text(japanese: "本文をコピー", english: "Copy text"), systemImage: "doc.on.doc")
                }
            }
        }
    }

    private func copyMessageText() {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = message.text
        #endif
    }

    private var bubbleBackground: some View {
        Group {
            if message.role == .narrator {
                Capsule()
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.055))
                    .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
            } else if message.role == .user {
                // ユーザーバブル: ダークは少し落とした緑、ライトは LINE 緑風。
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(colorScheme == .dark
                          ? Color(red: 0.18, green: 0.48, blue: 0.22)
                          : Color(red: 0.15, green: 0.46, blue: 0.20))
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(colorScheme == .dark
                          ? style.primary.opacity(0.16)
                          : style.highlight.opacity(0.26))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(style.primary.opacity(colorScheme == .dark ? 0.22 : 0.18), lineWidth: 1)
                    )
                    .shadow(color: style.shadow.opacity(colorScheme == .dark ? 0.0 : 0.08), radius: 5, y: 2)
            }
        }
    }

    private var timestamp: String {
        message.createdAt.formatted(.dateTime.hour().minute())
    }
}
