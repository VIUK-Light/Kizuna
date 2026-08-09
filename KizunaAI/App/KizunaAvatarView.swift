import SwiftUI

/// プロフィールで使える、文字絵文字に頼らないアバターの選択肢。
/// 保存値は文字列のままにして、旧バージョンの絵文字も読み出せるようにする。
enum KizunaAvatarCatalog {
    static let defaultID = "person.crop.circle.fill"

    static let options: [KizunaAvatarOption] = [
        KizunaAvatarOption(id: defaultID, japaneseTitle: "ベーシック", englishTitle: "Basic"),
        KizunaAvatarOption(id: "sparkles", japaneseTitle: "きらめき", englishTitle: "Spark"),
        KizunaAvatarOption(id: "leaf.fill", japaneseTitle: "リーフ", englishTitle: "Leaf"),
        KizunaAvatarOption(id: "moon.stars.fill", japaneseTitle: "ナイト", englishTitle: "Night"),
        KizunaAvatarOption(id: "headphones", japaneseTitle: "サウンド", englishTitle: "Sound"),
        KizunaAvatarOption(id: "book.closed.fill", japaneseTitle: "ストーリー", englishTitle: "Story"),
        KizunaAvatarOption(id: "compass.drawing", japaneseTitle: "コンパス", englishTitle: "Compass"),
        KizunaAvatarOption(id: "sun.max.fill", japaneseTitle: "デイライト", englishTitle: "Daylight")
    ]

    static func option(for id: String) -> KizunaAvatarOption? {
        options.first { $0.id == id }
    }
}

struct KizunaAvatarOption: Identifiable, Hashable {
    let id: String
    let japaneseTitle: String
    let englishTitle: String

    /// 言語設定を切り替えた後の再描画でも、現在の言語でラベルを返す。
    var title: String {
        KizunaCopy.text(japanese: japaneseTitle, english: englishTitle)
    }
}

struct KizunaAvatarView: View {
    let symbol: String
    var size: CGFloat = 72

    private var optionIndex: Int {
        KizunaAvatarCatalog.options.firstIndex { $0.id == symbol } ?? 0
    }

    private var gradientColors: [Color] {
        let palettes: [[Color]] = [
            [.blue, .indigo],
            [.purple, .pink],
            [.green, .teal],
            [.indigo, .blue],
            [.orange, .pink],
            [.brown, .orange],
            [.teal, .cyan],
            [.yellow, .orange]
        ]
        return palettes[optionIndex % palettes.count]
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: gradientColors.map { $0.opacity(0.9) },
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if KizunaAvatarCatalog.option(for: symbol) != nil {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                // 旧バージョンで保存された絵文字は、壊さずにフォールバック表示する。
                Text(symbol)
                    .font(.system(size: size * 0.42))
            }
        }
        .frame(width: size, height: size)
        .overlay {
            Circle()
                .strokeBorder(.white.opacity(0.28), lineWidth: max(1, size * 0.018))
        }
        .shadow(color: gradientColors[0].opacity(0.22), radius: size * 0.12, y: size * 0.06)
        .accessibilityLabel(
            KizunaAvatarCatalog.option(for: symbol)?.title
                ?? KizunaCopy.text(japanese: "プロフィールアイコン", english: "Profile icon")
        )
    }
}

struct KizunaAvatarPicker: View {
    @Binding var selection: String

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 10)], spacing: 10) {
            ForEach(KizunaAvatarCatalog.options) { option in
                Button {
                    selection = option.id
                } label: {
                    VStack(spacing: 7) {
                        KizunaAvatarView(symbol: option.id, size: 48)
                        Text(option.title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(selection == option.id ? Color.accentColor : .secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 76)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(selection == option.id
                                  ? Color.accentColor.opacity(0.13)
                                  : Color.primary.opacity(0.045))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(
                                selection == option.id ? Color.accentColor : Color.primary.opacity(0.08),
                                lineWidth: selection == option.id ? 1.5 : 1
                            )
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == option.id ? .isSelected : [])
            }
        }
    }
}
