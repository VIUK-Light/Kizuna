import CryptoKit
import Foundation

/// Performs inexpensive, format-aware validation before a downloaded model is
/// allowed to replace an installed artifact. Runtime self-check remains the
/// final compatibility check, but arbitrary data must not reach that stage.
enum LocalAssistantModelArtifactValidator {
    enum ValidationError: LocalizedError, Sendable {
        case unsupportedFormat
        case sizeMismatch(expected: Int64, actual: Int64)
        case digestMismatch
        case invalidExpectedDigest
        case fileTooSmall(minimum: Int64, actual: Int64)
        case invalidGGUFHeader
        case invalidLegacyGGMLHeader
        case invalidLiteRTLMMetadata
        case liteRTLMValidationUnavailable
        case unexpectedFileName

        nonisolated var errorDescription: String? {
            switch self {
            case .unsupportedFormat:
                return "対応していないモデル形式です。"
            case let .sizeMismatch(expected, actual):
                return "配布元が示したサイズと保存されたファイルサイズが一致しません（expected=\(expected), actual=\(actual)）。"
            case .digestMismatch:
                return "標準配布モデルのSHA-256が一致しません。"
            case .invalidExpectedDigest:
                return "標準配布モデルの検証情報が不正です。"
            case let .fileTooSmall(minimum, actual):
                return "モデルファイルが小さすぎます（minimum=\(minimum), actual=\(actual)）。"
            case .invalidGGUFHeader:
                return "GGUFヘッダーまたはメタデータを確認できません。"
            case .invalidLegacyGGMLHeader:
                return "旧GGMLモデルのヘッダーを確認できません。"
            case .invalidLiteRTLMMetadata:
                return "LiteRT-LMモデルのメタデータを確認できません。"
            case .liteRTLMValidationUnavailable:
                return "このビルドではカスタムLiteRT-LMモデルを検証できません。"
            case .unexpectedFileName:
                return "標準配布モデルのファイル名が一致しません。"
            }
        }
    }

    private enum ModelFormat {
        case gguf
        case legacyGGML
        case liteRTLM

        nonisolated init?(fileName: String) {
            switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
            case "gguf":
                self = .gguf
            case "bin":
                self = .legacyGGML
            case "litertlm":
                self = .liteRTLM
            default:
                return nil
            }
        }
    }

    /// Validates the on-disk structure and, when supplied, the exact artifact
    /// size and SHA-256 digest. `fileName` is separate from `url` so a
    /// URLSession temporary path can be validated before replacement begins.
    nonisolated static func validate(
        at url: URL,
        fileName: String,
        expectedByteCount: Int64? = nil,
        expectedSHA256: String? = nil,
        minimumByteCount: Int64 = 0,
        requireExactByteCount: Bool
    ) throws {
        guard let format = ModelFormat(fileName: fileName) else {
            throw ValidationError.unsupportedFormat
        }
        let fileSize = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        if minimumByteCount > 0, fileSize < minimumByteCount {
            throw ValidationError.fileTooSmall(minimum: minimumByteCount, actual: fileSize)
        }
        if let expectedByteCount, expectedByteCount > 0 {
            if requireExactByteCount {
                guard fileSize == expectedByteCount else {
                    throw ValidationError.sizeMismatch(expected: expectedByteCount, actual: fileSize)
                }
            } else {
                let tolerance = max(Int64(128 * 1024 * 1024), expectedByteCount / 20)
                guard abs(fileSize - expectedByteCount) <= tolerance else {
                    throw ValidationError.sizeMismatch(expected: expectedByteCount, actual: fileSize)
                }
            }
        }

        switch format {
        case .gguf:
            try validateGGUFHeader(at: url)
        case .legacyGGML:
            try validateLegacyGGMLHeader(at: url)
        case .liteRTLM:
            // LiteRT-LM packages use an SDK-owned metadata format. The caller
            // performs `Capabilities(modelPath:)` when the SDK is linked.
            break
        }

        if let expectedSHA256 {
            let normalizedExpectedDigest = expectedSHA256.lowercased()
            guard normalizedExpectedDigest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                throw ValidationError.invalidExpectedDigest
            }
            guard try sha256(at: url) == normalizedExpectedDigest else {
                throw ValidationError.digestMismatch
            }
        }
    }

    nonisolated static func sha256(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty {
                break
            }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func validateGGUFHeader(at url: URL) throws {
        let header = try readPrefix(from: url, count: 8_192)
        guard header.count >= 32,
              header.prefix(4) == Data([0x47, 0x47, 0x55, 0x46]),
              let version = littleEndianUInt32(in: header, at: 4),
              version > 0,
              let tensorCount = littleEndianUInt64(in: header, at: 8),
              tensorCount > 0,
              let metadataCount = littleEndianUInt64(in: header, at: 16),
              metadataCount > 0,
              let firstKeyLength = littleEndianUInt64(in: header, at: 24),
              firstKeyLength > 0,
              firstKeyLength <= 4_096,
              header.count >= 32 + Int(firstKeyLength)
        else {
            throw ValidationError.invalidGGUFHeader
        }

        let keyRange = 32..<(32 + Int(firstKeyLength))
        guard let firstMetadataKey = String(data: header.subdata(in: keyRange), encoding: .utf8),
              firstMetadataKey.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F })
        else {
            throw ValidationError.invalidGGUFHeader
        }
    }

    nonisolated private static func validateLegacyGGMLHeader(at url: URL) throws {
        let magic = try readPrefix(from: url, count: 4)
        let knownMagics: Set<Data> = [
            Data([0x67, 0x67, 0x6D, 0x6C]), // ggml
            Data([0x67, 0x67, 0x6D, 0x66]), // ggmf
            Data([0x67, 0x67, 0x6A, 0x74])  // ggjt
        ]
        guard knownMagics.contains(magic) else {
            throw ValidationError.invalidLegacyGGMLHeader
        }
    }

    nonisolated private static func readPrefix(from url: URL, count: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: count) ?? Data()
    }

    nonisolated private static func littleEndianUInt32(in data: Data, at offset: Int) -> UInt32? {
        guard data.count >= offset + 4 else { return nil }
        return data[offset..<(offset + 4)].enumerated().reduce(0) { partial, byte in
            partial | UInt32(byte.element) << UInt32(byte.offset * 8)
        }
    }

    nonisolated private static func littleEndianUInt64(in data: Data, at offset: Int) -> UInt64? {
        guard data.count >= offset + 8 else { return nil }
        return data[offset..<(offset + 8)].enumerated().reduce(0) { partial, byte in
            partial | UInt64(byte.element) << UInt64(byte.offset * 8)
        }
    }
}
