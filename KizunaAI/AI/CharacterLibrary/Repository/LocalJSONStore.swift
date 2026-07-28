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

private final class LocalJSONStoreFileLock: @unchecked Sendable {
    nonisolated static let shared = LocalJSONStoreFileLock()
    private let lock = NSLock()

    nonisolated func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

actor LocalJSONStore<T: Codable> {
    // Repositoryは画面ごとに別インスタンスでも同じファイルを指すため、
    // actor単位だけでは read-modify-write の競合を防げない。
    // 共有ロックで、同じJSONファイル群の更新を直列化する。
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
        try LocalJSONStoreFileLock.shared.withLock {
            try loadUnlocked()
        }
    }

    func save(_ items: [T]) async throws {
        try LocalJSONStoreFileLock.shared.withLock {
            try saveUnlocked(items)
        }
    }

    /// read-modify-writeを1回のロック内で完了させる。
    /// メモリーの重複排除・上限整理など、複数repositoryから同時に呼ばれる処理に使う。
    func mutate(_ mutation: (inout [T]) throws -> Void) async throws {
        try LocalJSONStoreFileLock.shared.withLock {
            var items = try loadUnlocked()
            try mutation(&items)
            try saveUnlocked(items)
        }
    }

    private func loadUnlocked() throws -> [T] {
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

    private func saveUnlocked(_ items: [T]) throws {
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
        try await mutate { items in
            if let idx = items.firstIndex(where: { idEquals($0, item) }) {
                items[idx] = item
            } else {
                items.append(item)
            }
        }
    }

    func delete(matching predicate: (T) -> Bool) async throws {
        try await mutate { items in
            items.removeAll(where: predicate)
        }
    }
}
