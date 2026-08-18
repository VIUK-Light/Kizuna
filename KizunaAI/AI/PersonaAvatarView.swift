/*
仕様:
- 役割: ペルソナのアバター表示と、その配色・アセット解決。
- 主な型: `PersonaAvatarView`, `PersonaAvatarStyle`.
- 編集ポイント: キャラクターの配色パレットやアセットを変えるときに触る。
- 方針: スタイルは PersonaProfile.avatarStyleID でデータ駆動に解決する。
  名前一致は旧スナップショット保存データとの互換のためのフォールバック (#285)。
*/

import SwiftUI

struct PersonaAvatarView: View {
    let profile: PersonaProfile
    let size: CGFloat

    var body: some View {
        let style = PersonaAvatarStyle(profile: profile)
        ZStack {
            if let image = KizunaAvatarImage.image(from: profile.avatarImageData) {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: size + 2, height: size + 2)
                    .clipShape(Circle())
            } else if let assetName = style.assetName {
                Image(assetName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size + 2, height: size + 2)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [style.highlight, style.primary, style.shadow],
                            center: .topLeading,
                            startRadius: 1,
                            endRadius: size
                        )
                    )
                // 画像未登録時はイニシャルや文字ではなく、人型アイコンを表示する。
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Circle()
                .strokeBorder(.white.opacity(0.58), lineWidth: max(1, size * 0.052))
            Circle()
                .strokeBorder(style.primary.opacity(0.34), lineWidth: max(1, size * 0.028))
                .padding(max(1, size * 0.045))
        }
        .frame(width: size, height: size)
        .background(
            Circle()
                .fill(style.highlight.opacity(0.22))
                .frame(width: size * 1.15, height: size * 1.15)
        )
        .shadow(color: style.shadow.opacity(0.26), radius: size * 0.12, y: size * 0.05)
        .accessibilityLabel(profile.name)
    }

}

/// アバターの配色とアセット。ID駆動で解決し、名前一致は旧保存データ用のフォールバック。
/// PersonaMessageBubble / PersonaComposer からも参照するため internal。
struct PersonaAvatarStyle {
    let primary: Color
    let highlight: Color
    let shadow: Color
    let assetName: String?

    /// スタイルID（アセット名と共通の識別子）ごとの定義済みパレット。
    /// キャラクター名はキーにしない。名前の変更・翻訳・複製で見た目が変わらないため。
    private static let palettes: [String: (primary: Color, highlight: Color, shadow: Color)] = [
        "PersonaAoiAvatar": (
            Color(red: 0.32, green: 0.50, blue: 0.86),
            Color(red: 0.70, green: 0.90, blue: 1.00),
            Color(red: 0.09, green: 0.16, blue: 0.34)
        ),
        "PersonaHaruAvatar": (
            Color(red: 1.00, green: 0.58, blue: 0.20),
            Color(red: 1.00, green: 0.91, blue: 0.38),
            Color(red: 0.57, green: 0.19, blue: 0.05)
        ),
        "PersonaYuiAvatar": (
            Color(red: 0.95, green: 0.42, blue: 0.68),
            Color(red: 1.00, green: 0.78, blue: 0.88),
            Color(red: 0.46, green: 0.09, blue: 0.26)
        ),
        "PersonaKaiAvatar": (
            Color(red: 0.19, green: 0.25, blue: 0.35),
            Color(red: 0.53, green: 0.66, blue: 0.82),
            Color(red: 0.03, green: 0.05, blue: 0.09)
        ),
        "PersonaRenAvatar": (
            Color(red: 0.32, green: 0.58, blue: 0.47),
            Color(red: 0.74, green: 0.89, blue: 0.66),
            Color(red: 0.08, green: 0.25, blue: 0.19)
        ),
        "PersonaNakamuraAvatar": (
            Color(red: 0.45, green: 0.39, blue: 0.72),
            Color(red: 0.88, green: 0.79, blue: 1.00),
            Color(red: 0.17, green: 0.12, blue: 0.33)
        ),
        "PersonaTsubasaAvatar": (
            Color(red: 0.16, green: 0.68, blue: 0.76),
            Color(red: 0.75, green: 1.00, blue: 0.96),
            Color(red: 0.02, green: 0.28, blue: 0.35)
        )
    ]

    /// avatarStyleID 未設定の旧保存スナップショットのための名前→ID対応。
    /// 新規データはすべて avatarStyleID を持つため、ここを編集しない。
    private static let legacyNameToStyleID: [String: String] = [
        "アオイ": "PersonaAoiAvatar",
        "ハル": "PersonaHaruAvatar",
        "ユイ": "PersonaYuiAvatar",
        "カイ": "PersonaKaiAvatar",
        "レン": "PersonaRenAvatar",
        "ナカムラ先生": "PersonaNakamuraAvatar",
        "ツバサ": "PersonaTsubasaAvatar"
    ]

    init(profile: PersonaProfile) {
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        // 1) プロファイルのIDで解決（正規経路）
        // 2) 旧スナップショットは名前からIDへフォールバック
        let styleID = profile.avatarStyleID ?? Self.legacyNameToStyleID[name]

        if let palette = styleID.flatMap({ Self.palettes[$0] }) {
            primary = palette.primary
            highlight = palette.highlight
            shadow = palette.shadow
            assetName = styleID.flatMap { Self.palettes[$0] != nil ? $0 : nil }
        } else {
            let hue = Self.nameHue(name)
            primary = Color(hue: hue, saturation: 0.58, brightness: 0.92)
            highlight = Color(hue: hue, saturation: 0.30, brightness: 1.00)
            shadow = Color(hue: hue, saturation: 0.70, brightness: 0.38)
            assetName = nil
        }
    }

    private static func nameHue(_ name: String) -> Double {
        var sum: Int = 0
        for scalar in name.unicodeScalars { sum &+= Int(scalar.value) }
        return Double(sum % 360) / 360.0
    }

}
