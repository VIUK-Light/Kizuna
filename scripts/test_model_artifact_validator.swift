import Foundation

@main
struct LocalAssistantModelArtifactValidatorTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kizuna-artifact-validator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let validGGUF = directory.appendingPathComponent("valid.gguf")
        try makeGGUFHeader().write(to: validGGUF)
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

        try expectFailure("GGUF with a wrong exact byte count") {
            try LocalAssistantModelArtifactValidator.validate(
                at: validGGUF,
                fileName: "valid.gguf",
                expectedByteCount: 9_999,
                requireExactByteCount: true
            )
        }

        let legacyGGML = directory.appendingPathComponent("legacy.bin")
        try Data([0x67, 0x67, 0x6D, 0x6C, 0x01]).write(to: legacyGGML)
        try LocalAssistantModelArtifactValidator.validate(
            at: legacyGGML,
            fileName: "legacy.bin",
            requireExactByteCount: false
        )

        print("Model artifact validator tests passed")
    }

    private static func makeGGUFHeader() -> Data {
        var data = Data([0x47, 0x47, 0x55, 0x46])
        appendLittleEndian(UInt32(3), to: &data)
        appendLittleEndian(UInt64(1), to: &data)
        appendLittleEndian(UInt64(1), to: &data)
        let key = Data("general.architecture".utf8)
        appendLittleEndian(UInt64(key.count), to: &data)
        data.append(key)
        data.append(0x08)
        return data
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func makeLargeArbitraryFile(at url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
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
        } catch {
            // The expected validation error proves the malformed artifact did
            // not reach an installed-model state.
        }
    }

    private enum TestFailure: Error {
        case expectedValidationFailure(String)
    }
}
