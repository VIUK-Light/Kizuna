import SwiftUI

#if canImport(AppKit)
import AppKit
private typealias StoryScenePlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit
private typealias StoryScenePlatformImage = UIImage
#endif

private extension Image {
    init(storyScenePlatformImage: StoryScenePlatformImage) {
        #if canImport(AppKit)
        self.init(nsImage: storyScenePlatformImage)
        #elseif canImport(UIKit)
        self.init(uiImage: storyScenePlatformImage)
        #else
        self.init(systemName: "photo")
        #endif
    }
}

/// シーンの空気を会話の前に見せる背景画像。
/// 画像キーがない旧データでも、場面情報を使った安全なフォールバックを表示する。
struct StorySceneImageView: View {
    let scene: StoryScene
    let world: StoryWorld?

    var body: some View {
        Group {
            if let image = storedImage {
                Image(storyScenePlatformImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                fallback
            }
        }
        .clipped()
        .accessibilityLabel(scene.title.isEmpty ? "Story scene" : scene.title)
    }

    private var storedImage: StoryScenePlatformImage? {
        guard let key = scene.imageKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            return nil
        }
        #if canImport(AppKit)
        return NSImage(named: key)
        #elseif canImport(UIKit)
        return UIImage(named: key)
        #else
        return nil
        #endif
    }

    private var fallback: some View {
        let palette = ScenePalette(scene: scene, world: world)
        return ZStack {
            LinearGradient(
                colors: palette.colors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: world?.genre.group.iconName ?? "sparkles.rectangle.stack")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.white.opacity(0.78))
            VStack(alignment: .leading, spacing: 4) {
                Spacer()
                Text(scene.location.isEmpty ? "Scene" : scene.location)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                if !scene.timeOfDay.isEmpty {
                    Text(scene.timeOfDay)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }
}

private struct ScenePalette {
    let colors: [Color]

    init(scene: StoryScene, world: StoryWorld?) {
        let seed = (scene.title + scene.location + (world?.title ?? ""))
            .unicodeScalars
            .reduce(0) { ($0 &* 31) &+ Int($1.value) }
        let palettes: [[Color]] = [
            [Color(red: 0.10, green: 0.18, blue: 0.38), Color(red: 0.32, green: 0.56, blue: 0.70)],
            [Color(red: 0.26, green: 0.13, blue: 0.34), Color(red: 0.68, green: 0.34, blue: 0.28)],
            [Color(red: 0.12, green: 0.28, blue: 0.24), Color(red: 0.48, green: 0.54, blue: 0.30)],
            [Color(red: 0.34, green: 0.18, blue: 0.10), Color(red: 0.70, green: 0.44, blue: 0.18)]
        ]
        colors = palettes[(seed == Int.min ? 0 : abs(seed)) % palettes.count]
    }
}
