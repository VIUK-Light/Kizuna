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
    @Published var draft: CharacterProfile
    @Published var state: CharacterCreateState = .editing
    @Published var availableTemplates: [CharacterTemplate] = []

    private let characterRepo: CharacterRepository
    private let templateRepo: TemplateRepository
    private let safetyPipeline: SafetyPipeline

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
            NSLog("[CharacterCreateVM] template load failed: %@", String(describing: error))
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
        self.draft = d
    }

    /// 保存しようとした時に呼ぶ。Safety を通したのち state を遷移させる。
    func attemptSave(force: Bool = false) async {
        state = .validating

        // ベースの safetyRating を起点に内部解決
        var working = draft
        working.updatedAt = Date()

        let decision = await safetyPipeline.evaluateCharacter(working)

        switch decision.action {
        case .allow:
            await persist(working)
        case .warn:
            if force {
                await persist(working)
            } else {
                state = .warned(decision)
            }
        case .soften:
            // soften 提案がある場合: 今回はそのまま warn 同等に表示し、ユーザー判断に委ねる
            if force {
                await persist(working)
            } else {
                state = .warned(decision)
            }
        case .requireEdit, .block:
            state = .blocked(decision)
        }
    }

    private func persist(_ c: CharacterProfile) async {
        do {
            try await characterRepo.saveCharacter(c)
            state = .saved(c)
        } catch {
            NSLog("[CharacterCreateVM] save failed: %@", String(describing: error))
            state = .blocked(
                SafetyDecision(
                    action: .requireEdit,
                    reasons: ["保存に失敗しました。少し時間を置いて再度お試しください。"],
                    severity: .warning
                )
            )
        }
    }

    func resetState() {
        state = .editing
    }
}
