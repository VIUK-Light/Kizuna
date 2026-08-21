import SwiftUI

/// Local Persona history controls. Story data is intentionally not included:
/// deleting or exporting Persona conversations must never affect Story.
@MainActor
struct KizunaPersonaDataManagementView: View {
    @ObservedObject private var store = PersonaChatStore.shared
    @ObservedObject private var service = PersonaChatService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var exportedShareItem: KizunaPersonaExportShareItem?
    @State private var pendingExportCleanupURLs: [URL] = []
    @State private var exportCleanupWarningMessage: String?
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var isShowingDeleteAllConfirmation = false
    @State private var isShowingRecoveryResetConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                summarySection
                exportSection
                deletionSection
                if store.isPersistenceRecoveryRequired {
                    recoverySection
                }
            }
            .navigationTitle(KizunaCopy.text(japanese: "データ管理", english: "Data management"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(KizunaCopy.text(japanese: "閉じる", english: "Done")) {
                        dismiss()
                    }
                }
            }
        }
        .alert(
            KizunaCopy.text(japanese: "書き出せませんでした", english: "Could not export"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        errorMessage = nil
                    }
                }
            )
        ) {
            Button(KizunaCopy.text(japanese: "閉じる", english: "Close"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            KizunaCopy.text(japanese: "Persona会話をすべて削除しますか？", english: "Delete all Persona conversations?"),
            isPresented: $isShowingDeleteAllConfirmation,
            titleVisibility: .visible
        ) {
            Button(KizunaCopy.text(japanese: "すべて削除", english: "Delete all"), role: .destructive) {
                deleteAllThreads()
            }
            Button(KizunaCopy.text(japanese: "キャンセル", english: "Cancel"), role: .cancel) {}
        } message: {
            Text(KizunaCopy.text(
                japanese: "この端末のPersona会話だけを削除します。Storyは削除されません。",
                english: "Only Persona conversations on this device will be deleted. Story is not affected."
            ))
        }
        .confirmationDialog(
            KizunaCopy.text(japanese: "破損したPersona履歴をリセットしますか？", english: "Reset the corrupted Persona history?"),
            isPresented: $isShowingRecoveryResetConfirmation,
            titleVisibility: .visible
        ) {
            Button(KizunaCopy.text(japanese: "バックアップしてリセット", english: "Back up and reset"), role: .destructive) {
                resetCorruptHistory()
            }
            Button(KizunaCopy.text(japanese: "キャンセル", english: "Cancel"), role: .cancel) {}
        } message: {
            Text(KizunaCopy.text(
                japanese: "元の保存値はバックアップキーに残ります。読み込めない履歴は復元されません。",
                english: "The original value will remain in a backup key. Unreadable history will not be restored."
            ))
        }
        .accessibilityElement(children: .contain)
        .onAppear {
            retryPendingExportCleanup()
        }
        .onDisappear {
            retryPendingExportCleanup()
        }
    }

    private var summarySection: some View {
        Section {
            LabeledContent(
                KizunaCopy.text(japanese: "Persona会話", english: "Persona conversations"),
                value: KizunaCopy.text(
                    japanese: "\(store.threads.count)件",
                    english: "\(store.threads.count)"
                )
            )
            LabeledContent(
                KizunaCopy.text(japanese: "履歴の保存サイズ", english: "History storage"),
                value: ByteCountFormatter.string(
                    fromByteCount: store.persistedHistoryByteCount,
                    countStyle: .file
                )
            )
            if store.isPersistenceRecoveryRequired {
                Label {
                    Text(KizunaCopy.text(
                        japanese: "保存データの復旧が必要です",
                        english: "Saved data needs recovery"
                    ))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } else if let statusMessage {
                Label(statusMessage, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
            if let exportCleanupWarningMessage {
                Label(exportCleanupWarningMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text(KizunaCopy.text(japanese: "状態", english: "Status"))
                .accessibilityIdentifier("myPage.dataManagement.heading")
        }
    }

    private var exportSection: some View {
        Section {
            Button {
                exportRawData()
            } label: {
                Label(
                    KizunaCopy.text(japanese: "保存データを書き出す", english: "Export stored data"),
                    systemImage: "externaldrive"
                )
            }
            .disabled(!store.hasPersistedValue)
            .accessibilityIdentifier("myPage.dataManagement.exportRaw")

            Button {
                exportJSON()
            } label: {
                Label(
                    KizunaCopy.text(japanese: "JSONで書き出す", english: "Export as JSON"),
                    systemImage: "curlybraces"
                )
            }
            .disabled(!canExportDecodedHistory)
            .accessibilityIdentifier("myPage.dataManagement.exportJSON")

            Button {
                exportText()
            } label: {
                Label(
                    KizunaCopy.text(japanese: "テキストで書き出す", english: "Export as text"),
                    systemImage: "doc.text"
                )
            }
            .disabled(!canExportDecodedHistory)
            .accessibilityIdentifier("myPage.dataManagement.exportText")

            if let exportedShareItem {
                ShareLink(
                    item: exportedShareItem,
                    preview: SharePreview(exportedShareItem.fileName)
                ) {
                    Label(
                        KizunaCopy.text(japanese: "共有／保存", english: "Share / Save"),
                        systemImage: "square.and.arrow.up"
                    )
                }
                .accessibilityIdentifier("myPage.dataManagement.share")
            }
        } header: {
            Text(KizunaCopy.text(japanese: "書き出し", english: "Export"))
        } footer: {
            Text(KizunaCopy.text(
                japanese: "JSONは再利用しやすい形式、テキストは読み返しやすい形式です。書き出しても端末内の履歴は変更されません。",
                english: "JSON is structured for reuse. Text is easier to read. Exporting does not modify the history on this device."
            ))
        }
    }

    private var canExportDecodedHistory: Bool {
        !store.isPersistenceRecoveryRequired
            && (store.hasPersistedValue || !store.threads.isEmpty)
    }

    private var deletionSection: some View {
        Section {
            Button(
                KizunaCopy.text(japanese: "Persona会話をすべて削除", english: "Delete all Persona conversations"),
                role: .destructive
            ) {
                isShowingDeleteAllConfirmation = true
            }
            .disabled(
                store.isPersistenceRecoveryRequired
                    || (!store.hasPersistedValue && store.threads.isEmpty)
            )
            .accessibilityIdentifier("myPage.dataManagement.deleteAll")
        } footer: {
            Text(KizunaCopy.text(
                japanese: "削除した会話はこの画面から元に戻せません。必要なら先に書き出してください。",
                english: "Deleted conversations cannot be restored from this screen. Export them first if needed."
            ))
        }
    }

    private var recoverySection: some View {
        Section {
            Text(KizunaCopy.text(
                japanese: "履歴を安全のため読み取り専用にしています。まず保存データを書き出し、内容を確認してからリセットしてください。",
                english: "History is read-only for safety. Export and inspect the stored data before resetting it."
            ))
            .foregroundStyle(.secondary)

            Button(
                KizunaCopy.text(japanese: "破損履歴をリセット…", english: "Reset corrupted history…"),
                role: .destructive
            ) {
                isShowingRecoveryResetConfirmation = true
            }
        } header: {
            Text(KizunaCopy.text(japanese: "復旧", english: "Recovery"))
        }
    }

    private func exportRawData() {
        do {
            let url = try store.exportRawPersistedThreads()
            let shareItem = try loadExportShareItem(from: url)
            if !removeExportFile(at: url) {
                rememberExportCleanupURL(url)
            }
            exportedShareItem = shareItem
            statusMessage = pendingExportCleanupURLs.isEmpty
                ? KizunaCopy.text(japanese: "保存データを書き出しました。", english: "Stored data exported.")
                : exportCleanupWarningText
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func exportJSON() {
        do {
            let url = try store.exportPersistedThreadsJSON()
            let shareItem = try loadExportShareItem(from: url)
            if !removeExportFile(at: url) {
                rememberExportCleanupURL(url)
            }
            exportedShareItem = shareItem
            statusMessage = pendingExportCleanupURLs.isEmpty
                ? KizunaCopy.text(japanese: "JSONを書き出しました。", english: "JSON exported.")
                : exportCleanupWarningText
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func exportText() {
        do {
            let url = try store.exportPersistedThreadsText()
            let shareItem = try loadExportShareItem(from: url)
            if !removeExportFile(at: url) {
                rememberExportCleanupURL(url)
            }
            exportedShareItem = shareItem
            statusMessage = pendingExportCleanupURLs.isEmpty
                ? KizunaCopy.text(japanese: "テキストを書き出しました。", english: "Text exported.")
                : exportCleanupWarningText
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteAllThreads() {
        guard service.deleteAllConversations() else {
            errorMessage = KizunaCopy.text(
                japanese: "履歴を削除できませんでした。復旧が必要な場合は、先に保存データを確認してください。",
                english: "The history could not be deleted. If recovery is required, inspect the stored data first."
            )
            return
        }
        exportedShareItem = nil
        statusMessage = KizunaCopy.text(japanese: "Persona会話を削除しました。", english: "Persona conversations deleted.")
    }

    private func resetCorruptHistory() {
        do {
            // Keep a user-shareable copy before the destructive reset. The
            // store also retains its internal recovery backup, but the URL is
            // what lets the user inspect or save the original bytes now. The
            // share item is materialized before the destructive reset so a
            // failed reset can leave the current share item untouched.
            let backupURL = try store.exportCorruptPersistedThreads()
            let backupItem = try loadExportShareItem(from: backupURL)
            // Keep the backup shareable even when the recovery operation fails.
            exportedShareItem = backupItem
            guard store.discardCorruptPersistedThreads() else {
                if !removeExportFile(at: backupURL) {
                    rememberExportCleanupURL(backupURL)
                }
                errorMessage = KizunaCopy.text(
                    japanese: "復旧状態を変更できませんでした。画面を開き直してください。",
                    english: "The recovery state could not be changed. Reopen this screen and try again."
                )
                return
            }
            if !removeExportFile(at: backupURL) {
                rememberExportCleanupURL(backupURL)
            }
            exportedShareItem = backupItem
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        statusMessage = pendingExportCleanupURLs.isEmpty
            ? KizunaCopy.text(japanese: "バックアップ後に履歴をリセットしました。", english: "History was reset after backup.")
            : exportCleanupWarningText
    }

    @discardableResult
    private func removeExportFile(at url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            let nsError = error as NSError
            guard nsError.domain != NSCocoaErrorDomain
                    || nsError.code != NSFileNoSuchFileError else {
                return true
            }
            AppLog.note(
                "[KizunaPersonaDataManagement] failed to remove export file: %@",
                "\(url.path): \(error.localizedDescription)"
            )
            return false
        }
    }

    private func loadExportShareItem(from url: URL) throws -> KizunaPersonaExportShareItem {
        do {
            return try KizunaPersonaExportShareItem(fileURL: url)
        } catch {
            if !removeExportFile(at: url) {
                rememberExportCleanupURL(url)
            }
            throw error
        }
    }

    private func rememberExportCleanupURL(
        _ url: URL,
        retryImmediately: Bool = true
    ) {
        guard !pendingExportCleanupURLs.contains(url) else { return }
        pendingExportCleanupURLs.append(url)
        exportCleanupWarningMessage = exportCleanupWarningText
        if retryImmediately {
            retryPendingExportCleanup()
        }
    }

    private func retryPendingExportCleanup() {
        let pendingURLs = pendingExportCleanupURLs
        pendingExportCleanupURLs.removeAll()
        for url in pendingURLs where !removeExportFile(at: url) {
            rememberExportCleanupURL(url, retryImmediately: false)
        }
        if pendingExportCleanupURLs.isEmpty {
            exportCleanupWarningMessage = nil
        }
    }

    private var exportCleanupWarningText: String {
        KizunaCopy.text(
            japanese: "書き出しは完了しましたが、一時ファイルの削除に失敗しました。再試行します。",
            english: "The export completed, but its temporary file could not be removed. It will be retried."
        )
    }
}
