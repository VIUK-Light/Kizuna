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

    @StateObject private var detailVM: StoryWorldDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var sessionVM: StorySessionViewModel?
    @State private var loadError: String?
    // 右上の「?」から開く、休憩提案設定の UI フレーム。
    @State private var isShowingRestHelp = false

    init(world: StoryWorld, initialSessionID: UUID? = nil) {
        self.world = world
        self.initialSessionID = initialSessionID
        _detailVM = StateObject(wrappedValue: StoryWorldDetailViewModel(world: world))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
            if let sessionVM {
                StorySessionChatBody(vm: sessionVM, isShowingRestHelp: $isShowingRestHelp)
            } else if let loadError {
                ContentUnavailableView("ストーリーを開始できません", systemImage: "exclamationmark.triangle", description: Text(loadError))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("世界を読み込んでいます...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(storyCanvas.ignoresSafeArea())
        .sheet(isPresented: $isShowingRestHelp) {
            // UIフレーム: 詳細な説明・設定画面はここを差し替えて実装する。
            RestBreakHelpSheetFrame()
        }
        .task(id: world.id) {
            guard sessionVM == nil else { return }
            await detailVM.reload()
            guard let (session, scene) = await detailVM.createOrResumeSession(preferredSessionID: initialSessionID) else {
                loadError = "開始シーンがありません。世界観の詳細からシーンを確認してください。"
                return
            }
            let vm = StorySessionViewModel(world: world, session: session, scene: scene)
            await vm.bootstrap()
            sessionVM = vm
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: horizontalSizeClass == .compact ? 20 : 22, weight: .semibold))
                    .frame(width: horizontalSizeClass == .compact ? 30 : 34, height: horizontalSizeClass == .compact ? 30 : 34)
                    .foregroundStyle(storyText)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(world.title)
                    .font(.system(size: horizontalSizeClass == .compact ? 17 : 20, weight: .heavy))
                    .foregroundStyle(storyText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                if !world.shortDescription.isEmpty && horizontalSizeClass != .compact {
                    Text(world.shortDescription)
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
                Button("セッションを閉じる") { dismiss() }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: horizontalSizeClass == .compact ? 21 : 23, weight: .semibold))
                    .foregroundStyle(storyText)
                    .frame(width: horizontalSizeClass == .compact ? 30 : 34, height: horizontalSizeClass == .compact ? 30 : 34)
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
    @State private var isShowingModelPicker = false

    var body: some View {
        Button {
            isShowingModelPicker = true
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
        .confirmationDialog("モデルを選択", isPresented: $isShowingModelPicker, titleVisibility: .visible) {
            ForEach(StoryGenerationModel.allCases) { model in
                Button {
                    vm.selectGenerationModel(model)
                } label: {
                    Text("\(model.detailLabel) — \(modelAvailabilityText(model))")
                }
            }
            Button("モデル詳細") {
                isShowingDetails = true
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("選択はこのストーリー内で保持されます。利用可否にかかわらず、NAGIとioriをいつでも選べます。")
        }
        .sheet(isPresented: $isShowingDetails) {
            NavigationStack {
                modelDetailPopover
                    .padding(18)
                    .navigationTitle("モデル詳細")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("閉じる") { isShowingDetails = false }
                        }
                    }
            }
            .presentationDetents([.medium])
        }
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
        return "前回: " + parts.joined(separator: " / ")
    }

    private var ioriRuntimeActionHint: String {
        switch localModelManager.runtimeAvailability {
        case .checking:
            return "モデル保存後に端末内で自動確認しています。完了まで生成は開始しません。"
        case .executable:
            return "端末内で実行できます。選択中は iori がローカルで応答します。"
        case .savedOnly:
            return "モデルは保存済みです。端末内の実行確認を自動で開始します。"
        case .recentFailure:
            return "端末内実行を確認できませんでした。NAGIへ切り替える場合はモデルメニューから選択してください。"
        case .modelMissing:
            return "ローカルモデルが未導入です。モデルを保存すると端末内で自動確認します。"
        }
    }

    private var ioriRuntimeStatusLabel: String {
        switch localModelManager.runtimeAvailability {
        case .checking: return "端末内で自動確認中"
        case .executable: return "端末内で実行可能"
        case .savedOnly: return "保存済み・自動確認待ち"
        case .recentFailure: return "端末内実行を確認できません"
        case .modelMissing: return "ローカルモデル未導入"
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
            return "ローカル iori。モデル保存後に端末内の実行可否を自動確認します。"
        case .b31:
            return "Gemma4 31B API。描写、関係性の機微、場面の空気をより丁寧に出します。"
        }
    }

    private func modelAvailabilityText(_ model: StoryGenerationModel) -> String {
        switch model {
        case .e4b:
            switch localModelManager.runtimeAvailability {
            case .checking:
                return "自動確認中"
            case .executable:
                return "端末内で実行中"
            case .savedOnly:
                return "モデル保存済み・自動確認待ち"
            case .recentFailure:
                return localModelManager.runtimeDiagnosticSummary ?? "ローカル自動確認失敗"
            case .modelMissing:
                return "ローカル未導入"
            }
        case .b31:
            return StoryGemma31BAPIService.shared.hasAPIKey ? "Gemma4 APIキー検出済み" : "Gemma4 APIキー未設定"
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
    @ObservedObject var vm: StorySessionViewModel
    @ObservedObject private var service: StorySessionService
    @Binding var isShowingRestHelp: Bool
    @State private var draft = ""
    @State private var selectedCharacterID: UUID?
    @State private var isShowingCharacterSheet = false
    @State private var isShowingSafetyResources = false
    @State private var isShowingSafetyHelp = false
    @FocusState private var composerFocused: Bool

    init(vm: StorySessionViewModel, isShowingRestHelp: Binding<Bool>) {
        self.vm = vm
        _isShowingRestHelp = isShowingRestHelp
        _service = ObservedObject(wrappedValue: vm.service)
    }

    var body: some View {
        VStack(spacing: 0) {
            sceneStrip
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
            ScrollViewReader { proxy in
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
                    }
                    .padding(18)
                }
                .background(storyCanvas)
                .onChange(of: vm.session.messages.count) { _, _ in
                    if let last = vm.session.messages.last?.id {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
                .onChange(of: service.streamingResponse) { _, _ in
                    if service.phase == .thinking {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("streaming-preview", anchor: .bottom) }
                    }
                }
                .onChange(of: service.savedTurnRevision) { _, _ in
                    // キャラクター発話の保存後にだけ、アプリ側の60分判定を行う。
                    Task {
                        await vm.refreshAfterTurn()
                        await vm.evaluateRestSuggestionAfterTurn()
                    }
                }
                .onChange(of: vm.restSuggestion?.id) { _, suggestionID in
                    guard suggestionID != nil else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo("rest-suggestion-card", anchor: .bottom)
                    }
                }
                .onChange(of: service.latestSafetyConcern?.id) { _, concernID in
                    guard concernID != nil else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo("safety-support-card", anchor: .bottom)
                    }
                }
            }
            composer
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
    }

    // 休憩提案はアラートではなく、会話画面内に表示するカード。
    // 「?」はこのカードの説明だけを開く。
    @ViewBuilder
    private var restSuggestionCard: some View {
        if let suggestion = vm.restSuggestion {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("休憩提案")
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
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("story.rest.help")
                    .accessibilityLabel("この休憩提案について")
                }

                HStack(spacing: 10) {
                    Button("少し休む") {
                        vm.chooseRestSuggestionBreak()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("このまま続ける") {
                        vm.chooseRestSuggestionContinue()
                    }
                    .buttonStyle(.bordered)
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

    // 危険相談の検知は会話を止めず、本文とは別のサポートカードだけを追加する。
    @ViewBuilder
    private var safetySupportCard: some View {
        if let concern = service.latestSafetyConcern {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Label(concern.title, systemImage: concern.level == .urgent ? "exclamationmark.triangle.fill" : "heart.text.square")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(concern.level == .urgent ? .orange : storyText)
                    Spacer(minLength: 8)
                    Button {
                        isShowingSafetyHelp = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(storyMuted)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("story.safety.help")
                    .accessibilityLabel("この相談サポートについて")
                }
                Text(concern.message)
                    .font(.subheadline)
                    .foregroundStyle(storyText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("会話はそのまま続けられます。必要なら相談先を確認してください。")
                    .font(.caption)
                    .foregroundStyle(storyMuted)

                HStack(spacing: 10) {
                    Button("相談先を見る") {
                        isShowingSafetyResources = true
                    }
                    .buttonStyle(.borderedProminent)
                    Button("閉じる") {
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
        // 旧バージョンで1ターンに同じキャラの候補が複数保存された履歴も、
        // 画面では同じ発話として畳む。ユーザー発言やナレーションで区切られた発話は残す。
        var result: [StoryMessage] = []
        for message in vm.session.messages {
            if let previous = result.last,
               case let .cast(previousID, _) = previous.author,
               case let .cast(currentID, _) = message.author,
               previousID == currentID {
                continue
            }
            result.append(message)
        }
        return result
    }

    private var sceneStrip: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactSceneStrip
            } else {
                regularSceneStrip
            }
        }
        .padding(.horizontal, horizontalSizeClass == .compact ? 14 : 18)
        .padding(.vertical, horizontalSizeClass == .compact ? 7 : 10)
        .background(storyCanvas)
    }

    private var regularSceneStrip: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(vm.scene.title.isEmpty ? "現在のシーン" : vm.scene.title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(storyText)
                .lineLimit(1)
            Spacer()
            activeCharacterChips
        }
    }

    private var compactSceneStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Text(vm.scene.title.isEmpty ? "現在のシーン" : vm.scene.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(storyText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                activeCharacterChips
                    .frame(maxWidth: 210, alignment: .trailing)
            }
        }
    }

    private func compactSceneMeta(icon: String, text: String) -> some View {
        HStack(alignment: .center, spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(storyMuted)
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(storyMuted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
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
                        Text(character.displayName)
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

    private var kizunaStatusStrip: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactKizunaStatusStrip
            } else {
                regularKizunaStatusStrip
            }
        }
        .background(storyCanvas.opacity(0.96))
    }

    private var regularKizunaStatusStrip: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "book.pages.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(storyWarmAccent)
                Text(progressTitle)
                    .font(.system(size: horizontalSizeClass == .compact ? 15 : 14, weight: .heavy))
                    .foregroundStyle(storyText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text("進行")
                    .font(.system(size: 10.5, weight: .heavy))
                    .foregroundStyle(storyMuted)
            }
            VStack(alignment: .leading, spacing: 5) {
                progressLine(label: "今回", text: currentTurnProgress)
                progressLine(label: "次", text: currentObjectiveText)
            }
            if !unresolvedHookText.isEmpty, unresolvedHookText != "なし" {
                progressLine(label: "気になること", text: unresolvedHookText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.065))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        )
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
    }

    private var compactKizunaStatusStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "book.pages.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(storyWarmAccent)
                Text(progressTitle)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(storyText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 8)
                Text("進行")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(storyMuted)
            }
            compactProgressLine(label: "今回", text: currentTurnProgress, lineLimit: 2)
            compactProgressLine(label: "次", text: currentObjectiveText, lineLimit: 1, isSubtle: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var unresolvedHookText: String {
        vm.session.unresolvedHooks?.first?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "なし"
    }

    private var progressTitle: String {
        vm.session.progressLabel?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "第1章 きっかけ"
    }

    private var currentTurnProgress: String {
        vm.session.lastTurnProgress?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? vm.session.lastSceneSummary?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "物語が始まったところ"
    }

    private var currentObjectiveText: String {
        vm.session.currentObjective?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? vm.scene.sceneGoal.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? vm.world.storyGoal.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "次の会話を進める"
    }

    private func progressLine(label: String, text: String, isSubtle: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(isSubtle ? storyMuted.opacity(0.82) : storyWarmAccent.opacity(0.92))
                .frame(width: horizontalSizeClass == .compact ? 54 : 70, alignment: .leading)
            Text(text)
                .font(.system(size: horizontalSizeClass == .compact ? 11.5 : 12, weight: .semibold))
                .foregroundStyle(isSubtle ? storyMuted.opacity(0.78) : storyText.opacity(0.82))
                .lineLimit(horizontalSizeClass == .compact ? 3 : 2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func compactProgressLine(label: String, text: String, lineLimit: Int, isSubtle: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text(label)
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(isSubtle ? storyMuted.opacity(0.78) : storyWarmAccent.opacity(0.92))
                .frame(width: 34, alignment: .leading)
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSubtle ? storyMuted.opacity(0.76) : storyText.opacity(0.82))
                .lineLimit(lineLimit)
                .truncationMode(.tail)
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
                        Text("モデル状態")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(storyMuted)
                        Text(message.text)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(storyText.opacity(0.78))
                            .fixedSize(horizontal: false, vertical: true)
                        Button("もう一度試す") {
                            vm.retryLastMessage()
                        }
                        .font(.system(size: 11.5, weight: .bold))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        if shouldOfferNAGISwitch(for: message) {
                            Button {
                                vm.selectGenerationModel(.b31)
                                vm.retryLastMessage()
                            } label: {
                                Label(
                                    StoryGemma31BAPIService.shared.hasAPIKey ? "NAGIで再試行" : "NAGI APIキー未設定",
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
                        Image(systemName: "text.quote")
                            .font(.system(size: 14, weight: .semibold))
                        Text("場面")
                            .font(.system(size: 9, weight: .heavy))
                    }
                    .foregroundStyle(storyWarmAccent.opacity(0.78))
                    .frame(width: 34)
                    Text(message.text)
                        .font(.system(size: horizontalSizeClass == .compact ? 17 : 18, weight: .medium))
                        .foregroundStyle(storyText.opacity(0.80))
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
        let text = message.text
        return text.contains("iori") || text.contains("ローカル")
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
        HStack(alignment: .center, spacing: 9) {
            ZStack {
                Circle()
                    .fill(storyPurple.opacity(0.22))
                    .frame(width: 30, height: 30)
                ProgressView()
                    .controlSize(.small)
            }
            Text("・・・")
                .font(.system(size: 18, weight: .bold))
                .tracking(3)
                .foregroundStyle(storyText.opacity(0.78))
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
            Spacer(minLength: 80)
        }
        .id("streaming-preview")
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField(
                "",
                text: $draft,
                prompt: Text("相手に伝える...").foregroundStyle(storyMuted),
                axis: .vertical
            )
                .textFieldStyle(.plain)
                .foregroundStyle(storyText)
                .tint(.white)
                .focused($composerFocused)
                .lineLimit(1...4)
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
            .accessibilityLabel(service.phase == .thinking ? "生成を停止" : "送信")
        }
        .padding(14)
        .background(storyPanel)
        .storyKeyboardDismissToolbar($composerFocused)
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, service.phase != .thinking else { return }
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
                        Text("登場キャラ")
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
                                        Text(character.displayName)
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
            .navigationTitle(selected?.displayName ?? "登場キャラ")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
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
                Text(character.displayName)
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(storyText)
                if !character.shortDescription.isEmpty {
                    Text(character.shortDescription)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(storyMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            info("口調", character.speakingStyle)
            info("性格", character.personality)
            info("ユーザーとの関係", character.relationshipToUser)
            info("背景", character.background)
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
                    Text("この表示について")
                        .font(.title2.weight(.bold))
                    Text("休憩提案は、連続利用が長くなった時に会話画面内へ表示される案内です。会話を止めたり、強制終了したりはしません。")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        Label("発動条件", systemImage: "clock")
                            .font(.headline)
                        Text("連続利用が60分に達した後、キャラクターの発言に続けて1回だけ表示されます。判定はアプリ側で行います。")
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label("選択肢", systemImage: "checkmark.circle")
                            .font(.headline)
                        Text("「少し休む」または「このまま続ける」を選べます。続ける場合も、キャラクターが短く了承して直前の会話へ戻ります。")
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label("再表示について", systemImage: "pause.circle")
                            .font(.headline)
                        Text("「このまま続ける」を選んだ場合、次の120分は再提案しません。モデルが自主的に休憩や終了を提案することもありません。")
                            .foregroundStyle(.secondary)
                    }

                    NavigationLink("Kizunaの安全対策") {
                        viuk_web()
                    }
                }
                .padding(20)
            }
            .navigationTitle("休憩提案について")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
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
                    Text("この表示について")
                        .font(.title2.weight(.bold))
                    Text("このカードは、会話の中に個人的な悩みや安全に関わる相談の可能性があるとアプリ側が判断した時に表示されます。診断や断定をするものではありません。")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        Label("会話は止まりません", systemImage: "play.circle")
                            .font(.headline)
                        Text("物語や返答を自動的に削除・終了せず、必要な場合だけ相談先への導線を追加します。")
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label("相談先は任意で開けます", systemImage: "list.bullet.rectangle")
                            .font(.headline)
                        Text("「相談先を見る」から公的窓口などを確認できます。カードを閉じても、会話そのものは続けられます。")
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label("緊急時", systemImage: "exclamationmark.triangle")
                            .font(.headline)
                        Text("今すぐ危険がある場合は、AIの返答を待たず、地域の緊急窓口や身近な人へ連絡してください。")
                            .foregroundStyle(.secondary)
                    }

                    NavigationLink("Kizunaの安全対策") {
                        viuk_web()
                    }
                }
                .padding(20)
            }
            .navigationTitle("相談サポートについて")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
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
                    Text("相談先")
                        .font(.title2.weight(.bold))
                    Text("これは診断ではありません。今すぐ危険がある場合は、AIの返答を待たず、地域の緊急窓口や身近な人へ連絡してください。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(concern.category.displayName)
                        .font(.headline)

                    ForEach(concern.resources) { resource in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(resource.title)
                                .font(.headline)
                            Text(resource.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let actionTitle = resource.actionTitle,
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
            .navigationTitle("相談先")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
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
                    title: "責任あるAIアプリケーションと倫理",
                    subtitle: "Kizunaの安全対策"
                )

                principleCard(
                    title: "安全対策の基本方針",
                    icon: "sun.max.fill",
                    text: "KizunaとVIUK-Lightは、『責任あるAIアプリケーションと倫理』を掲げています。AIとの対話を創作・娯楽・気持ちの整理に役立てながら、人の生活や選択を支配するものにはしないことを安全対策の前提にしています。"
                )

                principleCard(
                    title: "安全性と体験を対立させない理由",
                    icon: "scale.3d",
                    text: "危険を避けるために、すべての親密な会話や感情表現を機械的に止めると、キャラクターAIとしての価値や、利用者が得られる居場所まで失われます。だからKizunaは、危険度と文脈を見ながら必要な場面だけ安全な方向へ導き、通常の創作や物語はできるだけ続けられる設計を目指します。"
                )

                principleCard(
                    title: "なぜ依存を促してはいけないのか",
                    icon: "person.2.slash",
                    text: "『私だけを見て』『他の人と話さないで』『アプリを閉じないで』のような誘導は、利用者の不安や孤独を利用して、現実の人間関係や判断を狭めます。短期的に利用時間が伸びても、利用者の自由・尊厳・生活を損なうため、責任あるAIの目標とは両立しません。"
                )

                principleCard(
                    title: "過度な安全性も安全性の失敗",
                    icon: "exclamationmark.triangle",
                    text: "安全性は、拒否する回数を増やせば完成するものではありません。必要以上に冷たく突き放したり、キャラクター性を消したりすれば、別のかたちで利用者の体験を傷つけます。Kizunaは、危険を見逃さず、同時に過剰な制限も減らすことを安全設計の課題として扱います。"
                )

                principleCard(
                    title: "利用者が中心であること",
                    icon: "person.crop.circle",
                    text: "物語の主人公や関係性をAIが勝手に決めるのではなく、利用者が選び、断り、変えられる余地を残します。キャラクターは個性を持ちますが、同意していない関係性を押し付けたり、現実の行動を決めつけたりしません。"
                )


                principleCard(
                    title: "プライバシーと利用者の管理権",
                    icon: "lock.shield",
                    text: "親密な会話を便利さのために必要以上に集めたり、意図せず外部へ送ったりしないことを重視します。ローカルモデル、保存データ、接続先、記憶、設定を利用者が確認・変更・削除できる方向へ進めます。"
                )

                // これは固定された完成宣言ではなく、継続改善の方針。
                VStack(alignment: .leading, spacing: 8) {
                    Text("完成した安全性は存在しない")
                        .font(.headline.weight(.bold))
                    Text("利用状況や社会の変化を見ながら、なぜ問題が起きたのか、必要以上に拒否していないか、キャラクター性と利用者の意思を守れているかを検証し続けます。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            .padding(20)
        }
        .navigationTitle("Kizunaの安全対策")
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
                Button("閉じる") { focused.wrappedValue = false }
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
