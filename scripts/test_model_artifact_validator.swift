import Foundation

@main
struct LocalAssistantModelArtifactValidatorTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kizuna-artifact-validator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let validGGUF = directory.appendingPathComponent("valid.gguf")
        try makeGGUFModel().write(to: validGGUF)
        let digest = try LocalAssistantModelArtifactValidator.sha256(at: validGGUF)
        try LocalAssistantModelArtifactValidator.validate(
            at: validGGUF,
            fileName: "valid.gguf",
            expectedByteCount: Int64((try validGGUF.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
            expectedSHA256: digest,
            requireExactByteCount: true
        )

        try expectFailure("GGUF with a wrong digest") {
            try LocalAssistantModelArtifactValidator.validate(
                at: validGGUF,
                fileName: "valid.gguf",
                expectedSHA256: String(repeating: "0", count: 64),
                requireExactByteCount: false
            )
        }

        let corruptGGUF = directory.appendingPathComponent("corrupt.gguf")
        try Data(repeating: 0xA5, count: 64).write(to: corruptGGUF)
        try expectFailure("arbitrary binary renamed to GGUF") {
            try LocalAssistantModelArtifactValidator.validate(
                at: corruptGGUF,
                fileName: "corrupt.gguf",
                requireExactByteCount: false
            )
        }

        let largeCorruptGGUF = directory.appendingPathComponent("large-corrupt.gguf")
        try makeLargeArbitraryFile(at: largeCorruptGGUF)
        try expectFailure("large arbitrary binary renamed to GGUF") {
            try LocalAssistantModelArtifactValidator.validate(
                at: largeCorruptGGUF,
                fileName: "large-corrupt.gguf",
                minimumByteCount: 50 * 1024 * 1024,
                requireExactByteCount: false
            )
        }

        let forgedGGUF = directory.appendingPathComponent("forged-header.gguf")
        try makeForgedGGUFWithPaddedPayload(at: forgedGGUF)
        try expectFailure("forged GGUF prefix with padded payload") {
            try LocalAssistantModelArtifactValidator.validate(
                at: forgedGGUF,
                fileName: "forged-header.gguf",
                minimumByteCount: 50 * 1024 * 1024,
                requireExactByteCount: false
            )
        }

        try expectFailure("GGUF with a wrong exact byte count") {
            try LocalAssistantModelArtifactValidator.validate(
                at: validGGUF,
                fileName: "valid.gguf",
                expectedByteCount: 9_999,
                requireExactByteCount: true
            )
        }

        let legacyGGML = directory.appendingPathComponent("legacy.bin")
        try makeLegacyGGJTModel().write(to: legacyGGML)
        try LocalAssistantModelArtifactValidator.validate(
            at: legacyGGML,
            fileName: "legacy.bin",
            requireExactByteCount: false
        )

        let forgedLegacyGGML = directory.appendingPathComponent("forged-legacy.bin")
        try makeForgedLegacyGGMLWithPaddedPayload(at: forgedLegacyGGML)
        try expectFailure("forged legacy GGML magic with padded payload") {
            try LocalAssistantModelArtifactValidator.validate(
                at: forgedLegacyGGML,
                fileName: "forged-legacy.bin",
                minimumByteCount: 50 * 1024 * 1024,
                requireExactByteCount: false
            )
        }

        print("Model artifact validator tests passed")
    }

    private static func makeGGUFModel() -> Data {
        var data = Data("GGUF".utf8)
        appendLittleEndian(UInt32(3), to: &data)
        appendLittleEndian(UInt64(1), to: &data)
        appendLittleEndian(UInt64(1), to: &data)
        appendGGUFString("general.architecture", to: &data)
        appendLittleEndian(UInt32(8), to: &data) // GGUF string
        appendGGUFString("llama", to: &data)

        appendGGUFString("weight", to: &data)
        appendLittleEndian(UInt32(1), to: &data)
        appendLittleEndian(UInt64(32), to: &data)
        appendLittleEndian(UInt32(0), to: &data) // F32
        appendLittleEndian(UInt64(0), to: &data)
        appendZeroPadding(to: &data, alignment: 32)
        data.append(Data(repeating: 0, count: 32 * 4))
        return data
    }

    private static func makeLegacyGGJTModel() -> Data {
        var data = Data("ggjt".utf8)
        appendLittleEndian(UInt32(3), to: &data)
        appendLittleEndian(UInt32(1), to: &data) // n_vocab
        appendLittleEndian(UInt32(32), to: &data) // n_embd
        appendLittleEndian(UInt32(1), to: &data) // n_mult
        appendLittleEndian(UInt32(1), to: &data) // n_head
        appendLittleEndian(UInt32(1), to: &data) // n_layer
        appendLittleEndian(UInt32(32), to: &data) // n_rot
        appendLittleEndian(UInt32(0), to: &data) // F32

        appendLittleEndian(UInt32(1), to: &data)
        data.append(Data("a".utf8))
        appendLittleEndian(UInt32(0), to: &data) // vocabulary score bits

        appendLittleEndian(UInt32(1), to: &data) // n_dims
        appendLittleEndian(UInt32(1), to: &data) // name length
        appendLittleEndian(UInt32(0), to: &data) // F32
        appendLittleEndian(UInt32(32), to: &data)
        data.append(Data("w".utf8))
        appendZeroPadding(to: &data, alignment: 32)
        data.append(Data(repeating: 0, count: 32 * 4))
        return data
    }

    private static func makeForgedGGUFWithPaddedPayload(at url: URL) throws {
        var prefix = Data("GGUF".utf8)
        appendLittleEndian(UInt32(3), to: &prefix)
        appendLittleEndian(UInt64(1), to: &prefix)
        appendLittleEndian(UInt64(1), to: &prefix)
        appendGGUFString("general.architecture", to: &prefix)
        appendLittleEndian(UInt32(8), to: &prefix)
        appendGGUFString("llama", to: &prefix)
        appendLittleEndian(UInt64.max, to: &prefix) // impossible tensor-name length
        try writePadded(prefix: prefix, to: url)
    }

    private static func makeForgedLegacyGGMLWithPaddedPayload(at url: URL) throws {
        var prefix = Data("ggjt".utf8)
        appendLittleEndian(UInt32(3), to: &prefix)
        appendLittleEndian(UInt32(0), to: &prefix) // invalid n_vocab
        try writePadded(prefix: prefix, to: url)
    }

    private static func appendGGUFString(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        appendLittleEndian(UInt64(bytes.count), to: &data)
        data.append(bytes)
    }

    private static func appendZeroPadding(to data: inout Data, alignment: Int) {
        let padding = (alignment - (data.count % alignment)) % alignment
        data.append(Data(repeating: 0, count: padding))
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func makeLargeArbitraryFile(at url: URL) throws {
        try writePadded(prefix: Data(repeating: 0xA5, count: 64), to: url)
    }

    private static func writePadded(prefix: Data, to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: prefix)
        let chunk = Data(repeating: 0xA5, count: 1_048_576)
        for _ in 0..<50 {
            try handle.write(contentsOf: chunk)
        }
    }

    private static func expectFailure(_ name: String, _ operation: () throws -> Void) throws {
        do {
            try operation()
            throw TestFailure.expectedValidationFailure(name)
        } catch TestFailure.expectedValidationFailure {
            throw TestFailure.expectedValidationFailure(name)
        } catch is LocalAssistantModelArtifactValidator.ValidationError {
            // The expected validation error proves the malformed artifact did
            // not reach an installed-model state.
        }
    }

    private enum TestFailure: Error {
        case expectedValidationFailure(String)
    }
}
