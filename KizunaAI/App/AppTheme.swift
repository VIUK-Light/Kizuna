/*
仕様:
- 役割: 共通カラーや画面全体の見た目に関わるテーマ定義をまとめる。
- 主な型: `Color` 拡張やテーマ関連定数。
- 編集ポイント: 全体配色、背景色、カード色などUIトーンを変えるときに触る。
*/
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension Color {
    static var appCanvasBackground: Color {
#if canImport(UIKit)
        Color(uiColor: .systemBackground)
#elseif canImport(AppKit)
        Color(nsColor: .windowBackgroundColor)
#else
        Color(.systemBackground)
#endif
    }

    static var appSecondaryBackground: Color {
#if canImport(UIKit)
        Color(uiColor: .secondarySystemBackground)
#elseif canImport(AppKit)
        Color(nsColor: .underPageBackgroundColor)
#else
        Color(.secondarySystemBackground)
#endif
    }

    static var appCardBackground: Color {
#if canImport(UIKit)
        Color(uiColor: .tertiarySystemBackground)
#elseif canImport(AppKit)
        Color(nsColor: .controlBackgroundColor)
#else
        Color(.tertiarySystemBackground)
#endif
    }

    static var appSoftFill: Color {
#if canImport(UIKit)
        Color(uiColor: .tertiarySystemFill)
#elseif canImport(AppKit)
        Color(nsColor: .separatorColor).opacity(0.14)
#else
        Color.gray.opacity(0.14)
#endif
    }

    static var appBorder: Color {
#if canImport(UIKit)
        Color(uiColor: .separator)
#elseif canImport(AppKit)
        Color(nsColor: .separatorColor)
#else
        Color.black.opacity(0.12)
#endif
    }

    static var appElevatedBackground: Color {
#if canImport(UIKit)
        Color(uiColor: .systemBackground).opacity(0.98)
#elseif canImport(AppKit)
        Color(nsColor: .windowBackgroundColor).opacity(0.98)
#else
        Color.white.opacity(0.98)
#endif
    }
}

extension View {
    @ViewBuilder
    func viukMacWindowFrame(minWidth: CGFloat, minHeight: CGFloat) -> some View {
        #if os(macOS)
        self.frame(minWidth: minWidth, minHeight: minHeight)
        #else
        self
        #endif
    }

    func viukSurfaceCard(
        cornerRadius: CGFloat = 20,
        fill: Color = .appElevatedBackground,
        border: Color = Color.appBorder.opacity(0.18),
        shadowOpacity: Double = 0.035,
        shadowRadius: CGFloat = 14,
        shadowY: CGFloat = 8
    ) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(border, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(shadowOpacity), radius: shadowRadius, x: 0, y: shadowY)
    }

    func viukInsetCard(
        cornerRadius: CGFloat = 16,
        fill: Color = .appSecondaryBackground,
        border: Color = Color.appBorder.opacity(0.12)
    ) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(border, lineWidth: 1)
        )
    }
}

// MARK: - SafeBrowser Design Tokens
// AIsudio (AI Studio) と同じ warm tonality を SafeBrowser 系画面（履歴・ブロック・設定）でも
// 統一して使うためのトークン群。light/dark 両モードに自然に馴染むよう、システム色を基準に
// 微調整するヘルパーも提供する。
enum SafeBrowserToken {
    // 角丸
    static let radiusXS: CGFloat = 6
    static let radiusS: CGFloat = 10
    static let radiusM: CGFloat = 14
    static let radiusL: CGFloat = 18
    static let radiusXL: CGFloat = 22

    // hairline / softFill
    static let hairline = Color.primary.opacity(0.08)
    static let hairlineStrong = Color.primary.opacity(0.14)
    static let softFill = Color.primary.opacity(0.04)
    static let softFillHover = Color.primary.opacity(0.08)
    static let softFillActive = Color.primary.opacity(0.12)

    // SafeBrowser ブランド色（kid-friendly warm palette）
    static let brandWarm = Color(red: 0.93, green: 0.55, blue: 0.30)        // 暖色アクセント
    static let brandWarmSoft = Color(red: 0.93, green: 0.55, blue: 0.30).opacity(0.16)
    static let brandTrust = Color(red: 0.30, green: 0.62, blue: 0.95)       // 信頼の青
    static let brandTrustSoft = Color(red: 0.30, green: 0.62, blue: 0.95).opacity(0.16)

    // 安全度表示
    static let safetyOk = Color(red: 0.28, green: 0.72, blue: 0.45)
    static let safetyOkSoft = Color(red: 0.28, green: 0.72, blue: 0.45).opacity(0.16)
    static let safetyWarn = Color(red: 0.95, green: 0.65, blue: 0.20)
    static let safetyWarnSoft = Color(red: 0.95, green: 0.65, blue: 0.20).opacity(0.18)
    static let safetyDanger = Color(red: 0.92, green: 0.32, blue: 0.32)
    static let safetyDangerSoft = Color(red: 0.92, green: 0.32, blue: 0.32).opacity(0.16)

    /// 安全度スコア (0.0〜1.0) から色を返す。
    static func safetyColor(for score: Double) -> Color {
        if score >= 0.8 { return safetyOk }
        if score >= 0.5 { return safetyWarn }
        return safetyDanger
    }

    static func safetyColorSoft(for score: Double) -> Color {
        if score >= 0.8 { return safetyOkSoft }
        if score >= 0.5 { return safetyWarnSoft }
        return safetyDangerSoft
    }

    static func safetyIcon(for score: Double) -> String {
        if score >= 0.8 { return "checkmark.shield.fill" }
        if score >= 0.5 { return "exclamationmark.shield.fill" }
        return "xmark.shield.fill"
    }
}

extension View {
    /// SafeBrowser 系画面で使うシンプルなカード装飾。
    func safeBrowserCard(
        cornerRadius: CGFloat = SafeBrowserToken.radiusM,
        fill: Color = .appCardBackground,
        border: Color = SafeBrowserToken.hairline
    ) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(border, lineWidth: 1)
        )
    }

    /// 半透明の柔らかいフィル（リスト行・チップ等）。
    func safeBrowserSoftRow(
        cornerRadius: CGFloat = SafeBrowserToken.radiusM
    ) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(SafeBrowserToken.softFill)
        )
    }
}

/// 色付きピル型バッジ（カテゴリ/ステータス表示用）。
struct SafeBrowserChip: View {
    let text: String
    let icon: String?
    let color: Color
    let softColor: Color

    init(text: String, icon: String? = nil, color: Color, softColor: Color? = nil) {
        self.text = text
        self.icon = icon
        self.color = color
        self.softColor = softColor ?? color.opacity(0.16)
    }

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous).fill(softColor)
        )
    }
}
