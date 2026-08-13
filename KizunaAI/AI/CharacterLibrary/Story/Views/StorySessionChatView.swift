/*
仕様:
- 役割: StoryWorld の複数人チャット画面。現在の Scene と activeCharacters を表示し、
  発話者名付きの会話として進行する。
- 制約: activeCharacters は StoryScene 側の最大 3 名を尊重する。
*/

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
private typealias StoryChatPlatformImage = NSImage
#elseif canImport(UIKit)
private typealias StoryChatPlatformImage = UIImage
#endif

private extension Image {
    init(storyChatPlatformImage: StoryChatPlatformImage) {
        #if canImport(AppKit)
        self.init(nsImage: storyChatPlatformImage)
        #elseif canImport(UIKit)
        self.init(uiImage: storyChatPlatformImage)
        #else
        self.init(systemName: "person.crop.square")
        #endif
    }
}

private let storyCanvas = Color(red: 0.07, green: 0.07, blue: 0.08)
private let storyPanel = Color(red: 0.12, green: 0.12, blue: 0.13)
private let storyBubble = Color(red: 0.16, green: 0.16, blue: 0.17)
private let storyPurple = Color(red: 0.08, green: 0.56, blue: 0.52)
private let storyWarmAccent = Color(red: 0.93, green: 0.66, blue: 0.22)
private let storyText = Color.white.opacity(0.92)
private let storyMuted = Color.white.opacity(0.58)

struct StorySessionChatView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let world: StoryWorld
    let initialSessionID: UUID?
    let startsNewSession: Bool

    @StateObject private var detailVM: StoryWorldDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var sessionVM: StorySessionViewModel?
    @State private var loadError: String?
    /// A new-session request is consumed once. If bootstrap fails and the user
    /// retries, resume the session that was already persisted instead of
    /// creating another empty branch in the same world.
    @State private var resolvedSessionID: UUID?
    // 右上の「?」から開く、休憩提案設定の UI フレーム。
    @State private var isShowingRestHelp = false

    init(world: StoryWorld, initialSessionID: UUID? = nil, startsNewSession: Bool = false) {
        // Keep the raw persisted world at the session boundary.  Localized
        // copies are presentation-only and must never seed StorySession's
        // durable goal, summary, or first narration.
        self.world = world
        self.initialSessionID = initialSessionID
        self.startsNewSession = startsNewSession
        _detailVM = StateObject(wrappedValue: StoryWorldDetailViewModel(world: world))
    }

    private var displayedWorld: StoryWorld {
        world.localizedForCurrentLanguage
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
            if let sessionVM {
                StorySessionChatBody(vm: sessionVM, isShowingRestHelp: $isShowingRestHelp)
            } else if let loadError {
                VStack(spacing: 12) {
                    ContentUnavailableView(
                        storyCopy("ストーリーを開始できません", "Unable to start the story"),
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )
                    Button {
                        Task { @MainActor in await startSession() }
                    } label: {
                        Label(storyCopy("もう一度読み込む", "Load again"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView(storyCopy("世界を読み込んでいます…", "Loading the story…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(storyCanvas.ignoresSafeArea())
        // 戻る操作だけでなく、親のNavigationStack/sheetから実際に画面が
        // 消えた場合も、旧セッションへの遅延保存を止める最後の安全網にする。
        .onDisappear {
            sessionVM?.cancelGeneration()
        }
        .sheet(isPresented: $isShowingRestHelp) {
            // UIフレーム: 詳細な説明・設定画面はここを差し替えて実装する。
            RestBreakHelpSheetFrame()
        }
        .task(id: world.id) { await startSession() }
    }

    @MainActor
    private func startSession() async {
        guard sessionVM == nil else { return }
        loadError = nil
        await detailVM.reload()
        if detailVM.castLoadFailed || detailVM.sessionLoadFailed || detailVM.sceneLoadFailed || detailVM.characterLoadFailed {
            loadError = storyCopy(
                "ストーリーの保存データを読み込めませんでした。データを空として扱わず、再試行してください。",
                "The story data could not be loaded. It was not treated as empty; try again."
            )
            return
        }
        guard !detailVM.cast.isEmpty else {
            loadError = storyCopy(
                "このストーリーにはキャストが設定されていません。詳細画面からキャラクターを追加してください。",
                "This story has no cast. Add at least one character from the story details before starting it."
            )
            return
        }
        let preferredSessionID = resolvedSessionID ?? initialSessionID
        guard let (session, scene) = await detailVM.createOrResumeSession(
            preferredSessionID: preferredSessionID,
            forceNew: startsNewSession && resolvedSessionID == nil
        ) else {
            loadError = storyCopy(
                detailVM.sessionSaveFailed
                    ? "セッションを保存できませんでした。保存先を確認してから再試行してください。"
                    : "開始シーンがありません。世界観の詳細からシーンを確認してください。",
                detailVM.sessionSaveFailed
                    ? "The story session could not be saved. Check storage and try again."
                    : "This story has no opening scene. Add one from the story details."
            )
            return
        }
        resolvedSessionID = session.id
        let vm = StorySessionViewModel(world: world, session: session, scene: scene)
        await vm.bootstrap()
        if let bootstrapError = vm.bootstrapError {
            loadError = bootstrapError
            return
        }
        sessionVM = vm
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                sessionVM?.cancelGeneration()
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: horizontalSizeClass == .compact ? 20 : 22, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(storyText)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayedWorld.title)
                    .font(.system(size: horizontalSizeClass == .compact ? 17 : 20, weight: .heavy))
                    .foregroundStyle(storyText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                if !displayedWorld.shortDescription.isEmpty && horizontalSizeClass != .compact {
                    Text(displayedWorld.shortDescription)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(storyMuted)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)

            // モデル選択をハンバーガーメニューの中に隠さない。
            // 以前は StoryGenerationModelPill が定義されているだけで画面に挿入されておらず、
            // NAGIを選ぶ導線が見えない状態になっていた。
            if let sessionVM {
                StoryGenerationModelPill(vm: sessionVM)
            }

            Menu {
                Button(storyCopy("セッションを閉じる", "Close session")) {
                    sessionVM?.cancelGeneration()
                    dismiss()
                }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: horizontalSizeClass == .compact ? 21 : 23, weight: .semibold))
                    .foregroundStyle(storyText)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, horizontalSizeClass == .compact ? 14 : 18)
        .padding(.vertical, horizontalSizeClass == .compact ? 7 : 13)
        .background(storyCanvas)
    }
}

private struct StoryGenerationModelPill: View {
    @ObservedObject var vm: StorySessionViewModel
    @ObservedObject private var localModelManager = LocalAssistantModelManager.shared
    @State private var isShowingDetails = false

    var body: some View {
        Menu {
            ForEach(StoryGenerationModel.allCases) { model in
                Button {
                    vm.generationModel = model
                } label: {
                    Label(
                        "\(model.detailLabel) - \(modelAvailabilityText(model))",
                        systemImage: vm.generationModel == model ? "checkmark" : "cpu"
                    )
                }
                // 選択後に初めて失敗させると、未導入の iori や API キー未設定の
                // NAGI が「使えるモデル」として保存されてしまう。状態表示は残しつつ、
                // 送信可能なモデルだけを選択できるようにする。
                .disabled(!isModelSelectable(model))
                .help(modelHelpText(model))
            }
            Divider()
                Button {
                    isShowingDetails = true
                } label: {
                    Label(storyCopy("モデル詳細", "Model details"), systemImage: "info.circle")
            }
        } label: {
            HStack(spacing: 5) {
                Text(vm.generationModel.displayName)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .allowsTightening(true)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(storyText)
            .frame(width: 88, height: 34, alignment: .center)
            .background(Capsule().fill(Color.white.opacity(0.16)))
        }
        .buttonStyle(.plain)
        .help(modelHelpText(vm.generationModel))
        .sheet(isPresented: $isShowingDetails) {
            NavigationStack {
                modelDetailPopover
                    .padding(18)
                    .navigationTitle(storyCopy("モデル詳細", "Model details"))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(storyCopy("閉じる", "Close")) { isShowingDetails = false }
                        }
                    }
            }
            .presentationDetents([.medium])
        }
        .onAppear(perform: selectUsableModelIfNeeded)
        .onChange(of: localModelManager.runtimeAvailability) { _, _ in
            selectUsableModelIfNeeded()
        }
    }

    private func isModelSelectable(_ model: StoryGenerationModel) -> Bool {
        switch model {
        case .e4b:
            return localModelManager.runtimeAvailability == .executable
        case .b31:
            return StoryGemma31BAPIService.shared.hasAPIKey
        }
    }

    private func selectUsableModelIfNeeded() {
        guard !isModelSelectable(vm.generationModel),
              let fallback = StoryGenerationModel.allCases.first(where: { isModelSelectable($0) }) else {
            return
        }
        vm.generationModel = fallback
    }

    private var modelDetailPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(vm.generationModel.detailLabel)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.primary)
            Text(modelShortDescription(vm.generationModel))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(modelAvailabilityText(vm.generationModel))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(modelAvailabilityColor(vm.generationModel))
                .fixedSize(horizontal: false, vertical: true)
            if let lastBackendStatus {
                Text(lastBackendStatus)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if vm.generationModel == .e4b {
                Divider().opacity(0.35)
                Label(
                    ioriRuntimeStatusLabel,
                    systemImage: ioriRuntimeStatusIcon
                )
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(modelAvailabilityColor(.e4b))
                Text(ioriRuntimeActionHint)
                    .font(.system(size: 10, weight: .medium))
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
        let backend = vm.session.lastUsedBackendName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [selected, backend].compactMap { value -> String? in
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
            return StoryGemma31BAPIService.shared.hasAPIKey
                ? storyCopy("Gemma4 APIキー検出済み", "Gemma4 API key detected")
                : storyCopy("Gemma4 APIキー未設定", "Gemma4 API key not set")
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
            return StoryGemma31BAPIService.shared.hasAPIKey ? .green : .orange
        }
    }
}

private struct StorySessionChatBody: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ObservedObject var vm: StorySessionViewModel
    @ObservedObject private var service: StorySessionService
    @ObservedObject private var localModelManager: LocalAssistantModelManager
    @Binding var isShowingRestHelp: Bool
    @State private var draft = ""
    @State private var selectedCharacterID: UUID?
    @State private var isShowingCharacterSheet = false
    @State private var isShowingSafetyResources = false
    @State private var isShowingSafetyHelp = false
    @State private var unavailableModelMessage = ""
    @State private var isShowingUnavailableModelAlert = false
    @State private var isStoryChatNearLatest = true
    @State private var unreadStoryMessageCount = 0
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
                                ForEach(visibleMessages) { message in
                                    messageRow(message)
                                        .id(message.id)
                                }
                                if service.phase == .thinking {
                                    streamingPreview
                                }
                                // 最新のキャラクター発話の後ろに、会話の一部として表示する。
                                restSuggestionCard
                                safetySupportCard
                                runtimeNoticeCard
                            }
                            .padding(18)
                        }
                        .background(storyCanvas)
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
                            if isStoryChatNearLatest {
                                if let last = vm.session.messages.last?.id {
                                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
                                }
                            } else {
                                unreadStoryMessageCount += 1
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
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("streaming-preview", anchor: .bottom) }
                        }
                        .onChange(of: service.savedTurnRevision) { _, _ in
                            // キャラクター発話の保存後にだけ、アプリ側の60分判定を行う。
                            Task {
                                await vm.refreshAfterTurn()
                                await vm.evaluateRestSuggestionAfterTurn()
                            }
                        }
                        .onChange(of: vm.restSuggestion?.id) { _, suggestionID in
                            guard suggestionID != nil, isStoryChatNearLatest else { return }
                            withAnimation(.easeOut(duration: 0.25)) {
                                proxy.scrollTo("rest-suggestion-card", anchor: .bottom)
                            }
                        }
                        .onChange(of: service.latestSafetyConcern?.id) { _, concernID in
                            guard concernID != nil, isStoryChatNearLatest else { return }
                            withAnimation(.easeOut(duration: 0.25)) {
                                proxy.scrollTo("safety-support-card", anchor: .bottom)
                            }
                        }
                        .onChange(of: service.latestRuntimeNotice?.id) { _, noticeID in
                            guard noticeID != nil, isStoryChatNearLatest else { return }
                            withAnimation(.easeOut(duration: 0.25)) {
                                proxy.scrollTo("runtime-notice-card", anchor: .bottom)
                            }
                        }

                        if !isStoryChatNearLatest {
                            Button {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    if let last = vm.session.messages.last?.id {
                                        proxy.scrollTo(last, anchor: .bottom)
                                    } else {
                                        proxy.scrollTo("streaming-preview", anchor: .bottom)
                                    }
                                }
                                isStoryChatNearLatest = true
                                unreadStoryMessageCount = 0
                            } label: {
                                Label(
                                    unreadStoryMessageCount > 0
                                        ? "\(unreadStoryMessageCount) " + storyCopy("新しい発言", "new messages")
                                        : storyCopy("最新へ", "Latest"),
                                    systemImage: "arrow.down"
                                )
                                .font(.system(size: 11, weight: .bold))
                                .padding(.horizontal, 11)
                                .padding(.vertical, 8)
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
                    .disabled(vm.isSavingRestAcknowledgement)

                    Button(storyCopy("このまま続ける", "Continue")) {
                        vm.chooseRestSuggestionContinue()
                    }
                    .buttonStyle(.bordered)
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
            .transition(.move(edge: .top).combined(with: .opacity))
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
                    Text(storyCopy("モデル状態", "Model status"))
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(storyMuted)
                    Text(notice.text)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(storyText.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button(storyCopy("もう一度試す", "Try again")) {
                            _ = vm.retryRuntimeNotice(notice)
                        }
                        .font(.system(size: 11.5, weight: .bold))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
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
                                .font(.system(size: 11.5, weight: .bold))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
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
                    Button(storyCopy("閉じる", "Dismiss")) {
                        service.dismissSafetyConcern()
                    }
                    .buttonStyle(.bordered)
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
            .transition(.move(edge: .top).combined(with: .opacity))
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
                Text(vm.scene.title.isEmpty ? storyCopy("現在のシーン", "Current scene") : vm.scene.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(storyText)
                    .lineLimit(1)
                Spacer()
                activeCharacterChips
            }
            sceneVisual(availableHeight: availableHeight)
        }
    }

    private func compactSceneStrip(availableHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Text(vm.scene.title.isEmpty ? storyCopy("現在のシーン", "Current scene") : vm.scene.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(storyText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .layoutPriority(1)
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
                            .font(.system(size: 10.5, weight: .bold))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(selectedCharacterID == character.id ? storyPurple.opacity(0.42) : Color.white.opacity(0.10)))
                    .overlay(Capsule().stroke(selectedCharacterID == character.id ? storyPurple.opacity(0.78) : Color.clear, lineWidth: 1))
                    .foregroundStyle(storyText)
                }
                .buttonStyle(.plain)
            }
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ message: StoryMessage) -> some View {
        switch message.author {
        case .user:
            HStack {
                Spacer(minLength: 80)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(message.text)
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(storyPurple)
                        )
                    Text(message.createdAt, style: .time)
                        .font(.system(size: 10))
                        .foregroundStyle(storyMuted.opacity(0.72))
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
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(storyMuted)
                        Text(StoryRetryMetadata.removingMetadata(from: message.text))
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(storyText.opacity(0.78))
                            .fixedSize(horizontal: false, vertical: true)
                        Button(storyCopy("もう一度試す", "Try again")) {
                            vm.retryLastMessage(for: message.id)
                        }
                        .font(.system(size: 11.5, weight: .bold))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
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
                                .font(.system(size: 11.5, weight: .bold))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(!StoryGemma31BAPIService.shared.hasAPIKey)
                            .padding(.top, 4)
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
                        .font(.system(size: horizontalSizeClass == .compact ? 17 : 18, weight: .medium))
                        .foregroundStyle(storyText.opacity(0.50))
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
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(storyMuted)
                        .lineLimit(1)
                    Text(message.text)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(storyText.opacity(0.82))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(storyBubble)
                        )
                    Text(message.createdAt, style: .time)
                        .font(.system(size: 10))
                        .foregroundStyle(storyMuted.opacity(0.72))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
                    Text(speaker?.nonEmpty ?? storyCopy("kizuna", "kizuna"))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(storyText.opacity(0.88))
                    Text(status)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(storyMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if !preview.isEmpty, preview != "・・・", preview != "..." {
                    Text(preview)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(storyText.opacity(0.78))
                        .lineLimit(4)
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
        .accessibilityLabel(storyCopy("\(speaker ?? "kizuna")が\(status)", "\(speaker ?? "kizuna") is \(status)"))
        .id("streaming-preview")
    }

    private var composer: some View {
        HStack(spacing: 10) {
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
            Button {
                if service.phase == .thinking {
                    vm.cancelGeneration()
                } else {
                    submit()
                }
            } label: {
                Image(systemName: service.phase == .thinking ? "stop.fill" : "paperplane.fill")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 42, height: 42)
                    .background(
                        Circle().fill(
                            service.phase == .thinking || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Color.accentColor
                                : Color.white.opacity(0.24)
                        )
                    )
                    .overlay(Circle().stroke(Color.white.opacity(0.28), lineWidth: 1))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(service.phase != .thinking && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(service.phase == .thinking ? storyCopy("生成を停止", "Stop generating") : storyCopy("送信", "Send"))
        }
        .padding(14)
        .background(storyPanel)
        .storyKeyboardDismissToolbar($composerFocused)
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, service.phase != .thinking else { return }
        guard selectedModelIsReady else {
            handleUnavailableModelBeforeSubmission()
            return
        }
        // 送信準備中の二重タップでは受付されないため、受理された時だけ入力を消す。
        guard vm.send(text) else { return }
        draft = ""
        composerFocused = false
    }
}

private struct StoryCharacterSpotlightSheet: View {
    let characters: [CharacterProfile]
    let selectedCharacterID: UUID?
    var onSelect: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    private var selected: CharacterProfile? {
        characters.first(where: { $0.id == selectedCharacterID }) ?? characters.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let selected {
                        StoryCharacterHero(character: selected)
                    }
                    if characters.count > 1 {
                        Text(storyCopy("登場キャラ", "Characters"))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            ForEach(characters) { character in
                                Button {
                                    onSelect(character.id)
                                } label: {
                                    VStack(spacing: 7) {
                                        StoryCharacterHero.image(for: character)
                                            .frame(width: 72, height: 72)
                                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                        Text(character.visibleName)
                                            .font(.system(size: 11, weight: .bold))
                                            .lineLimit(1)
                                    }
                                    .padding(7)
                                    .background(
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .fill(character.id == selected?.id ? storyPurple.opacity(0.18) : Color.primary.opacity(0.045))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .stroke(character.id == selected?.id ? storyPurple.opacity(0.72) : Color.clear, lineWidth: 2)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(18)
            }
            .navigationTitle(selected?.visibleName ?? storyCopy("登場キャラ", "Characters"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(storyCopy("閉じる", "Close")) { dismiss() }
                }
            }
        }
    }
}

private struct StoryCharacterHero: View {
    let character: CharacterProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Self.image(for: character)
                .frame(maxWidth: .infinity)
                .frame(height: 360)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 5) {
                Text(character.visibleName)
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(storyText)
                if !character.shortDescription.isEmpty {
                    Text(character.shortDescription)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(storyMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            info(storyCopy("口調", "Speaking style"), character.speakingStyle)
            info(storyCopy("性格", "Personality"), character.personality)
            info(storyCopy("ユーザーとの関係", "Relationship to you"), character.relationshipToUser)
            info(storyCopy("背景", "Background"), character.background)
        }
    }

    @ViewBuilder
    static func image(for character: CharacterProfile) -> some View {
        if let data = character.avatarImageData, let image = storySpotlightPlatformImage(from: data) {
            Image(storyChatPlatformImage: image)
                .resizable()
                .scaledToFill()
        } else if let key = character.imageKey,
                  !key.isEmpty,
                  let image = storySpotlightPlatformImage(named: key) {
            Image(storyChatPlatformImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(colors: [storyPurple.opacity(0.75), Color.black.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "person.fill")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }

    private func info(_ title: String, _ value: String) -> some View {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return Group {
            if !trimmed.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(trimmed)
                        .font(.system(size: 14, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private func storySpotlightPlatformImage(from data: Data) -> StoryChatPlatformImage? {
    #if canImport(AppKit)
    return NSImage(data: data)
    #elseif canImport(UIKit)
    return UIImage(data: data)
    #else
    return nil
    #endif
}

private func storySpotlightPlatformImage(named name: String) -> StoryChatPlatformImage? {
    #if canImport(AppKit)
    return NSImage(named: name)
    #elseif canImport(UIKit)
    return UIImage(named: name)
    #else
    return nil
    #endif
}

/// 休憩提案の別画面用 SwiftUI フレーム。
/// 実際の説明・設定 UI はこの View を差し替えて実装する。
struct RestBreakHelpSheetFrame: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                        Text(storyCopy("この表示について", "About this notice"))
                        .font(.title2.weight(.bold))
                    Text(storyCopy(
                        "休憩提案は、連続利用が長くなった時に会話画面内へ表示される案内です。会話を止めたり、強制終了したりはしません。",
                        "A break suggestion appears in the conversation after an extended session. It never stops or force-closes the conversation."
                    ))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        Label(storyCopy("発動条件", "When it appears"), systemImage: "clock")
                            .font(.headline)
                        Text(storyCopy(
                            "連続利用が60分に達した後、キャラクターの発言に続けて1回だけ表示されます。判定はアプリ側で行います。",
                            "After 60 minutes of continuous use, it appears once after a character message. The app, not the model, decides when to show it."
                        ))
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label(storyCopy("選択肢", "Your choices"), systemImage: "checkmark.circle")
                            .font(.headline)
                        Text(storyCopy(
                            "「少し休む」または「このまま続ける」を選べます。続ける場合も、キャラクターが短く了承して直前の会話へ戻ります。",
                            "Choose to take a short break or continue. If you continue, a brief acknowledgement returns you to the conversation."
                        ))
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label(storyCopy("再表示について", "Showing it again"), systemImage: "pause.circle")
                            .font(.headline)
                        Text(storyCopy(
                            "「このまま続ける」を選んだ場合、次の120分は再提案しません。モデルが自主的に休憩や終了を提案することもありません。",
                            "If you continue, the app will not suggest another break for 120 minutes. The model cannot decide to end the conversation on its own."
                        ))
                            .foregroundStyle(.secondary)
                    }

                    NavigationLink(storyCopy("安全対策", "Safety principles")) {
                        viuk_web()
                    }
                }
                .padding(20)
            }
            .navigationTitle(storyCopy("休憩提案について", "About break suggestions"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(storyCopy("閉じる", "Close")) { dismiss() }
                }
            }
        }
    }
}

/// 危険相談サポートカードの「？」から開く説明画面。
struct SafetyConcernHelpSheetFrame: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(storyCopy("この表示について", "About this notice"))
                        .font(.title2.weight(.bold))
                    Text(storyCopy(
                        "このカードは、会話の中に個人的な悩みや安全に関わる相談の可能性があるとアプリ側が判断した時に表示されます。診断や断定をするものではありません。",
                        "This card appears when the app detects a possible personal or safety-related concern. It is not a diagnosis or a conclusion."
                    ))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        Label(storyCopy("会話は止まりません", "The conversation continues"), systemImage: "play.circle")
                            .font(.headline)
                        Text(storyCopy(
                            "物語や返答を自動的に削除・終了せず、必要な場合だけ相談先への導線を追加します。",
                            "The app does not automatically delete or end the story. It only adds an optional path to support when needed."
                        ))
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label(storyCopy("相談先は任意で開けます", "Support is optional"), systemImage: "list.bullet.rectangle")
                            .font(.headline)
                        Text(storyCopy(
                            "「相談先を見る」から公的窓口などを確認できます。カードを閉じても、会話そのものは続けられます。",
                            "Use View support resources to see public services. Dismissing this card does not stop the conversation."
                        ))
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label(storyCopy("緊急時", "If you are in immediate danger"), systemImage: "exclamationmark.triangle")
                            .font(.headline)
                        Text(storyCopy(
                            "今すぐ危険がある場合は、AIの返答を待たず、地域の緊急窓口や身近な人へ連絡してください。",
                            "If there is immediate danger, contact local emergency services or someone you trust instead of waiting for an AI reply."
                        ))
                            .foregroundStyle(.secondary)
                    }

                    NavigationLink(storyCopy("安全対策", "Safety principles")) {
                        viuk_web()
                    }
                }
                .padding(20)
            }
            .navigationTitle(storyCopy("相談サポートについて", "About support") )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(storyCopy("閉じる", "Close")) { dismiss() }
                }
            }
        }
    }
}

/// 検知後に利用者が任意で開く相談先一覧。会話を閉じたり、自動発信したりしない。
struct SafetySupportSheet: View {
    let concern: SafetyConcern
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(storyCopy("相談先", "Support resources"))
                        .font(.title2.weight(.bold))
                    Text(storyCopy(
                        "これは診断ではありません。今すぐ危険がある場合は、AIの返答を待たず、地域の緊急窓口や身近な人へ連絡してください。",
                        "This is not a diagnosis. If there is immediate danger, contact local emergency services or someone you trust instead of waiting for an AI reply."
                    ))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(concern.category.localizedDisplayName)
                        .font(.headline)

                    ForEach(concern.resources) { resource in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(resource.localizedTitle)
                                .font(.headline)
                            Text(resource.localizedDetail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let actionTitle = resource.localizedActionTitle,
                               let urlString = resource.urlString,
                               let url = URL(string: urlString) {
                                Link(actionTitle, destination: url)
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(20)
            }
            .navigationTitle(storyCopy("相談先", "Support resources"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(storyCopy("閉じる", "Close")) { dismiss() }
                }
            }
        }
    }
}

struct viuk_web: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // 安全対策ページの位置づけを最初に明示する。
                pageHeader(
                    title: storyCopy("責任あるAIアプリケーションと倫理", "Responsible AI and ethics"),
                    subtitle: storyCopy("kizunaの安全対策", "kizuna safety principles")
                )

                principleCard(
                    title: storyCopy("安全対策の基本方針", "Our safety approach"),
                    icon: "sun.max.fill",
                    text: storyCopy(
                        "kizunaとVIUK-Lightは、『責任あるAIアプリケーションと倫理』を掲げています。AIとの対話を創作・娯楽・気持ちの整理に役立てながら、人の生活や選択を支配するものにはしないことを安全対策の前提にしています。",
                        "kizuna and VIUK-Light aim for responsible AI and ethics. Conversation can support creativity, entertainment, and reflection without controlling a person's life or choices."
                    )
                )

                principleCard(
                    title: storyCopy("安全性と体験を対立させない理由", "Safety and a useful experience"),
                    icon: "scale.3d",
                    text: storyCopy(
                        "危険を避けるために、すべての親密な会話や感情表現を機械的に止めると、キャラクターAIとしての価値や、利用者が得られる居場所まで失われます。だからkizunaは、危険度と文脈を見ながら必要な場面だけ安全な方向へ導き、通常の創作や物語はできるだけ続けられる設計を目指します。",
                        "Blocking every intimate conversation or emotion would remove the value of character AI and the sense of space it can provide. kizuna considers context and risk, adds guidance only when needed, and keeps ordinary creative stories moving."
                    )
                )

                principleCard(
                    title: storyCopy("なぜ依存を促してはいけないのか", "Why we avoid dependency cues"),
                    icon: "person.2.slash",
                    text: storyCopy(
                        "『私だけを見て』『他の人と話さないで』『アプリを閉じないで』のような誘導は、利用者の不安や孤独を利用して、現実の人間関係や判断を狭めます。短期的に利用時間が伸びても、利用者の自由・尊厳・生活を損なうため、責任あるAIの目標とは両立しません。",
                        "Prompts such as “only talk to me” or “don't close the app” exploit anxiety or loneliness and narrow real-world relationships and choices. Longer short-term usage is not worth sacrificing freedom, dignity, or everyday life."
                    )
                )

                principleCard(
                    title: storyCopy("過度な安全性も安全性の失敗", "Overblocking is also a safety failure"),
                    icon: "exclamationmark.triangle",
                    text: storyCopy(
                        "安全性は、拒否する回数を増やせば完成するものではありません。必要以上に冷たく突き放したり、キャラクター性を消したりすれば、別のかたちで利用者の体験を傷つけます。kizunaは、危険を見逃さず、同時に過剰な制限も減らすことを安全設計の課題として扱います。",
                        "Safety is not achieved by increasing refusals. A cold or characterless response can harm the experience in another way. kizuna works to catch real risks while reducing unnecessary restrictions."
                    )
                )

                principleCard(
                    title: storyCopy("利用者が中心であること", "Keep the user in control"),
                    icon: "person.crop.circle",
                    text: storyCopy(
                        "物語の主人公や関係性をAIが勝手に決めるのではなく、利用者が選び、断り、変えられる余地を残します。キャラクターは個性を持ちますが、同意していない関係性を押し付けたり、現実の行動を決めつけたりしません。",
                        "The AI should not decide the protagonist or relationships for you. You can choose, decline, or change them. Characters have personality, but they do not impose an unchosen relationship or dictate real-world actions."
                    )
                )


                principleCard(
                    title: storyCopy("プライバシーと利用者の管理権", "Privacy and user control"),
                    icon: "lock.shield",
                    text: storyCopy(
                        "親密な会話を便利さのために必要以上に集めたり、意図せず外部へ送ったりしないことを重視します。ローカルモデル、保存データ、接続先、記憶、設定を利用者が確認・変更・削除できる方向へ進めます。",
                        "We avoid collecting intimate conversations beyond what is needed or sending them outside the device unexpectedly. Local models, saved data, connections, memories, and settings should remain visible, changeable, and deletable by the user."
                    )
                )

                // これは固定された完成宣言ではなく、継続改善の方針。
                VStack(alignment: .leading, spacing: 8) {
                    Text(storyCopy("完成した安全性は存在しない", "Safety is never finished"))
                        .font(.headline.weight(.bold))
                    Text(storyCopy(
                        "利用状況や社会の変化を見ながら、なぜ問題が起きたのか、必要以上に拒否していないか、キャラクター性と利用者の意思を守れているかを検証し続けます。",
                        "As usage and society change, we keep checking why problems occur, whether we over-refuse, and whether the character and the user's intent remain protected."
                    ))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            .padding(20)
        }
        .navigationTitle(storyCopy("kizunaの安全対策", "kizuna safety principles"))
    }

    // 説明ページ内の見出しを統一するための小さなUI部品。
    private func pageHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title2.weight(.bold))
            Text(subtitle)
                .font(.headline)
                .foregroundStyle(.tint)
        }
    }

    // 目標・理由を同じカード形式で読みやすく表示する。
    private func principleCard(title: String, icon: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline.weight(.bold))
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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

private func storyCopy(_ japanese: String, _ english: String) -> String {
    KizunaCopy.text(japanese: japanese, english: english)
}
