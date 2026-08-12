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

final class LocalJSONStoreFileLock: @unchecked Sendable {
    nonisolated static let shared = LocalJSONStoreFileLock()
    private let lock = NSLock()

    nonisolated func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// 複数のJSONファイルへまたがる短いコミットで、通常のLocalJSONStoreと
/// 同じプロセス内ロックを共有するための低レベルヘルパー。
///
/// ここでは読み込み・エンコード・atomic writeだけを行い、LLM生成や
/// ネットワーク待ちをロック内で実行しない。Storyのターンジャーナルが
/// session/sceneを一緒に確定するために使う。
enum LocalJSONStoreTransaction {
    static func withSharedLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        try LocalJSONStoreFileLock.shared.withLock(body)
    }

    static func load<T: Codable>(_ type: T.Type, fileName: String) throws -> [T] {
        let url = KizunaDataMigration.characterLibraryURL.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([T].self, from: data)
        } catch let decodingError as DecodingError {
            throw LocalJSONStoreError.decode(underlying: decodingError)
        } catch {
            throw LocalJSONStoreError.ioFailure(underlying: error)
        }
    }

    static func save<T: Codable>(_ items: [T], fileName: String) throws {
        let base = KizunaDataMigration.characterLibraryURL
        let url = base.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(items)
            try data.write(to: url, options: [.atomic])
        } catch let encodingError as EncodingError {
            throw LocalJSONStoreError.encode(underlying: encodingError)
        } catch {
            throw LocalJSONStoreError.ioFailure(underlying: error)
        }
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

    /// 配列内の一部レコードだけが壊れている場合に、読めるレコードを救出する。
    ///
    /// 旧バージョンで保存された enum 値や途中終了したJSONが1件あるだけで
    /// ファイル全体の decode が失敗し、一覧が空になる問題を防ぐ。壊れた
    /// レコードは削除せず、インデックスと原因だけをログへ残す。書き戻しは
    /// 行わないため、ユーザーのデータを自動的に失わない。
    func loadRecoveringCorruptRecords() async throws -> [T] {
        try LocalJSONStoreFileLock.shared.withLock {
            do {
                return try loadUnlocked()
            } catch let decodeError as LocalJSONStoreError {
                guard case .decode = decodeError else { throw decodeError }
                let recovery = try recoverRecordsUnlocked(fallback: decodeError)
                NSLog("[LocalJSONStore] recovered %@ for read: %ld valid, %ld invalid; source was not modified", fileName, recovery.validItems.count, recovery.invalidCount)
                return recovery.validItems
            }
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
            var items: [T]
            do {
                items = try loadUnlocked()
            } catch let decodeError as LocalJSONStoreError {
                guard case .decode = decodeError else { throw decodeError }
                // 保存経路でも同じ救出処理を行う。元ファイルを先に退避し、
                // 退避できなければ現行データを上書きしない。
                let recovery = try recoverRecordsUnlocked(fallback: decodeError)
                let backupURL = try backupCorruptFileUnlocked()
                try saveUnlocked(recovery.validItems)
                NSLog("[LocalJSONStore] repaired %@ before write: %ld valid, %ld invalid; backup=%@", fileName, recovery.validItems.count, recovery.invalidCount, backupURL.lastPathComponent)
                items = recovery.validItems
            }
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

    private struct RecoveryResult {
        let validItems: [T]
        let invalidCount: Int
    }

    /// 配列の各要素を個別にdecodeし、壊れた要素がある場合だけ救出結果を返す。
    /// ルートJSON自体が配列でない場合は、復元不能なので元のdecodeエラーを返す。
    private func recoverRecordsUnlocked(fallback: LocalJSONStoreError) throws -> RecoveryResult {
        guard fm.fileExists(atPath: fileURL.path) else { throw fallback }
        do {
            let data = try Data(contentsOf: fileURL)
            guard let rawItems = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [Any] else {
                throw fallback
            }

            var validItems: [T] = []
            var invalidCount = 0
            for (index, rawItem) in rawItems.enumerated() {
                do {
                    let itemData = try JSONSerialization.data(withJSONObject: rawItem, options: [.fragmentsAllowed])
                    validItems.append(try decoder.decode(T.self, from: itemData))
                } catch {
                    invalidCount += 1
                    NSLog("[LocalJSONStore] skipped invalid %@ record at index %ld: %@", fileName, index, String(describing: error))
                }
            }

            guard invalidCount > 0 else { throw fallback }
            return RecoveryResult(validItems: validItems, invalidCount: invalidCount)
        } catch let storeError as LocalJSONStoreError {
            throw storeError
        } catch {
            throw LocalJSONStoreError.ioFailure(underlying: error)
        }
    }

    /// 破損した元ファイルを同じディレクトリに退避する。コピーに失敗した場合は
    /// 呼び出し側が保存処理を中止できるよう、成功したURLを返す。
    private func backupCorruptFileUnlocked() throws -> URL {
        let backupURL = fileURL
            .deletingPathExtension()
            .appendingPathExtension("corrupt-\(UUID().uuidString).json")
        do {
            try fm.copyItem(at: fileURL, to: backupURL)
            return backupURL
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
