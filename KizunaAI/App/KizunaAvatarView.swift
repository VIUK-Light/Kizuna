import Foundation
import ImageIO
import SwiftUI
import PhotosUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// プロフィールで使える、文字絵文字に頼らないアバターの選択肢。
/// 保存値は文字列のままにして、旧バージョンの絵文字も読み出せるようにする。
enum KizunaAvatarCatalog {
    static let defaultID = "person.crop.circle.fill"
    static let customImageID = "custom.profile.image"

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

enum KizunaAvatarImage {
    private static let maximumPixelSize = 512
    /// 写真ライブラリの原本をImageIOへ渡す前に、入力サイズを制限する。
    static let maximumInputByteCount = 40 * 1024 * 1024
    /// UserDefaultsへ保存するプロフィール画像の上限。
    static let maximumStoredByteCount = 2 * 1024 * 1024

    static func image(from data: Data?) -> Image? {
        guard let data else { return nil }

        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
        #elseif canImport(AppKit)
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
        #else
        return nil
        #endif
    }

    /// CharacterProfile.imageKey / PersonaProfile.avatarStyleID に入る
    /// Asset Catalog名を、ライブラリーとPersonaで同じ優先順位で解決する。
    static func image(named name: String?) -> Image? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }

        #if canImport(UIKit)
        guard let image = UIImage(named: name) else { return nil }
        return Image(uiImage: image)
        #elseif canImport(AppKit)
        guard let image = NSImage(named: name) else { return nil }
        return Image(nsImage: image)
        #else
        return nil
        #endif
    }

    /// Store a small, normalized JPEG instead of the original camera asset.
    /// This keeps the profile in UserDefaults bounded while retaining enough
    /// resolution for the circular avatar surfaces.
    static func normalizedData(from data: Data) -> Data? {
        guard data.count <= maximumInputByteCount else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceShouldCacheImmediately: false,
                      kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
                  ] as CFDictionary
              ) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImage(
            destination,
            thumbnail,
            [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        let normalized = output as Data
        guard normalized.count <= maximumStoredByteCount else { return nil }
        return normalized
    }

    /// Normalize both newly selected and legacy stored data before persistence.
    static func normalizedStoredData(from data: Data?) -> Data? {
        guard let data else { return nil }
        return normalizedData(from: data)
    }
}

struct KizunaAvatarView: View {
    let symbol: String
    let imageData: Data?
    var size: CGFloat = 72
    @State private var decodedImage: Image?
    @State private var decodedImageData: Data?

    init(symbol: String, imageData: Data? = nil, size: CGFloat = 72) {
        self.symbol = symbol
        self.imageData = imageData
        self.size = size
    }

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

    private var hasCurrentDecodedImage: Bool {
        imageData != nil && decodedImageData == imageData && decodedImage != nil
    }

    private var accessibilityText: String {
        if hasCurrentDecodedImage {
            return KizunaCopy.text(japanese: "プロフィール画像", english: "Profile photo")
        }
        if symbol == KizunaAvatarCatalog.customImageID {
            return KizunaAvatarCatalog.option(for: KizunaAvatarCatalog.defaultID)?.title
                ?? KizunaCopy.text(japanese: "プロフィールアイコン", english: "Profile icon")
        }
        return KizunaAvatarCatalog.option(for: symbol)?.title
            ?? KizunaCopy.text(japanese: "プロフィールアイコン", english: "Profile icon")
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

            if hasCurrentDecodedImage, let image = decodedImage {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else if symbol == KizunaAvatarCatalog.customImageID {
                Image(systemName: KizunaAvatarCatalog.defaultID)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            } else if KizunaAvatarCatalog.option(for: symbol) != nil {
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
        .accessibilityLabel(accessibilityText)
        .task(id: imageData) {
            let nextData = imageData
            decodedImageData = nextData
            decodedImage = KizunaAvatarImage.image(from: nextData)
        }
    }
}

struct KizunaAvatarPicker: View {
    @Binding var selection: String
    @Binding var imageData: Data?
    @Binding var isLoadingPhoto: Bool
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photoError: String?

    init(
        selection: Binding<String>,
        imageData: Binding<Data?>,
        isLoadingPhoto: Binding<Bool> = .constant(false)
    ) {
        _selection = selection
        _imageData = imageData
        _isLoadingPhoto = isLoadingPhoto
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                PhotosPicker(selection: $selectedPhoto, matching: .images, photoLibrary: .shared()) {
                    HStack(spacing: 9) {
                        KizunaAvatarView(symbol: selection, imageData: imageData, size: 48)
                        Text(KizunaCopy.text(
                            japanese: imageData == nil ? "自分の画像を選ぶ" : "画像を変更",
                            english: imageData == nil ? "Choose your photo" : "Change photo"
                        ))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isLoadingPhoto)

                if imageData != nil {
                    Button(KizunaCopy.text(japanese: "画像を削除", english: "Remove photo")) {
                        imageData = nil
                        selection = KizunaAvatarCatalog.defaultID
                        selectedPhoto = nil
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .disabled(isLoadingPhoto)
                }
            }

            if isLoadingPhoto {
                ProgressView(KizunaCopy.text(japanese: "画像を読み込み中…", english: "Loading photo…"))
                    .font(.caption)
            }
            if let photoError {
                Text(photoError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 10)], spacing: 10) {
                ForEach(KizunaAvatarCatalog.options) { option in
                    Button {
                        selection = option.id
                        imageData = nil
                        photoError = nil
                    } label: {
                        VStack(spacing: 7) {
                            KizunaAvatarView(symbol: option.id, size: 48)
                            Text(option.title)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(selection == option.id && imageData == nil ? Color.accentColor : .secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 76)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(selection == option.id && imageData == nil
                                      ? Color.accentColor.opacity(0.13)
                                      : Color.primary.opacity(0.045))
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(
                                    selection == option.id && imageData == nil ? Color.accentColor : Color.primary.opacity(0.08),
                                    lineWidth: selection == option.id && imageData == nil ? 1.5 : 1
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == option.id && imageData == nil ? .isSelected : [])
                    .disabled(isLoadingPhoto)
                }
            }
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            isLoadingPhoto = true
            photoError = nil

            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw KizunaAvatarError.invalidImage
                    }
                    let normalizedData = await Task.detached(priority: .userInitiated) {
                        KizunaAvatarImage.normalizedData(from: data)
                    }.value
                    guard let normalizedData else {
                        throw KizunaAvatarError.invalidImage
                    }
                    await MainActor.run {
                        imageData = normalizedData
                        selection = KizunaAvatarCatalog.customImageID
                        isLoadingPhoto = false
                        selectedPhoto = nil
                    }
                } catch {
                    await MainActor.run {
                        isLoadingPhoto = false
                        selectedPhoto = nil
                        photoError = KizunaCopy.text(
                            japanese: "画像を読み込めませんでした。",
                            english: "The photo could not be loaded."
                        )
                    }
                }
            }
        }
    }
}

private enum KizunaAvatarError: Error {
    case invalidImage
}
