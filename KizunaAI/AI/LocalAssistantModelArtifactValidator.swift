import CryptoKit
import Foundation

/// Performs format-aware validation before a downloaded model is allowed to
/// replace an installed artifact. A runtime self-check remains the final
/// compatibility check, but a valid filename or four-byte magic must never be
/// enough to advance arbitrary data to that stage.
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
                return "GGUFヘッダー、メタデータ、またはテンソル領域を確認できません。"
            case .invalidLegacyGGMLHeader:
                return "旧GGMLモデルのヘッダー、語彙、またはテンソル領域を確認できません。"
            case .invalidLiteRTLMMetadata:
                return "LiteRT-LMモデルのメタデータを確認できません。"
            case .liteRTLMValidationUnavailable:
                return "このビルドではカスタムLiteRT-LMモデルを検証できません。"
            case .unexpectedFileName:
                return "標準配布モデルのファイル名が一致しません。"
            }
        }
    }

    /// Stored-model discovery needs a fast structural check. Complete
    /// candidates use `.strict` off the main actor before replacement; only
    /// that path may also request a full SHA-256 digest.
    nonisolated enum ValidationDepth: Sendable {
        case quick
        case strict
    }

    nonisolated private enum ModelFormat {
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

    nonisolated private enum GGUFMetadataValueType: UInt32 {
        case uint8 = 0
        case int8 = 1
        case uint16 = 2
        case int16 = 3
        case uint32 = 4
        case int32 = 5
        case float32 = 6
        case bool = 7
        case string = 8
        case array = 9
        case uint64 = 10
        case int64 = 11
        case float64 = 12
    }

    nonisolated private enum LegacyGGMLFormat {
        case ggml
        case ggmf
        case ggjt

        var hasVocabularyScores: Bool {
            self != .ggml
        }

        var alignsTensorData: Bool {
            self == .ggjt
        }
    }

    nonisolated private struct TensorLayout: Sendable {
        let elementsPerBlock: UInt64
        let bytesPerBlock: UInt64
    }

    nonisolated private struct TensorRange: Sendable {
        let offset: UInt64
        let byteCount: UInt64
    }

    nonisolated private enum ReaderError: Error {
        case malformed
    }

    /// A small sequential reader that leaves tensor payloads on disk. It keeps
    /// a bounded look-ahead buffer so tokenizer metadata does not cause a
    /// system call for every tiny string.
    nonisolated private struct BufferedFileReader {
        private let handle: FileHandle
        let fileSize: UInt64
        private var buffer = Data()
        private var bufferStartOffset: UInt64 = 0
        private(set) var offset: UInt64 = 0

        init(url: URL) throws {
            let fileSize = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            guard fileSize >= 0 else { throw ReaderError.malformed }
            self.fileSize = UInt64(fileSize)
            handle = try FileHandle(forReadingFrom: url)
        }

        func close() {
            try? handle.close()
        }

        var remaining: UInt64 {
            fileSize - offset
        }

        mutating func readByte() throws -> UInt8 {
            try readData(count: 1)[0]
        }

        mutating func readUInt32() throws -> UInt32 {
            let data = try readData(count: 4)
            return data.enumerated().reduce(0) { partial, byte in
                partial | UInt32(byte.element) << UInt32(byte.offset * 8)
            }
        }

        mutating func readUInt64() throws -> UInt64 {
            let data = try readData(count: 8)
            return data.enumerated().reduce(0) { partial, byte in
                partial | UInt64(byte.element) << UInt64(byte.offset * 8)
            }
        }

        mutating func readData(count: Int) throws -> Data {
            guard count >= 0 else { throw ReaderError.malformed }
            try ensureBuffered(count: count)
            let start = Int(offset - bufferStartOffset)
            let data = buffer.subdata(in: start..<(start + count))
            offset += UInt64(count)
            discardConsumedPrefixIfNeeded()
            return data
        }

        mutating func readUTF8String(maximumLength: UInt64) throws -> String {
            let length = try readUInt64()
            guard length <= maximumLength, length <= remaining, length <= UInt64(Int.max) else {
                throw ReaderError.malformed
            }
            let data = try readData(count: Int(length))
            guard let value = String(data: data, encoding: .utf8) else {
                throw ReaderError.malformed
            }
            return value
        }

        mutating func skipLengthPrefixedBytes(maximumLength: UInt64) throws {
            let length = try readUInt64()
            guard length <= maximumLength else { throw ReaderError.malformed }
            try skip(length)
        }

        mutating func skip(_ count: UInt64) throws {
            guard count <= remaining else { throw ReaderError.malformed }
            offset += count
            discardConsumedPrefixIfNeeded()
        }

        mutating func skipToAlignment(_ alignment: UInt64, requireZeroPadding: Bool) throws {
            guard alignment > 0 else { throw ReaderError.malformed }
            let remainder = offset % alignment
            guard remainder != 0 else { return }
            let padding = alignment - remainder
            if requireZeroPadding {
                guard try readData(count: Int(padding)).allSatisfy({ $0 == 0 }) else {
                    throw ReaderError.malformed
                }
            } else {
                try skip(padding)
            }
        }

        private mutating func ensureBuffered(count: Int) throws {
            let requested = UInt64(count)
            guard requested <= remaining else { throw ReaderError.malformed }
            let (target, overflow) = offset.addingReportingOverflow(requested)
            guard !overflow else { throw ReaderError.malformed }

            var bufferEnd = bufferStartOffset + UInt64(buffer.count)
            if offset < bufferStartOffset || offset > bufferEnd {
                buffer.removeAll(keepingCapacity: true)
                bufferStartOffset = offset
                bufferEnd = offset
            }

            while bufferEnd < target {
                try handle.seek(toOffset: bufferEnd)
                let needed = target - bufferEnd
                let available = fileSize - bufferEnd
                let chunkSize = min(max(UInt64(64 * 1024), needed), available)
                guard chunkSize <= UInt64(Int.max) else { throw ReaderError.malformed }
                let chunk = try handle.read(upToCount: Int(chunkSize)) ?? Data()
                guard !chunk.isEmpty else { throw ReaderError.malformed }
                buffer.append(chunk)
                bufferEnd += UInt64(chunk.count)
            }
        }

        private mutating func discardConsumedPrefixIfNeeded() {
            let bufferEnd = bufferStartOffset + UInt64(buffer.count)
            guard offset > bufferStartOffset else { return }

            if offset >= bufferEnd {
                buffer.removeAll(keepingCapacity: true)
                bufferStartOffset = offset
                return
            }

            let consumed = offset - bufferStartOffset
            guard consumed >= UInt64(64 * 1024), consumed <= UInt64(Int.max) else { return }
            buffer.removeSubrange(0..<Int(consumed))
            bufferStartOffset = offset
        }
    }

    // Derived from the bundled llama.cpp ggml_type table. A tensor range is
    // valid only when its declared type, element count, and bytes all fit in
    // the GGUF tensor-data region.
    nonisolated private static let tensorLayouts: [UInt32: TensorLayout] = [
        0: TensorLayout(elementsPerBlock: 1, bytesPerBlock: 4),
        1: TensorLayout(elementsPerBlock: 1, bytesPerBlock: 2),
        2: TensorLayout(elementsPerBlock: 32, bytesPerBlock: 18),
        3: TensorLayout(elementsPerBlock: 32, bytesPerBlock: 20),
        6: TensorLayout(elementsPerBlock: 32, bytesPerBlock: 22),
        7: TensorLayout(elementsPerBlock: 32, bytesPerBlock: 24),
        8: TensorLayout(elementsPerBlock: 32, bytesPerBlock: 34),
        9: TensorLayout(elementsPerBlock: 32, bytesPerBlock: 36),
        10: TensorLayout(elementsPerBlock: 256, bytesPerBlock: 84),
        11: TensorLayout(elementsPerBlock: 256, bytesPerBlock: 110),
        12: TensorLayout(elementsPerBlock: 256, bytesPerBlock: 144),
        13: TensorLayout(elementsPerBlock: 256, bytesPerBlock: 176),
        14: TensorLayout(elementsPerBlock: 256, bytesPerBlock: 210),
        15: TensorLayout(elementsPerBlock: 256, bytesPerBlock: 292),
        16: TensorLayout(elementsPerBlock: 256, bytesPerBlock: 66),
        17: TensorLayout(elementsPerBlock: 256, bytesPerBlock: 74),
        18: TensorLayout(elementsPerBlock: 256, bytesPerBlock: 98),
        19: TensorLayout(elementsPerBlock: 256, bytesPerBlock: 50),
        20: TensorLayout(elementsPerBlock: 32, bytesPerBlock: 18),
        21: TensorLayout(elementsPerBlock: 256, bytesPerBlock: 110),
        22: TensorLayout(elementsPerBlock: 256, bytesPerBlock: 82),
        23: TensorLayout(elementsPerBlock: 256, bytesPerBlock: 136),
        24: TensorLayout(elementsPerBlock: 1, bytesPerBlock: 1),
        25: TensorLayout(elementsPerBlock: 1, bytesPerBlock: 2),
        26: TensorLayout(elementsPerBlock: 1, bytesPerBlock: 4),
        27: TensorLayout(elementsPerBlock: 1, bytesPerBlock: 8),
        28: TensorLayout(elementsPerBlock: 1, bytesPerBlock: 8),
        29: TensorLayout(elementsPerBlock: 256, bytesPerBlock: 56),
        30: TensorLayout(elementsPerBlock: 1, bytesPerBlock: 2),
        34: TensorLayout(elementsPerBlock: 256, bytesPerBlock: 54),
        35: TensorLayout(elementsPerBlock: 256, bytesPerBlock: 66),
        39: TensorLayout(elementsPerBlock: 32, bytesPerBlock: 17),
        40: TensorLayout(elementsPerBlock: 64, bytesPerBlock: 36)
    ]

    nonisolated private static let supportedLegacyFTypes: Set<UInt32> = [
        0, 1, 2, 3, 4, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18
    ]

    nonisolated private static let maximumMetadataEntries: UInt64 = 1_000_000
    nonisolated private static let maximumTensorEntries: UInt64 = 1_000_000
    nonisolated private static let maximumArrayElements: UInt64 = 8_000_000
    nonisolated private static let maximumMetadataStringBytes: UInt64 = 64 * 1024 * 1024
    nonisolated private static let maximumLegacyVocabularyEntries: UInt32 = 1_000_000

    /// Validates the on-disk structure and, when supplied, the exact artifact
    /// size and SHA-256 digest. `fileName` is separate from `url` so a
    /// URLSession temporary path can be validated before replacement begins.
    nonisolated static func validate(
        at url: URL,
        fileName: String,
        expectedByteCount: Int64? = nil,
        expectedSHA256: String? = nil,
        minimumByteCount: Int64 = 0,
        requireExactByteCount: Bool,
        validationDepth: ValidationDepth = .strict
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
            try validateGGUFHeader(at: url, depth: validationDepth)
        case .legacyGGML:
            try validateLegacyGGMLHeader(at: url, depth: validationDepth)
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

    nonisolated private static func validateGGUFHeader(at url: URL, depth: ValidationDepth) throws {
        do {
            var reader = try BufferedFileReader(url: url)
            defer { reader.close() }

            guard try reader.readData(count: 4) == Data([0x47, 0x47, 0x55, 0x46]) else {
                throw ReaderError.malformed
            }
            let version = try reader.readUInt32()
            guard version == 2 || version == 3 else { throw ReaderError.malformed }
            let tensorCount = try reader.readUInt64()
            let metadataCount = try reader.readUInt64()
            guard tensorCount > 0,
                  tensorCount <= maximumTensorEntries,
                  metadataCount > 0,
                  metadataCount <= maximumMetadataEntries else {
                throw ReaderError.malformed
            }
            guard depth == .strict else { return }

            var alignment: UInt64 = 32
            var hasArchitecture = false
            var metadataKeys = Set<String>()
            var metadataIndex: UInt64 = 0
            while metadataIndex < metadataCount {
                let key = try reader.readUTF8String(maximumLength: 65_535)
                guard isValidGGUFMetadataKey(key), metadataKeys.insert(key).inserted,
                      let valueType = GGUFMetadataValueType(rawValue: try reader.readUInt32()) else {
                    throw ReaderError.malformed
                }

                switch key {
                case "general.architecture":
                    guard valueType == .string else { throw ReaderError.malformed }
                    let architecture = try reader.readUTF8String(maximumLength: 128)
                    guard isValidGGUFArchitecture(architecture) else { throw ReaderError.malformed }
                    hasArchitecture = true
                case "general.alignment":
                    guard valueType == .uint32 else { throw ReaderError.malformed }
                    alignment = UInt64(try reader.readUInt32())
                    guard alignment >= 8, alignment <= 4_096, alignment % 8 == 0 else {
                        throw ReaderError.malformed
                    }
                default:
                    try skipGGUFMetadataValue(valueType, reader: &reader)
                }
                metadataIndex += 1
            }
            guard hasArchitecture else { throw ReaderError.malformed }

            var tensorNames = Set<String>()
            var tensorRanges: [TensorRange] = []
            tensorRanges.reserveCapacity(Int(min(tensorCount, 16_384)))
            var tensorIndex: UInt64 = 0
            while tensorIndex < tensorCount {
                let name = try reader.readUTF8String(maximumLength: 64)
                guard !name.isEmpty, tensorNames.insert(name).inserted else {
                    throw ReaderError.malformed
                }
                let dimensionsCount = try reader.readUInt32()
                guard (1...4).contains(dimensionsCount) else { throw ReaderError.malformed }
                var dimensions: [UInt64] = []
                dimensions.reserveCapacity(Int(dimensionsCount))
                for _ in 0..<dimensionsCount {
                    let dimension = try reader.readUInt64()
                    guard dimension > 0 else { throw ReaderError.malformed }
                    dimensions.append(dimension)
                }
                let type = try reader.readUInt32()
                let byteCount = try tensorByteCount(dimensions: dimensions, type: type)
                let offset = try reader.readUInt64()
                guard offset % alignment == 0 else { throw ReaderError.malformed }
                tensorRanges.append(TensorRange(offset: offset, byteCount: byteCount))
                tensorIndex += 1
            }

            guard let tensorDataStart = alignedOffset(reader.offset, to: alignment),
                  tensorDataStart <= reader.fileSize,
                  tensorDataStart >= reader.offset else {
                throw ReaderError.malformed
            }
            let padding = tensorDataStart - reader.offset
            guard padding <= UInt64(Int.max),
                  try reader.readData(count: Int(padding)).allSatisfy({ $0 == 0 }) else {
                throw ReaderError.malformed
            }

            var previousTensorEnd: UInt64 = 0
            for range in tensorRanges.sorted(by: { $0.offset < $1.offset }) {
                guard range.offset >= previousTensorEnd else { throw ReaderError.malformed }
                let (end, overflow) = range.offset.addingReportingOverflow(range.byteCount)
                guard !overflow else { throw ReaderError.malformed }
                previousTensorEnd = end
            }
            let (fileDataEnd, overflow) = tensorDataStart.addingReportingOverflow(previousTensorEnd)
            guard !overflow, fileDataEnd <= reader.fileSize else { throw ReaderError.malformed }
        } catch {
            throw ValidationError.invalidGGUFHeader
        }
    }

    nonisolated private static func validateLegacyGGMLHeader(at url: URL, depth: ValidationDepth) throws {
        do {
            var reader = try BufferedFileReader(url: url)
            defer { reader.close() }

            let magic = try reader.readData(count: 4)
            let format: LegacyGGMLFormat
            switch magic {
            case Data([0x67, 0x67, 0x6D, 0x6C]): // ggml
                format = .ggml
            case Data([0x67, 0x67, 0x6D, 0x66]): // ggmf
                guard try reader.readUInt32() == 1 else { throw ReaderError.malformed }
                format = .ggmf
            case Data([0x67, 0x67, 0x6A, 0x74]): // ggjt
                let version = try reader.readUInt32()
                guard (1...3).contains(version) else { throw ReaderError.malformed }
                format = .ggjt
            default:
                throw ReaderError.malformed
            }

            let vocabularyCount = try reader.readUInt32()
            let embeddingLength = try reader.readUInt32()
            let multiplier = try reader.readUInt32()
            let headCount = try reader.readUInt32()
            let layerCount = try reader.readUInt32()
            let rotationDimensions = try reader.readUInt32()
            let fileType = try reader.readUInt32()
            try validateLegacyHyperparameters(
                vocabularyCount: vocabularyCount,
                embeddingLength: embeddingLength,
                multiplier: multiplier,
                headCount: headCount,
                layerCount: layerCount,
                rotationDimensions: rotationDimensions,
                fileType: fileType
            )
            guard depth == .strict else { return }

            for _ in 0..<vocabularyCount {
                let tokenLength = UInt64(try reader.readUInt32())
                guard tokenLength <= 4_096 else { throw ReaderError.malformed }
                try reader.skip(tokenLength)
                if format.hasVocabularyScores {
                    try reader.skip(4)
                }
            }

            var tensorCount = 0
            while reader.offset < reader.fileSize {
                let dimensionsCount = try reader.readUInt32()
                let nameLength = try reader.readUInt32()
                let type = try reader.readUInt32()
                guard (1...4).contains(dimensionsCount), nameLength > 0, nameLength <= 4_096 else {
                    throw ReaderError.malformed
                }
                var dimensions: [UInt64] = []
                dimensions.reserveCapacity(Int(dimensionsCount))
                for _ in 0..<dimensionsCount {
                    let dimension = UInt64(try reader.readUInt32())
                    guard dimension > 0 else { throw ReaderError.malformed }
                    dimensions.append(dimension)
                }
                try reader.skip(UInt64(nameLength))
                if format.alignsTensorData {
                    try reader.skipToAlignment(32, requireZeroPadding: true)
                }
                try reader.skip(try tensorByteCount(dimensions: dimensions, type: type))
                tensorCount += 1
                guard tensorCount <= Int(maximumTensorEntries) else { throw ReaderError.malformed }
            }
            guard tensorCount > 0, reader.offset == reader.fileSize else {
                throw ReaderError.malformed
            }
        } catch {
            throw ValidationError.invalidLegacyGGMLHeader
        }
    }

    nonisolated private static func validateLegacyHyperparameters(
        vocabularyCount: UInt32,
        embeddingLength: UInt32,
        multiplier: UInt32,
        headCount: UInt32,
        layerCount: UInt32,
        rotationDimensions: UInt32,
        fileType: UInt32
    ) throws {
        guard vocabularyCount > 0,
              vocabularyCount <= maximumLegacyVocabularyEntries,
              embeddingLength > 0,
              embeddingLength <= 262_144,
              multiplier > 0,
              headCount > 0,
              headCount <= embeddingLength,
              embeddingLength % headCount == 0,
              layerCount > 0,
              layerCount <= 100_000,
              rotationDimensions > 0,
              rotationDimensions <= embeddingLength,
              supportedLegacyFTypes.contains(fileType % 1_000) else {
            throw ReaderError.malformed
        }
    }

    nonisolated private static func skipGGUFMetadataValue(
        _ type: GGUFMetadataValueType,
        reader: inout BufferedFileReader,
        recursionDepth: Int = 0
    ) throws {
        switch type {
        case .uint8, .int8:
            try reader.skip(1)
        case .uint16, .int16:
            try reader.skip(2)
        case .uint32, .int32, .float32:
            try reader.skip(4)
        case .uint64, .int64, .float64:
            try reader.skip(8)
        case .bool:
            guard try reader.readByte() <= 1 else { throw ReaderError.malformed }
        case .string:
            try reader.skipLengthPrefixedBytes(maximumLength: maximumMetadataStringBytes)
        case .array:
            guard recursionDepth < 8,
                  let elementType = GGUFMetadataValueType(rawValue: try reader.readUInt32()) else {
                throw ReaderError.malformed
            }
            let elementCount = try reader.readUInt64()
            guard elementCount <= maximumArrayElements,
                  let minimumElementSize = minimumSerializedSize(for: elementType),
                  elementCount <= reader.remaining / minimumElementSize else {
                throw ReaderError.malformed
            }

            if let fixedSize = fixedSerializedSize(for: elementType) {
                let (byteCount, overflow) = elementCount.multipliedReportingOverflow(by: fixedSize)
                guard !overflow else { throw ReaderError.malformed }
                if elementType == .bool {
                    guard byteCount <= UInt64(Int.max),
                          try reader.readData(count: Int(byteCount)).allSatisfy({ $0 <= 1 }) else {
                        throw ReaderError.malformed
                    }
                } else {
                    try reader.skip(byteCount)
                }
                return
            }

            var index: UInt64 = 0
            while index < elementCount {
                try skipGGUFMetadataValue(
                    elementType,
                    reader: &reader,
                    recursionDepth: recursionDepth + 1
                )
                index += 1
            }
        }
    }

    nonisolated private static func minimumSerializedSize(for type: GGUFMetadataValueType) -> UInt64? {
        switch type {
        case .uint8, .int8, .bool:
            return 1
        case .uint16, .int16:
            return 2
        case .uint32, .int32, .float32:
            return 4
        case .uint64, .int64, .float64:
            return 8
        case .string:
            return 8
        case .array:
            return 12
        }
    }

    nonisolated private static func fixedSerializedSize(for type: GGUFMetadataValueType) -> UInt64? {
        switch type {
        case .uint8, .int8, .bool:
            return 1
        case .uint16, .int16:
            return 2
        case .uint32, .int32, .float32:
            return 4
        case .uint64, .int64, .float64:
            return 8
        case .string, .array:
            return nil
        }
    }

    nonisolated private static func tensorByteCount(dimensions: [UInt64], type: UInt32) throws -> UInt64 {
        guard let layout = tensorLayouts[type],
              let firstDimension = dimensions.first,
              firstDimension % layout.elementsPerBlock == 0 else {
            throw ReaderError.malformed
        }

        var elementCount: UInt64 = 1
        for dimension in dimensions {
            let (product, overflow) = elementCount.multipliedReportingOverflow(by: dimension)
            guard !overflow else { throw ReaderError.malformed }
            elementCount = product
        }
        let blockCount = elementCount / layout.elementsPerBlock
        let (byteCount, overflow) = blockCount.multipliedReportingOverflow(by: layout.bytesPerBlock)
        guard !overflow, byteCount > 0 else { throw ReaderError.malformed }
        return byteCount
    }

    nonisolated private static func alignedOffset(_ offset: UInt64, to alignment: UInt64) -> UInt64? {
        guard alignment > 0 else { return nil }
        let remainder = offset % alignment
        guard remainder != 0 else { return offset }
        let (aligned, overflow) = offset.addingReportingOverflow(alignment - remainder)
        return overflow ? nil : aligned
    }

    nonisolated private static func isValidGGUFMetadataKey(_ key: String) -> Bool {
        guard !key.isEmpty, key.utf8.count <= 65_535 else { return false }
        let segments = key.split(separator: ".", omittingEmptySubsequences: false)
        return !segments.isEmpty && segments.allSatisfy { segment in
            !segment.isEmpty && segment.utf8.allSatisfy { byte in
                (97...122).contains(byte) || (48...57).contains(byte) || byte == 95
            }
        }
    }

    nonisolated private static func isValidGGUFArchitecture(_ architecture: String) -> Bool {
        guard !architecture.isEmpty else { return false }
        return architecture.utf8.allSatisfy { byte in
            (97...122).contains(byte) || (48...57).contains(byte) || byte == 45
        }
    }
}
