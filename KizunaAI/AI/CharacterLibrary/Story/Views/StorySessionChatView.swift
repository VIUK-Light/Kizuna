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
                StorySessionChatBody(vm: sessionVM)
            } else if let loadError {
                ContentUnavailableView("ストーリーを開始できません", systemImage: "exclamationmark.triangle", description: Text(loadError))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("世界を読み込んでいます...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(storyCanvas.ignoresSafeArea())
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
                .help(modelHelpText(model))
            }
            Divider()
            Button {
                isShowingDetails = true
            } label: {
                Label("モデル詳細", systemImage: "info.circle")
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
                Button {
                    localModelManager.recheckRuntimeAvailability()
                } label: {
                    Label(
                        localModelManager.runtimeAvailability == .checking ? "確認中..." : "ioriを起動確認",
                        systemImage: "checkmark.seal"
                    )
                    .font(.system(size: 11.5, weight: .bold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(localModelManager.runtimeAvailability == .checking)
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
            return "端末内で短い生成を走らせ、本当に実行できるか確認しています。"
        case .executable:
            return "self-check 済みです。選択中は iori が端末内で実行されます。"
        case .savedOnly:
            return "ファイル保存済みですが、まだ実行可能とは扱いません。起動確認を実行してください。"
        case .recentFailure:
            return "失敗理由を確認し、修正後に再度起動確認してください。NAGIへは自動切替しません。"
        case .modelMissing:
            return "ローカルモデルが未導入です。モデルを保存してから起動確認できます。"
        }
    }

    private func modelHelpText(_ model: StoryGenerationModel) -> String {
        "\(model.detailLabel): \(modelShortDescription(model))"
    }

    private func modelShortDescription(_ model: StoryGenerationModel) -> String {
        switch model {
        case .e4b:
            return "ローカル iori。self-check 成功済みの時だけ端末内で実行します。"
        case .b31:
            return "Gemma4 31B API。描写、関係性の機微、場面の空気をより丁寧に出します。"
        }
    }

    private func modelAvailabilityText(_ model: StoryGenerationModel) -> String {
        switch model {
        case .e4b:
            switch localModelManager.runtimeAvailability {
            case .checking:
                return "起動確認中"
            case .executable:
                return "端末内で実行中"
            case .savedOnly:
                return "モデル保存済み・起動未確認"
            case .recentFailure:
                return localModelManager.runtimeDiagnosticSummary ?? "ローカル起動失敗"
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
    @State private var draft = ""
    @State private var selectedCharacterID: UUID?
    @State private var isShowingCharacterSheet = false
    @FocusState private var composerFocused: Bool

    init(vm: StorySessionViewModel) {
        self.vm = vm
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
                    Task { await vm.refreshAfterTurn() }
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
    }

    private var visibleMessages: [StoryMessage] {
        var castTurns = Set<String>()
        return vm.session.messages.filter { message in
            guard case let .cast(characterID, _) = message.author else { return true }
            let second = Int(message.createdAt.timeIntervalSince1970)
            return castTurns.insert("\(characterID.uuidString)-\(second)").inserted
        }
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
            VStack(alignment: .leading, spacing: 3) {
                Text(vm.scene.title.isEmpty ? "現在のシーン" : vm.scene.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(storyText)
                HStack(spacing: 8) {
                    if !vm.scene.location.isEmpty {
                        Label(vm.scene.location, systemImage: "mappin.and.ellipse")
                    }
                    if !vm.scene.timeOfDay.isEmpty {
                        Label(vm.scene.timeOfDay, systemImage: "clock")
                    }
                    if !vm.scene.mood.isEmpty {
                        Label(vm.scene.mood, systemImage: "theatermasks")
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(storyMuted)
                .lineLimit(1)
            }
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
            HStack(spacing: 10) {
                if !vm.scene.location.isEmpty {
                    compactSceneMeta(icon: "mappin.and.ellipse", text: vm.scene.location)
                }
                if !vm.scene.timeOfDay.isEmpty {
                    compactSceneMeta(icon: "clock", text: vm.scene.timeOfDay)
                }
                if !vm.scene.mood.isEmpty {
                    compactSceneMeta(icon: "theatermasks", text: vm.scene.mood)
                }
                Spacer(minLength: 0)
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
                        if shouldOfferNAGISwitch(for: message) {
                            Button {
                                vm.generationModel = .b31
                            } label: {
                                Label(
                                    StoryGemma31BAPIService.shared.hasAPIKey ? "NAGIで続ける" : "NAGI APIキー未設定",
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
            HStack(alignment: .bottom, spacing: 9) {
                VStack(spacing: 4) {
                    Text(displayName)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(storyMuted)
                        .lineLimit(1)
                        .frame(maxWidth: 68)
                    characterAvatar(vm.characterIndex[characterID], fallbackName: displayName, size: 34)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(message.text)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(storyText.opacity(0.82))
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
                Spacer(minLength: 80)
            }
        }
    }

    private func shouldOfferNAGISwitch(for message: StoryMessage) -> Bool {
        guard case .system = message.author else { return false }
        let text = message.text
        return text.contains("iori") || text.contains("ローカル")
    }

    @ViewBuilder
    private func characterAvatar(_ character: CharacterProfile?, fallbackName: String = "?", size: CGFloat) -> some View {
        if let data = character?.avatarImageData, let image = storyChatPlatformImage(from: data) {
            Image(storyChatPlatformImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else if let key = character?.imageKey, !key.isEmpty {
            Image(key)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            let name = character.map { $0.displayName.isEmpty ? $0.name : $0.displayName } ?? fallbackName
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
                    Text(String(name.prefix(1)).isEmpty ? "?" : String(name.prefix(1)))
                        .font(.system(size: max(10, size * 0.4), weight: .bold))
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
                    service.cancel()
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
        draft = ""
        composerFocused = false
        vm.send(text)
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
        } else if let key = character.imageKey, !key.isEmpty {
            Image(key)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(colors: [storyPurple.opacity(0.75), Color.black.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(String(character.displayName.prefix(1)))
                    .font(.system(size: 56, weight: .heavy))
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
