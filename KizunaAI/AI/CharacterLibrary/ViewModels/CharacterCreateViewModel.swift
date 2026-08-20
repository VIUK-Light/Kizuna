/*
仕様:
- 役割: CharacterCreateView の draft 編集と保存フロー (SafetyPipeline.evaluateCharacter 経由)。
- 主な型: `CharacterCreateViewModel`, `CharacterCreateState`.
- 編集ポイント: バリデーション、テンプレ適用、保存時の Safety 反応分岐。
*/

import Foundation
import Combine

enum CharacterCreateState: Equatable {
    case editing                // 通常編集
    case validating             // SafetyPipeline 実行中
    case warned(SafetyDecision) // .warn 表示中、ユーザー確認で保存
    case blocked(SafetyDecision) // .block / .requireEdit ─ 修正必須
    case saved(CharacterProfile)
}

@MainActor
final class CharacterCreateViewModel: ObservableObject {
    @Published var draft: CharacterProfile {
        didSet { draftRevision &+= 1 }
    }
    @Published var state: CharacterCreateState = .editing
    @Published var availableTemplates: [CharacterTemplate] = []

    private let characterRepo: CharacterRepository
    private let templateRepo: TemplateRepository
    private let safetyPipeline: SafetyPipeline
    /// Safety evaluation and persistence are asynchronous.  Keep an operation
    /// token plus the draft revision so a stale completion can never save an
    /// earlier snapshot after a newer edit or save attempt.
    private var saveOperationID: UUID?
    private var draftRevision: UInt = 0

    init(
        existing: CharacterProfile? = nil,
        characterRepo: CharacterRepository? = nil,
        templateRepo: TemplateRepository? = nil,
        safetyPipeline: SafetyPipeline? = nil
    ) {
        self.characterRepo = characterRepo ?? LocalJSONCharacterRepository()
        self.templateRepo = templateRepo ?? LocalJSONTemplateRepository()
        self.safetyPipeline = safetyPipeline ?? SafetyPipeline.shared
        if let existing {
            self.draft = existing
        } else {
            self.draft = CharacterProfile(
                name: "",
                displayName: "",
                category: .originalFreeform,
                relationshipGenre: .none
            )
        }
    }

    func loadTemplates() async {
        do {
            self.availableTemplates = try await templateRepo.fetchTemplates()
        } catch {
            AppLog.error("[CharacterCreateVM] template load failed: %@", String(describing: error))
        }
    }

    func applyTemplate(_ template: CharacterTemplate) {
        var d = template.makeDraft()
        // id は既存 draft の id を維持 (新規 draft の場合は新 UUID のまま)
        d.id = draft.id
        d.createdAt = draft.createdAt
        d.updatedAt = Date()
        // 既に入力済みの shortDescription/firstMessage は上書きしないようにする
        if !draft.shortDescription.isEmpty { d.shortDescription = draft.shortDescription }
        if !draft.firstMessage.isEmpty { d.firstMessage = draft.firstMessage }
        // テンプレート由来の重複ルールも、詳細画面のForEachへそのまま渡さない。
        // 順序は維持し、正規化した文字列だけで重複を除く。
        d.rules = uniqueRules(d.rules)
        d.safetyRules = uniqueRules(d.safetyRules)
        self.draft = d
    }

    private func uniqueRules(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            let normalized = value
                .precomposedStringWithCanonicalMapping
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !normalized.isEmpty else { return false }
            return seen.insert(normalized).inserted
        }
    }

    /// 保存しようとした時に呼ぶ。Safety を通したのち state を遷移させる。
    func attemptSave(force: Bool = false) async {
        // A second tap (or a keyboard shortcut) must not start a second
        // validation against the same form while the first one is awaiting.
        guard state != .validating else { return }
        let operationID = UUID()
        saveOperationID = operationID
        let revision = draftRevision
        state = .validating

        // ベースの safetyRating を起点に内部解決
        // The editor intentionally allows an empty display-name field, but
        // persisted profiles must not carry an empty label into Story views.
        var working = draft.normalizedForPersistence
        working.updatedAt = Date()

        let decision = await safetyPipeline.evaluateCharacter(working)

        // Editing is disabled in the view while validation runs, but retain
        // this guard for programmatic bindings and delayed test doubles.
        guard saveOperationID == operationID else { return }
        guard draftRevision == revision else {
            state = .editing
            return
        }

        switch decision.action {
        case .allow:
            await persist(working, operationID: operationID, draftRevision: revision)
        case .warn:
            if force {
                await persist(working, operationID: operationID, draftRevision: revision)
            } else {
                state = .warned(decision)
            }
        case .soften:
            // soften 提案がある場合: 今回はそのまま warn 同等に表示し、ユーザー判断に委ねる
            if force {
                await persist(working, operationID: operationID, draftRevision: revision)
            } else {
                state = .warned(decision)
            }
        case .requireEdit, .block:
            state = .blocked(decision)
        }
    }

    private func persist(
        _ c: CharacterProfile,
        operationID: UUID,
        draftRevision: UInt
    ) async {
        let normalized = c.normalizedForPersistence
        do {
            try await characterRepo.saveCharacter(normalized)
            guard saveOperationID == operationID, self.draftRevision == draftRevision else {
                return
            }
            state = .saved(normalized)
            CharacterLibraryChangeCenter.post()
        } catch {
            guard saveOperationID == operationID, self.draftRevision == draftRevision else {
                return
            }
            AppLog.error("[CharacterCreateVM] save failed: %@", String(describing: error))
            state = .blocked(
                SafetyDecision(
                    action: .requireEdit,
                    reasons: [KizunaCopy.text(
                        japanese: "保存に失敗しました。少し時間を置いて再度お試しください。",
                        english: "The character could not be saved. Please wait a moment and try again."
                    )],
                    severity: .warning
                )
            )
        }
    }

    func resetState() {
        saveOperationID = nil
        state = .editing
    }

    /// 画面が閉じられた時に、検証完了後の遅延保存を無効化する。
    /// リポジトリへの保存が既に開始された場合は中断できないため、
    /// `attemptSave` 側でもoperationIDを再確認して完了状態を公開しない。
    func cancelPendingSave() {
        saveOperationID = nil
        if case .validating = state {
            state = .editing
        }
    }
}
