/*
仕様:
- 役割: StoryWorld の複数人チャット画面。現在の Session と Scene の初期値から
  activeCharacters を表示し、
  発話者名付きの会話として進行する。
- 制約: activeCharacters は StorySession 側の最大 3 名を正本として扱う。
- 構成: 会話本体は StorySessionChatBody.swift、説明シートは
  StorySupportSheets.swift、共通色・文言は StoryChatSupport.swift (#286)。
*/

import SwiftUI

struct StorySessionChatView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
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
        .onAppear {
            ContinuousUsageTracker.shared.enterActive()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                ContinuousUsageTracker.shared.enterActive()
            case .inactive, .background:
                ContinuousUsageTracker.shared.enterInactive()
            @unknown default:
                ContinuousUsageTracker.shared.enterInactive()
            }
        }
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
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(storyText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                if !displayedWorld.shortDescription.isEmpty && horizontalSizeClass != .compact {
                    Text(displayedWorld.shortDescription)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(storyMuted)
                        .lineLimit(2)
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

        }
        .padding(.horizontal, horizontalSizeClass == .compact ? 14 : 18)
        .padding(.vertical, horizontalSizeClass == .compact ? 7 : 13)
        .background(storyCanvas)
    }
}
