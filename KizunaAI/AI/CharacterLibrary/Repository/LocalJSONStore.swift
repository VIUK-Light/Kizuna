/*
仕様:
- 役割: Codable コレクションを 1 ファイル単位で Application Support に JSON 保存する汎用ヘルパー。
- 主な型: `LocalJSONStore<T: Codable>`.
- 編集ポイント: 保存先パス、エンコード設定、エラーリトライ等を変える時。
- 保存先: ~/Library/Application Support/VIUK/KizunaAI/CharacterLibrary/<fileName>
*/

import Dispatch
import Foundation

enum LocalJSONStoreError: Error {
    case ioFailure(underlying: Error)
    case encode(underlying: Error)
    case decode(underlying: Error)
}

enum LocalJSONStoreCoding {
    private static func encodeDate(_ date: Date, to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        // A JSON number round-trips Date's underlying Double exactly. Using
        // ISO8601DateFormatter here would discard sub-millisecond precision,
        // which breaks equality and stable retry ownership after a restart.
        try container.encode(date.timeIntervalSinceReferenceDate)
    }

    private static func decodeDate(from decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()

        if let timestamp = try? container.decode(Double.self) {
            return Date(timeIntervalSinceReferenceDate: timestamp)
        }

        let value = try container.decode(String.self)

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        // Existing Kizuna JSON used ISO8601 strings. Keep those files readable
        // while new records use the exact numeric representation above.
        let legacyFormatter = ISO8601DateFormatter()
        legacyFormatter.formatOptions = [.withInternetDateTime]
        if let date = legacyFormatter.date(from: value) {
            return date
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Invalid ISO8601 date: \(value)"
        )
    }

    nonisolated static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            try encodeDate(date, to: encoder)
        }
        return encoder
    }

    nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            try decodeDate(from: decoder)
        }
        return decoder
    }
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

/// Synchronous file operations must not inherit the caller's MainActor.
/// Keep the queue separate from the shared lock: the queue provides the
/// asynchronous execution boundary, while the lock still protects callers
/// that use the regular LocalJSONStore actor or the transaction helpers.
final class LocalJSONStoreFileIOExecutor: @unchecked Sendable {
    nonisolated static let shared = LocalJSONStoreFileIOExecutor()

    private let queue = DispatchQueue(
        label: "com.viuk.kizuna.local-json-file-io",
        qos: .userInitiated
    )

    nonisolated func submit(_ operation: @escaping @Sendable () -> Void) {
        queue.async(execute: operation)
    }
}

/// Cancellation state for a queued file operation. Cancellation never
/// interrupts a synchronous read/write halfway through an atomic operation.
/// It can prevent work that has not started, but once the body begins the
/// completed result is returned even if the waiting task is cancelled.
final class LocalJSONStoreFileIOCancellationState: @unchecked Sendable {
    private enum State {
        case queued
        case started
        case cancelled
    }

    private let lock = NSLock()
    nonisolated(unsafe) private var state: State = .queued

    nonisolated init() {}

    nonisolated func cancel() {
        lock.lock()
        if case .queued = state {
            state = .cancelled
        }
        lock.unlock()
    }

    /// Atomically claims the operation before its synchronous body starts.
    /// A cancellation that wins this race prevents the body from running;
    /// cancellation after this method returns cannot replace the operation's
    /// result because the body may already have committed an atomic write.
    nonisolated func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .queued = state else { return false }
        state = .started
        return true
    }
}

/// 複数のJSONファイルへまたがる短いコミットで、通常のLocalJSONStoreと
/// 同じプロセス内ロックを共有するための低レベルヘルパー。
///
/// ここでは読み込み・エンコード・atomic writeだけを行い、LLM生成や
/// ネットワーク待ちをロック内で実行しない。Storyのターンジャーナルが
/// session/sceneを一緒に確定するために使う。
enum LocalJSONStoreTransaction {
    struct RecoveredRecords<T> {
        let items: [T]
        let invalidCount: Int
    }

    nonisolated static func withSharedLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        try LocalJSONStoreFileLock.shared.withLock(body)
    }

    /// Execute a synchronous transaction on the dedicated file-I/O queue.
    ///
    /// The low-level transaction APIs remain synchronous so they can be used
    /// inside one lock-held read-modify-write section and by recovery tests.
    /// Production async repositories call this boundary before entering those
    /// APIs, preventing Data(contentsOf:), JSON encoding, backup copies, and
    /// atomic writes from blocking the MainActor.
    nonisolated static func performOnFileIO<Result>(
        _ body: @escaping @Sendable () throws -> Result
    ) async throws -> Result {
        let cancellationState = LocalJSONStoreFileIOCancellationState()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Result, Error>) in
                LocalJSONStoreFileIOExecutor.shared.submit {
                    guard cancellationState.begin() else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        let result = try body()
                        // A synchronous atomic operation cannot be rolled back
                        // by cancelling the waiting task after it has started.
                        // Return its result so callers do not retry a write
                        // that already committed; callers may check their own
                        // task cancellation before continuing post-processing.
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }, onCancel: {
            cancellationState.cancel()
        })
    }

    nonisolated static func load<T: Codable>(
        _ type: T.Type,
        fileName: String,
        baseURL: URL = KizunaDataMigration.characterLibraryURL
    ) throws -> [T] {
        let url = baseURL.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let decoder = LocalJSONStoreCoding.makeDecoder()
            return try decoder.decode([T].self, from: data)
        } catch let decodingError as DecodingError {
            throw LocalJSONStoreError.decode(underlying: decodingError)
        } catch {
            throw LocalJSONStoreError.ioFailure(underlying: error)
        }
    }

    /// Recover an array one element at a time while preserving the source
    /// file. This API does not acquire the shared file lock: callers must
    /// invoke it inside `withSharedLock`, and call that from
    /// `performOnFileIO` when the read may otherwise block the MainActor.
    /// Callers that need a safe read-modify-write must inspect `invalidCount`
    /// and refuse to save the recovered array, otherwise saving it would
    /// silently delete the unreadable records.
    nonisolated static func recoverRecords<T: Decodable>(
        at url: URL,
        fileName: String,
        fallback: LocalJSONStoreError,
        logPrefix: String = "[LocalJSONStore]"
    ) throws -> RecoveredRecords<T> {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw fallback
        }
        do {
            let data = try Data(contentsOf: url)
            guard let rawItems = try JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            ) as? [Any] else {
                throw fallback
            }

            let decoder = LocalJSONStoreCoding.makeDecoder()
            var validItems: [T] = []
            var invalidCount = 0
            for (index, rawItem) in rawItems.enumerated() {
                do {
                    let itemData = try JSONSerialization.data(
                        withJSONObject: rawItem,
                        options: [.fragmentsAllowed]
                    )
                    validItems.append(try decoder.decode(T.self, from: itemData))
                } catch {
                    invalidCount += 1
                    NSLog(
                        "%@ skipped invalid %@ record at index %ld: %@",
                        logPrefix,
                        fileName,
                        index,
                        String(describing: error)
                    )
                }
            }

            guard invalidCount > 0 else { throw fallback }
            NSLog(
                "%@ recovered %@ for read: %ld valid, %ld invalid; source was not modified",
                logPrefix,
                fileName,
                validItems.count,
                invalidCount
            )
            return RecoveredRecords(items: validItems, invalidCount: invalidCount)
        } catch let storeError as LocalJSONStoreError {
            throw storeError
        } catch {
            throw LocalJSONStoreError.ioFailure(underlying: error)
        }
    }

    /// Read an array while preserving the source file when individual records
    /// are malformed. This nonisolated API does not acquire the shared file
    /// lock: callers must invoke it inside `withSharedLock`, and call that
    /// from `performOnFileIO` when the read may otherwise block the MainActor.
    /// It is deliberately separate from `load` so callers can inspect
    /// `invalidCount` before deciding whether a write is safe.
    nonisolated static func loadRecoveringCorruptRecords<T: Codable>(
        _ type: T.Type,
        fileName: String,
        baseURL: URL = KizunaDataMigration.characterLibraryURL
    ) throws -> RecoveredRecords<T> {
        do {
            return RecoveredRecords(
                items: try load(type, fileName: fileName, baseURL: baseURL),
                invalidCount: 0
            )
        } catch let decodeError as LocalJSONStoreError {
            guard case .decode = decodeError else { throw decodeError }
            let url = baseURL.appendingPathComponent(fileName)
            return try recoverRecords(
                at: url,
                fileName: fileName,
                fallback: decodeError,
                logPrefix: "[LocalJSONStoreTransaction]"
            )
        }
    }

    nonisolated static func save<T: Codable>(
        _ items: [T],
        fileName: String,
        baseURL: URL = KizunaDataMigration.characterLibraryURL
    ) throws {
        let base = baseURL
        let url = base.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let encoder = LocalJSONStoreCoding.makeEncoder()
            let data = try encoder.encode(items)
            try data.write(to: url, options: [.atomic])
        } catch let encodingError as EncodingError {
            throw LocalJSONStoreError.encode(underlying: encodingError)
        } catch {
            throw LocalJSONStoreError.ioFailure(underlying: error)
        }
    }

    /// 壊れた補助ファイルを上書きせずに同じ保存先へ退避する。
    /// 呼び出し側は退避後に新しい空ファイルを作るか、失敗を利用者へ返す。
    nonisolated static func backup(
        fileName: String,
        baseURL: URL = KizunaDataMigration.characterLibraryURL
    ) throws -> URL {
        let base = baseURL
        let sourceURL = base.appendingPathComponent(fileName)
        let backupName = "\(sourceURL.deletingPathExtension().lastPathComponent).corrupt-\(UUID().uuidString).json"
        let backupURL = base.appendingPathComponent(backupName)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: backupURL)
            return backupURL
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

    init(fileName: String, baseURL: URL = KizunaDataMigration.characterLibraryURL) {
        self.fileName = fileName

        let base = baseURL
        self.fileURL = base.appendingPathComponent(fileName)

        self.encoder = LocalJSONStoreCoding.makeEncoder()
        self.decoder = LocalJSONStoreCoding.makeDecoder()
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
                return recovery.items
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
                try saveUnlocked(recovery.items)
                NSLog("[LocalJSONStore] repaired %@ before write: %ld valid, %ld invalid; backup=%@", fileName, recovery.items.count, recovery.invalidCount, backupURL.lastPathComponent)
                items = recovery.items
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

    /// 配列の各要素を個別にdecodeし、壊れた要素がある場合だけ救出結果を返す。
    /// ルートJSON自体が配列でない場合は、復元不能なので元のdecodeエラーを返す。
    private func recoverRecordsUnlocked(
        fallback: LocalJSONStoreError
    ) throws -> LocalJSONStoreTransaction.RecoveredRecords<T> {
        try LocalJSONStoreTransaction.recoverRecords(
            at: fileURL,
            fileName: fileName,
            fallback: fallback
        )
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
            try fm.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
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
