/*
仕様:
- 役割: ストーリー会話画面の生成モデル表示ピル。
- 主な型: `StoryGenerationModelPill`.
- 編集ポイント: モデル切替UI・状態表示を変えるときに触る。
- 構成: StorySessionChatView.swift から機械的に分割 (#286)。
*/

import SwiftUI

struct StoryGenerationModelPill: View {
    @ObservedObject var vm: StorySessionViewModel
    private let onOpenSettings: () -> Void
    @ObservedObject private var localModelManager = LocalAssistantModelManager.shared
    @State private var isShowingDetails = false
    @State private var detailsModel: StoryGenerationModel?
    @State private var nagiAvailability = StoryGemma31BAPIService.shared.availability

    init(vm: StorySessionViewModel, onOpenSettings: @escaping () -> Void = {}) {
        self.vm = vm
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        Menu {
            ForEach(StoryGenerationModel.allCases) { model in
                Button {
                    if isModelSelectable(model) {
                        vm.generationModel = model
                    } else {
                        detailsModel = model
                        isShowingDetails = true
                    }
                } label: {
                    Label(
                        "\(model.detailLabel) - \(modelAvailabilityText(model))",
                        systemImage: vm.generationModel == model ? "checkmark" : "cpu"
                    )
                }
                // 選択後に初めて失敗させると、未導入の iori や API キー未設定の
                // NAGI が「使えるモデル」として保存されてしまう。状態表示は残しつつ、
                // 送信可能なモデルだけを選択できるようにする。
                .disabled(vm.service.phase == .thinking)
                .help(modelHelpText(model))
            }
            Divider()
                Button {
                    detailsModel = vm.generationModel
                    isShowingDetails = true
                } label: {
                    Label(storyCopy("モデル詳細", "Model details"), systemImage: "info.circle")
            }
        } label: {
            HStack(spacing: 5) {
                Text(vm.generationModel.displayName)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .allowsTightening(true)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(storyText)
            .frame(minWidth: 88, minHeight: 44, alignment: .center)
            .background(Capsule().fill(Color.white.opacity(0.16)))
        }
        .buttonStyle(.plain)
        .disabled(vm.service.phase == .thinking)
        .accessibilityLabel(storyCopy("生成モデル", "Generation model"))
        .accessibilityValue(Text(
            "\(vm.generationModel.displayName), \(modelAvailabilityText(vm.generationModel))"
        ))
        .help(modelHelpText(vm.generationModel))
        .sheet(isPresented: $isShowingDetails) {
            NavigationStack {
                ScrollView {
                    modelDetailPopover
                        .padding(18)
                }
                    .navigationTitle(storyCopy("モデル詳細", "Model details"))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(storyCopy("閉じる", "Close")) { isShowingDetails = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
        .onAppear(perform: selectUsableModelIfNeeded)
        .task {
            nagiAvailability = await StoryGemma31BAPIService.shared.validateConfiguration()
            selectUsableModelIfNeeded()
        }
        .onChange(of: localModelManager.runtimeAvailability) { _, _ in
            selectUsableModelIfNeeded()
        }
    }

    private func isModelSelectable(_ model: StoryGenerationModel) -> Bool {
        switch model {
        case .e4b:
            return localModelManager.runtimeAvailability == .executable
        case .b31:
            return nagiAvailability.isUsable
        }
    }

    private func selectUsableModelIfNeeded() {
        // `.checking` and `.savedOnly` are transitional states. Do not turn a
        // temporary readiness check into a persisted model preference.
        if isModelSelectable(vm.preferredModel) {
            vm.restorePreferredGenerationModel()
            return
        }
        if localModelManager.runtimeAvailability == .checking
            || localModelManager.runtimeAvailability == .savedOnly
            || nagiAvailability == .checking
            || nagiAvailability == .savedNotVerified {
            return
        }
        guard !isModelSelectable(vm.generationModel),
              let fallback = StoryGenerationModel.allCases.first(where: { isModelSelectable($0) }) else {
            return
        }
        vm.applyTemporaryGenerationModel(fallback)
    }

    private var modelForDetails: StoryGenerationModel {
        detailsModel ?? vm.generationModel
    }

    private var modelDetailPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(modelForDetails.detailLabel)
                .font(.headline.weight(.bold))
                .foregroundStyle(.primary)
            Text(modelShortDescription(modelForDetails))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(modelAvailabilityText(modelForDetails))
                .font(.caption.weight(.semibold))
                .foregroundStyle(modelAvailabilityColor(modelForDetails))
                .fixedSize(horizontal: false, vertical: true)
            if !isModelSelectable(modelForDetails) {
                Button {
                    isShowingDetails = false
                    onOpenSettings()
                } label: {
                    Label(
                        storyCopy("設定を開く", "Open settings"),
                        systemImage: "arrow.right.circle"
                    )
                }
                .buttonStyle(.borderedProminent)
            }
            if let lastBackendStatus {
                Text(lastBackendStatus)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if modelForDetails == .e4b {
                Divider().opacity(0.35)
                Label(
                    ioriRuntimeStatusLabel,
                    systemImage: ioriRuntimeStatusIcon
                )
                .font(.subheadline.weight(.bold))
                .foregroundStyle(modelAvailabilityColor(.e4b))
                Text(ioriRuntimeActionHint)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 280, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.24), radius: 14, x: 0, y: 8)
    }

    private var lastBackendStatus: String? {
        let selected = vm.session.lastSelectedModelName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = vm.session.lastUsedModelIdentity?.trimmingCharacters(in: .whitespacesAndNewlines)
        let backend = vm.session.lastUsedBackendName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [selected, identity, backend].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        guard !parts.isEmpty else { return nil }
        return storyCopy("前回: ", "Last used: ") + parts.joined(separator: " / ")
    }

    private var ioriRuntimeActionHint: String {
        switch localModelManager.runtimeAvailability {
        case .checking:
            return storyCopy("モデル保存後に端末内で自動確認しています。完了まで生成は開始しません。", "The saved model is being checked on-device. Generation starts after the check finishes.")
        case .executable:
            return storyCopy("端末内で実行できます。選択中は iori がローカルで応答します。", "Ready on this device. iori will answer locally while selected.")
        case .savedOnly:
            return storyCopy("モデルは保存済みです。端末内の実行確認を自動で開始します。", "The model is saved. The on-device check will start automatically.")
        case .recentFailure:
            return storyCopy("端末内実行を確認できませんでした。NAGIへ切り替える場合はモデルメニューから選択してください。", "The on-device check failed. Choose NAGI from the model menu to continue.")
        case .modelMissing:
            return storyCopy("ローカルモデルが未導入です。モデルを保存すると端末内で自動確認します。", "The local model is not installed. Save a model to start the automatic check.")
        }
    }

    private var ioriRuntimeStatusLabel: String {
        switch localModelManager.runtimeAvailability {
        case .checking: return storyCopy("端末内で自動確認中", "Checking on device")
        case .executable: return storyCopy("端末内で実行可能", "Ready on device")
        case .savedOnly: return storyCopy("保存済み・自動確認待ち", "Saved · check pending")
        case .recentFailure: return storyCopy("端末内実行を確認できません", "On-device check failed")
        case .modelMissing: return storyCopy("ローカルモデル未導入", "Local model not installed")
        }
    }

    private var ioriRuntimeStatusIcon: String {
        switch localModelManager.runtimeAvailability {
        case .checking: return "arrow.triangle.2.circlepath"
        case .executable: return "checkmark.seal.fill"
        case .savedOnly: return "clock"
        case .recentFailure: return "exclamationmark.triangle"
        case .modelMissing: return "arrow.down.circle"
        }
    }

    private func modelHelpText(_ model: StoryGenerationModel) -> String {
        "\(model.detailLabel): \(modelShortDescription(model))"
    }

    private func modelShortDescription(_ model: StoryGenerationModel) -> String {
        switch model {
        case .e4b:
            return storyCopy("ローカル iori。モデル保存後に端末内の実行可否を自動確認します。", "Local iori. The app automatically checks the saved model on this device.")
        case .b31:
            return storyCopy("Gemma4 31B API。描写、関係性の機微、場面の空気をより丁寧に出します。", "Gemma4 31B API. Better for detailed scenes, relationships, and atmosphere.")
        }
    }

    private func modelAvailabilityText(_ model: StoryGenerationModel) -> String {
        switch model {
        case .e4b:
            switch localModelManager.runtimeAvailability {
            case .checking:
                return storyCopy("自動確認中", "Checking automatically")
            case .executable:
                return storyCopy("端末内で実行中", "Running on device")
            case .savedOnly:
                return storyCopy("モデル保存済み・自動確認待ち", "Model saved · check pending")
            case .recentFailure:
                return localModelManager.localizedRuntimeDiagnosticSummary
                    ?? storyCopy("ローカル自動確認失敗", "Automatic local check failed")
            case .modelMissing:
                return storyCopy("ローカル未導入", "Local model not installed")
            }
        case .b31:
            switch nagiAvailability {
            case .available:
                return storyCopy("接続確認済み", "Connection verified")
            case .savedNotVerified:
                return storyCopy("APIキー保存済み・未確認", "API key saved · not verified")
            case .checking:
                return storyCopy("接続確認中", "Checking connection")
            case .authenticationError:
                return storyCopy("認証エラー", "Authentication error")
            case .modelUnavailable:
                return storyCopy("モデル利用不可", "Model unavailable")
            case .rateLimited:
                return storyCopy("quota/rate limit", "Quota/rate limit")
            case .unavailable:
                return storyCopy("接続できません", "Unavailable")
            case .notConfigured:
                return storyCopy("Gemma4 APIキー未設定", "Gemma4 API key not set")
            }
        }
    }

    private func modelAvailabilityColor(_ model: StoryGenerationModel) -> Color {
        switch model {
        case .e4b:
            switch localModelManager.runtimeAvailability {
            case .checking:
                return .orange
            case .executable:
                return .green
            case .recentFailure:
                return .red
            case .savedOnly:
                return .orange
            case .modelMissing:
                return .secondary
            }
        case .b31:
            switch nagiAvailability {
            case .available: return .green
            case .authenticationError, .modelUnavailable, .unavailable: return .red
            case .rateLimited, .checking, .savedNotVerified: return .orange
            case .notConfigured: return .secondary
            }
        }
    }
}
