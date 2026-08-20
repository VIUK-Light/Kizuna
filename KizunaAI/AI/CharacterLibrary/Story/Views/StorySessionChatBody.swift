/*
仕様:
- 役割: ストーリーセッションの会話本体（シーン・メッセージ・コンポーザー）。
- 主な型: `StorySessionChatBody`.
- 編集ポイント: メッセージ表示、シーン演出、送信UIを変えるときに触る。
- 構成: StorySessionChatView.swift から機械的に分割 (#286)。
*/

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

struct StorySessionChatBody: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @ObservedObject var vm: StorySessionViewModel
    @ObservedObject private var service: StorySessionService
    @ObservedObject private var localModelManager: LocalAssistantModelManager
    @Binding var isShowingRestHelp: Bool
    @State private var draft = ""
    @State private var selectedCharacterID: UUID?
    @State private var isShowingCharacterSheet = false
    @State private var isShowingSafetyResources = false
    @State private var isShowingSafetyHelp = false
    @State private var isShowingInterruptedDiscardConfirmation = false
    @State private var isShowingResponseActionError = false
    @State private var unavailableModelMessage = ""
    @State private var isShowingUnavailableModelAlert = false
    @State private var isStoryChatNearLatest = true
    @State private var unreadStoryMessageCount = 0
    @State private var previousStoryMessageIDs: Set<UUID> = []
    @FocusState private var composerFocused: Bool

    init(vm: StorySessionViewModel, isShowingRestHelp: Binding<Bool>) {
        self.vm = vm
        _isShowingRestHelp = isShowingRestHelp
        _service = ObservedObject(wrappedValue: vm.service)
        _localModelManager = ObservedObject(wrappedValue: LocalAssistantModelManager.shared)
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                sceneStrip(availableHeight: geometry.size.height)
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                ScrollViewReader { proxy in
                    ZStack(alignment: .bottomTrailing) {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                let latestResponseID = vm.latestCommittedResponseMessageID
                                ForEach(visibleMessages) { message in
                                    messageRow(
                                        message,
                                        showsResponseActions: message.id == latestResponseID
                                    )
                                        .id(message.id)
                                }
                                if service.phase == .thinking {
                                    streamingPreview
                                }
                                bootstrapWarningCard
                                sendPreparationErrorCard
                                interruptedTurnCard
                                // 最新のキャラクター発話の後ろに、会話の一部として表示する。
                                restSuggestionCard
                                safetySupportCard
                                runtimeNoticeCard
                                Color.clear
                                    .frame(height: 1)
                                    .id("story-chat-bottom")
                            }
                            .padding(18)
                        }
                        .background(storyCanvas)
                        .onAppear {
                            previousStoryMessageIDs = Set(vm.session.messages.map(\.id))
                        }
                        .onScrollGeometryChange(for: Bool.self) { geometry in
                            let distanceFromBottom = geometry.contentSize.height
                                - geometry.contentOffset.y
                                - geometry.containerSize.height
                            return distanceFromBottom < 72
                        } action: { _, nearLatest in
                            isStoryChatNearLatest = nearLatest
                            if nearLatest {
                                unreadStoryMessageCount = 0
                            }
                        }
                        .onChange(of: vm.session.messages.count) { _, _ in
                            let currentMessageIDs = Set(vm.session.messages.map(\.id))
                            if isStoryChatNearLatest {
                                if let last = vm.session.messages.last?.id {
                                    withAnimation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.2)) {
                                        proxy.scrollTo(last, anchor: .bottom)
                                    }
                                }
                            } else {
                                let newMessageIDs = currentMessageIDs.subtracting(previousStoryMessageIDs)
                                let newCastMessages = vm.session.messages.filter { message in
                                    newMessageIDs.contains(message.id) && isUnreadStoryMessage(message)
                                }
                                if !newCastMessages.isEmpty {
                                    unreadStoryMessageCount += newCastMessages.count
                                }
                            }
                            previousStoryMessageIDs = currentMessageIDs
                        }
                        .onChange(of: vm.bootstrapWarning) { _, warning in
                            guard warning != nil, isStoryChatNearLatest else { return }
                            Task { @MainActor in
                                // Wait for the conditional card to enter the
                                // LazyVStack before scrolling to its stable ID.
                                await Task.yield()
                                guard vm.bootstrapWarning != nil else { return }
                                withAnimation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.2)) {
                                    proxy.scrollTo("story.bootstrap-warning", anchor: .bottom)
                                }
                            }
                        }
                        .task(id: vm.session.id) {
                            // 既存セッションを開いた直後は messages.count が変化しないため、
                            // onChangeだけでは保存済みの最新発話へ移動できない。LazyVStackの
                            // レイアウトを1回待ってから、再開時だけ最新へ初期配置する。
                            await Task.yield()
                            guard let last = vm.session.messages.last?.id else { return }
                            proxy.scrollTo(last, anchor: .bottom)
                            isStoryChatNearLatest = true
                            unreadStoryMessageCount = 0
                        }
                        .onChange(of: service.streamingResponse) { _, _ in
                            guard isStoryChatNearLatest, service.phase == .thinking else { return }
                            withAnimation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.2)) {
                                proxy.scrollTo("streaming-preview", anchor: .bottom)
                            }
                        }
                        .onChange(of: service.savedTurnRevision) { _, _ in
                            // キャラクター発話の保存後にだけ、アプリ側の60分判定を行う。
                            Task {
                                guard await vm.refreshAfterTurn() else { return }
                                await vm.evaluateRestSuggestionAfterTurn()
                            }
                        }
                        .onChange(of: vm.restSuggestion?.id) { _, suggestionID in
                            guard suggestionID != nil, isStoryChatNearLatest else { return }
                            withAnimation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.25)) {
                                proxy.scrollTo("rest-suggestion-card", anchor: .bottom)
                            }
                        }
                        .onChange(of: service.latestSafetyConcern?.id) { _, concernID in
                            guard concernID != nil, isStoryChatNearLatest else { return }
                            withAnimation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.25)) {
                                proxy.scrollTo("safety-support-card", anchor: .bottom)
                            }
                        }
                        .onChange(of: service.latestRuntimeNotice?.id) { _, noticeID in
                            guard noticeID != nil, isStoryChatNearLatest else { return }
                            withAnimation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.25)) {
                                proxy.scrollTo("runtime-notice-card", anchor: .bottom)
                            }
                        }
                        .onChange(of: vm.responseActionError) { _, error in
                            isShowingResponseActionError = error != nil
                        }
                        .onChange(of: vm.lastStartedUserMessageID) { _, startedID in
                            guard startedID != nil else { return }
                            draft = ""
                            composerFocused = false
                        }

                        if !isStoryChatNearLatest {
                            Button {
                                withAnimation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.2)) {
                                    proxy.scrollTo("story-chat-bottom", anchor: .bottom)
                                }
                                isStoryChatNearLatest = true
                                unreadStoryMessageCount = 0
                            } label: {
                                Label(
                                    unreadStoryMessageCount > 0
                                        ? "\(unreadStoryMessageCount) " + KizunaCopy.pluralText(
                                            japanese: "新しい発言",
                                            englishSingular: "new message",
                                            englishPlural: "new messages",
                                            count: unreadStoryMessageCount
                                        )
                                        : storyCopy("最新へ", "Latest"),
                                    systemImage: "arrow.down"
                                )
                                .font(.body.weight(.bold))
                                .padding(.horizontal, 11)
                                .padding(.vertical, 8)
                                .frame(minHeight: 44)
                                .background(.regularMaterial, in: Capsule())
                                .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 16)
                            .padding(.bottom, 14)
                            .accessibilityLabel(storyCopy("最新の発言へ移動", "Jump to the latest message"))
                        }
                    }
                    .background(storyCanvas)
                    .alert(storyCopy("モデルを準備してください", "Prepare a model"), isPresented: $isShowingUnavailableModelAlert) {
                        Button(storyCopy("閉じる", "Close"), role: .cancel) { }
                    } message: {
                        Text(unavailableModelMessage)
                    }
                    .alert(
                        storyCopy("応答を変更できませんでした", "Could not change the response"),
                        isPresented: $isShowingResponseActionError
                    ) {
                        Button(storyCopy("閉じる", "Close"), role: .cancel) { }
                    } message: {
                        Text(vm.responseActionError ?? storyCopy("保存状態を確認してください。", "Check the saved conversation."))
                    }
                }
            }
            // Keeping the composer in the safe-area inset reserves its actual
            // height from the ScrollView, including when the keyboard appears.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composer
            }
        }
        .sheet(isPresented: $isShowingCharacterSheet) {
            StoryCharacterSpotlightSheet(
                characters: vm.activeCharacters,
                selectedCharacterID: selectedCharacterID,
                onSelect: { selectedCharacterID = $0 }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isShowingSafetyResources) {
            if let concern = service.latestSafetyConcern {
                SafetySupportSheet(concern: concern)
            }
        }
        .sheet(isPresented: $isShowingSafetyHelp) {
            SafetyConcernHelpSheetFrame()
        }
        .onChange(of: localModelManager.runtimeAvailability) { _, availability in
            guard availability == .executable,
                  let notice = service.latestRuntimeNotice,
                  notice.backend == .local,
                  notice.retryWhenLocalReady else { return }
            // A readiness timeout is not a generation failure. Reuse the
            // persisted user-message ID so the same turn resumes once the
            // background self-check finishes, without duplicating input.
            _ = vm.retryRuntimeNotice(notice)
        }
        .confirmationDialog(
            storyCopy("中断した発言を破棄しますか？", "Discard the interrupted message?"),
            isPresented: $isShowingInterruptedDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                storyCopy("この発言を破棄", "Discard this message"),
                role: .destructive
            ) {
                vm.discardInterruptedTurn()
            }
            Button(storyCopy("キャンセル", "Cancel"), role: .cancel) { }
        } message: {
            Text(storyCopy(
                "未完了の発言と生成待ち状態を履歴から取り除きます。",
                "The incomplete message and its pending generation state will be removed from this story."
            ))
        }
    }

    /// Auxiliary memory-retry restoration is useful but not required to read
    /// or continue the conversation. Keep the warning in the chat surface so
    /// bootstrap can remain non-blocking without silently hiding a persistence
    /// problem.
    @ViewBuilder
    private var bootstrapWarningCard: some View {
        if let warning = vm.bootstrapWarning {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.orange.opacity(0.9))
                        .frame(width: 18)
                    Text(warning)
                        .font(.footnote)
                        .foregroundStyle(storyText.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                HStack {
                    Spacer(minLength: 0)
                    if vm.isRestoringBootstrapWarning {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(storyCopy("再試行中", "Retrying"))
                    }
                    Button {
                        Task { @MainActor in
                            await vm.retryBootstrapMemoryRestore()
                        }
                    } label: {
                        Label(
                            storyCopy("再試行", "Retry"),
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(minHeight: 44)
                    .disabled(vm.isRestoringBootstrapWarning)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.orange.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.orange.opacity(0.16), lineWidth: 1)
            )
            .accessibilityElement(children: .contain)
            .id("story.bootstrap-warning")
        }
    }

    @ViewBuilder
    private var sendPreparationErrorCard: some View {
        if let error = vm.sendPreparationError {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange.opacity(0.9))
                VStack(alignment: .leading, spacing: 4) {
                    Text(storyCopy("送信を開始できませんでした", "The message could not start"))
                        .font(.subheadline.weight(.bold))
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(storyText.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(storyCopy(
                        "入力欄の本文は保持しています。保存状態を確認して再送信してください。",
                        "Your text was kept. Check the saved state and send it again."
                    ))
                        .font(.caption)
                        .foregroundStyle(storyMuted)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.orange.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.orange.opacity(0.18), lineWidth: 1)
            )
            .id("story.send-preparation-error")
        }
    }

    /// A pending turn becomes interrupted after relaunch. Keep this recovery
    /// surface in the conversation itself; it is not a story event or a new
    /// navigation mode, and it must remain visible until retry or discard has
    /// completed successfully.
    @ViewBuilder
    private var interruptedTurnCard: some View {
        if service.phase != .thinking, let checkpoint = vm.interruptedTurn {
            let messageText = vm.interruptedTurnMessage?.text.trimmingCharacters(in: .whitespacesAndNewlines)
            VStack(alignment: .leading, spacing: 11) {
                Label(
                    storyCopy("前回の生成が中断されました", "The previous generation was interrupted"),
                    systemImage: "arrow.triangle.2.circlepath"
                )
                    .font(.headline.weight(.bold))
                    .foregroundStyle(storyText)

                Text(
                    messageText?.isEmpty == false
                        ? messageText!
                        : storyCopy("中断した発言の本文を確認できません。破棄してください。", "The interrupted message is unavailable. Discard it.")
                )
                    .font(.subheadline)
                    .foregroundStyle(storyText.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)

                if let error = vm.interruptedTurnRecoveryError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    if vm.isHandlingInterruptedTurn {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(storyCopy("処理中", "Working"))
                    }
                    Button {
                        _ = vm.retryInterruptedTurn()
                    } label: {
                        Label(
                            storyCopy("この発言を再試行", "Retry this message"),
                            systemImage: "arrow.clockwise"
                        )
                    }
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: 44)
                        .disabled(vm.isHandlingInterruptedTurn || vm.interruptedTurnMessage == nil)

                    Button(role: .destructive) {
                        isShowingInterruptedDiscardConfirmation = true
                    } label: {
                        Label(
                            storyCopy("この発言を破棄", "Discard this message"),
                            systemImage: "trash"
                        )
                    }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                        .disabled(vm.isHandlingInterruptedTurn)
                }
            }
            .padding(14)
            .background(storyPanel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.orange.opacity(0.35), lineWidth: 1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("story.interrupted-turn")
            .transition(accessibilityReduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
            .id("story.interrupted-turn-\(checkpoint.turnID.uuidString)")
        }
    }

    // 休憩提案はアラートではなく、会話画面内に表示するカード。
    // 「?」はこのカードの説明だけを開く。
    @ViewBuilder
    private var restSuggestionCard: some View {
        if let suggestion = vm.restSuggestion {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(storyCopy("休憩提案", "Take a break"))
                            .font(.headline.weight(.bold))
                            .foregroundStyle(storyText)
                        Text(suggestion.text)
                            .font(.subheadline)
                            .foregroundStyle(storyText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button {
                        isShowingRestHelp = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(storyMuted)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("story.rest.help")
                    .accessibilityLabel(storyCopy("この休憩提案について", "About this break suggestion"))
                }

                HStack(spacing: 10) {
                    if vm.isSavingRestAcknowledgement {
                        ProgressView()
                            .controlSize(.small)
                        Text(storyCopy("保存中…", "Saving…"))
                            .font(.caption)
                            .foregroundStyle(storyMuted)
                    }
                    if let error = vm.restAcknowledgementError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 10) {
                    Button(storyCopy("少し休む", "Take a short break")) {
                        vm.chooseRestSuggestionBreak()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                    .disabled(vm.isSavingRestAcknowledgement)

                    Button(storyCopy("このまま続ける", "Continue")) {
                        vm.chooseRestSuggestionContinue()
                    }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                    .disabled(vm.isSavingRestAcknowledgement)
                }
            }
            .padding(14)
            .background(storyPanel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .id("rest-suggestion-card")
            .transition(accessibilityReduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
        }
    }

    /// ランタイム/保存失敗の通知は履歴へ書き込まず、現在の画面だけに表示する。
    /// これにより「エラーをsystem発話として会話に混ぜる」「再試行のたびにカードが
    /// 増える」問題を防ぎつつ、入力本文を失わずに再試行できる。
    @ViewBuilder
    private var runtimeNoticeCard: some View {
        if let notice = service.latestRuntimeNotice {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.orange.opacity(0.9))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 7) {
                    Text(
                        notice.retryAction.isAuxiliarySave
                            ? storyCopy("保存状態", "Save status")
                            : storyCopy("モデル状態", "Model status")
                    )
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(storyMuted)
                    Text(notice.text)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(storyText.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button(
                            notice.retryAction.isAuxiliarySave
                                ? storyCopy("保存を再試行", "Retry save")
                                : storyCopy("もう一度試す", "Try again")
                        ) {
                            _ = vm.retryRuntimeNotice(notice)
                        }
                        .font(.body.weight(.bold))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .frame(minHeight: 44)
                        .disabled(service.isRetryingAuxiliarySave)
                        if notice.backend == .local {
                            Button {
                                vm.generationModel = .b31
                                _ = vm.retryRuntimeNotice(notice)
                            } label: {
                                Label(
                                    StoryGemma31BAPIService.shared.hasAPIKey
                                        ? storyCopy("NAGIで再試行", "Retry with NAGI")
                                        : storyCopy("NAGI APIキー未設定", "NAGI API key not set"),
                                    systemImage: "arrow.triangle.2.circlepath"
                                )
                                .font(.body.weight(.bold))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .frame(minHeight: 44)
                            .disabled(!StoryGemma31BAPIService.shared.hasAPIKey)
                        }
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
                Spacer(minLength: 28)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.orange.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.orange.opacity(0.18), lineWidth: 1)
            )
            .id("runtime-notice-card")
        }
    }

    // 危険相談の検知は会話を止めず、本文とは別のサポートカードだけを追加する。
    @ViewBuilder
    private var safetySupportCard: some View {
        if let concern = service.latestSafetyConcern {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Label(concern.localizedTitle, systemImage: concern.level == .urgent ? "exclamationmark.triangle.fill" : "heart.text.square")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(concern.level == .urgent ? .orange : storyText)
                    Spacer(minLength: 8)
                    Button {
                        isShowingSafetyHelp = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(storyMuted)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("story.safety.help")
                    .accessibilityLabel(storyCopy("この相談サポートについて", "About this support"))
                }
                Text(concern.localizedMessage)
                    .font(.subheadline)
                    .foregroundStyle(storyText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(storyCopy(
                    "会話はそのまま続けられます。必要なら相談先を確認してください。",
                    "You can continue the conversation. Open support resources if you need them."
                ))
                    .font(.caption)
                    .foregroundStyle(storyMuted)

                HStack(spacing: 10) {
                    Button(storyCopy("相談先を見る", "View support resources")) {
                        isShowingSafetyResources = true
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                    Button(storyCopy("閉じる", "Dismiss")) {
                        service.dismissSafetyConcern()
                    }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                }
            }
            .padding(14)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.orange.opacity(0.35), lineWidth: 1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .id("safety-support-card")
            .transition(accessibilityReduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
        }
    }

    private var visibleMessages: [StoryMessage] {
        // 重複修復は StorySessionRepository の読み込み・保存時に行う。
        // ここで表示だけを隠すと、保存データの不整合を見逃してしまうため、
        // 会話画面は永続化されたメッセージをそのまま表示する。
        vm.session.messages
    }

    private var selectedModelIsReady: Bool {
        isModelReady(vm.generationModel)
    }

    private func isModelReady(_ model: StoryGenerationModel) -> Bool {
        switch model {
        case .e4b:
            return localModelManager.runtimeAvailability == .executable
        case .b31:
            return StoryGemma31BAPIService.shared.hasAPIKey
        }
    }

    private var availableFallbackModel: StoryGenerationModel? {
        StoryGenerationModel.allCases.first { model in
            model != vm.generationModel && isModelReady(model)
        }
    }

    private func handleUnavailableModelBeforeSubmission() {
        let unavailableModel = vm.generationModel
        guard let fallback = availableFallbackModel else {
            showUnavailableModelAlert()
            return
        }

        // APIキーの削除や端末内セルフチェックの失敗は、メニューを開いた後にも
        // 起こり得る。送信を失敗させる前に、次回送信のモデルを切り替える。
        vm.generationModel = fallback
        unavailableModelMessage = storyCopy(
            "\(unavailableModel.displayName) は現在利用できないため、\(fallback.displayName) に切り替えました。内容を確認して、もう一度送信してください。",
            "\(unavailableModel.displayName) is unavailable, so the model was switched to \(fallback.displayName). Review the change and send again."
        )
        isShowingUnavailableModelAlert = true
    }

    private func showUnavailableModelAlert() {
        switch vm.generationModel {
        case .e4b:
            switch localModelManager.runtimeAvailability {
            case .checking:
                unavailableModelMessage = storyCopy(
                    "iori は端末内で起動確認中です。確認が終わるまで待つか、モデルメニューから利用可能なモデルを選択してください。",
                    "iori is being checked on this device. Wait for the check to finish or choose an available model from the model menu."
                )
            case .savedOnly:
                unavailableModelMessage = storyCopy(
                    "iori のモデルは保存済みですが、端末内の起動確認がまだ完了していません。確認が終わるまで待つか、モデルメニューから利用可能なモデルを選択してください。",
                    "The iori model is saved, but its on-device check has not finished. Wait for the check or choose an available model from the model menu."
                )
            case .recentFailure:
                // Native runtime diagnostics are localized by the model manager;
                // do not leak a Japanese error into an English story alert.
                unavailableModelMessage = localModelManager.localizedRuntimeDiagnosticSummary
                    ?? storyCopy(
                        "iori を端末内で起動できませんでした。モデル詳細で状態を確認するか、利用可能なモデルを選択してください。",
                        "iori could not start on this device. Check the model details or choose an available model."
                    )
            case .modelMissing:
                unavailableModelMessage = storyCopy(
                    "iori のモデルが端末にありません。設定でモデルを保存するか、モデルメニューから利用可能なモデルを選択してください。",
                    "The iori model is not installed on this device. Save it in Settings or choose an available model from the model menu."
                )
            case .executable:
                unavailableModelMessage = storyCopy(
                    "iori は利用できます。もう一度送信してください。",
                    "iori is ready. Try sending again."
                )
            }
        case .b31:
            unavailableModelMessage = storyCopy(
                "NAGI を使うには Gemma4 API キーが必要です。設定で API キーを登録するか、モデルメニューから iori を選択してください。",
                "NAGI requires a Gemma4 API key. Add the key in Settings or choose iori from the model menu."
            )
        }
        isShowingUnavailableModelAlert = true
    }

    private func sceneStrip(availableHeight: CGFloat) -> some View {
        Group {
            if horizontalSizeClass == .compact {
                compactSceneStrip(availableHeight: availableHeight)
            } else {
                regularSceneStrip(availableHeight: availableHeight)
            }
        }
        .padding(.horizontal, horizontalSizeClass == .compact ? 14 : 18)
        .padding(.vertical, horizontalSizeClass == .compact ? 7 : 10)
        .background(storyCanvas)
    }

    private func regularSceneStrip(availableHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 12) {
                currentSceneLabel
                Spacer()
                activeCharacterChips
            }
            sceneVisual(availableHeight: availableHeight)
        }
    }

    private func compactSceneStrip(availableHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                currentSceneLabel
                Spacer(minLength: 4)
                activeCharacterChips
                    .frame(maxWidth: 210, alignment: .trailing)
            }
            sceneVisual(availableHeight: availableHeight)
        }
    }

    private func sceneVisual(availableHeight: CGFloat) -> some View {
        StorySceneImageView(
            scene: vm.scene,
            world: vm.world.localizedForCurrentLanguage,
            contentMode: .fit
        )
            .frame(maxWidth: .infinity)
            // `.fit` preserves the source image, but it does not cap the
            // container height. An unbounded 16:9 aspect-ratio container can
            // consume the compact landscape screen. Limit the image to a
            // small share of the available body height while keeping the
            // established compact/regular caps for taller layouts.
            .frame(height: sceneVisualHeight(availableHeight: availableHeight))
            .background(Color.black.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.26)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
    }

    private var currentSceneLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(currentSceneTitle)
                .font(.headline.weight(.bold))
                .foregroundStyle(storyText)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .layoutPriority(1)
            if !currentSceneContext.isEmpty {
                Text(currentSceneContext)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(storyMuted)
                    .lineLimit(1)
            }
        }
    }

    private var currentSceneTitle: String {
        let location = vm.session.storyState?.location.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !location.isEmpty {
            return location
        }
        return vm.scene.title.isEmpty ? storyCopy("現在のシーン", "Current scene") : vm.scene.title
    }

    private var currentSceneContext: String {
        guard let state = vm.session.storyState else { return "" }
        return [state.timeOfDay, state.mood, state.weather]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func sceneVisualHeight(availableHeight: CGFloat) -> CGFloat {
        let sizeClassCap: CGFloat = verticalSizeClass == .compact ? 78 : 104
        return min(sizeClassCap, max(0, availableHeight * 0.20))
    }

    private var activeCharacterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
            ForEach(vm.activeCharacters.prefix(StoryConstants.maxActiveCharacters)) { character in
                Button {
                    selectedCharacterID = character.id
                    isShowingCharacterSheet = true
                } label: {
                    HStack(spacing: 5) {
                        characterAvatar(character, size: 18)
                        Text(character.visibleName)
                            .font(.caption.weight(.bold))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(minHeight: 44)
                    .background(Capsule().fill(selectedCharacterID == character.id ? storyPurple.opacity(0.42) : Color.white.opacity(0.10)))
                    .overlay(Capsule().stroke(selectedCharacterID == character.id ? storyPurple.opacity(0.78) : Color.clear, lineWidth: 1))
                    .foregroundStyle(storyText)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedCharacterID == character.id ? .isSelected : [])
            }
        }
        }
    }

    @ViewBuilder
    private func messageRow(
        _ message: StoryMessage,
        showsResponseActions: Bool = false
    ) -> some View {
        if showsResponseActions {
            messageRowContainer(message, showsResponseActions: true)
                .contextMenu {
                    responseActionButtons(for: message)
                }
                .accessibilityAction(named: Text(storyCopy("この発言をコピー", "Copy this message"))) {
                    StorySessionClipboard.copy(message.text)
                }
                .accessibilityAction(named: Text(storyCopy("このターンを再生成", "Regenerate this turn"))) {
                    vm.regenerateLatestResponse()
                }
                .accessibilityAction(named: Text(storyCopy("このターンを取り消す", "Undo this turn"))) {
                    vm.undoLatestResponse()
                }
        } else {
            messageRowContainer(message, showsResponseActions: false)
        }
    }

    @ViewBuilder
    private func messageRowContainer(
        _ message: StoryMessage,
        showsResponseActions: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            accessibleMessageRowContent(message)
            if showsResponseActions {
                HStack {
                    Spacer(minLength: 0)
                    responseActionMenu(for: message)
                }
            }
        }
    }

    @ViewBuilder
    private func accessibleMessageRowContent(_ message: StoryMessage) -> some View {
        if case .system = message.author {
            messageRowContent(message)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(storyAccessibilityLabel(for: message))
        } else {
            messageRowContent(message)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(storyAccessibilityLabel(for: message))
                .accessibilityValue(Text(message.createdAt, style: .time))
        }
    }

    private func responseActionMenu(for message: StoryMessage) -> some View {
        Menu {
            responseActionButtons(for: message)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(storyMuted)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(storyCopy("このターンの操作", "Actions for this turn"))
        .accessibilityHint(storyCopy("この発言をコピー、ターンを再生成または取り消し", "Copy this message, regenerate or undo the turn"))
        .disabled(vm.isHandlingResponseAction)
    }

    @ViewBuilder
    private func responseActionButtons(for message: StoryMessage) -> some View {
        Button {
            StorySessionClipboard.copy(message.text)
        } label: {
            Label(storyCopy("この発言をコピー", "Copy this message"), systemImage: "doc.on.doc")
        }
        Button {
            vm.regenerateLatestResponse()
        } label: {
            Label(storyCopy("このターンを再生成", "Regenerate this turn"), systemImage: "arrow.clockwise")
        }
        Button(role: .destructive) {
            vm.undoLatestResponse()
        } label: {
            Label(storyCopy("このターンを取り消す", "Undo this turn"), systemImage: "arrow.uturn.backward")
        }
    }

    @ViewBuilder
    private func messageRowContent(_ message: StoryMessage) -> some View {
        switch message.author {
        case .user:
            HStack {
                Spacer(minLength: 80)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(message.text)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(storyPurple)
                        )
                    Text(message.createdAt, style: .time)
                        .font(.caption2)
                        .foregroundStyle(storyMuted)
                }
            }
        case .system:
            HStack {
                Spacer(minLength: 28)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.orange.opacity(0.9))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(storyCopy("モデル状態", "Model status"))
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(storyMuted)
                        Text(StoryRetryMetadata.removingMetadata(from: message.text))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(storyText.opacity(0.78))
                            .fixedSize(horizontal: false, vertical: true)
                        Button(storyCopy("もう一度試す", "Try again")) {
                            vm.retryLastMessage(for: message.id)
                        }
                        .font(.body.weight(.bold))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .frame(minHeight: 44)
                        if shouldOfferNAGISwitch(for: message) {
                            Button {
                                vm.generationModel = .b31
                                vm.retryLastMessage(for: message.id)
                            } label: {
                                Label(
                                    StoryGemma31BAPIService.shared.hasAPIKey
                                        ? storyCopy("NAGIで再試行", "Retry with NAGI")
                                        : storyCopy("NAGI APIキー未設定", "NAGI API key not set"),
                                    systemImage: "arrow.triangle.2.circlepath"
                                )
                                .font(.body.weight(.bold))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(!StoryGemma31BAPIService.shared.hasAPIKey)
                            .padding(.top, 4)
                            .frame(minHeight: 44)
                        }
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.orange.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.orange.opacity(0.18), lineWidth: 1)
                )
                Spacer(minLength: 28)
            }
        case .narrator:
            HStack {
                Spacer(minLength: 28)
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 3) {
                        Image(systemName: "decrease.quotelevel")
                            .font(.system(size: 14, weight: .semibold))
                        
                    }
                    .foregroundStyle(storyWarmAccent.opacity(0.78))
                    .frame(width: 34)
                    Text(message.text)
                        .font(.body.weight(.medium))
                        .foregroundStyle(storyText.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 620, alignment: .leading)
                Spacer(minLength: 28)
            }
        case let .cast(characterID, displayName):
            HStack(alignment: .top, spacing: 10) {
                characterAvatar(vm.characterIndex[characterID], size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    // アイコンの隣に発話者名を置き、誰の返答かをすぐ確認できるようにする。
                    Text(displayName)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(storyMuted)
                        .lineLimit(1)
                    Text(message.text)
                        .font(.body.weight(.medium))
                        .foregroundStyle(storyText.opacity(0.82))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(storyBubble)
                        )
                    Text(message.createdAt, style: .time)
                        .font(.caption2)
                        .foregroundStyle(storyMuted)
                }
                .frame(maxWidth: 620, alignment: .leading)
            }
            .frame(maxWidth: 680, alignment: .leading)
        }
    }

    private func isUnreadStoryMessage(_ message: StoryMessage) -> Bool {
        if case .cast = message.author {
            return true
        }
        return false
    }

    private func storyAccessibilityLabel(for message: StoryMessage) -> String {
        switch message.author {
        case .user:
            return storyCopy("あなた: \(message.text)", "You: \(message.text)")
        case .narrator:
            return storyCopy("ナレーション: \(message.text)", "Narration: \(message.text)")
        case let .cast(_, displayName):
            return "\(displayName): \(message.text)"
        case .system:
            let visibleText = StoryRetryMetadata.removingMetadata(from: message.text)
            return storyCopy("システム: \(visibleText)", "System: \(visibleText)")
        }
    }

    private func shouldOfferNAGISwitch(for message: StoryMessage) -> Bool {
        guard case .system = message.author else { return false }
        // エラー本文は表示言語で変わるため、文字列検索でバックエンドを
        // 推測しない。新形式は明示値、旧ストアのnilはローカル失敗を
        // 含む可能性があるため互換的に表示する。
        return message.retryBackend == nil || message.retryBackend == .local
    }

    @ViewBuilder
    private func characterAvatar(_ character: CharacterProfile?, size: CGFloat) -> some View {
        if let data = character?.avatarImageData, let image = storyChatPlatformImage(from: data) {
            Image(storyChatPlatformImage: image)
                .resizable()
                .scaledToFill()
                // 縦長の立ち絵を中央で切ると顔が消えるため、上端を優先して丸く切り抜く。
                .frame(width: size, height: size, alignment: .top)
                .clipped()
                .clipShape(Circle())
        } else if let key = character?.imageKey,
                  !key.isEmpty,
                  let image = storyChatPlatformImage(named: key) {
            Image(storyChatPlatformImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size, alignment: .top)
                .clipped()
                .clipShape(Circle())
        } else {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.62, green: 0.68, blue: 0.95), Color(red: 0.18, green: 0.21, blue: 0.35)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "person.fill")
                        .font(.system(size: max(12, size * 0.42), weight: .semibold))
                        .foregroundStyle(.white)
                )
        }
    }

    private func storyChatPlatformImage(from data: Data) -> StoryChatPlatformImage? {
        #if canImport(AppKit)
        return NSImage(data: data)
        #elseif canImport(UIKit)
        return UIImage(data: data)
        #else
        return nil
        #endif
    }

    // SwiftUIのImage("name")は未登録アセットをログに出すため、存在確認してから表示する。
    private func storyChatPlatformImage(named name: String) -> StoryChatPlatformImage? {
        #if canImport(AppKit)
        return NSImage(named: name)
        #elseif canImport(UIKit)
        return UIImage(named: name)
        #else
        return nil
        #endif
    }

    private var streamingPreview: some View {
        let status = service.streamingStatusText.nonEmpty
            ?? storyCopy("生成中…", "Generating…")
        let preview = service.streamingResponse
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let speaker = service.streamingSpeakerName?.trimmingCharacters(in: .whitespacesAndNewlines)

        return HStack(alignment: .top, spacing: 9) {
            ZStack {
                Circle()
                    .fill(storyPurple.opacity(0.22))
                    .frame(width: 30, height: 30)
                ProgressView()
                    .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(speaker?.nonEmpty ?? KizunaCopy.appName)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(storyText.opacity(0.88))
                    Text(status)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(storyMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if !preview.isEmpty, preview != "・・・", preview != "..." {
                    Text(preview)
                        .font(.body.weight(.medium))
                        .foregroundStyle(storyText.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(storyBubble)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(storyPurple.opacity(0.28), lineWidth: 1)
            )
            Spacer(minLength: 40)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(storyCopy("\(speaker?.nonEmpty ?? KizunaCopy.appName)が\(status)", "\(speaker?.nonEmpty ?? KizunaCopy.appName) is \(status)"))
        .accessibilityValue(Text(preview))
        .id("streaming-preview")
    }

    private var composer: some View {
        let isPreparing = vm.isPreparingSend
        let isGenerating = service.phase == .thinking
        let hasInterruptedTurn = vm.interruptedTurn != nil
        return HStack(spacing: 10) {
            TextField(
                "",
                text: $draft,
                prompt: Text(storyCopy("相手に伝える…", "Say something…")).foregroundStyle(storyMuted),
                axis: .vertical
            )
                .textFieldStyle(.plain)
                .foregroundStyle(storyText)
                .tint(.white)
                .focused($composerFocused)
                .lineLimit(1...4)
                .submitLabel(.send)
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .onSubmit(submit)
                .disabled(isPreparing || isGenerating || hasInterruptedTurn || service.hasPendingStoryCommitRetry || service.isRetryingAuxiliarySave)
            Button {
                if isPreparing || isGenerating {
                    vm.cancelGeneration()
                } else {
                    submit()
                }
            } label: {
                Image(systemName: isPreparing ? "hourglass" : (isGenerating ? "stop.fill" : "paperplane.fill"))
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 44, height: 44)
                    .background(
                        Circle().fill(
                            isPreparing || isGenerating || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Color.accentColor
                                : Color.white.opacity(0.24)
                        )
                    )
                    .overlay(Circle().stroke(Color.white.opacity(0.28), lineWidth: 1))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled((!isPreparing && !isGenerating && (hasInterruptedTurn || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                || service.hasPendingStoryCommitRetry
                || service.isRetryingAuxiliarySave)
            .accessibilityLabel(
                isPreparing
                    ? storyCopy("送信準備を停止", "Stop preparing to send")
                    : (isGenerating ? storyCopy("生成を停止", "Stop generating") : storyCopy("送信", "Send"))
            )
        }
        .padding(14)
        .background(storyPanel)
        .storyKeyboardDismissToolbar($composerFocused)
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              service.phase != .thinking,
              !vm.isPreparingSend,
              vm.interruptedTurn == nil else { return }
        guard selectedModelIsReady else {
            handleUnavailableModelBeforeSubmission()
            return
        }
        // 送信準備中の二重タップでは受付されないため、受理された時だけ入力を消す。
        guard vm.send(text) else { return }
        composerFocused = false
    }
}


private extension View {
    @ViewBuilder
    func storyKeyboardDismissToolbar(_ focused: FocusState<Bool>.Binding) -> some View {
        #if canImport(UIKit)
        self.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(storyCopy("閉じる", "Close keyboard")) { focused.wrappedValue = false }
            }
        }
        #else
        self
        #endif
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
