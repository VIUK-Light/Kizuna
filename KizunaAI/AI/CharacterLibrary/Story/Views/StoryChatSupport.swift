/*
仕様:
- 役割: Story系チャット画面で共有する色トークン・画像ヘルパー・コピー文言。
- 主な型: なし（グローバル定数と拡張）。
- 編集ポイント: ストーリー画面の共通配色や文言切替を変えるときに触る。
- 構成: StorySessionChatView.swift から機械的に分割 (#286)。
*/

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
typealias StoryChatPlatformImage = NSImage
#elseif canImport(UIKit)
typealias StoryChatPlatformImage = UIImage
#endif

extension Image {
    init(storyChatPlatformImage: StoryChatPlatformImage) {
        #if canImport(AppKit)
        self.init(nsImage: storyChatPlatformImage)
        #elseif canImport(UIKit)
        self.init(uiImage: storyChatPlatformImage)
        #else
        self.init(systemName: "person.crop.square")
        #endif
    }
}

let storyCanvas = Color(red: 0.07, green: 0.07, blue: 0.08)
let storyPanel = Color(red: 0.12, green: 0.12, blue: 0.13)
let storyBubble = Color(red: 0.16, green: 0.16, blue: 0.17)
// Keep the Kizuna teal identity while meeting normal-text contrast when the
// user message is rendered in white on this bubble.
let storyPurple = Color(red: 0.06, green: 0.46, blue: 0.43)
let storyWarmAccent = Color(red: 0.93, green: 0.66, blue: 0.22)
let storyText = Color.white.opacity(0.92)
// Keep secondary story text readable on the dark canvas. The previous 0.58
// opacity fell below the normal-text contrast target for timestamps and
// status labels.
let storyMuted = Color.white.opacity(0.78)

enum StorySessionClipboard {
    static func copy(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}

func storyCopy(_ japanese: String, _ english: String) -> String {
    KizunaCopy.text(japanese: japanese, english: english)
}
