/*
仕様:
- 役割: ローカルAIモデルの保存先、ダウンロード、認証トークン、導入状態を管理する。
- 主な型: `LocalAssistantModelManager`.
- 編集ポイント: ダウンロード元URL、保存先、認証ヘッダ、進捗表示を変えるときに触る。
*/
import Combine
import Foundation
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
}

private struct LocalAssistantDownloadPreflight {
    let sourceURL: URL
    let resolvedURL: URL
    let expectedBytes: Int64
    let eTag: String?
    let suggestedFilename: String?
    let acceptsResume: Bool
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
    @Published private(set) var runtimeAvailabilitySnapshot: LocalAssistantRuntimeAvailability = .modelMissing
    @Published private(set) var modelLoadProgress: LocalAssistantLoadProgress?

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

    private var urlSession: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var preflightTask: URLSessionDataTask?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var isCancellingForResume = false
    private var progressSamples: [(time: TimeInterval, bytes: Int64)] = []
    private var activeDownloadBaseBytes: Int64 = 0
    private var isEnvironmentRefreshScheduled = false

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

    var progressValue: Double? {
        guard expectedBytes > 0 else { return nil }
        return min(max(Double(downloadedBytes) / Double(expectedBytes), 0), 1)
    }

    var transferRateSummary: String? {
        guard let transferRateBytesPerSecond, transferRateBytesPerSecond > 0 else { return nil }
        return "\(ByteCountFormatter.string(fromByteCount: Int64(transferRateBytesPerSecond), countStyle: .file))/秒"
    }

    var estimatedRemainingSummary: String? {
        guard let estimatedRemainingSeconds, estimatedRemainingSeconds.isFinite, estimatedRemainingSeconds > 0 else {
            return nil
        }

        let totalSeconds = Int(estimatedRemainingSeconds.rounded(.up))
        if totalSeconds < 60 {
            return "残り約\(max(totalSeconds, 1))秒"
        }

        let totalMinutes = Int((Double(totalSeconds) / 60).rounded(.up))
        if totalMinutes < 60 {
            return "残り約\(max(totalMinutes, 1))分"
        }

        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if minutes == 0 {
            return "残り約\(hours)時間"
        }
        return "残り約\(hours)時間\(minutes)分"
    }

    var resolvedSourceURLString: String {
        Self.normalizedSourceURL(sourceURLString)
    }

    var isUsingDefaultSource: Bool {
        resolvedSourceURLString == LocalAssistantModelProfile.defaultDownloadURL
    }

    var sourceDisplayLabel: String {
        isUsingDefaultSource ? LocalAssistantModelProfile.defaultDownloadLabel : "カスタムURL"
    }

    var sourceHostLabel: String {
        URL(string: resolvedSourceURLString)?.host ?? "標準ソース"
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

    var downloadStateSummary: String {
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

    var statusTitle: String {
        switch displayState {
        case .downloading:
            return "ダウンロード中"
        case .resumable:
            return "再開可能"
        case .checking:
            return "起動確認中"
        case .executable:
            return "実行可能"
        case .savedOnly:
            return "保存のみ"
        case .recentFailure:
            return "直近失敗"
        case .modelMissing:
            return "未導入"
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
            return "起動確認中"
        case .executable:
            return "この端末で会話可能"
        case .recentFailure:
            return "起動失敗"
        case .savedOnly:
            return "保存済み・未起動"
        case .modelMissing:
            return "未導入"
        }
    }

    var runtimeStatusSummary: String {
        switch runtimeAvailability {
        case .checking:
            return "\(LocalAssistantModelProfile.modelName) を端末内で起動確認しています。"
        case .executable:
            return "\(LocalAssistantModelProfile.modelName) をこの端末で実行できます。"
        case .recentFailure:
            return runtimeDiagnosticSummary ?? "ローカル実行の起動確認に失敗しました。APIへ自動で切り替えず、原因を確認してください。"
        case .savedOnly:
            return "モデルファイルは保存済みです。まだ端末内で起動確認は完了していません。"
        case .modelMissing:
            if hasLegacyInstalledModel {
                return "旧ローカルモデルは残っていますが、既定の \(LocalAssistantModelProfile.internalModelName) は未導入です。"
            }
            return "\(LocalAssistantModelProfile.modelName) は未導入です。"
        }
    }

    var downloadHelpText: String {
        "標準ダウンロードリンクはアプリに内蔵しています。別ソースを使いたい時だけ、URLや Bearer トークンを詳細設定で上書きします。"
    }

    var runtimeDiagnosticSummary: String? {
        LocalAssistantRuntimeBridge.shared.lastRuntimeDiagnostic?.summary
    }

    var runtimeDiagnosticMessage: String? {
        LocalAssistantRuntimeBridge.shared.lastRuntimeDiagnostic?.detailedMessage
            ?? LocalAssistantRuntimeBridge.shared.lastRuntimeError
    }

    var runtimeWarningMessage: String? {
        switch runtimeAvailability {
        case .checking:
            return "ローカルモデルを端末内で起動確認中です。完了するまで実行可能とは表示しません。"
        case .recentFailure:
            return runtimeDiagnosticSummary ?? "ローカル実行に失敗しました。NAGI/APIへは自動で切り替えません。"
        case .savedOnly:
            return "モデルは保存済みですが、まだ端末内で使えるとは確認できていません。"
        case .executable, .modelMissing:
            return nil
        }
    }

    var supplementalLastErrorMessage: String? {
        let message = lastErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !message.isEmpty else { return nil }
        if message == runtimeWarningMessage {
            return nil
        }
        if message == downloadStateSummary || classifyReadableError(message) == downloadStateSummary {
            return nil
        }
        return message
    }

    func updateSourceURL(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
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

    func updateAccessToken(_ value: String) {
        accessToken = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if accessToken.isEmpty {
            secretStore.removeValue(for: .localModelAccessToken)
        } else {
            secretStore.setString(accessToken, for: .localModelAccessToken)
        }
    }

    func refreshEnvironment() {
        scheduleEnvironmentRefresh()
    }

    func recheckRuntimeAvailability() {
        LocalAssistantRuntimeBridge.shared.clearRuntimeError()
        refreshEnvironment()

        guard let currentModelURL = installedModelURL else {
            scheduleStatusPresentationRefresh()
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.runtimeAvailabilitySnapshot = .checking
            self.statusMessage = "Gemma の実行を確認しています"
        }

        Task { [weak self] in
            guard let self else { return }
            _ = await LocalAssistantRuntimeBridge.shared.performSelfCheck(installedModelURL: currentModelURL)
            await MainActor.run {
                self.refreshEnvironment()
            }
        }
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
        DispatchQueue.main.async { [weak self] in
            self?.runtimeAvailabilitySnapshot = nextAvailability
        }
    }

    func startDownload() {
        guard !isDownloading else { return }
        beginDownload(resuming: false)
    }

    func resumeDownloadIfPossible() {
        guard !isDownloading, canResumeDownload else { return }
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
            isDownloading = false
            downloadStatus = .idle
            statusMessage = "ダウンロード準備を停止しました"
            return
        }

        guard let downloadTask else { return }
        isCancellingForResume = true
        downloadTask.cancel(byProducingResumeData: { [weak self] resumeData in
            DispatchQueue.main.async {
                guard let self else { return }
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
                    self.statusMessage = "前回の続きから再開できます"
                } else {
                    self.downloadStatus = .idle
                    self.statusMessage = "ダウンロードをキャンセルしました"
                    self.clearPersistedDownloadState(removeResumeData: true)
                }
                self.isCancellingForResume = false
            }
        })
    }

    func removeInstalledModel() {
        cancelActiveTasksWithoutResume()
        LocalAssistantRuntimeBridge.shared.clearRuntimeError()
        removeIncompleteDownloadedFileIfNeeded()

        if let installedModelURL {
            try? FileManager.default.removeItem(at: installedModelURL)
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
        statusMessage = "ローカルモデルを削除しました"
    }

    func removeLegacyInstalledModel() {
        let fileManager = FileManager.default
        let legacyModelURLs = discoverLegacyModelFilesForRemoval()
        guard !legacyModelURLs.isEmpty else {
            refreshInstalledState()
            statusMessage = "旧 Gemma 3n モデルは見つかりませんでした"
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
            statusMessage = "旧 Gemma 3n モデルを削除しました"
        } catch {
            refreshInstalledState()
            lastErrorMessage = "旧 Gemma 3n モデルの削除に失敗しました。"
            applyStatusPresentation()
        }
    }

    private var displayState: LocalAssistantDisplayState {
        if isDownloading || downloadStatus == .preflighting || downloadStatus == .downloading {
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
        LocalAssistantRuntimeBridge.shared.clearRuntimeError()
        if isUsingDefaultSource, hasStaleAuthorizationFailureState {
            clearPersistedDownloadState(removeResumeData: true)
            removeIncompleteDownloadedFileIfNeeded()
        }
        let sourceString = resuming ? (persistedDownloadState?.sourceURL ?? resolvedSourceURLString) : resolvedSourceURLString
        guard let url = URL(string: sourceString),
              let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme) else {
            applyFailure(message: "標準ダウンロードリンクを解決できません。必要なら詳細設定からURLを上書きしてください。")
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
        performPreflight(for: url, resuming: resuming)
    }

    private func performPreflight(for url: URL, resuming: Bool) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration)

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        if shouldAttachAuthorization(to: url) {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        preflightTask = session.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.preflightTask = nil
                if let error = error as NSError? {
                    if error.code == NSURLErrorCancelled {
                        return
                    }
                    self.applyFailure(message: "配布元の確認に失敗しました。ネットワーク接続を確認して再試行してください。")
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    self.applyFailure(message: "配布元の応答を確認できませんでした。")
                    return
                }

                let statusCode = httpResponse.statusCode
                if statusCode == 401 || statusCode == 403 {
                    self.applyFailure(message: "配布元が認証を要求しました。Bearer トークンを確認してください。")
                    return
                }

                guard (200...299).contains(statusCode) else {
                    self.applyFailure(message: "配布元が HTTP \(statusCode) を返しました。しばらく待って再試行してください。")
                    return
                }

                let contentType = (httpResponse.value(forHTTPHeaderField: "Content-Type") ?? response?.mimeType ?? "").lowercased()
                if contentType.contains("html") {
                    self.applyFailure(message: "モデル本体ではなくHTMLが返されました。配布元か認証設定を確認してください。")
                    return
                }

                let expectedBytes = self.expectedBytesFromResponse(httpResponse, fallbackURL: url)
                do {
                    try FileManager.default.createDirectory(at: self.installationDirectoryURL, withIntermediateDirectories: true)
                } catch {
                    self.applyFailure(message: "保存先フォルダを作成できません。")
                    return
                }

                let requiredBytes = self.requiredBytesForPreflight(expectedBytes: expectedBytes)
                if let freeBytes = self.availableDiskSpaceBytes(),
                   freeBytes > 0,
                   freeBytes < requiredBytes {
                    self.applyFailure(message: "空き容量が不足しています。モデル保存には追加の空きが必要です。")
                    return
                }

                let acceptsResume = (httpResponse.value(forHTTPHeaderField: "Accept-Ranges") ?? "")
                    .lowercased()
                    .contains("bytes")
                if resuming && !acceptsResume {
                    self.applyFailure(message: "配布元が続きからの再開に対応していません。最初からやり直してください。")
                    return
                }

                let preflight = LocalAssistantDownloadPreflight(
                    sourceURL: url,
                    resolvedURL: httpResponse.url ?? url,
                    expectedBytes: expectedBytes,
                    eTag: httpResponse.value(forHTTPHeaderField: "ETag"),
                    suggestedFilename: self.suggestedFileName(from: httpResponse, fallbackURL: httpResponse.url ?? url),
                    acceptsResume: acceptsResume
                )
                self.startDownloadTask(with: preflight, resuming: resuming)
            }
        }
        preflightTask?.resume()
    }

    private func startDownloadTask(with preflight: LocalAssistantDownloadPreflight, resuming: Bool) {
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
        statusMessage = resuming ? "モデルの続きをダウンロードしています" : "モデルをダウンロードしています"
        task.resume()
    }

    private func refreshInstalledState() {
        resolvedInstalledModelURL = discoverInstalledModelURL()
        legacyResolvedInstalledModelURL = resolvedInstalledModelURL == nil ? discoverLegacyInstalledModelURL() : nil
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
        guard !isBlockedByIncompleteDownloadState(url) else { return false }
        return isValidModelFile(at: url, expectedBytes: expectedBytesForCompletedModel(at: url))
    }

    private func isBlockedByIncompleteDownloadState(_ url: URL) -> Bool {
        guard let state = persistedDownloadState else { return false }
        guard state.status != .completed else { return false }
        guard let stateFileName = stateReferencedFileName(for: state) else { return false }
        return stateFileName == url.lastPathComponent
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
        let lowercasedPath = url.lastPathComponent.lowercased()
#if os(iOS)
        // iOS runs .litertlm through LiteRT-LM and GGUF/bin through the embedded
        // llama.cpp runtime. Both are valid local model formats.
        guard lowercasedPath.hasSuffix(".litertlm")
            || lowercasedPath.hasSuffix(".gguf")
            || lowercasedPath.hasSuffix(".bin") else { return false }
#else
        guard lowercasedPath.hasSuffix(".gguf") || lowercasedPath.hasSuffix(".bin") || lowercasedPath.hasSuffix(".litertlm") else { return false }
#endif
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard fileSize >= LocalAssistantModelProfile.minimumAcceptedModelSizeBytes else { return false }
        guard let expectedBytes, expectedBytes > 0 else { return true }

        let tolerance = max(Int64(128 * 1024 * 1024), expectedBytes / 20)
        return abs(fileSize - expectedBytes) <= tolerance
    }

    private func applyStatusPresentation() {
        let nextStatusMessage: String = switch displayState {
        case .downloading:
            if downloadStatus == .preflighting {
                "配布元と保存先を確認しています"
            } else if let progressValue {
                "モデルを受信しています (\(Int(progressValue * 100))%)"
            } else {
                "モデルを受信しています"
            }
        case .resumable:
            "前回の続きから再開できます"
        case .checking:
            "ローカルモデルを起動確認しています"
        case .executable:
            "ローカルモデルを実行できます"
        case .savedOnly:
            "モデルファイルは保存済みです"
        case .recentFailure:
            runtimeDiagnosticSummary ?? "ローカル実行の確認に失敗しました"
        case .modelMissing:
            hasLegacyInstalledModel ? "旧ローカルモデルを検出しました。Gemma 4 は未導入です" : "ローカルモデルは未導入です"
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statusMessage = nextStatusMessage
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
        return message
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

        let fileName = [
            response?.suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines),
            persistedDownloadState?.suggestedFilename,
            response?.url?.lastPathComponent
        ]
        .compactMap { $0 }
        .first(where: { !$0.isEmpty && $0 != "/" })
        ?? LocalAssistantModelProfile.defaultFileName

        let destinationURL = installationDirectoryURL.appendingPathComponent(fileName)
        let expectedBytesForValidation = persistedDownloadState?.expectedBytes ?? expectedBytes

        do {
            try FileManager.default.createDirectory(at: installationDirectoryURL, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)

            guard isValidModelFile(at: destinationURL, expectedBytes: expectedBytesForValidation > 0 ? expectedBytesForValidation : nil) else {
                try? FileManager.default.removeItem(at: destinationURL)
                applyFailure(message: "保存したファイルが不完全か、モデル本体として扱えませんでした。最初からやり直してください。")
                return
            }

            let savedSize = (try? destinationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            AILegacyCompatibility.exportString(
                fileName,
                primaryKey: installedFileNameKey,
                aliases: AILegacyCompatibility.localModelInstalledFileAliases,
                defaults: defaults
            )
            installedFileName = fileName
            installedFileSize = savedSize
            resolvedInstalledModelURL = destinationURL
            lastErrorMessage = nil
            downloadedBytes = savedSize
            expectedBytes = max(expectedBytesForValidation, savedSize)
            activeDownloadBaseBytes = 0
            resetDownloadProgressMetrics()
            downloadStatus = .completed
            persistDownloadState(
                LocalAssistantDownloadState(
                    sourceURL: persistedDownloadState?.sourceURL ?? resolvedSourceURLString,
                    resolvedURL: persistedDownloadState?.resolvedURL ?? response?.url?.absoluteString,
                    expectedBytes: max(expectedBytesForValidation, savedSize),
                    eTag: persistedDownloadState?.eTag,
                    resumeDataPath: nil,
                    status: .completed,
                    startedAt: persistedDownloadState?.startedAt ?? Date(),
                    updatedAt: Date(),
                    lastError: nil,
                    suggestedFilename: fileName
                )
            )
            removeResumeData()
            statusMessage = "ローカルモデルを保存しました"
            refreshEnvironment()
        } catch {
            applyFailure(message: "モデル保存に失敗しました。保存先を確認して再試行してください。")
        }
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

        if let headerValue = response.value(forHTTPHeaderField: "Content-Length"),
           let parsed = Int64(headerValue),
           parsed > 0 {
            return parsed
        }

        let expected = response.expectedContentLength
        if expected > 0 {
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
        do {
            try FileManager.default.createDirectory(at: installationDirectoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(state)
            try data.write(to: downloadStateURL, options: .atomic)
            downloadStatus = state.status
        } catch {
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

    private func restorePersistedDownloadState() {
        guard FileManager.default.fileExists(atPath: downloadStateURL.path) else {
            persistedDownloadState = nil
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
            persistedDownloadState = nil
            downloadStatus = .idle
            downloadedBytes = 0
            activeDownloadBaseBytes = 0
            resetDownloadProgressMetrics()
        }
    }

    private func clearPersistedDownloadState(removeResumeData shouldRemoveResumeData: Bool) {
        persistedDownloadState = nil
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
        if state.status != .completed || !isValidModelFile(at: candidate, expectedBytes: state.expectedBytes > 0 ? state.expectedBytes : nil) {
            try? FileManager.default.removeItem(at: candidate)
        }
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
        preflightTask?.cancel()
        preflightTask = nil
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
                self.statusMessage = "モデルをダウンロード中 \(percent)%"
            } else {
                self.statusMessage = "モデルをダウンロード中"
            }
            self.updateDownloadState(
                status: .downloading,
                expectedBytes: self.expectedBytes,
                lastError: nil
            )
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let preservedLocation: URL
        do {
            preservedLocation = try preserveDownloadFileForFinalization(from: location)
        } catch {
            DispatchQueue.main.async {
                self.applyFailure(message: "ダウンロードしたモデルの一時ファイルを保持できませんでした。保存先を確認して再試行してください。")
            }
            return
        }

        DispatchQueue.main.async {
            self.finalizeDownloadedFile(tempURL: preservedLocation, response: downloadTask.response)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.async {
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
                    self.lastErrorMessage = "前回の再開データが壊れていたため、最初からダウンロードし直します。"
                    self.beginDownload(resuming: false)
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
