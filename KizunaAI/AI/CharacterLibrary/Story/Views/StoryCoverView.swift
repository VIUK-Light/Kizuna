import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
private typealias StoryCoverPlatformImage = NSImage
#elseif canImport(UIKit)
private typealias StoryCoverPlatformImage = UIImage
#endif

private extension Image {
    init(storyCoverPlatformImage: StoryCoverPlatformImage) {
        #if canImport(AppKit)
        self.init(nsImage: storyCoverPlatformImage)
        #elseif canImport(UIKit)
        self.init(uiImage: storyCoverPlatformImage)
        #else
        self.init(systemName: "sparkles.rectangle.stack")
        #endif
    }
}

/// 物語カード共通のカバー。
/// キャラ画像がある場合はそれを優先し、未登録・旧データ・未収録アセットでも
/// 世界観に合わせたカバーを描いて「画像なし」の空白を作らない。
struct StoryCoverView: View {
    let world: StoryWorld
    let character: CharacterProfile?

    var body: some View {
        ZStack {
            if let image = storedImage {
                Image(storyCoverPlatformImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                generatedCover
            }
        }
        .clipped()
        .accessibilityLabel(world.localizedForCurrentLanguage.title)
    }

    private var storedImage: StoryCoverPlatformImage? {
        if let data = character?.avatarImageData {
            #if canImport(AppKit)
            if let image = NSImage(data: data) { return image }
            #elseif canImport(UIKit)
            if let image = UIImage(data: data) { return image }
            #endif
        }
        guard let key = character?.imageKey?.trimmingCharacters(in: .whitespacesAndNewlines),
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

    private var generatedCover: some View {
        let palette = CoverPalette(for: world)
        return GeometryReader { proxy in
            ZStack {
                Image("StoryCoverFallback")
                    .resizable()
                    .scaledToFill()
                    .opacity(0.92)

                LinearGradient(
                    colors: [
                        palette.colors[0].opacity(0.76),
                        palette.colors[1].opacity(0.70)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .fill(palette.accent.opacity(0.32))
                    .frame(width: proxy.size.width * 0.82)
                    .blur(radius: 1)
                    .offset(x: proxy.size.width * 0.28, y: -proxy.size.height * 0.18)

                Circle()
                    .stroke(Color.white.opacity(0.17), lineWidth: 1)
                    .frame(width: proxy.size.width * 0.68)
                    .offset(x: -proxy.size.width * 0.30, y: proxy.size.height * 0.22)

                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .rotationEffect(.degrees(-18))
                    .frame(width: proxy.size.width * 0.95, height: proxy.size.height * 0.35)
                    .offset(y: proxy.size.height * 0.25)

                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: world.genre.group.iconName)
                        .font(.system(size: min(proxy.size.width, proxy.size.height) * 0.16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 54, height: 54)
                        .background(Circle().fill(Color.white.opacity(0.14)))

                    Spacer(minLength: 0)

                    Text(world.localizedForCurrentLanguage.genre.localizedDisplayName)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.76))
                        .textCase(.uppercase)

                    Text(world.localizedForCurrentLanguage.title)
                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(3)

                    if !world.localizedForCurrentLanguage.mood.isEmpty {
                        Text(world.localizedForCurrentLanguage.mood)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(2)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

private struct CoverPalette {
    let colors: [Color]
    let accent: Color

    init(for world: StoryWorld) {
        let text = (world.title + world.genre.rawValue + world.relationshipGenre.rawValue)
            .unicodeScalars
            .reduce(0) { ($0 &* 31) &+ Int($1.value) }
        let palettes: [([Color], Color)] = [
            ([Color(red: 0.10, green: 0.18, blue: 0.38), Color(red: 0.26, green: 0.52, blue: 0.72)], .cyan),
            ([Color(red: 0.25, green: 0.12, blue: 0.34), Color(red: 0.66, green: 0.25, blue: 0.42)], .pink),
            ([Color(red: 0.14, green: 0.28, blue: 0.24), Color(red: 0.38, green: 0.52, blue: 0.30)], .mint),
            ([Color(red: 0.34, green: 0.18, blue: 0.10), Color(red: 0.70, green: 0.42, blue: 0.16)], .orange),
            ([Color(red: 0.11, green: 0.12, blue: 0.24), Color(red: 0.30, green: 0.34, blue: 0.66)], .indigo)
        ]
        let index = text == Int.min ? 0 : abs(text) % palettes.count
        let selected = palettes[index]
        colors = selected.0
        accent = selected.1
    }
}
