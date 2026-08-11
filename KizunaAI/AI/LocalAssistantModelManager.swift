/*
仕様:
- 役割: ローカルAIモデルの保存先、ダウンロード、認証トークン、導入状態を管理する。
- 主な型: `LocalAssistantModelManager`.
- 編集ポイント: ダウンロード元URL、保存先、認証ヘッダ、進捗表示を変えるときに触る。
*/
import Combine
import Foundation
#if os(iOS) && !targetEnvironment(simulator) && VIUK_ENABLE_LITERTLM_NATIVE
#if canImport(LiteRTLM)
import LiteRTLM
#endif
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

struct LocalAssistantLoadProgress: Equatable {
    var fraction: Double
    var message: String
    var isDone: Bool
}

enum LocalAssistantDownloadStatus: String, Codable {
    case idle
    case preflighting
    case downloading
    case paused
    case resumable
    /// A complete download is being checked outside the installed-model path.
    /// It must not replace an existing model until that check succeeds.
    case validating
    case failed
    case completed
}

struct LocalAssistantDownloadState: Codable {
    var sourceURL: String
    var resolvedURL: String?
    var expectedBytes: Int64
    var eTag: String?
    var resumeDataPath: String?
    var status: LocalAssistantDownloadStatus
    var startedAt: Date?
    var updatedAt: Date
    var lastError: String?
    var suggestedFilename: String?
    /// A temporary candidate stays outside the installed-model namespace until
    /// runtime validation has completed. These fields make an interrupted
    /// validation recoverable without adopting or deleting an existing model.
    var pendingValidationPath: String? = nil
    var replacementBackupPath: String? = nil
    // Optional preserves compatibility with state JSON written before this
    // recovery marker existed; missing means `false`.
    var replacementInProgress: Bool? = nil
    var previousInstalledFileName: String? = nil
    var previousSourceURL: String? = nil
    var previousResolvedURL: String? = nil
    var previousExpectedBytes: Int64? = nil
    var previousETag: String? = nil
}

private struct LocalAssistantDownloadPreflight {
    let sourceURL: URL
    let resolvedURL: URL
    let expectedBytes: Int64
    let eTag: String?
    let suggestedFilename: String?
    let acceptsResume: Bool
}

/// Rangeを無視する配布元でも、モデル本体をDataへ全量バッファしないためのpreflight delegate。
/// ヘッダーだけ受け取って意図的にキャンセルし、本ダウンロードは別のdownload taskで行う。
private final class LocalAssistantPreflightDelegate: NSObject, URLSessionDataDelegate {
    private let responseHandler: (HTTPURLResponse) -> Void
    private let failureHandler: (Error?) -> Void
    private var didDeliverResponse = false

    init(
        responseHandler: @escaping (HTTPURLResponse) -> Void,
        failureHandler: @escaping (Error?) -> Void
    ) {
        self.responseHandler = responseHandler
        self.failureHandler = failureHandler
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse else {
            didDeliverResponse = true
            completionHandler(.cancel)
            failureHandler(nil)
            return
        }

        // リダイレクトは最終URLのヘッダーを検査するまで追従する。
        if (300...399).contains(httpResponse.statusCode) {
            completionHandler(.allow)
            return
        }

        didDeliverResponse = true
        responseHandler(httpResponse)
        // ここで本文を受け取らずに終了するため、巨大なGGUFをメモリへ載せない。
        completionHandler(.cancel)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !didDeliverResponse else { return }
        failureHandler(error)
    }
}

private enum LocalAssistantDisplayState {
    case downloading
    case resumable
    case checking
    case executable
    case savedOnly
    case recentFailure
    case modelMissing
}

/// `statusMessage` is kept as Japanese for persistence-free diagnostics and
/// logging, but the UI must not reverse-engineer its meaning with Japanese
/// substring checks. Keep the semantic state beside the display text so a
/// wording change cannot turn a normal state into an error in English UI.
private enum LocalAssistantStatusKind: Equatable {
    case modelMissing(hasLegacyModel: Bool)
    case preflighting
    case preparationStopped
    case downloading(resuming: Bool, percent: Int?)
    case resumeAvailable
    case paused
    case cancelled
    case checking
    case executable
    case savedOnly
    case recentFailure
    case downloadFailure(message: String)
    case modelSaved
    case modelDeleted
    case modelDeletionFailed
    case legacyModelMissing
    case legacyModelDeleted
}

private struct LocalAssistantInstalledModelSnapshot {
    let modelURL: URL
    let fileName: String
    let sourceURL: String?
    let resolvedURL: String?
    let expectedBytes: Int64?
    let eTag: String?
}

private struct LocalAssistantPendingModelCandidate {
    let stagedURL: URL
    let fileName: String
    let sourceURL: String
    let resolvedURL: String?
    let expectedBytes: Int64
    let eTag: String?
    let previousModel: LocalAssistantInstalledModelSnapshot?
}

final class LocalAssistantModelManager: NSObject, ObservableObject {
    static let shared = LocalAssistantModelManager()

    private static let minimumFreeSpaceMarginBytes: Int64 = 512 * 1024 * 1024
    private static let downloadStateFileName = "download-state.json"
    private static let resumeDataFileName = "download.resume"

    @Published var sourceURLString: String
    @Published var accessToken: String
    @Published private(set) var statusMessage: String = "未導入"
    @Published private(set) var downloadedBytes: Int64 = 0
    @Published private(set) var expectedBytes: Int64 = 0
    @Published private(set) var transferRateBytesPerSecond: Double?
    @Published private(set) var estimatedRemainingSeconds: TimeInterval?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var installedFileName: String?
    @Published private(set) var installedFileSize: Int64 = 0
    @Published private(set) var isDownloading: Bool = false
    @Published private(set) var runtimeRefreshedAt = Date()
    @Published private(set) var downloadStatus: LocalAssistantDownloadStatus = .idle
    @Published private(set) var downloadStatePersistenceError: String?
    @Published private(set) var runtimeAvailabilitySnapshot: LocalAssistantRuntimeAvailability = .modelMissing
    @Published private(set) var modelLoadProgress: LocalAssistantLoadProgress?

    private var statusKind: LocalAssistantStatusKind = .modelMissing(hasLegacyModel: false)

    private func setStatus(_ kind: LocalAssistantStatusKind, japaneseMessage: String) {
        statusKind = kind
        statusMessage = japaneseMessage
    }

    /// 状態保存は日本語の内部メッセージを維持し、画面へ出す直前に現在言語へ
    /// 変換する。ダウンロード中に表示言語を切り替えても、次の状態通知を
    /// 待たずに設定画面を再描画できる。
    var localizedStatusMessage: String {
        localizedStatusMessage(for: statusKind)
    }

    var localizedSupplementalLastErrorMessage: String? {
        let message = lastErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !message.isEmpty else { return nil }
        if message == rawRuntimeWarningMessage || message == rawDownloadStateSummary {
            return nil
        }
        if let diagnostic = LocalAssistantRuntimeBridge.shared.lastRuntimeDiagnostic,
           message == diagnostic.detailedMessage {
            return localizedRuntimeDiagnosticMessage
        }
        return localizedReadableError(message)
    }

    private var modelLoadProgressClearTask: Task<Void, Never>?

    func updateModelLoadProgress(_ progress: LocalAssistantLoadProgress?) {
        Task { @MainActor in
            self.modelLoadProgressClearTask?.cancel()
            self.modelLoadProgress = progress
            if let progress, progress.isDone {
                self.modelLoadProgressClearTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    if self.modelLoadProgress?.isDone == true {
                        self.modelLoadProgress = nil
                    }
                }
            }
        }
    }

    private let defaults = UserDefaults.standard
    private let sourceURLKey = "localAssistantModelSourceURL"
    private let installedFileNameKey = "localAssistantInstalledFileName"
    private let secretStore = AISecretStore.shared
    private var resolvedInstalledModelURL: URL?
    private var legacyResolvedInstalledModelURL: URL?
    private var persistedDownloadState: LocalAssistantDownloadState?
    /// A corrupt state file must not let directory scanning adopt an unfinished
    /// model. This is cleared only by an explicit download/state reset or a
    /// successfully validated installation.
    private var hasInvalidPersistedDownloadState = false

    private var urlSession: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var preflightTask: URLSessionDataTask?
    private var preflightSession: URLSession?
    private var preflightDelegate: LocalAssistantPreflightDelegate?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var isCancellingForResume = false
    private var progressSamples: [(time: TimeInterval, bytes: Int64)] = []
    private var activeDownloadBaseBytes: Int64 = 0
    /// URLSessionの古いdelegate callbackが、後から開始した転送へ混ざらないための世代。
    private var activeTransferID = UUID()
    private var isEnvironmentRefreshScheduled = false
    // 端末内 runtime の確認は UI ボタンではなく、モデル検出後に一度だけ自動実行する。
    // 同じモデルで refreshEnvironment() が連続しても、重いモデル初期化を重ねない。
    private var automaticRuntimeCheckTask: Task<Void, Never>?
    private var automaticRuntimeCheckModelKey: String?
    private var installedModelSnapshotBeforeDownload: LocalAssistantInstalledModelSnapshot?
    private var pendingModelCandidate: LocalAssistantPendingModelCandidate?
    private var candidateRuntimeValidationTask: Task<Void, Never>?

    private override init() {
        self.sourceURLString = Self.normalizedSourceURL(
            AILegacyCompatibility.stringValue(
                primaryKey: sourceURLKey,
                aliases: AILegacyCompatibility.localModelSourceAliases,
                defaults: defaults
            )
        )
        self.accessToken = secretStore.string(for: .localModelAccessToken) ?? ""
        super.init()
        AILegacyCompatibility.exportString(
            sourceURLString,
            primaryKey: sourceURLKey,
            aliases: AILegacyCompatibility.localModelSourceAliases,
            defaults: defaults
        )
        registerLifecycleObservers()
        scheduleEnvironmentRefresh()
    }

    deinit {
        automaticRuntimeCheckTask?.cancel()
        candidateRuntimeValidationTask?.cancel()
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
    }

    private static func isEffectivelyDefaultSource(_ value: String?) -> Bool {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return true }
        guard let candidateURL = URL(string: trimmed) else {
            return false
        }

        let knownDefaultURLs = [LocalAssistantModelProfile.defaultDownloadURL] + LocalAssistantModelProfile.legacyDefaultDownloadURLs
        return knownDefaultURLs.contains { rawURL in
            guard let knownURL = URL(string: rawURL) else { return false }
            return candidateURL.host?.lowercased() == knownURL.host?.lowercased()
                && candidateURL.lastPathComponent == knownURL.lastPathComponent
        }
    }

    private static func normalizedSourceURL(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return LocalAssistantModelProfile.defaultDownloadURL }
        return isEffectivelyDefaultSource(trimmed) ? LocalAssistantModelProfile.defaultDownloadURL : trimmed
    }

    var installationDirectoryURL: URL {
        KizunaDataMigration.localModelsURL
            .appendingPathComponent(LocalAssistantModelProfile.storageFolderName, isDirectory: true)
    }

    private var downloadStateURL: URL {
        installationDirectoryURL.appendingPathComponent(Self.downloadStateFileName)
    }

    private var resumeDataStorageURL: URL {
        installationDirectoryURL.appendingPathComponent(Self.resumeDataFileName)
    }

    private func buildCandidateDirectories(folderNames: [String]) -> [URL] {
        let directories = folderNames.map {
            KizunaDataMigration.localModelsURL.appendingPathComponent($0, isDirectory: true)
        }

        var seen = Set<String>()
        return directories.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    var candidateInstallationDirectories: [URL] {
        var seen = Set<String>()
        let directories = currentModelCandidateDirectories + legacyModelCandidateDirectories
        return directories.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private var currentModelCandidateDirectories: [URL] {
        var directories = [installationDirectoryURL]
        directories.append(contentsOf: buildCandidateDirectories(folderNames: [LocalAssistantModelProfile.storageFolderName]))
        var seen = Set<String>()
        return directories.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private var legacyModelCandidateDirectories: [URL] {
        buildCandidateDirectories(folderNames: LocalAssistantModelProfile.legacyFolderNames)
    }

    var installedModelURL: URL? {
        resolvedInstalledModelURL
    }

    var legacyInstalledModelURL: URL? {
        legacyResolvedInstalledModelURL
    }

    var hasLegacyInstalledModel: Bool {
        legacyResolvedInstalledModelURL != nil
    }

    private var isValidatingDownloadedCandidate: Bool {
        pendingModelCandidate != nil || candidateRuntimeValidationTask != nil || downloadStatus == .validating
    }

    private func currentInstalledModelSnapshot() -> LocalAssistantInstalledModelSnapshot? {
        guard let modelURL = resolvedInstalledModelURL,
              let fileName = safeModelFileName(modelURL.lastPathComponent) else {
            return nil
        }

        let completedState: LocalAssistantDownloadState?
        if let state = persistedDownloadState,
           state.status == .completed,
           stateReferencedFileName(for: state) == fileName {
            completedState = state
        } else {
            completedState = nil
        }

        let fileSize = (try? modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return LocalAssistantInstalledModelSnapshot(
            modelURL: modelURL,
            fileName: fileName,
            sourceURL: completedState?.sourceURL,
            resolvedURL: completedState?.resolvedURL,
            expectedBytes: completedState?.expectedBytes ?? (fileSize > 0 ? fileSize : nil),
            eTag: completedState?.eTag
        )
    }

    var progressValue: Double? {
        guard expectedBytes > 0 else { return nil }
        return min(max(Double(downloadedBytes) / Double(expectedBytes), 0), 1)
    }

    var transferRateSummary: String? {
        guard let transferRateBytesPerSecond, transferRateBytesPerSecond > 0 else { return nil }
        let value = ByteCountFormatter.string(fromByteCount: Int64(transferRateBytesPerSecond), countStyle: .file)
        return KizunaCopy.text(japanese: "\(value)/秒", english: "\(value)/s")
    }

    var estimatedRemainingSummary: String? {
        guard let estimatedRemainingSeconds, estimatedRemainingSeconds.isFinite, estimatedRemainingSeconds > 0 else {
            return nil
        }

        let totalSeconds = Int(estimatedRemainingSeconds.rounded(.up))
        if totalSeconds < 60 {
            return KizunaCopy.text(
                japanese: "残り約\(max(totalSeconds, 1))秒",
                english: "About \(max(totalSeconds, 1)) sec remaining"
            )
        }

        let totalMinutes = Int((Double(totalSeconds) / 60).rounded(.up))
        if totalMinutes < 60 {
            return KizunaCopy.text(
                japanese: "残り約\(max(totalMinutes, 1))分",
                english: "About \(max(totalMinutes, 1)) min remaining"
            )
        }

        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if minutes == 0 {
            return KizunaCopy.text(japanese: "残り約\(hours)時間", english: "About \(hours) hr remaining")
        }
        return KizunaCopy.text(
            japanese: "残り約\(hours)時間\(minutes)分",
            english: "About \(hours) hr \(minutes) min remaining"
        )
    }

    var resolvedSourceURLString: String {
        Self.normalizedSourceURL(sourceURLString)
    }

    var isUsingDefaultSource: Bool {
        resolvedSourceURLString == LocalAssistantModelProfile.defaultDownloadURL
    }

    var sourceDisplayLabel: String {
        isUsingDefaultSource
            ? KizunaCopy.text(
                japanese: LocalAssistantModelProfile.defaultDownloadLabel,
                english: "\(LocalAssistantModelProfile.internalModelName) standard link"
            )
            : KizunaCopy.text(japanese: "カスタムURL", english: "Custom URL")
    }

    var sourceHostLabel: String {
        URL(string: resolvedSourceURLString)?.host
            ?? KizunaCopy.text(japanese: "標準ソース", english: "Standard source")
    }

    var canResumeDownload: Bool {
        guard !isDownloading, resolvedInstalledModelURL == nil, let state = persistedDownloadState else { return false }
        guard [.resumable, .paused].contains(state.status) else { return false }
        guard let resumeURL = currentResumeDataURL(from: state),
              let resumeData = try? Data(contentsOf: resumeURL)
        else {
            return false
        }
        return resumeDataLooksUsable(resumeData)
    }

    var canRestartDownloadFromScratch: Bool {
        canResumeDownload || downloadStatus == .failed || downloadStatus == .paused
    }

    var isDownloadStateFailure: Bool {
        downloadStatus == .failed
    }

    var isDownloadStateWarning: Bool {
        switch downloadStatus {
        case .failed, .paused, .resumable:
            return true
        default:
            return false
        }
    }

    private var rawDownloadStateSummary: String {
        switch downloadStatus {
        case .preflighting:
            return "配布元と保存先、空き容量を確認しています。"
        case .downloading:
            if let progressValue {
                return "ダウンロード中 \(Int(progressValue * 100))%"
            }
            return "モデルを受信しています。"
        case .resumable:
            return "前回の途中から再開できます。"
        case .paused:
            return "ダウンロードを一時停止しました。"
        case .validating:
            return "ダウンロードしたモデルを置換前に確認しています。"
        case .failed:
            return classifyReadableError(lastErrorMessage)
        case .completed:
            return "モデルファイルは保存済みです。"
        case .idle:
            if resolvedInstalledModelURL != nil {
                return "保存済みモデルを確認できます。"
            }
            if hasLegacyInstalledModel {
                return "旧ローカルモデルは残っています。Gemma 4 を追加できます。"
            }
            return "標準モデルをアプリ内に保存できます。"
        }
    }

    var downloadStateSummary: String {
        localizedDownloadStateSummary(rawDownloadStateSummary)
    }

    var statusTitle: String {
        switch displayState {
        case .downloading:
            return KizunaCopy.text(japanese: "ダウンロード中", english: "Downloading")
        case .resumable:
            return KizunaCopy.text(japanese: "再開可能", english: "Ready to resume")
        case .checking:
            return KizunaCopy.text(japanese: "起動確認中", english: "Checking runtime")
        case .executable:
            return KizunaCopy.text(japanese: "実行可能", english: "Ready to run")
        case .savedOnly:
            return KizunaCopy.text(japanese: "保存のみ", english: "Saved only")
        case .recentFailure:
            return KizunaCopy.text(japanese: "直近失敗", english: "Recent failure")
        case .modelMissing:
            return KizunaCopy.text(japanese: "未導入", english: "Not installed")
        }
    }

    var runtimeAvailability: LocalAssistantRuntimeAvailability {
        runtimeAvailabilitySnapshot
    }

    var canExecuteInstalledModel: Bool {
        runtimeAvailability == .executable
    }

    var canAttemptInstalledModel: Bool {
        guard resolvedInstalledModelURL != nil else { return false }
        guard LocalAssistantRuntimeBridge.shared.isBundledRunnerAvailable else { return false }
        return true
    }

    var runnerStatusLabel: String {
        switch runtimeAvailability {
        case .checking:
            return KizunaCopy.text(japanese: "起動確認中", english: "Checking runtime")
        case .executable:
            return KizunaCopy.text(japanese: "この端末で会話可能", english: "Ready for on-device chat")
        case .recentFailure:
            return KizunaCopy.text(japanese: "起動失敗", english: "Runtime failed")
        case .savedOnly:
            return KizunaCopy.text(japanese: "保存済み・未起動", english: "Saved, not started")
        case .modelMissing:
            return KizunaCopy.text(japanese: "未導入", english: "Not installed")
        }
    }

    var runtimeStatusSummary: String {
        switch runtimeAvailability {
        case .checking:
            return KizunaCopy.text(
                japanese: "\(LocalAssistantModelProfile.modelName) を端末内で起動確認しています。",
                english: "Checking \(LocalAssistantModelProfile.modelName) on this device."
            )
        case .executable:
            return KizunaCopy.text(
                japanese: "\(LocalAssistantModelProfile.modelName) をこの端末で実行できます。",
                english: "\(LocalAssistantModelProfile.modelName) can run on this device."
            )
        case .recentFailure:
            return localizedRuntimeDiagnosticSummary ?? KizunaCopy.text(
                japanese: "ローカル実行の自動確認に失敗しました。モデル形式と端末の空き容量を確認してください。",
                english: "The automatic on-device check failed. Check the model format and free space."
            )
        case .savedOnly:
            return KizunaCopy.text(
                japanese: "モデルファイルは保存済みです。端末内の実行確認を自動で開始します。",
                english: "The model file is saved. An automatic on-device check will start shortly."
            )
        case .modelMissing:
            if hasLegacyInstalledModel {
                return KizunaCopy.text(
                    japanese: "旧ローカルモデルは残っていますが、既定の \(LocalAssistantModelProfile.internalModelName) は未導入です。",
                    english: "An older local model remains, but the default \(LocalAssistantModelProfile.internalModelName) is not installed."
                )
            }
            return KizunaCopy.text(
                japanese: "\(LocalAssistantModelProfile.modelName) は未導入です。",
                english: "\(LocalAssistantModelProfile.modelName) is not installed."
            )
        }
    }

    var downloadHelpText: String {
        KizunaCopy.text(
            japanese: "標準ダウンロードリンクはアプリに内蔵しています。別ソースを使いたい時だけ、URLや Bearer トークンを詳細設定で上書きします。",
            english: "A standard download link is built in. Override it with a URL or Bearer token only when using another source."
        )
    }

    var runtimeDiagnosticSummary: String? {
        LocalAssistantRuntimeBridge.shared.lastRuntimeDiagnostic?.summary
    }

    var localizedRuntimeDiagnosticSummary: String? {
        guard let diagnostic = LocalAssistantRuntimeBridge.shared.lastRuntimeDiagnostic else { return nil }
        return KizunaCopy.text(
            japanese: diagnostic.summary,
            english: englishRuntimeDiagnosticSummary(for: diagnostic.kind)
        )
    }

    var runtimeDiagnosticMessage: String? {
        LocalAssistantRuntimeBridge.shared.lastRuntimeDiagnostic?.detailedMessage
            ?? LocalAssistantRuntimeBridge.shared.lastRuntimeError
    }

    var localizedRuntimeDiagnosticMessage: String? {
        guard let diagnostic = LocalAssistantRuntimeBridge.shared.lastRuntimeDiagnostic else {
            return LocalAssistantRuntimeBridge.shared.lastRuntimeError.map(localizedReadableError)
        }

        var lines = [KizunaCopy.text(
            japanese: diagnostic.summary,
            english: englishRuntimeDiagnosticSummary(for: diagnostic.kind)
        )]
        if let terminationStatus = diagnostic.terminationStatus {
            lines.append(KizunaCopy.text(
                japanese: "終了コード: \(terminationStatus)",
                english: "Exit code: \(terminationStatus)"
            ))
        }
        // runner/modelの絶対パスや日本語の生ログは表示言語を汚染し、
        // 端末情報を必要以上に露出するため、詳細はログだけに残す。
        return lines.joined(separator: "\n")
    }

    private var rawRuntimeWarningMessage: String? {
        switch runtimeAvailability {
        case .checking:
            return "ローカルモデルを端末内で起動確認中です。完了するまで実行可能とは表示しません。"
        case .recentFailure:
            return runtimeDiagnosticSummary ?? "ローカル実行の自動確認に失敗しました。"
        case .savedOnly:
            return "モデルは保存済みです。端末内の実行確認を自動で開始します。"
        case .executable, .modelMissing:
            return nil
        }
    }

    var runtimeWarningMessage: String? {
        rawRuntimeWarningMessage.map { localizedRuntimeWarning($0) }
    }

    var supplementalLastErrorMessage: String? {
        let message = lastErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !message.isEmpty else { return nil }
        if message == rawRuntimeWarningMessage {
            return nil
        }
        if message == rawDownloadStateSummary {
            return nil
        }
        return message
    }

    func updateSourceURL(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextSourceURL = trimmed.isEmpty
            ? LocalAssistantModelProfile.defaultDownloadURL
            : trimmed

        // 3Nなど別モデルへ切り替える時、前モデルの途中データを再利用しない。
        if Self.normalizedSourceURL(sourceURLString) != Self.normalizedSourceURL(nextSourceURL) {
            cancelActiveTasksWithoutResume()
            // 旧モデル本体は削除せず保持するが、状態JSONを消してしまうと
            // ディレクトリ走査で旧ファイルを新しいモデルとして再採用する。
            // 旧ファイル名を状態へ残したまま失敗扱いにし、sourceURL変更後は
            // 必ず新しいモデルを明示的にダウンロードする。
            let previous = persistedDownloadState
            let invalidatedState = LocalAssistantDownloadState(
                sourceURL: nextSourceURL,
                resolvedURL: previous?.resolvedURL,
                expectedBytes: previous?.expectedBytes ?? installedFileSize,
                eTag: previous?.eTag,
                resumeDataPath: nil,
                status: .failed,
                startedAt: previous?.startedAt ?? Date(),
                updatedAt: Date(),
                lastError: "モデルの配布元を変更しました。新しいモデルをダウンロードしてください。",
                suggestedFilename: previous?.suggestedFilename ?? installedFileName
            )
            persistDownloadState(invalidatedState)
            removeResumeData()
            downloadedBytes = 0
            expectedBytes = 0
            resolvedInstalledModelURL = nil
            legacyResolvedInstalledModelURL = nil
            installedFileName = nil
            installedFileSize = 0
            AILegacyCompatibility.removeValue(
                primaryKey: installedFileNameKey,
                aliases: AILegacyCompatibility.localModelInstalledFileAliases,
                defaults: defaults
            )
            runtimeAvailabilitySnapshot = .modelMissing
        }

        if trimmed.isEmpty {
            sourceURLString = LocalAssistantModelProfile.defaultDownloadURL
            AILegacyCompatibility.removeValue(
                primaryKey: sourceURLKey,
                aliases: AILegacyCompatibility.localModelSourceAliases,
                defaults: defaults
            )
        } else {
            sourceURLString = trimmed
            AILegacyCompatibility.exportString(
                sourceURLString,
                primaryKey: sourceURLKey,
                aliases: AILegacyCompatibility.localModelSourceAliases,
                defaults: defaults
            )
        }
    }

    @discardableResult
    func updateAccessToken(_ value: String) -> Bool {
        accessToken = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if accessToken.isEmpty {
            return secretStore.removeValue(for: .localModelAccessToken)
        } else {
            return secretStore.setString(accessToken, for: .localModelAccessToken)
        }
    }

    func refreshEnvironment() {
        scheduleEnvironmentRefresh()
    }

    func recheckRuntimeAvailability() {
        LocalAssistantRuntimeBridge.shared.clearRuntimeError()

        automaticRuntimeCheckTask?.cancel()
        automaticRuntimeCheckTask = nil
        automaticRuntimeCheckModelKey = nil

        // 手動再確認を残す呼び出し元向けの互換入口。通常はモデル検出後に自動実行する。
        NSLog(
            "[ModelManager] self-check requested installed=%@ downloading=%@ status=%@",
            installedModelURL?.path ?? "nil",
            isDownloading ? "true" : "false",
            downloadStatus.rawValue
        )

        // 環境更新を非同期に待つ前にURLを確定する。
        // 旧実装は更新前のnilを拾い、保存済みモデルを未導入扱いにすることがあった。
        restorePersistedDownloadState()
        refreshInstalledState()

        // 実ファイルが見つかったのに、古い状態JSONだけが downloading のまま残る
        // ケースを修復する。実ダウンロード中なら状態を変更しない。
        if !isDownloading,
           resolvedInstalledModelURL != nil,
           [.preflighting, .downloading].contains(downloadStatus) {
            downloadStatus = .completed
            updateDownloadState(
                status: .completed,
                expectedBytes: installedFileSize > 0 ? max(expectedBytes, installedFileSize) : nil,
                lastError: nil,
                resumeDataPath: nil
            )
            applyStatusPresentation()
        }

        guard let currentModelURL = installedModelURL else {
            scheduleStatusPresentationRefresh()
            return
        }

        startRuntimeAvailabilityCheck(for: currentModelURL)
    }

    private func scheduleEnvironmentRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            guard let self else { return }
            if self.isEnvironmentRefreshScheduled {
                return
            }
            self.isEnvironmentRefreshScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                guard let self else { return }
                self.isEnvironmentRefreshScheduled = false
                self.performEnvironmentRefresh()
            }
        }
    }

    private func performEnvironmentRefresh() {
        restorePersistedDownloadState()
        refreshInstalledState()
        refreshRuntimeAvailabilitySnapshot()
        // 起動直後はモデルの存在確認とランタイムの環境確認が別々の非同期経路で
        // 走るため、先に環境が更新されると prewarm が一度も実行されないことがある。
        // インストール済みモデルを再検出した直後に一度だけ暖機を試し、保存済み
        // モデルが「確認待ち」のまま残らないようにする。
        LocalAssistantRuntimeBridge.shared.prewarmIfPossible()
        DispatchQueue.main.async { [weak self] in
            self?.runtimeRefreshedAt = Date()
        }
        if isDownloading == false {
            scheduleStatusPresentationRefresh()
        }
    }

    private func scheduleStatusPresentationRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            guard let self else { return }
            if self.isDownloading == false {
                self.applyStatusPresentation()
            }
        }
    }

    private func refreshRuntimeAvailabilitySnapshot() {
        let nextAvailability = LocalAssistantRuntimeBridge.shared.availability(installedModelURL: installedModelURL)
        runtimeAvailabilitySnapshot = nextAvailability
        scheduleAutomaticRuntimeCheckIfNeeded()
    }

    private func scheduleAutomaticRuntimeCheckIfNeeded() {
        guard !isDownloading,
              !isValidatingDownloadedCandidate,
              runtimeAvailability == .savedOnly,
              let modelURL = installedModelURL else {
            return
        }
        startRuntimeAvailabilityCheck(for: modelURL)
    }

    private func startRuntimeAvailabilityCheck(for modelURL: URL) {
        let modelKey = automaticRuntimeCheckKey(for: modelURL)
        guard automaticRuntimeCheckTask == nil,
              automaticRuntimeCheckModelKey != modelKey else {
            return
        }

        automaticRuntimeCheckModelKey = modelKey
        runtimeAvailabilitySnapshot = .checking
        setStatus(.checking, japaneseMessage: "ローカルモデルを端末内で確認しています")

        automaticRuntimeCheckTask = Task { [weak self] in
            guard let self else { return }
            let result = await LocalAssistantRuntimeBridge.shared.performSelfCheck(installedModelURL: modelURL)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.automaticRuntimeCheckTask = nil
                guard self.installedModelURL?.standardizedFileURL == modelURL.standardizedFileURL else {
                    self.automaticRuntimeCheckModelKey = nil
                    return
                }
                self.runtimeAvailabilitySnapshot = result
                self.applyStatusPresentation()
            }
        }
    }

    private func automaticRuntimeCheckKey(for modelURL: URL) -> String {
        let values = try? modelURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        let modified = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        return "\(modelURL.standardizedFileURL.path)|\(size)|\(modified)"
    }

    func startDownload() {
        guard !isDownloading, !isValidatingDownloadedCandidate else { return }
        NSLog(
            "[ModelManager] DOWNLOAD START requested status=%@ installed=%@ callstack=%@",
            downloadStatus.rawValue,
            installedModelURL?.path ?? "nil",
            Thread.callStackSymbols.prefix(8).joined(separator: " <- ")
        )
        beginDownload(resuming: false)
    }

    func resumeDownloadIfPossible() {
        guard !isDownloading, !isValidatingDownloadedCandidate, canResumeDownload else { return }
        NSLog(
            "[ModelManager] DOWNLOAD RESUME requested status=%@ installed=%@",
            downloadStatus.rawValue,
            installedModelURL?.path ?? "nil"
        )
        beginDownload(resuming: true)
    }

    func restartDownloadFromScratch() {
        guard !isDownloading else { return }
        clearPersistedDownloadState(removeResumeData: true)
        removeIncompleteDownloadedFileIfNeeded()
        downloadedBytes = 0
        expectedBytes = 0
        activeDownloadBaseBytes = 0
        resetDownloadProgressMetrics()
        lastErrorMessage = nil
        downloadStatus = .idle
        beginDownload(resuming: false)
    }

    func resetSourceURLToDefault() {
        sourceURLString = LocalAssistantModelProfile.defaultDownloadURL
        AILegacyCompatibility.removeValue(
            primaryKey: sourceURLKey,
            aliases: AILegacyCompatibility.localModelSourceAliases,
            defaults: defaults
        )
    }

    func cancelDownload() {
        if let preflightTask {
            preflightTask.cancel()
            self.preflightTask = nil
            preflightSession?.invalidateAndCancel()
            preflightSession = nil
            preflightDelegate = nil
            // Invalidate the preflight generation immediately. URLSession can
            // still deliver a response/failure after cancel() returns.
            activeTransferID = UUID()
            isDownloading = false
            downloadStatus = .idle
            clearPersistedDownloadState(removeResumeData: true)
            downloadedBytes = 0
            expectedBytes = 0
            setStatus(.preparationStopped, japaneseMessage: "ダウンロード準備を停止しました")
            return
        }

        guard let downloadTask else { return }
        // The resume-data callback is asynchronous. Keep the identity of the
        // task being cancelled so a new download started before that callback
        // cannot persist A's resume data or reset B's session.
        let cancelledTransferID = activeTransferID
        isCancellingForResume = true
        downloadTask.cancel(byProducingResumeData: { [weak self] resumeData in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.activeTransferID == cancelledTransferID else {
                    NSLog("[Kizuna] ignored stale cancel callback for download generation")
                    return
                }
                self.persistResumeData(resumeData)
                self.isDownloading = false
                self.resetActiveSession()
                if resumeData?.isEmpty == false {
                    self.downloadStatus = .resumable
                    self.lastErrorMessage = nil
                    self.updateDownloadState(
                        status: .resumable,
                        lastError: "ダウンロードを停止しました。続きから再開できます。"
                    )
                    self.setStatus(.resumeAvailable, japaneseMessage: "前回の続きから再開できます")
                } else {
                    self.downloadStatus = .idle
                    self.setStatus(.cancelled, japaneseMessage: "ダウンロードをキャンセルしました")
                    self.clearPersistedDownloadState(removeResumeData: true)
                }
                self.isCancellingForResume = false
            }
        })
    }

    @discardableResult
    func removeInstalledModel() -> Bool {
        cancelActiveTasksWithoutResume()
        LocalAssistantRuntimeBridge.shared.clearRuntimeError()
        removeIncompleteDownloadedFileIfNeeded()

        if let installedModelURL {
            do {
                if FileManager.default.fileExists(atPath: installedModelURL.path) {
                    try FileManager.default.removeItem(at: installedModelURL)
                }
            } catch {
                // ファイル削除に失敗したのに状態だけ消すと、UIは未導入と表示し、
                // 次回起動で同じモデルが残る。実体を保持したまま状態も保持する。
                lastErrorMessage = "ローカルモデルの削除に失敗しました。ファイルを使用中のアプリを閉じてから再試行してください。"
                setStatus(.modelDeletionFailed, japaneseMessage: "ローカルモデルの削除に失敗しました")
                refreshInstalledState()
                applyStatusPresentation()
                return false
            }
        }

        clearPersistedDownloadState(removeResumeData: true)
        AILegacyCompatibility.removeValue(
            primaryKey: installedFileNameKey,
            aliases: AILegacyCompatibility.localModelInstalledFileAliases,
            defaults: defaults
        )
        installedFileName = nil
        installedFileSize = 0
        downloadedBytes = 0
        expectedBytes = 0
        activeDownloadBaseBytes = 0
        resetDownloadProgressMetrics()
        lastErrorMessage = nil
        resolvedInstalledModelURL = nil
        downloadStatus = .idle
        setStatus(.modelDeleted, japaneseMessage: "ローカルモデルを削除しました")
        return true
    }

    func removeLegacyInstalledModel() {
        let fileManager = FileManager.default
        let legacyModelURLs = discoverLegacyModelFilesForRemoval()
        guard !legacyModelURLs.isEmpty else {
            refreshInstalledState()
            setStatus(.legacyModelMissing, japaneseMessage: "旧 Gemma 3n モデルは見つかりませんでした")
            return
        }

        do {
            for legacyModelURL in legacyModelURLs {
                if fileManager.fileExists(atPath: legacyModelURL.path) {
                    try fileManager.removeItem(at: legacyModelURL)
                }
            }
            removeEmptyLegacyDirectoriesIfNeeded(using: fileManager)
            refreshInstalledState()
            setStatus(.legacyModelDeleted, japaneseMessage: "旧 Gemma 3n モデルを削除しました")
        } catch {
            refreshInstalledState()
            lastErrorMessage = "旧 Gemma 3n モデルの削除に失敗しました。"
            applyStatusPresentation()
        }
    }

    private var displayState: LocalAssistantDisplayState {
        // 保存済みモデルがある場合、停止済みの古い状態JSONだけで
        // 「ダウンロード中」に戻さない。実ダウンロード中は isDownloading が真。
        if isValidatingDownloadedCandidate {
            return .checking
        }
        if isDownloading || (resolvedInstalledModelURL == nil && [.preflighting, .downloading].contains(downloadStatus)) {
            return .downloading
        }
        if canResumeDownload {
            return .resumable
        }
        if resolvedInstalledModelURL == nil {
            return .modelMissing
        }
        switch runtimeAvailability {
        case .checking:
            return .checking
        case .executable:
            return .executable
        case .recentFailure:
            return .recentFailure
        case .savedOnly:
            return .savedOnly
        case .modelMissing:
            return .modelMissing
        }
    }

    private func beginDownload(resuming: Bool) {
        installedModelSnapshotBeforeDownload = currentInstalledModelSnapshot()
        activeTransferID = UUID()
        // A previous cancel(byProducingResumeData:) may still be waiting on
        // its callback. The new transfer owns cancellation state from here;
        // the old callback is rejected by its transfer ID below.
        isCancellingForResume = false
        LocalAssistantRuntimeBridge.shared.clearRuntimeError()
        if isUsingDefaultSource, hasStaleAuthorizationFailureState {
            clearPersistedDownloadState(removeResumeData: true)
            removeIncompleteDownloadedFileIfNeeded()
        }
        let sourceString = resuming ? (persistedDownloadState?.sourceURL ?? resolvedSourceURLString) : resolvedSourceURLString
        guard let url = URL(string: sourceString),
              let scheme = url.scheme?.lowercased(),
              scheme == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil else {
            applyFailure(message: "モデルの配布元は安全なHTTPS URLで指定してください。")
            return
        }

        isDownloading = true
        downloadedBytes = 0
        expectedBytes = persistedDownloadState?.expectedBytes ?? 0
        activeDownloadBaseBytes = 0
        resetDownloadProgressMetrics()
        lastErrorMessage = nil
        downloadStatus = .preflighting
        persistDownloadState(
            LocalAssistantDownloadState(
                sourceURL: sourceString,
                resolvedURL: persistedDownloadState?.resolvedURL,
                expectedBytes: persistedDownloadState?.expectedBytes ?? 0,
                eTag: persistedDownloadState?.eTag,
                resumeDataPath: persistedDownloadState?.resumeDataPath,
                status: .preflighting,
                startedAt: persistedDownloadState?.startedAt ?? Date(),
                updatedAt: Date(),
                lastError: nil,
                suggestedFilename: persistedDownloadState?.suggestedFilename
            )
        )
        applyStatusPresentation()
        performPreflight(for: url, resuming: resuming, transferID: activeTransferID)
    }

    private func performPreflight(for url: URL, resuming: Bool, transferID: UUID) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 60
        let delegate = LocalAssistantPreflightDelegate { [weak self] response in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.activeTransferID == transferID,
                      self.isDownloading,
                      self.downloadStatus == .preflighting else { return }
                self.preflightTask = nil
                self.preflightSession?.invalidateAndCancel()
                self.preflightSession = nil
                self.preflightDelegate = nil
                self.handlePreflightResponse(response, sourceURL: url, resuming: resuming, transferID: transferID)
            }
        } failureHandler: { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.activeTransferID == transferID,
                      self.isDownloading,
                      self.downloadStatus == .preflighting else { return }
                self.preflightTask = nil
                self.preflightSession?.invalidateAndCancel()
                self.preflightSession = nil
                self.preflightDelegate = nil
                if let error = error as NSError?, error.code == NSURLErrorCancelled {
                    return
                }
                self.applyFailure(message: "配布元の確認に失敗しました。ネットワーク接続を確認して再試行してください。")
            }
        }
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        preflightSession = session
        preflightDelegate = delegate

        var request = URLRequest(url: url)
        // Hugging Face/XetはHEADで配布サイズを返さないことがあるため、1バイトだけGETして確認する。
        request.httpMethod = "GET"
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        if shouldAttachAuthorization(to: url) {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        preflightTask = session.dataTask(with: request)
        preflightTask?.resume()
    }

    private func handlePreflightResponse(
        _ response: HTTPURLResponse,
        sourceURL: URL,
        resuming: Bool,
        transferID: UUID
    ) {
        guard activeTransferID == transferID else { return }
        let statusCode = response.statusCode
        if statusCode == 401 || statusCode == 403 {
            applyFailure(message: "配布元が認証を要求しました。Bearer トークンを確認してください。")
            return
        }

        guard (200...299).contains(statusCode) else {
            applyFailure(message: "配布元が HTTP \(statusCode) を返しました。しばらく待って再試行してください。")
            return
        }

        let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? response.mimeType ?? "").lowercased()
        if contentType.contains("html") {
            applyFailure(message: "モデル本体ではなくHTMLが返されました。配布元か認証設定を確認してください。")
            return
        }

        let expectedBytes = expectedBytesFromResponse(response, fallbackURL: sourceURL)
        do {
            try FileManager.default.createDirectory(at: installationDirectoryURL, withIntermediateDirectories: true)
        } catch {
            applyFailure(message: "保存先フォルダを作成できません。")
            return
        }

        let requiredBytes = requiredBytesForPreflight(expectedBytes: expectedBytes)
        if let freeBytes = availableDiskSpaceBytes(),
           freeBytes > 0,
           freeBytes < requiredBytes {
            applyFailure(message: "空き容量が不足しています。モデル保存には追加の空きが必要です。")
            return
        }

        let acceptsResume = (response.value(forHTTPHeaderField: "Accept-Ranges") ?? "")
            .lowercased()
            .contains("bytes")
        if resuming && !acceptsResume {
            applyFailure(message: "配布元が続きからの再開に対応していません。最初からやり直してください。")
            return
        }

        let preflight = LocalAssistantDownloadPreflight(
            sourceURL: sourceURL,
            resolvedURL: response.url ?? sourceURL,
            expectedBytes: expectedBytes,
            eTag: response.value(forHTTPHeaderField: "ETag"),
            suggestedFilename: suggestedFileName(from: response, fallbackURL: response.url ?? sourceURL),
            acceptsResume: acceptsResume
        )
        startDownloadTask(with: preflight, resuming: resuming, transferID: transferID)
    }

    private func startDownloadTask(
        with preflight: LocalAssistantDownloadPreflight,
        resuming: Bool,
        transferID: UUID
    ) {
        guard activeTransferID == transferID else { return }
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60 * 6
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        urlSession = session

        let task: URLSessionDownloadTask
        var resumedBytes: Int64 = 0
        if resuming, let resumeData = loadResumeData(), resumeDataLooksUsable(resumeData) {
            resumedBytes = estimatedResumeBytes(from: resumeData)
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            if resuming {
                removeResumeData()
            }
            var request = URLRequest(url: preflight.sourceURL)
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            if shouldAttachAuthorization(to: preflight.sourceURL) {
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            }
            task = session.downloadTask(with: request)
        }

        isDownloading = true
        downloadTask = task
        expectedBytes = preflight.expectedBytes
        activeDownloadBaseBytes = resumedBytes
        downloadedBytes = resumedBytes
        resetDownloadProgressMetrics()
        lastErrorMessage = nil
        downloadStatus = .downloading
        updateDownloadState(
            status: .downloading,
            resolvedURL: preflight.resolvedURL.absoluteString,
            expectedBytes: preflight.expectedBytes,
            eTag: preflight.eTag,
            suggestedFilename: preflight.suggestedFilename,
            lastError: nil
        )
        setStatus(
            .downloading(resuming: resuming, percent: nil),
            japaneseMessage: resuming ? "モデルの続きをダウンロードしています" : "モデルをダウンロードしています"
        )
        task.resume()
    }

    private func refreshInstalledState() {
        resolvedInstalledModelURL = discoverInstalledModelURL()
        legacyResolvedInstalledModelURL = resolvedInstalledModelURL == nil ? discoverLegacyInstalledModelURL() : nil
        if let resolvedInstalledModelURL {
            adoptExistingModelIfNeeded(at: resolvedInstalledModelURL)
        }
        installedFileName = resolvedInstalledModelURL?.lastPathComponent
        installedFileSize = resolvedInstalledModelURL
            .flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
            .map(Int64.init) ?? 0

        if let installedFileName {
            AILegacyCompatibility.exportString(
                installedFileName,
                primaryKey: installedFileNameKey,
                aliases: AILegacyCompatibility.localModelInstalledFileAliases,
                defaults: defaults
            )
        } else {
            AILegacyCompatibility.removeValue(
                primaryKey: installedFileNameKey,
                aliases: AILegacyCompatibility.localModelInstalledFileAliases,
                defaults: defaults
            )
        }

        if !isDownloading {
            applyStatusPresentation()
        }
    }

    private func discoverInstalledModelURL() -> URL? {
        let storedFileName = AILegacyCompatibility.stringValue(
            primaryKey: installedFileNameKey,
            aliases: AILegacyCompatibility.localModelInstalledFileAliases,
            defaults: defaults
        )

        if let storedFileName {
            for directory in currentModelCandidateDirectories {
                let candidate = directory.appendingPathComponent(storedFileName)
                if isAvailableInstalledModel(at: candidate) {
                    return relocateIfNeeded(candidate)
                }
            }
        }

        for directory in currentModelCandidateDirectories {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            let models = contents.filter { isAvailableInstalledModel(at: $0) }
            let sortedModels = models.sorted {
                let lhsDate = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }

            if let found = sortedModels.first {
                return relocateIfNeeded(found)
            }
        }

        return nil
    }

    private func discoverLegacyInstalledModelURL() -> URL? {
        guard !hasInvalidPersistedDownloadState else { return nil }
        for directory in legacyModelCandidateDirectories {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            let models = contents.filter { isAvailableInstalledModel(at: $0) }
            let sortedModels = models.sorted {
                let lhsDate = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }

            if let found = sortedModels.first {
                return found
            }
        }

        return nil
    }

    private func discoverLegacyModelFilesForRemoval() -> [URL] {
        var legacyModelURLs: [URL] = []
        var seen = Set<String>()

        if let legacyResolvedInstalledModelURL {
            legacyModelURLs.append(legacyResolvedInstalledModelURL)
            seen.insert(legacyResolvedInstalledModelURL.standardizedFileURL.path)
        }

        for directory in legacyModelCandidateDirectories {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for candidate in contents where isRemovableLegacyModelFile(at: candidate) {
                let standardizedPath = candidate.standardizedFileURL.path
                if seen.insert(standardizedPath).inserted {
                    legacyModelURLs.append(candidate)
                }
            }
        }

        return legacyModelURLs
    }

    private func isRemovableLegacyModelFile(at url: URL) -> Bool {
        guard !hasInvalidPersistedDownloadState else { return false }
        guard isValidModelFile(at: url) else { return false }
        if url.standardizedFileURL == resolvedInstalledModelURL?.standardizedFileURL {
            return false
        }
        if url.standardizedFileURL == legacyResolvedInstalledModelURL?.standardizedFileURL {
            return true
        }
        return url.lastPathComponent.lowercased().contains("3n")
    }

    private func removeEmptyLegacyDirectoriesIfNeeded(using fileManager: FileManager) {
        for directory in legacyModelCandidateDirectories {
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            let remainingContents = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            if remainingContents.isEmpty {
                try? fileManager.removeItem(at: directory)
            }
        }
    }

    private func relocateIfNeeded(_ sourceURL: URL) -> URL {
        guard sourceURL.deletingLastPathComponent().standardizedFileURL != installationDirectoryURL.standardizedFileURL else {
            return sourceURL
        }

        let destinationURL = installationDirectoryURL.appendingPathComponent(sourceURL.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: installationDirectoryURL, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: destinationURL.path) {
                do {
                    try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
                } catch {
                    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                }
            }
            return destinationURL
        } catch {
            return sourceURL
        }
    }

    private func isAvailableInstalledModel(at url: URL) -> Bool {
        guard !hasInvalidPersistedDownloadState else { return false }
        guard !isBlockedByIncompleteDownloadState(url) else { return false }
        return isValidModelFile(at: url, expectedBytes: expectedBytesForCompletedModel(at: url))
    }

    private func isBlockedByIncompleteDownloadState(_ url: URL) -> Bool {
        guard let state = persistedDownloadState else { return false }
        // A `.validating` state refers to a hidden candidate file. The file at
        // the public installed path is still the previous model and must remain
        // usable while the candidate is checked.
        guard state.status != .completed, state.status != .validating else { return false }
        guard let stateFileName = stateReferencedFileName(for: state) else { return false }
        guard stateFileName == url.lastPathComponent else { return false }

        // 旧バージョンではRange確認の Content-Length: 1 が状態JSONに保存されていた。
        // ただし、単に50MB以上あるだけでは中断ファイルも完成扱いになる。
        // 標準Gemmaの既知サイズに近く、再開データもない場合だけ移行扱いにする。
        guard state.expectedBytes > 1 else {
            return !isLikelyCompletedModelWithUnknownSize(at: url, state: state)
        }
        return !isValidModelFile(at: url, expectedBytes: state.expectedBytes)
    }

    private func isLikelyCompletedModelWithUnknownSize(
        at url: URL,
        state: LocalAssistantDownloadState
    ) -> Bool {
        guard Self.isEffectivelyDefaultSource(state.sourceURL),
              currentResumeDataURL(from: state) == nil,
              isValidModelFile(at: url) else {
            return false
        }

        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let expectedSize = LocalAssistantModelProfile.expectedModelSizeBytes
        let tolerance = max(Int64(128 * 1024 * 1024), expectedSize / 20)
        return abs(fileSize - expectedSize) <= tolerance
    }

    private func adoptExistingModelIfNeeded(at modelURL: URL) {
        // During candidate validation the public path still belongs to the
        // previous model. Do not rewrite the durable validation marker just
        // because the old model is rediscovered by an environment refresh.
        guard persistedDownloadState?.status != .validating else { return }
        guard isValidModelFile(at: modelURL) else { return }
        let fileSize = (try? modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard fileSize > 0 else { return }
        if let previous = persistedDownloadState,
           previous.status == .completed,
           stateReferencedFileName(for: previous) == modelURL.lastPathComponent {
            return
        }

        // ダウンロード済み本体を見つけたら、状態JSONを完成済みに修復する。
        let previous = persistedDownloadState
        let completedState = LocalAssistantDownloadState(
            sourceURL: previous?.sourceURL ?? resolvedSourceURLString,
            resolvedURL: previous?.resolvedURL,
            expectedBytes: max(previous?.expectedBytes ?? 0, fileSize),
            eTag: previous?.eTag,
            resumeDataPath: nil,
            status: .completed,
            startedAt: previous?.startedAt ?? Date(),
            updatedAt: Date(),
            lastError: nil,
            suggestedFilename: modelURL.lastPathComponent
        )
        persistDownloadState(completedState)
        try? FileManager.default.removeItem(at: resumeDataStorageURL)
        downloadedBytes = fileSize
        expectedBytes = completedState.expectedBytes
        lastErrorMessage = nil
        downloadStatus = .completed
    }

    private func expectedBytesForCompletedModel(at url: URL) -> Int64? {
        guard let state = persistedDownloadState, state.status == .completed else { return nil }
        guard stateReferencedFileName(for: state) == url.lastPathComponent else { return nil }
        return state.expectedBytes > 0 ? state.expectedBytes : nil
    }

    private func stateReferencedFileName(for state: LocalAssistantDownloadState) -> String? {
        if let suggestedFilename = state.suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines),
           !suggestedFilename.isEmpty {
            return suggestedFilename
        }
        if let resolvedURL = state.resolvedURL, let url = URL(string: resolvedURL), !url.lastPathComponent.isEmpty {
            return url.lastPathComponent
        }
        if let sourceURL = URL(string: state.sourceURL), !sourceURL.lastPathComponent.isEmpty {
            return sourceURL.lastPathComponent
        }
        return nil
    }

    private func isValidModelFile(at url: URL, expectedBytes: Int64? = nil) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            let trustedArtifact = trustedArtifactForStoredModel(at: url)
            try validateModelArtifact(
                at: url,
                fileName: url.lastPathComponent,
                expectedBytes: expectedBytes,
                trustedArtifact: trustedArtifact,
                requireExactByteCount: false,
                validateLiteRTLMMetadata: false,
                validationDepth: trustedArtifact == nil ? .strict : .quick
            )
            return true
        } catch {
            return false
        }
    }

    private func trustedArtifactForStoredModel(at url: URL) -> LocalAssistantModelProfile.TrustedArtifact? {
        guard let state = persistedDownloadState,
              state.status == .completed,
              stateReferencedFileName(for: state) == url.lastPathComponent else {
            return nil
        }
        return LocalAssistantModelProfile.trustedArtifact(for: state.sourceURL)
    }

    private func validateModelArtifact(
        at url: URL,
        fileName: String,
        expectedBytes: Int64?,
        trustedArtifact: LocalAssistantModelProfile.TrustedArtifact?,
        requireExactByteCount: Bool,
        validateLiteRTLMMetadata: Bool,
        validationDepth: LocalAssistantModelArtifactValidator.ValidationDepth
    ) throws {
        if let trustedArtifact, fileName != trustedArtifact.fileName {
            throw LocalAssistantModelArtifactValidator.ValidationError.unexpectedFileName
        }

        let verificationSize = trustedArtifact?.byteCount ?? expectedBytes
        try LocalAssistantModelArtifactValidator.validate(
            at: url,
            fileName: fileName,
            expectedByteCount: verificationSize,
            // Complete candidates are SHA-256 verified on a utility queue
            // before replacement. Routine discovery never hashes every
            // 2.6–5.3 GB model on the main queue. Standard artifacts already
            // tied to a completed state use a fast header check; unknown files
            // still receive strict structural parsing before they are adopted.
            expectedSHA256: nil,
            minimumByteCount: LocalAssistantModelProfile.minimumAcceptedModelSizeBytes,
            requireExactByteCount: requireExactByteCount,
            validationDepth: validationDepth
        )

        if URL(fileURLWithPath: fileName).pathExtension.lowercased() == "litertlm",
           validateLiteRTLMMetadata {
            try Self.validateLiteRTLMMetadata(at: url, hasTrustedDigest: trustedArtifact != nil)
        }
    }

    nonisolated private static func validateLiteRTLMMetadata(at url: URL, hasTrustedDigest: Bool) throws {
#if os(iOS) && !targetEnvironment(simulator) && VIUK_ENABLE_LITERTLM_NATIVE
#if canImport(LiteRTLM)
        guard Capabilities(modelPath: url.path) != nil else {
            throw LocalAssistantModelArtifactValidator.ValidationError.invalidLiteRTLMMetadata
        }
#else
        guard hasTrustedDigest else {
            throw LocalAssistantModelArtifactValidator.ValidationError.liteRTLMValidationUnavailable
        }
#endif
#else
        guard hasTrustedDigest else {
            throw LocalAssistantModelArtifactValidator.ValidationError.liteRTLMValidationUnavailable
        }
#endif
    }

    private func localizedStatusMessage(for kind: LocalAssistantStatusKind) -> String {
        guard KizunaCopy.language == .english else { return statusMessage }

        switch kind {
        case .modelMissing(let hasLegacyModel):
            return hasLegacyModel
                ? "An older local model was found. Gemma 4 is not installed."
                : "Local model not installed"
        case .preflighting:
            return "Checking the download source, destination, and free space"
        case .preparationStopped:
            return "Download preparation stopped"
        case .downloading(let resuming, let percent):
            let prefix = resuming ? "Downloading the rest of the model" : "Downloading model"
            guard let percent else { return prefix }
            return "\(prefix) (\(percent)%)"
        case .resumeAvailable:
            return "The previous download can be resumed"
        case .paused:
            return "Download paused"
        case .cancelled:
            return "Download cancelled"
        case .checking:
            return "Checking the local model on this device"
        case .executable:
            return "The local model can run on this device"
        case .savedOnly:
            return "The model file is saved"
        case .recentFailure:
            if let diagnostic = LocalAssistantRuntimeBridge.shared.lastRuntimeDiagnostic {
                return englishRuntimeDiagnosticSummary(for: diagnostic.kind)
            }
            return "The automatic on-device check failed."
        case .downloadFailure(let message):
            return localizedReadableError(message)
        case .modelSaved:
            return "Local model saved"
        case .modelDeleted:
            return "Local model deleted"
        case .modelDeletionFailed:
            return "The local model could not be deleted"
        case .legacyModelMissing:
            return "No older Gemma 3n model was found"
        case .legacyModelDeleted:
            return "Older Gemma 3n model deleted"
        }
    }

    private func localizedDownloadStateSummary(_ rawMessage: String) -> String {
        guard KizunaCopy.language == .english else { return rawMessage }
        switch downloadStatus {
        case .preflighting:
            return "Checking the download source, destination, and free space"
        case .downloading:
            if let progressValue {
                return "Downloading model (\(Int(progressValue * 100))%)"
            }
            return "Downloading model"
        case .resumable:
            return "The previous download can be resumed"
        case .paused:
            return "Download paused"
        case .validating:
            return "Checking the downloaded model before replacing the installed model"
        case .failed:
            return localizedReadableError(lastErrorMessage)
        case .completed:
            return "The model file is saved"
        case .idle:
            if resolvedInstalledModelURL != nil {
                return "A saved model is available"
            }
            if hasLegacyInstalledModel {
                return "An older local model remains. Gemma 4 can be added."
            }
            return "A standard model can be saved in the app"
        }
    }

    private func localizedRuntimeWarning(_ rawMessage: String) -> String {
        guard KizunaCopy.language == .english else { return rawMessage }
        switch runtimeAvailability {
        case .checking:
            return "Checking the local model on this device. It will not be marked ready until the check finishes."
        case .recentFailure:
            return localizedRuntimeDiagnosticSummary ?? "The automatic on-device check failed."
        case .savedOnly:
            return "The model is saved. An automatic on-device check will start shortly."
        case .executable, .modelMissing:
            return rawMessage
        }
    }

    private func englishRuntimeDiagnosticSummary(for kind: LocalAssistantRuntimeFailureKind) -> String {
        switch kind {
        case .runnerUnavailable:
            return "The on-device runtime is unavailable."
        case .runnerStartupFailed:
            return "The on-device runtime could not start."
        case .modelLoadFailed:
            return "The model could not be loaded on this device."
        case .thinkingUnsupported:
            return "This model does not support the requested thinking mode."
        case .toolCallingUnsupported:
            return "This model does not support the requested tools."
        case .timeout:
            return "The on-device runtime timed out."
        case .emptyOutput:
            return "The on-device runtime returned no response."
        case .selfCheckFailed:
            return "The on-device runtime check failed."
        case .generationFailed:
            return "The local model failed to generate a response."
        case .supportBriefFailed:
            return "The safety-support response could not be generated."
        }
    }

    private func applyStatusPresentation() {
        // ダウンロード失敗時に「未導入」で上書きせず、原因を最上段へ出す。
        var nextStatus: (kind: LocalAssistantStatusKind, japaneseMessage: String)
        if downloadStatus == .failed, let lastErrorMessage, !lastErrorMessage.isEmpty {
            let message = classifyReadableError(lastErrorMessage)
            nextStatus = (.downloadFailure(message: message), message)
        } else {
            switch displayState {
            case .downloading:
                if downloadStatus == .preflighting {
                    nextStatus = (.preflighting, "配布元と保存先を確認しています")
                } else if let progressValue {
                    let percent = Int(progressValue * 100)
                    nextStatus = (.downloading(resuming: false, percent: percent), "モデルを受信しています (\(percent)%)")
                } else {
                    nextStatus = (.downloading(resuming: false, percent: nil), "モデルを受信しています")
                }
            case .resumable:
                nextStatus = (.resumeAvailable, "前回の続きから再開できます")
            case .checking:
                nextStatus = (.checking, "ローカルモデルを起動確認しています")
            case .executable:
                nextStatus = (.executable, "ローカルモデルを実行できます")
            case .savedOnly:
                nextStatus = (.savedOnly, "モデルファイルは保存済みです")
            case .recentFailure:
                nextStatus = (.recentFailure, runtimeDiagnosticSummary ?? "ローカル実行の確認に失敗しました")
            case .modelMissing:
                if hasLegacyInstalledModel {
                    nextStatus = (.modelMissing(hasLegacyModel: true), "旧ローカルモデルを検出しました。Gemma 4 は未導入です")
                } else {
                    nextStatus = (.modelMissing(hasLegacyModel: false), "ローカルモデルは未導入です")
                }
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.setStatus(nextStatus.kind, japaneseMessage: nextStatus.japaneseMessage)
        }
    }

    private func classifyReadableError(_ rawMessage: String?) -> String {
        let message = rawMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !message.isEmpty else { return "直近のダウンロードで失敗しました" }
        if message.contains("空き容量") {
            return "空き容量が不足しています"
        }
        if message.contains("Bearer") || message.contains("認証") {
            return "配布元の認証が必要です"
        }
        if message.contains("HTML") {
            return "配布元がモデル本体を返しませんでした"
        }
        if message.contains("再開") {
            return "通信が中断されました。続きから再開できます"
        }
        if message.contains("HTTP") {
            return "配布元がエラーを返しました"
        }
        if message.contains("SHA-256")
            || message.contains("GGUF")
            || message.contains("GGML")
            || message.contains("LiteRT-LM")
            || message.contains("サイズ")
            || message.contains("小さすぎ") {
            return "ダウンロードしたモデルの整合性または形式を確認できませんでした。既存モデルは変更していません"
        }
        if message.contains("既存モデルは置き換えません") || message.contains("既存モデルは保持") {
            return "新しいモデルを受け入れなかったため、既存モデルを保持しました"
        }
        return message
    }

    nonisolated private static func validateDownloadedCandidate(
        at url: URL,
        fileName: String,
        reportedExpectedBytes: Int64,
        trustedArtifact: LocalAssistantModelProfile.TrustedArtifact?
    ) throws {
        if let trustedArtifact, fileName != trustedArtifact.fileName {
            throw LocalAssistantModelArtifactValidator.ValidationError.unexpectedFileName
        }

        let expectedBytes = trustedArtifact?.byteCount
            ?? (reportedExpectedBytes > 0 ? reportedExpectedBytes : nil)
        try LocalAssistantModelArtifactValidator.validate(
            at: url,
            fileName: fileName,
            expectedByteCount: expectedBytes,
            expectedSHA256: trustedArtifact?.sha256,
            minimumByteCount: LocalAssistantModelProfile.minimumAcceptedModelSizeBytes,
            requireExactByteCount: true
        )

        if URL(fileURLWithPath: fileName).pathExtension.lowercased() == "litertlm" {
            try validateLiteRTLMMetadata(at: url, hasTrustedDigest: trustedArtifact != nil)
        }
    }

    private func beginDownloadedCandidateValidation(
        tempURL: URL,
        fileName: String,
        response: URLResponse?,
        expectedBytes: Int64
    ) {
        guard !isValidatingDownloadedCandidate else {
            try? FileManager.default.removeItem(at: tempURL)
            return
        }

        let sourceURL = persistedDownloadState?.sourceURL ?? resolvedSourceURLString
        let trustedArtifact = LocalAssistantModelProfile.trustedArtifact(for: sourceURL)
        let recordedExpectedBytes = trustedArtifact?.byteCount ?? max(expectedBytes, 0)
        let pendingCandidate = LocalAssistantPendingModelCandidate(
            stagedURL: tempURL,
            fileName: fileName,
            sourceURL: sourceURL,
            resolvedURL: persistedDownloadState?.resolvedURL ?? response?.url?.absoluteString,
            expectedBytes: recordedExpectedBytes,
            eTag: persistedDownloadState?.eTag,
            previousModel: installedModelSnapshotBeforeDownload ?? currentInstalledModelSnapshot()
        )
        pendingModelCandidate = pendingCandidate

        persistDownloadState(
            pendingValidationState(for: pendingCandidate)
        )
        guard downloadStatePersistenceError == nil else {
            rejectDownloadedCandidate(
                pendingCandidate,
                message: "モデルの検証状態を保存できなかったため、既存モデルは置き換えませんでした。"
            )
            return
        }

        setStatus(.checking, japaneseMessage: "ダウンロードしたモデルを置換前に確認しています")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result: Result<Void, Error> = Result {
                try Self.validateDownloadedCandidate(
                    at: tempURL,
                    fileName: fileName,
                    reportedExpectedBytes: recordedExpectedBytes,
                    trustedArtifact: trustedArtifact
                )
            }
            DispatchQueue.main.async {
                self?.finishDownloadedCandidateFileValidation(result, candidate: pendingCandidate)
            }
        }
    }

    private func pendingValidationState(
        for candidate: LocalAssistantPendingModelCandidate
    ) -> LocalAssistantDownloadState {
        LocalAssistantDownloadState(
            sourceURL: candidate.sourceURL,
            resolvedURL: candidate.resolvedURL,
            expectedBytes: candidate.expectedBytes,
            eTag: candidate.eTag,
            resumeDataPath: nil,
            status: .validating,
            startedAt: persistedDownloadState?.startedAt ?? Date(),
            updatedAt: Date(),
            lastError: nil,
            suggestedFilename: candidate.fileName,
            pendingValidationPath: candidate.stagedURL.path,
            replacementBackupPath: nil,
            replacementInProgress: false,
            previousInstalledFileName: candidate.previousModel?.fileName,
            previousSourceURL: candidate.previousModel?.sourceURL,
            previousResolvedURL: candidate.previousModel?.resolvedURL,
            previousExpectedBytes: candidate.previousModel?.expectedBytes,
            previousETag: candidate.previousModel?.eTag
        )
    }

    private func finishDownloadedCandidateFileValidation(
        _ result: Result<Void, Error>,
        candidate: LocalAssistantPendingModelCandidate
    ) {
        guard pendingModelCandidate?.stagedURL.standardizedFileURL == candidate.stagedURL.standardizedFileURL else {
            try? FileManager.default.removeItem(at: candidate.stagedURL)
            return
        }

        switch result {
        case .failure(let error):
            rejectDownloadedCandidate(
                candidate,
                message: "ダウンロードしたモデルを検証できませんでした: \(error.localizedDescription)"
            )
        case .success:
            do {
                let stagingURL = validationStagingURL(for: candidate.fileName)
                try FileManager.default.createDirectory(at: installationDirectoryURL, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: candidate.stagedURL, to: stagingURL)
                let stagedCandidate = LocalAssistantPendingModelCandidate(
                    stagedURL: stagingURL,
                    fileName: candidate.fileName,
                    sourceURL: candidate.sourceURL,
                    resolvedURL: candidate.resolvedURL,
                    expectedBytes: candidate.expectedBytes,
                    eTag: candidate.eTag,
                    previousModel: candidate.previousModel
                )
                pendingModelCandidate = stagedCandidate
                persistDownloadState(pendingValidationState(for: stagedCandidate))
                guard downloadStatePersistenceError == nil else {
                    throw NSError(
                        domain: "LocalAssistantModelManager",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "モデルの検証状態を保存できませんでした。"]
                    )
                }
                startRuntimeValidation(for: stagedCandidate)
            } catch {
                rejectDownloadedCandidate(
                    pendingModelCandidate ?? candidate,
                    message: "検証済みモデルを安全な確認領域へ移せませんでした。既存モデルは保持されています。"
                )
            }
        }
    }

    private func validationStagingURL(for fileName: String) -> URL {
        let fileURL = URL(fileURLWithPath: fileName)
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let fileExtension = fileURL.pathExtension
        return installationDirectoryURL
            .appendingPathComponent(".\(baseName).candidate-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
    }

    private func startRuntimeValidation(for candidate: LocalAssistantPendingModelCandidate) {
        candidateRuntimeValidationTask?.cancel()
        candidateRuntimeValidationTask = Task { [weak self] in
            let availability = await LocalAssistantRuntimeBridge.shared.performSelfCheck(
                installedModelURL: candidate.stagedURL
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.finishRuntimeValidation(availability, candidate: candidate)
            }
        }
    }

    private func finishRuntimeValidation(
        _ availability: LocalAssistantRuntimeAvailability,
        candidate: LocalAssistantPendingModelCandidate
    ) {
        guard pendingModelCandidate?.stagedURL.standardizedFileURL == candidate.stagedURL.standardizedFileURL else {
            return
        }
        candidateRuntimeValidationTask = nil

        switch availability {
        case .executable:
            commitValidatedCandidate(candidate)
        case .savedOnly where candidate.previousModel == nil:
            // A first install may be kept after structural/integrity validation
            // when this build cannot run a local self-check. It cannot displace
            // an already working model in that state.
            commitValidatedCandidate(candidate)
        case .savedOnly:
            rejectDownloadedCandidate(
                candidate,
                message: "このビルドでは新しいモデルを起動確認できないため、既存モデルは置き換えませんでした。"
            )
        case .recentFailure:
            rejectDownloadedCandidate(
                candidate,
                message: "新しいモデルの端末内起動確認に失敗したため、既存モデルは置き換えませんでした。"
            )
        case .checking:
            rejectDownloadedCandidate(
                candidate,
                message: "新しいモデルの起動確認が完了しなかったため、既存モデルは置き換えませんでした。"
            )
        case .modelMissing:
            rejectDownloadedCandidate(
                candidate,
                message: "新しいモデルを確認できなかったため、既存モデルは置き換えませんでした。"
            )
        }
    }

    private func commitValidatedCandidate(_ candidate: LocalAssistantPendingModelCandidate) {
        let fileManager = FileManager.default
        let destinationURL = installationDirectoryURL.appendingPathComponent(candidate.fileName)
        let hasDestination = fileManager.fileExists(atPath: destinationURL.path)
        let backupURL = hasDestination
            ? LocalAssistantModelReplacement.backupURL(for: destinationURL)
            : nil
        var replacementTransaction: LocalAssistantModelReplacement.Transaction?

        do {
            guard var validationState = persistedDownloadState else {
                throw NSError(
                    domain: "LocalAssistantModelManager",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "モデル検証の状態が見つかりません。"]
                )
            }
            validationState.replacementInProgress = true
            validationState.replacementBackupPath = backupURL?.path
            persistDownloadState(validationState)
            guard downloadStatePersistenceError == nil else {
                throw NSError(
                    domain: "LocalAssistantModelManager",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "安全な置換状態を保存できませんでした。"]
                )
            }

            let transaction = try LocalAssistantModelReplacement.begin(
                candidateURL: candidate.stagedURL,
                destinationURL: destinationURL,
                backupURL: backupURL,
                fileManager: fileManager
            )
            replacementTransaction = transaction

            let savedSize = (try destinationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            guard savedSize >= LocalAssistantModelProfile.minimumAcceptedModelSizeBytes else {
                throw LocalAssistantModelArtifactValidator.ValidationError.fileTooSmall(
                    minimum: LocalAssistantModelProfile.minimumAcceptedModelSizeBytes,
                    actual: savedSize
                )
            }

            let completedState = LocalAssistantDownloadState(
                sourceURL: candidate.sourceURL,
                resolvedURL: candidate.resolvedURL,
                expectedBytes: max(candidate.expectedBytes, savedSize),
                eTag: candidate.eTag,
                resumeDataPath: nil,
                status: .completed,
                startedAt: persistedDownloadState?.startedAt ?? Date(),
                updatedAt: Date(),
                lastError: nil,
                suggestedFilename: candidate.fileName,
                pendingValidationPath: nil,
                replacementBackupPath: backupURL?.path,
                replacementInProgress: false
            )
            persistDownloadState(completedState)
            guard downloadStatePersistenceError == nil else {
                throw NSError(
                    domain: "LocalAssistantModelManager",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "置換後のモデル状態を保存できませんでした。"]
                )
            }

            try LocalAssistantModelReplacement.finish(transaction, fileManager: fileManager)
            if var savedState = persistedDownloadState {
                savedState.replacementBackupPath = nil
                persistDownloadState(savedState)
            }

            AILegacyCompatibility.exportString(
                candidate.fileName,
                primaryKey: installedFileNameKey,
                aliases: AILegacyCompatibility.localModelInstalledFileAliases,
                defaults: defaults
            )
            installedFileName = candidate.fileName
            installedFileSize = savedSize
            resolvedInstalledModelURL = destinationURL
            downloadedBytes = savedSize
            expectedBytes = max(candidate.expectedBytes, savedSize)
            activeDownloadBaseBytes = 0
            resetDownloadProgressMetrics()
            lastErrorMessage = nil
            pendingModelCandidate = nil
            installedModelSnapshotBeforeDownload = nil
            removeResumeData()
            setStatus(.modelSaved, japaneseMessage: "検証済みのローカルモデルを保存しました")
            refreshEnvironment()
        } catch {
            if let replacementTransaction {
                try? LocalAssistantModelReplacement.rollback(replacementTransaction, fileManager: fileManager)
            } else {
                restoreReplacementBackupIfNeeded(for: candidate)
            }
            rejectDownloadedCandidate(
                candidate,
                message: "検証済みモデルの置換に失敗しました。既存モデルは保持されています。"
            )
        }
    }

    private func restoreReplacementBackupIfNeeded(for candidate: LocalAssistantPendingModelCandidate) {
        let fileManager = FileManager.default
        let destinationURL = installationDirectoryURL.appendingPathComponent(candidate.fileName)
        guard let path = persistedDownloadState?.replacementBackupPath,
              let backupURL = managedReplacementBackupURL(from: path),
              fileManager.fileExists(atPath: backupURL.path) else {
            return
        }
        if fileManager.fileExists(atPath: destinationURL.path) {
            try? fileManager.removeItem(at: destinationURL)
        }
        try? fileManager.moveItem(at: backupURL, to: destinationURL)
    }

    private func rejectDownloadedCandidate(
        _ candidate: LocalAssistantPendingModelCandidate,
        message: String
    ) {
        candidateRuntimeValidationTask?.cancel()
        candidateRuntimeValidationTask = nil
        rollbackUnfinishedCandidateReplacementIfNeeded(for: candidate)
        if isManagedValidationCandidateURL(candidate.stagedURL) {
            try? FileManager.default.removeItem(at: candidate.stagedURL)
        }

        pendingModelCandidate = nil
        installedModelSnapshotBeforeDownload = nil
        isDownloading = false

        if let previousModel = candidate.previousModel,
           FileManager.default.fileExists(atPath: previousModel.modelURL.path) {
            let restoredSize = (try? previousModel.modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let restoredState = LocalAssistantDownloadState(
                sourceURL: previousModel.sourceURL ?? resolvedSourceURLString,
                resolvedURL: previousModel.resolvedURL,
                expectedBytes: max(previousModel.expectedBytes ?? 0, restoredSize),
                eTag: previousModel.eTag,
                resumeDataPath: nil,
                status: .completed,
                startedAt: Date(),
                updatedAt: Date(),
                lastError: nil,
                suggestedFilename: previousModel.fileName
            )
            persistDownloadState(restoredState)
            AILegacyCompatibility.exportString(
                previousModel.fileName,
                primaryKey: installedFileNameKey,
                aliases: AILegacyCompatibility.localModelInstalledFileAliases,
                defaults: defaults
            )
            installedFileName = previousModel.fileName
            installedFileSize = restoredSize
            resolvedInstalledModelURL = previousModel.modelURL
            downloadedBytes = restoredSize
            expectedBytes = restoredState.expectedBytes
            lastErrorMessage = message
            refreshEnvironment()
            return
        }

        let failedState = LocalAssistantDownloadState(
            sourceURL: candidate.sourceURL,
            resolvedURL: candidate.resolvedURL,
            expectedBytes: candidate.expectedBytes,
            eTag: candidate.eTag,
            resumeDataPath: nil,
            status: .failed,
            startedAt: Date(),
            updatedAt: Date(),
            lastError: message,
            suggestedFilename: candidate.fileName
        )
        persistDownloadState(failedState)
        lastErrorMessage = message
        applyStatusPresentation()
    }

    private func rollbackUnfinishedCandidateReplacementIfNeeded(
        for candidate: LocalAssistantPendingModelCandidate
    ) {
        let fileManager = FileManager.default
        let destinationURL = installationDirectoryURL.appendingPathComponent(candidate.fileName)
        if let path = persistedDownloadState?.replacementBackupPath,
           let backupURL = managedReplacementBackupURL(from: path),
           fileManager.fileExists(atPath: backupURL.path) {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try? fileManager.removeItem(at: destinationURL)
            }
            try? fileManager.moveItem(at: backupURL, to: destinationURL)
            return
        }

        guard persistedDownloadState?.replacementInProgress == true,
              candidate.previousModel?.fileName != candidate.fileName,
              fileManager.fileExists(atPath: destinationURL.path) else {
            return
        }
        try? fileManager.removeItem(at: destinationURL)
    }

    private func isManagedValidationCandidateURL(_ url: URL) -> Bool {
        let standardizedURL = url.standardizedFileURL
        let temporaryDirectory = FileManager.default.temporaryDirectory.standardizedFileURL
        let installationDirectory = installationDirectoryURL.standardizedFileURL
        let fileName = standardizedURL.lastPathComponent
        if standardizedURL.deletingLastPathComponent() == temporaryDirectory {
            return fileName.hasPrefix("viuk-local-model-") && standardizedURL.pathExtension == "download"
        }
        return standardizedURL.deletingLastPathComponent() == installationDirectory
            && fileName.hasPrefix(".")
            && fileName.contains(".candidate-")
            && ["gguf", "bin", "litertlm"].contains(standardizedURL.pathExtension.lowercased())
    }

    private func managedReplacementBackupURL(from path: String) -> URL? {
        let candidateURL = URL(fileURLWithPath: path).standardizedFileURL
        guard candidateURL.deletingLastPathComponent() == installationDirectoryURL.standardizedFileURL,
              candidateURL.lastPathComponent.hasPrefix("."),
              candidateURL.lastPathComponent.contains(".rollback-") else {
            return nil
        }
        return candidateURL
    }

    private func localizedReadableError(_ rawMessage: String?) -> String {
        let message = rawMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard KizunaCopy.language == .english else {
            return message.isEmpty ? "直近のダウンロードで失敗しました" : message
        }
        guard !message.isEmpty else { return "The last model download failed." }

        if message.contains("空き容量") {
            return "There is not enough free space to store the model."
        }
        if message.contains("Bearer") || message.contains("認証") {
            return "The download source requires authentication. Check the access token."
        }
        if message.contains("HTML") {
            return "The source returned an HTML page instead of model data. Check the URL or authentication."
        }
        if message.contains("安全なHTTPS") {
            return "Use a secure HTTPS URL without embedded credentials."
        }
        if message.contains("安全でないモデルファイル名") {
            return "The source returned an unsafe model filename."
        }
        if message.contains("再開データ") {
            return "The previous resume data is unavailable. Resume or download the model again."
        }
        if message.contains("再開") || message.contains("中断") {
            return "The connection was interrupted. You can resume or try again."
        }
        if message.contains("HTTP") {
            return "The download source returned an HTTP error. Try again later."
        }
        if message.contains("保存先") || message.contains("フォルダ") || message.contains("書き込") {
            return "The model could not be saved. Check storage permissions and free space."
        }
        if message.contains("SHA-256")
            || message.contains("GGUF")
            || message.contains("GGML")
            || message.contains("LiteRT-LM")
            || message.contains("サイズ")
            || message.contains("小さすぎ") {
            return "The downloaded file failed model integrity or format validation. The installed model was left unchanged."
        }
        if message.contains("既存モデルは置き換えません") || message.contains("既存モデルは保持") {
            return "The new model was not accepted, so the existing installed model was kept."
        }
        if message.contains("不完全") || message.contains("扱えません") {
            return "The saved file is incomplete or is not a supported model. Download it again."
        }
        if message.contains("ダウンロード状態を保存") {
            return "Download progress could not be saved; resuming may not be possible after interruption."
        }
        if message.contains("配布元") && message.contains("変更") {
            return "The download source changed. Download the new model explicitly."
        }
        if message.contains("削除") {
            return "The local model could not be deleted. Close apps using it and try again."
        }
        return "The local model operation failed. Check the model source and try again."
    }

    private func finalizeDownloadedFile(tempURL: URL, response: URLResponse?) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.finalizeDownloadedFile(tempURL: tempURL, response: response)
            }
            return
        }

        let httpResponse = response as? HTTPURLResponse
        if let httpResponse, !(200...299).contains(httpResponse.statusCode) {
            switch httpResponse.statusCode {
            case 401, 403:
                applyFailure(message: "配布元が認証を要求しました。Bearer トークンを確認してください。")
            default:
                applyFailure(message: "配布元が HTTP \(httpResponse.statusCode) を返しました。しばらく待って再試行してください。")
            }
            try? FileManager.default.removeItem(at: tempURL)
            return
        }

        if let mimeType = response?.mimeType?.lowercased(), mimeType.contains("html") {
            applyFailure(message: "モデル本体ではなくHTMLが返されました。配布元か認証設定を確認してください。")
            try? FileManager.default.removeItem(at: tempURL)
            return
        }

        let requestedFileName = [
            response?.suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines),
            persistedDownloadState?.suggestedFilename,
            response?.url?.lastPathComponent
        ]
        .compactMap { $0 }
        .first(where: { !$0.isEmpty && $0 != "/" })
        ?? LocalAssistantModelProfile.defaultFileName
        guard let fileName = safeModelFileName(requestedFileName) else {
            try? FileManager.default.removeItem(at: tempURL)
            applyFailure(message: "配布元が安全でないモデルファイル名を返しました。")
            return
        }

        let expectedBytesForValidation = persistedDownloadState?.expectedBytes ?? expectedBytes
        // The URLSession temporary file is verified while the currently
        // installed model remains in place. It is then self-checked from a
        // hidden staging path before any replacement operation can begin.
        beginDownloadedCandidateValidation(
            tempURL: tempURL,
            fileName: fileName,
            response: response,
            expectedBytes: expectedBytesForValidation
        )
    }

    private func applyFailure(message: String, resumable: Bool = false) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.applyFailure(message: message, resumable: resumable)
            }
            return
        }

        isDownloading = false
        activeDownloadBaseBytes = 0
        resetDownloadProgressMetrics()
        lastErrorMessage = message
        if resumable {
            downloadStatus = .resumable
            updateDownloadState(status: .resumable, lastError: message)
        } else {
            downloadStatus = .failed
            updateDownloadState(status: .failed, lastError: message)
        }
        applyStatusPresentation()
    }

    private func expectedBytesFromResponse(_ response: HTTPURLResponse, fallbackURL: URL) -> Int64 {
        if let linkedSize = response.value(forHTTPHeaderField: "X-Linked-Size"),
           let parsed = Int64(linkedSize),
           parsed > 0 {
            return parsed
        }

        // Range: bytes=0-0 の応答は Content-Length が「1」になる。
        // Content-Range のスラッシュ後が本体全体のサイズなので、先に読む。
        if let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
           let total = contentRange.split(separator: "/").last,
           let parsed = Int64(total),
           parsed > 1 {
            return parsed
        }

        if let headerValue = response.value(forHTTPHeaderField: "Content-Length"),
           let parsed = Int64(headerValue),
           parsed > 1 {
            return parsed
        }

        let expected = response.expectedContentLength
        if expected > 1 {
            return expected
        }

        if Self.isEffectivelyDefaultSource(fallbackURL.absoluteString) {
            return LocalAssistantModelProfile.expectedModelSizeBytes
        }
        return 0
    }

    private func requiredBytesForPreflight(expectedBytes: Int64) -> Int64 {
        let baseline = expectedBytes > 0 ? expectedBytes : LocalAssistantModelProfile.expectedModelSizeBytes
        let dynamicMargin = max(Self.minimumFreeSpaceMarginBytes, baseline / 10)
        return baseline + dynamicMargin
    }

    private func availableDiskSpaceBytes() -> Int64? {
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: installationDirectoryURL.path)
        if let number = attributes?[.systemFreeSize] as? NSNumber {
            return number.int64Value
        }
        return nil
    }

    private func suggestedFileName(from response: HTTPURLResponse, fallbackURL: URL) -> String? {
        if let disposition = response.value(forHTTPHeaderField: "Content-Disposition"),
           let parsed = parseFileName(fromContentDisposition: disposition) {
            return parsed
        }
        return response.suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? fallbackURL.lastPathComponent
    }

    /// HTTPヘッダー由来の名前を保存先の単一ファイル名へ限定する。
    /// Content-Disposition は配布元が制御できるため、パス要素や制御文字をそのまま
    /// appendingPathComponent に渡すと保存先外への書き込みにつながる。
    private func safeModelFileName(_ candidate: String) -> String? {
        let decoded = candidate.removingPercentEncoding ?? candidate
        let basename = URL(fileURLWithPath: decoded).lastPathComponent
            .replacingOccurrences(of: "\\", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !basename.isEmpty, basename != ".", basename != ".." else { return nil }
        let filtered = basename.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && scalar != "/" && scalar != "\\"
        }
        let name = String(String.UnicodeScalarView(filtered))
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        guard ["gguf", "bin", "litertlm"].contains(ext) else { return nil }
        return name
    }

    private func parseFileName(fromContentDisposition disposition: String) -> String? {
        let segments = disposition.components(separatedBy: ";")
        for rawSegment in segments {
            let segment = rawSegment.trimmingCharacters(in: .whitespacesAndNewlines)
            if segment.lowercased().hasPrefix("filename*="),
               let value = segment.split(separator: "=", maxSplits: 1).last {
                let cleaned = value.replacingOccurrences(of: "\"", with: "")
                let components = cleaned.components(separatedBy: "''")
                return components.last?.removingPercentEncoding ?? components.last
            }
            if segment.lowercased().hasPrefix("filename="),
               let value = segment.split(separator: "=", maxSplits: 1).last {
                return value
                    .replacingOccurrences(of: "\"", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func persistDownloadState(_ state: LocalAssistantDownloadState) {
        persistedDownloadState = state
        hasInvalidPersistedDownloadState = false
        do {
            try FileManager.default.createDirectory(at: installationDirectoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(state)
            try data.write(to: downloadStateURL, options: .atomic)
            downloadStatus = state.status
            downloadStatePersistenceError = nil
        } catch {
            // 状態JSONだけの失敗をidleに戻すと、再開可否と原因が消える。
            // 本体転送は継続できる場合があるため、転送状態は維持しつつ、
            // 次回起動でも確認できる明示的なエラーを残す。
            downloadStatePersistenceError = "ダウンロード状態を保存できません。中断すると再開情報を失う可能性があります。"
            lastErrorMessage = downloadStatePersistenceError
            downloadStatus = state.status
        }
    }

    private func updateDownloadState(
        status: LocalAssistantDownloadStatus,
        resolvedURL: String? = nil,
        expectedBytes: Int64? = nil,
        eTag: String? = nil,
        suggestedFilename: String? = nil,
        lastError: String? = nil,
        resumeDataPath: String?? = nil
    ) {
        var state = persistedDownloadState ?? LocalAssistantDownloadState(
            sourceURL: resolvedSourceURLString,
            resolvedURL: nil,
            expectedBytes: 0,
            eTag: nil,
            resumeDataPath: nil,
            status: status,
            startedAt: Date(),
            updatedAt: Date(),
            lastError: nil,
            suggestedFilename: nil
        )
        state.status = status
        state.updatedAt = Date()
        if state.startedAt == nil {
            state.startedAt = Date()
        }
        if let resolvedURL {
            state.resolvedURL = resolvedURL
        }
        if let expectedBytes {
            state.expectedBytes = expectedBytes
        }
        if let eTag {
            state.eTag = eTag
        }
        if let suggestedFilename {
            state.suggestedFilename = suggestedFilename
        }
        if let lastError {
            state.lastError = lastError
        }
        if let resumeDataPath {
            state.resumeDataPath = resumeDataPath
        }
        persistDownloadState(state)
    }

    private func recoverInterruptedCandidateValidation(_ state: LocalAssistantDownloadState) {
        let fileManager = FileManager.default
        let restorationMessage = "ダウンロード済みモデルの確認が完了しなかったため、既存モデルを維持しました。"
        let pendingFileName: String?
        if let referencedFileName = stateReferencedFileName(for: state) {
            pendingFileName = safeModelFileName(referencedFileName)
        } else {
            pendingFileName = nil
        }
        let destinationURL = pendingFileName.map {
            installationDirectoryURL.appendingPathComponent($0)
        }

        if state.replacementInProgress == true,
           let destinationURL {
            if let backupPath = state.replacementBackupPath,
               let backupURL = managedReplacementBackupURL(from: backupPath),
               fileManager.fileExists(atPath: backupURL.path) {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try? fileManager.removeItem(at: destinationURL)
                }
                try? fileManager.moveItem(at: backupURL, to: destinationURL)
            } else if state.previousInstalledFileName != pendingFileName,
                      fileManager.fileExists(atPath: destinationURL.path) {
                // No backup means this was a first install, or a replacement
                // for a different filename. The destination can only be the
                // candidate that was never committed.
                try? fileManager.removeItem(at: destinationURL)
            }
        }

        if let pendingPath = state.pendingValidationPath,
           let pendingURL = managedValidationCandidateURL(from: pendingPath) {
            try? fileManager.removeItem(at: pendingURL)
        }

        if let rawPreviousFileName = state.previousInstalledFileName,
           let previousFileName = safeModelFileName(rawPreviousFileName),
           let previousURL = candidateInstallationDirectories
            .map({ $0.appendingPathComponent(previousFileName) })
            .first(where: { fileManager.fileExists(atPath: $0.path) }) {
            let previousSize = (try? previousURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let recovered = LocalAssistantDownloadState(
                sourceURL: state.previousSourceURL ?? resolvedSourceURLString,
                resolvedURL: state.previousResolvedURL,
                expectedBytes: max(state.previousExpectedBytes ?? 0, previousSize),
                eTag: state.previousETag,
                resumeDataPath: nil,
                status: .completed,
                startedAt: state.startedAt,
                updatedAt: Date(),
                lastError: nil,
                suggestedFilename: previousFileName
            )
            persistDownloadState(recovered)
            AILegacyCompatibility.exportString(
                previousFileName,
                primaryKey: installedFileNameKey,
                aliases: AILegacyCompatibility.localModelInstalledFileAliases,
                defaults: defaults
            )
            installedFileName = previousFileName
            installedFileSize = previousSize
            resolvedInstalledModelURL = previousURL
            downloadedBytes = previousSize
            expectedBytes = recovered.expectedBytes
            lastErrorMessage = restorationMessage
            applyStatusPresentation()
            return
        }

        var failedState = state
        failedState.status = .failed
        failedState.updatedAt = Date()
        failedState.lastError = "ダウンロード済みモデルの確認が中断されました。最初からやり直してください。"
        failedState.pendingValidationPath = nil
        failedState.replacementBackupPath = nil
        failedState.replacementInProgress = false
        failedState.previousInstalledFileName = nil
        failedState.previousSourceURL = nil
        failedState.previousResolvedURL = nil
        failedState.previousExpectedBytes = nil
        failedState.previousETag = nil
        persistDownloadState(failedState)
        lastErrorMessage = failedState.lastError
        applyStatusPresentation()
    }

    private func managedValidationCandidateURL(from path: String) -> URL? {
        let candidateURL = URL(fileURLWithPath: path).standardizedFileURL
        return isManagedValidationCandidateURL(candidateURL) ? candidateURL : nil
    }

    private func removeCompletedReplacementBackupIfNeeded(from state: inout LocalAssistantDownloadState) {
        guard state.status == .completed,
              let path = state.replacementBackupPath,
              let backupURL = managedReplacementBackupURL(from: path) else {
            return
        }
        try? FileManager.default.removeItem(at: backupURL)
        state.replacementBackupPath = nil
    }

    private func restorePersistedDownloadState() {
        guard FileManager.default.fileExists(atPath: downloadStateURL.path) else {
            persistedDownloadState = nil
            hasInvalidPersistedDownloadState = false
            if !isDownloading {
                downloadStatus = .idle
                downloadedBytes = 0
                activeDownloadBaseBytes = 0
                resetDownloadProgressMetrics()
            }
            return
        }

        do {
            let data = try Data(contentsOf: downloadStateURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var state = try decoder.decode(LocalAssistantDownloadState.self, from: data)

            if let resumeDataPath = state.resumeDataPath, isManagedResumeDataPath(resumeDataPath) == false {
                state.resumeDataPath = nil
            }

            if let resumeURL = currentResumeDataURL(from: state),
               let resumeData = try? Data(contentsOf: resumeURL),
               resumeDataLooksUsable(resumeData) == false {
                if resumeURL.standardizedFileURL == resumeDataStorageURL.standardizedFileURL {
                    try? FileManager.default.removeItem(at: resumeURL)
                }
                state.resumeDataPath = nil
                if state.status == .resumable || state.status == .paused {
                    state.status = .failed
                    if state.lastError?.isEmpty != false {
                        state.lastError = "続きから再開する情報を復元できませんでした。最初からやり直してください。"
                    }
                }
            }

            if state.status == .validating, pendingModelCandidate == nil {
                recoverInterruptedCandidateValidation(state)
                return
            }

            removeCompletedReplacementBackupIfNeeded(from: &state)

            if [.preflighting, .downloading].contains(state.status) && !isDownloading {
                if currentResumeDataURL(from: state) != nil {
                    state.status = .resumable
                    if state.lastError?.isEmpty != false {
                        state.lastError = "前回のダウンロードが中断されました。続きから再開できます。"
                    }
                } else {
                    state.status = .failed
                    if state.lastError?.isEmpty != false {
                        state.lastError = "前回のダウンロードは中断され、再開データを復元できませんでした。"
                    }
                }
            }

            persistedDownloadState = state
            hasInvalidPersistedDownloadState = false
            if isUsingDefaultSource, hasStaleAuthorizationFailureState {
                clearPersistedDownloadState(removeResumeData: true)
                if !isDownloading {
                    downloadStatus = resolvedInstalledModelURL == nil ? .idle : .completed
                    downloadedBytes = 0
                    activeDownloadBaseBytes = 0
                    resetDownloadProgressMetrics()
                    lastErrorMessage = nil
                    applyStatusPresentation()
                }
                return
            }
            downloadStatus = state.status
            if !isDownloading {
                expectedBytes = state.expectedBytes
                if state.status == .resumable || state.status == .paused {
                    downloadedBytes = estimatedResumeBytes(for: state)
                } else if state.status == .completed, let resolvedInstalledModelURL {
                    downloadedBytes = (try? resolvedInstalledModelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                } else {
                    downloadedBytes = 0
                }
                activeDownloadBaseBytes = 0
                resetDownloadProgressMetrics()
                if state.status != .completed {
                    lastErrorMessage = state.lastError
                }
                applyStatusPresentation()
            }
        } catch {
            // 壊れたJSONだけを理由に有効なresumeデータまで捨てない。
            // 先に元の状態ファイルを退避し、続きから復元できる最小状態を
            // 再構成する。resumeデータ自体が無効な場合だけ失敗表示にする。
            if let resumeData = try? Data(contentsOf: resumeDataStorageURL),
               !resumeData.isEmpty,
               resumeDataLooksUsable(resumeData) {
                let backupURL = downloadStateURL
                    .deletingPathExtension()
                    .appendingPathExtension("corrupt-\(UUID().uuidString).json")
                do {
                    try FileManager.default.copyItem(at: downloadStateURL, to: backupURL)
                    let recovered = LocalAssistantDownloadState(
                        sourceURL: resolvedSourceURLString,
                        resolvedURL: nil,
                        expectedBytes: LocalAssistantModelProfile.expectedModelSizeBytes,
                        eTag: nil,
                        resumeDataPath: resumeDataStorageURL.path,
                        status: .resumable,
                        startedAt: nil,
                        updatedAt: Date(),
                        lastError: "ダウンロード状態を復元しました。続きから再開できます。",
                        suggestedFilename: nil
                    )
                    persistDownloadState(recovered)
                    persistedDownloadState = recovered
                    hasInvalidPersistedDownloadState = false
                    downloadStatus = .resumable
                    expectedBytes = recovered.expectedBytes
                    downloadedBytes = estimatedResumeBytes(for: recovered)
                    activeDownloadBaseBytes = 0
                    resetDownloadProgressMetrics()
                    lastErrorMessage = recovered.lastError
                    applyStatusPresentation()
                    NSLog("[KizunaModelManager] recovered resumable download state from valid resume data; backup=%@", backupURL.lastPathComponent)
                    return
                } catch {
                    NSLog("[KizunaModelManager] could not back up corrupt download state: %@", error.localizedDescription)
                }
            }

            // 壊れた/読めない状態ファイルを「未導入」として隠さない。
            // ファイルは保持し、再開不能な失敗として表示することで、
            // ユーザーが再ダウンロードを選べる状態にする。
            persistedDownloadState = nil
            hasInvalidPersistedDownloadState = true
            downloadStatePersistenceError = "ダウンロード状態を復元できませんでした。再ダウンロードしてください。"
            lastErrorMessage = downloadStatePersistenceError
            downloadStatus = .failed
            downloadedBytes = 0
            activeDownloadBaseBytes = 0
            resetDownloadProgressMetrics()
            applyStatusPresentation()
        }
    }

    private func clearPersistedDownloadState(removeResumeData shouldRemoveResumeData: Bool) {
        persistedDownloadState = nil
        hasInvalidPersistedDownloadState = false
        try? FileManager.default.removeItem(at: downloadStateURL)
        if shouldRemoveResumeData {
            removeResumeData()
        }
        if !isDownloading {
            downloadStatus = resolvedInstalledModelURL == nil ? .idle : .completed
            activeDownloadBaseBytes = 0
            resetDownloadProgressMetrics()
        }
    }

    private func persistResumeData(_ data: Data?) {
        guard let data, !data.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: installationDirectoryURL, withIntermediateDirectories: true)
            try data.write(to: resumeDataStorageURL, options: .atomic)
            updateDownloadState(status: .resumable, resumeDataPath: resumeDataStorageURL.path)
        } catch {
            updateDownloadState(status: .failed, lastError: "続きから再開する情報を保存できませんでした。", resumeDataPath: nil)
        }
    }

    private func removeResumeData() {
        try? FileManager.default.removeItem(at: resumeDataStorageURL)
        if persistedDownloadState != nil {
            updateDownloadState(status: persistedDownloadState?.status ?? .idle, resumeDataPath: nil)
        }
    }

    private func loadResumeData() -> Data? {
        guard let url = currentResumeDataURL(from: persistedDownloadState) else { return nil }
        return try? Data(contentsOf: url)
    }

    private func estimatedResumeBytes(for state: LocalAssistantDownloadState?) -> Int64 {
        guard let url = currentResumeDataURL(from: state),
              let resumeData = try? Data(contentsOf: url) else {
            return 0
        }
        return estimatedResumeBytes(from: resumeData)
    }

    private func estimatedResumeBytes(from resumeData: Data) -> Int64 {
        guard
            let plist = try? PropertyListSerialization.propertyList(from: resumeData, options: [], format: nil),
            let dictionary = plist as? [String: Any]
        else {
            return 0
        }

        let numericKeys = [
            "NSURLSessionResumeBytesReceived",
            "__nsurlsession_resume_bytes_received"
        ]
        for key in numericKeys {
            if let number = dictionary[key] as? NSNumber, number.int64Value > 0 {
                return number.int64Value
            }
        }

        let pathKeys = [
            "NSURLSessionResumeInfoLocalPath",
            "__nsurlsession_resume_info_local_path"
        ]
        for key in pathKeys {
            guard let path = dictionary[key] as? String, !path.isEmpty else { continue }
            let fileURL = URL(fileURLWithPath: path)
            if let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init),
               fileSize > 0 {
                return fileSize
            }
        }

        return 0
    }

    private func currentResumeDataURL(from state: LocalAssistantDownloadState?) -> URL? {
        if let path = state?.resumeDataPath,
           isManagedResumeDataPath(path),
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.fileExists(atPath: resumeDataStorageURL.path) ? resumeDataStorageURL : nil
    }

    private func isManagedResumeDataPath(_ path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return standardized == resumeDataStorageURL.standardizedFileURL.path
    }

    private func resumeDataLooksUsable(_ data: Data) -> Bool {
        guard
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let dictionary = plist as? [String: Any]
        else {
            return true
        }

        let pathKeys = [
            "NSURLSessionResumeInfoLocalPath",
            "__nsurlsession_resume_info_local_path"
        ]

        for key in pathKeys {
            guard let path = dictionary[key] as? String, !path.isEmpty else { continue }
            if FileManager.default.fileExists(atPath: path) == false {
                return false
            }
        }

        return true
    }

    private var hasStaleAuthorizationFailureState: Bool {
        guard let state = persistedDownloadState else { return false }
        return isAuthorizationFailureMessage(state.lastError)
    }

    private func isAuthorizationFailureMessage(_ rawMessage: String?) -> Bool {
        let message = rawMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !message.isEmpty else { return false }
        return message.contains("Bearer") || message.contains("認証")
    }

    private func shouldAttachAuthorization(to url: URL) -> Bool {
        guard !accessToken.isEmpty else { return false }
        let host = url.host?.lowercased() ?? ""
        if host.contains("huggingface.co") {
            return true
        }
        return Self.isEffectivelyDefaultSource(url.absoluteString) == false
    }

    private func removeIncompleteDownloadedFileIfNeeded() {
        guard let state = persistedDownloadState, let fileName = stateReferencedFileName(for: state) else { return }
        let candidate = installationDirectoryURL.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return }
        // 保存予定サイズが分かる場合は、それを使って途中ファイルだけを掃除する。
        // 完成済みモデルを起動確認前に消さない。
        let expectedBytes = state.expectedBytes > 1 ? state.expectedBytes : nil
        guard !isValidModelFile(at: candidate, expectedBytes: expectedBytes) else { return }
        try? FileManager.default.removeItem(at: candidate)
    }

    private func preserveDownloadFileForFinalization(from location: URL) throws -> URL {
        let preservedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("viuk-local-model-\(UUID().uuidString)")
            .appendingPathExtension("download")
        if FileManager.default.fileExists(atPath: preservedURL.path) {
            try? FileManager.default.removeItem(at: preservedURL)
        }
        try FileManager.default.copyItem(at: location, to: preservedURL)
        return preservedURL
    }

    private func resetDownloadProgressMetrics() {
        progressSamples.removeAll()
        transferRateBytesPerSecond = nil
        estimatedRemainingSeconds = nil
    }

    private func updateDownloadProgressMetrics(downloadedBytes: Int64, expectedBytes: Int64) {
        let now = Date().timeIntervalSinceReferenceDate
        progressSamples.append((time: now, bytes: downloadedBytes))
        progressSamples.removeAll { now - $0.time > 12 }
        if progressSamples.count > 8 {
            progressSamples.removeFirst(progressSamples.count - 8)
        }

        guard
            let first = progressSamples.first,
            let last = progressSamples.last,
            last.time > first.time,
            last.bytes >= first.bytes
        else {
            transferRateBytesPerSecond = nil
            estimatedRemainingSeconds = nil
            return
        }

        let deltaBytes = Double(last.bytes - first.bytes)
        let deltaTime = last.time - first.time
        guard deltaBytes > 0, deltaTime > 0 else {
            transferRateBytesPerSecond = nil
            estimatedRemainingSeconds = nil
            return
        }

        let rate = deltaBytes / deltaTime
        transferRateBytesPerSecond = rate
        let remainingBytes = max(Double(expectedBytes - downloadedBytes), 0)
        estimatedRemainingSeconds = remainingBytes > 0 ? (remainingBytes / rate) : nil
    }

    private func cancelActiveTasksWithoutResume() {
        activeTransferID = UUID()
        preflightTask?.cancel()
        preflightTask = nil
        preflightSession?.invalidateAndCancel()
        preflightSession = nil
        preflightDelegate = nil
        downloadTask?.cancel()
        resetActiveSession()
        isDownloading = false
        activeDownloadBaseBytes = 0
    }

    private func resetActiveSession() {
        downloadTask = nil
        preflightTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    private func registerLifecycleObservers() {
        #if canImport(AppKit)
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.prepareResumeDataForTermination()
            }
        )
        #elseif canImport(UIKit)
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.prepareResumeDataForTermination()
            }
        )
        #endif
    }

    private func prepareResumeDataForTermination() {
        guard isDownloading, preflightTask == nil else { return }
        guard let downloadTask else { return }
        isCancellingForResume = true
        downloadTask.cancel(byProducingResumeData: { [weak self] resumeData in
            DispatchQueue.main.async {
                guard let self else { return }
                self.persistResumeData(resumeData)
                self.isCancellingForResume = false
            }
        })
    }
}

extension LocalAssistantModelManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        DispatchQueue.main.async {
            guard self.isDownloading,
                  session === self.urlSession,
                  downloadTask === self.downloadTask else { return }
            let combinedBytes = self.activeDownloadBaseBytes + totalBytesWritten
            self.downloadedBytes = combinedBytes
            let combinedExpectedBytes = totalBytesExpectedToWrite > 0
                ? self.activeDownloadBaseBytes + totalBytesExpectedToWrite
                : self.expectedBytes
            self.expectedBytes = max(combinedExpectedBytes, self.expectedBytes, combinedBytes, 0)
            self.updateDownloadProgressMetrics(
                downloadedBytes: combinedBytes,
                expectedBytes: self.expectedBytes
            )
            if totalBytesExpectedToWrite > 0 {
                let percent = Int((Double(combinedBytes) / Double(max(self.expectedBytes, 1))) * 100)
                self.setStatus(.downloading(resuming: false, percent: percent), japaneseMessage: "モデルをダウンロード中 \(percent)%")
            } else {
                self.setStatus(.downloading(resuming: false, percent: nil), japaneseMessage: "モデルをダウンロード中")
            }
            self.updateDownloadState(
                status: .downloading,
                expectedBytes: self.expectedBytes,
                lastError: nil
            )
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard isDownloading,
              session === self.urlSession,
              downloadTask === self.downloadTask else { return }
        let preservedLocation: URL
        do {
            preservedLocation = try preserveDownloadFileForFinalization(from: location)
        } catch {
            DispatchQueue.main.async {
                // didFinishDownloadingTo is delivered off the main queue. A
                // new transfer may be started before this block runs; do not
                // let the old transfer turn the new one into a failure.
                guard session === self.urlSession, downloadTask === self.downloadTask else { return }
                self.applyFailure(message: "ダウンロードしたモデルの一時ファイルを保持できませんでした。保存先を確認して再試行してください。")
            }
            return
        }

        DispatchQueue.main.async {
            // The temporary file belongs to this exact URLSession task. The
            // callback can be queued while the user cancels and starts a new
            // model (or a new resume) before the main queue processes it.
            // Compare object identity again at execution time, and clean up
            // the stale copy instead of finalizing it into the new download.
            guard session === self.urlSession, downloadTask === self.downloadTask else {
                try? FileManager.default.removeItem(at: preservedLocation)
                return
            }
            self.finalizeDownloadedFile(tempURL: preservedLocation, response: downloadTask.response)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.async {
            guard session === self.urlSession, task === self.downloadTask else { return }
            self.isDownloading = false
            self.resetActiveSession()
            self.activeDownloadBaseBytes = 0
            self.resetDownloadProgressMetrics()

            guard let error else {
                self.refreshEnvironment()
                return
            }

            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled {
                if self.isCancellingForResume {
                    if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                        self.persistResumeData(resumeData)
                    }
                    self.isCancellingForResume = false
                }
                return
            }

            if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, !resumeData.isEmpty {
                self.persistResumeData(resumeData)
                self.applyFailure(message: "通信が中断されました。続きから再開できます。", resumable: true)
                return
            }

            switch nsError.code {
            case NSURLErrorCannotCreateFile, NSURLErrorCannotOpenFile, NSURLErrorCannotWriteToFile:
                if self.currentResumeDataURL(from: self.persistedDownloadState) != nil {
                    self.removeResumeData()
                    // 再開データの破損を理由に自動再ダウンロードしない。
                    // ユーザーが明示的に「再開」または「再ダウンロード」を選ぶ。
                    self.applyFailure(message: "前回の再開データを使えませんでした。再開または再ダウンロードを選択してください。", resumable: false)
                    return
                }
                self.applyFailure(message: "保存先ファイルを作成できませんでした。")
            case NSURLErrorUserAuthenticationRequired, NSURLErrorUserCancelledAuthentication:
                self.applyFailure(message: "配布元の認証に失敗しました。Bearer トークンを確認してください。")
            case NSURLErrorNoPermissionsToReadFile:
                self.applyFailure(message: "保存先に書き込めません。")
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut:
                self.applyFailure(message: "通信が中断されました。再試行してください。")
            default:
                self.applyFailure(message: "ダウンロードに失敗しました。しばらく待って再試行してください。")
            }
        }
    }
}
