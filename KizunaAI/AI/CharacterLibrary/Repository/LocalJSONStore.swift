/*
仕様:
- 役割: Codable コレクションを 1 ファイル単位で Application Support に JSON 保存する汎用ヘルパー。
- 主な型: `LocalJSONStore<T: Codable>`.
- 編集ポイント: 保存先パス、エンコード設定、エラーリトライ等を変える時。
- 保存先: ~/Library/Application Support/VIUK/KizunaAI/CharacterLibrary/<fileName>
*/

import Foundation

enum LocalJSONStoreError: Error {
    case ioFailure(underlying: Error)
    case encode(underlying: Error)
    case decode(underlying: Error)
}

actor LocalJSONStore<T: Codable> {
    private let fileName: String
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fm = FileManager.default

    init(fileName: String) {
        self.fileName = fileName

        let base = KizunaDataMigration.characterLibraryURL
        self.fileURL = base.appendingPathComponent(fileName)

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec

        // ディレクトリ作成
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    func load() async throws -> [T] {
        guard fm.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode([T].self, from: data)
        } catch let decodeErr as DecodingError {
            throw LocalJSONStoreError.decode(underlying: decodeErr)
        } catch {
            throw LocalJSONStoreError.ioFailure(underlying: error)
        }
    }

    func save(_ items: [T]) async throws {
        do {
            let data = try encoder.encode(items)
            try data.write(to: fileURL, options: [.atomic])
        } catch let encodeErr as EncodingError {
            throw LocalJSONStoreError.encode(underlying: encodeErr)
        } catch {
            throw LocalJSONStoreError.ioFailure(underlying: error)
        }
    }

    /// id が一致する既存要素を置き換え、なければ末尾に追加する。
    func appendOrReplace(_ item: T, idEquals: (T, T) -> Bool) async throws {
        var items = (try? await load()) ?? []
        if let idx = items.firstIndex(where: { idEquals($0, item) }) {
            items[idx] = item
        } else {
            items.append(item)
        }
        try await save(items)
    }

    func delete(matching predicate: (T) -> Bool) async throws {
        var items = (try? await load()) ?? []
        items.removeAll(where: predicate)
        try await save(items)
    }
}
