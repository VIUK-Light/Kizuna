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
