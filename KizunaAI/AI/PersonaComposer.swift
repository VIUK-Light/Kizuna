/*
仕様:
- 役割: ペルソナチャットの入力欄（コンポーザー）。
- 主な型: `PersonaComposer`.
- 編集ポイント: 送信UI、キーボードツールバー、送信可否判定を変えるときに触る。
- 構成: PersonaChatView.swift から機械的に分割 (#286)。
*/

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Composer

struct PersonaComposer: View {
    let thread: PersonaThread
    @ObservedObject private var store = PersonaChatStore.shared
    @StateObject private var service = PersonaChatService.shared
    @Binding private var text: String
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var colorScheme

    init(thread: PersonaThread, draft: Binding<String>) {
        self.thread = thread
        _text = draft
    }

    private var isGeneratingThisThread: Bool {
        service.activeGenerationThreadID == thread.id && service.phase == .thinking
    }

    private var isGeneratingAnotherThread: Bool {
        guard let activeThreadID = service.activeGenerationThreadID,
              service.phase == .thinking else { return false }
        return activeThreadID != thread.id
    }

    private var generatingThread: PersonaThread? {
        guard let activeThreadID = service.activeGenerationThreadID,
              service.phase == .thinking else { return nil }
        return store.thread(id: activeThreadID)
    }

    private var selectedRegistryConfiguration: AIModelConfiguration? {
        guard let configurationID = store.thread(id: thread.id)?.preferredGenerationConfigurationID else {
            return nil
        }
        guard let configuration = AIModelRegistry.shared.configuration(id: configurationID),
              configuration.isEnabled,
              configuration.roles.contains(.persona) else {
            return nil
        }
        return configuration
    }

    private var customRegistryConfigurations: [AIModelConfiguration] {
        AIModelRegistry.shared.configurations
            .filter { $0.roles.contains(.persona) }
            .sorted {
                if $0.priority != $1.priority { return $0.priority < $1.priority }
                return $0.identity.displayName.localizedStandardCompare($1.identity.displayName) == .orderedAscending
            }
    }

    private var selectedGenerationModel: PersonaGenerationModel {
        guard selectedRegistryConfiguration == nil else { return service.generationModel }
        return store.thread(id: thread.id)?.preferredGenerationModel ?? service.generationModel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: selectedRegistryConfiguration == nil && selectedGenerationModel == .local
                      ? "desktopcomputer"
                      : "cloud")
                Text(selectedRegistryConfiguration?.identity.displayName ?? selectedGenerationModel.localizedDisplayName)
                    .font(.caption.weight(.semibold))
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(modelAvailabilityText)
                    .font(.caption)
                if let identity = store.thread(id: thread.id)?.lastUsedModelIdentity,
                   !identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("· " + identity)
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)

            if isGeneratingAnotherThread {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(KizunaCopy.text(
                                japanese: "別のスレッドで生成中です",
                                english: "Another thread is generating"
                            ))
                                .font(.body.weight(.medium))
                            if let generatingThread {
                                Text("「\(generatingThread.title)」")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 8) {
                        if let generatingThread {
                            Button(KizunaCopy.text(japanese: "会話へ戻る", english: "Return to conversation")) {
                                store.selectThread(id: generatingThread.id)
                            }
                            .buttonStyle(.bordered)
                        }
                        Button(KizunaCopy.text(japanese: "生成を停止", english: "Stop generation"), role: .destructive) {
                            service.cancel()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal, 14)
                .accessibilityElement(children: .combine)
            }

            HStack(alignment: .bottom, spacing: 8) {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.18))
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 34, height: 34)
                .help(KizunaCopy.appName)

                Menu {
                    Button {
                        store.setPreferredGenerationModel(nil, configurationID: nil, forThread: thread.id)
                    } label: {
                        Label(
                            KizunaCopy.text(japanese: "アプリ既定（\(service.generationModel.localizedDisplayName)）", english: "App default (\(service.generationModel.localizedDisplayName))"),
                            systemImage: selectedRegistryConfiguration == nil
                                && store.thread(id: thread.id)?.preferredGenerationModel == nil
                                ? "checkmark"
                                : "arrow.uturn.backward"
                        )
                    }
                    Divider()
                    ForEach(PersonaGenerationModel.allCases) { model in
                        Button {
                            store.setPreferredGenerationModel(model, configurationID: nil, forThread: thread.id)
                        } label: {
                            Label(
                                "\(model.localizedDisplayName) · \(model.isAvailable ? KizunaCopy.text(japanese: "利用可能", english: "Available") : KizunaCopy.text(japanese: "未準備", english: "Not ready"))",
                                systemImage: selectedRegistryConfiguration == nil && selectedGenerationModel == model ? "checkmark" : "cpu"
                            )
                        }
                        .disabled(!model.isAvailable || isGeneratingThisThread)
                    }
                    if !customRegistryConfigurations.isEmpty {
                        Divider()
                        ForEach(customRegistryConfigurations) { configuration in
                            Button {
                                store.setPreferredGenerationModel(
                                    nil,
                                    configurationID: configuration.id,
                                    forThread: thread.id
                                )
                            } label: {
                                Label(
                                    "\(configuration.identity.displayName) · \(registryProviderDisplayName(configuration.identity.providerID)) · \(registryAvailabilityText(configuration))",
                                    systemImage: selectedRegistryConfiguration?.id == configuration.id ? "checkmark" : "cloud"
                                )
                            }
                            .disabled(!registryConfigurationIsSelectable(configuration) || isGeneratingThisThread)
                        }
                    }
                } label: {
                    Image(systemName: "cpu")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(KizunaCopy.text(japanese: "Personaの生成モデル", english: "Persona generation model"))

                TextField(KizunaCopy.text(japanese: "メッセージを送る…", english: "Message…"), text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .lineLimit(1...4)
                    .submitLabel(.send)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(colorScheme == .dark
                                  ? Color(red: 0.20, green: 0.20, blue: 0.24)
                                  : Color.white)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                    .onSubmit(submit)

                Button {
                    if isGeneratingThisThread {
                        service.cancel()
                    } else {
                        submit()
                    }
                } label: {
                    Image(systemName: isGeneratingThisThread ? "stop.fill" : "paperplane.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(
                            Circle().fill(isGeneratingThisThread || canSubmit ? Color.accentColor : Color.secondary.opacity(0.25))
                        )
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(!isGeneratingThisThread && !canSubmit)
                .help(isGeneratingAnotherThread
                      ? KizunaCopy.text(japanese: "別のスレッドで生成中です", english: "Another thread is generating")
                      : "")
                .accessibilityLabel(isGeneratingThisThread
                                    ? KizunaCopy.text(japanese: "生成を停止", english: "Stop generating")
                                    : KizunaCopy.text(japanese: "送信", english: "Send"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.thinMaterial)
        .personaKeyboardDismissToolbar($focused)
    }

    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !store.isPersistenceRecoveryRequired
            && !isGeneratingAnotherThread
    }

    private var modelAvailabilityText: String {
        if let selectedRegistryConfiguration {
            return registryAvailabilityText(selectedRegistryConfiguration)
        }
        switch selectedGenerationModel {
        case .local:
            switch LocalAssistantModelManager.shared.runtimeAvailability {
            case .executable: return KizunaCopy.text(japanese: "利用可能", english: "Ready")
            case .checking: return KizunaCopy.text(japanese: "確認中", english: "Checking")
            case .savedOnly: return KizunaCopy.text(japanese: "保存済み・未確認", english: "Saved · not verified")
            case .recentFailure: return KizunaCopy.text(japanese: "実行エラー", english: "Runtime error")
            case .modelMissing: return KizunaCopy.text(japanese: "未導入", english: "Not installed")
            }
        case .nagi:
            switch StoryGemma31BAPIService.shared.availability {
            case .available: return KizunaCopy.text(japanese: "接続確認済み", english: "Verified")
            case .checking: return KizunaCopy.text(japanese: "接続確認中", english: "Checking")
            case .savedNotVerified: return KizunaCopy.text(japanese: "保存済み・未確認", english: "Saved · not verified")
            case .authenticationError: return KizunaCopy.text(japanese: "認証エラー", english: "Auth error")
            case .modelUnavailable: return KizunaCopy.text(japanese: "モデル利用不可", english: "Model unavailable")
            case .rateLimited: return KizunaCopy.text(japanese: "quota / rate limit", english: "Quota / rate limit")
            case .unavailable: return KizunaCopy.text(japanese: "接続不可", english: "Unavailable")
            case .notConfigured: return KizunaCopy.text(japanese: "未設定", english: "Not configured")
            }
        }
    }

    private func registryConfigurationIsSelectable(_ configuration: AIModelConfiguration) -> Bool {
        guard configuration.isEnabled else { return false }
        switch configuration.identity.providerID {
        case .localRuntime:
            return LocalAssistantModelManager.shared.runtimeAvailability == .executable
                && LocalAssistantModelManager.shared.modelURL(
                    forArtifactID: configuration.identity.artifactID
                ) != nil
        case .googleGenerativeLanguage:
            return AISecretStore.shared.providerAPIKey(for: configuration.id) != nil
                || AISecretStore.shared.configuredGemmaWebReaderAPIKey() != nil
        case .openAICompatible, .anthropic:
            return !AIEndpointPolicy.requiresAPIKey(
                providerID: configuration.identity.providerID,
                endpoint: configuration.endpoint
            ) || AISecretStore.shared.providerAPIKey(for: configuration.id) != nil
        }
    }

    private func registryAvailabilityText(_ configuration: AIModelConfiguration) -> String {
        guard configuration.isEnabled else {
            return KizunaCopy.text(japanese: "無効", english: "Disabled")
        }
        guard registryConfigurationIsSelectable(configuration) else {
            return KizunaCopy.text(japanese: "未準備", english: "Not ready")
        }
        return KizunaCopy.text(japanese: "利用可能", english: "Available")
    }

    private func registryProviderDisplayName(_ provider: AIProviderID) -> String {
        switch provider {
        case .localRuntime: return "Local"
        case .googleGenerativeLanguage: return "Google"
        case .openAICompatible: return "OpenAI-compatible"
        case .anthropic: return "Anthropic"
        }
    }

    private func submit() {
        guard canSubmit else { return }
        let toSend = text
        guard service.send(toSend, to: thread) else { return }
        text = ""
        focused = false
    }
}

private extension View {
    @ViewBuilder
    func personaKeyboardDismissToolbar(_ focused: FocusState<Bool>.Binding) -> some View {
        #if canImport(UIKit)
        self.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(KizunaCopy.text(japanese: "閉じる", english: "Done")) { focused.wrappedValue = false }
            }
        }
        #else
        self
        #endif
    }
}
