/*
仕様:
- 役割: CharacterLibraryView の状態と検索/フィルター処理を保持。
- 主な型: `CharacterLibraryViewModel` (ObservableObject, MainActor).
- 編集ポイント: フィルター追加、ソート順、検索ロジック変更。
*/

import Foundation
import Combine

enum CharacterLibraryLoadIssue: Equatable {
    case characterStorageFailure

    var message: String {
        switch self {
        case .characterStorageFailure:
            return KizunaCopy.text(
                japanese: "キャラクターの保存データを読み込めませんでした。データは削除されていません。",
                english: "The saved characters could not be loaded. Your data has not been deleted."
            )
        }
    }
}

@MainActor
final class CharacterLibraryViewModel: ObservableObject {
    @Published private(set) var allCharacters: [CharacterProfile] = []
    @Published private(set) var templates: [CharacterTemplate] = []
    @Published var searchText: String = ""
    @Published var groupFilter: CategoryGroup? = nil
    @Published var categoryFilter: CharacterCategory? = nil
    @Published var genreFilter: RelationshipGenre? = nil
    @Published var tagFilter: String? = nil
    @Published private(set) var isLoading: Bool = false
    /// キャラクターの読込に失敗した時だけ設定する。空配列を「未作成」と解釈させない。
    @Published private(set) var loadError: CharacterLibraryLoadIssue?
    /// 少なくとも一度、キャラクター配列の読込に成功したか。
    @Published private(set) var didLoadCharacters: Bool = false
    /// テンプレートを読み込めない状態。空のテンプレート一覧とは区別する。
    @Published private(set) var templateLoadError: String?
    @Published private(set) var didLoadTemplates: Bool = false
    /// 一覧からの削除失敗を成功扱いにせず、確認画面の後でUIへ通知する。
    @Published private(set) var deleteErrorMessage: String?
    /// 同じ行の確認アラートを連続して確定しても、関連データの掃除と
    /// repository削除を二重に走らせない。VMはMainActor上で直列化される。
    private var deletingIDs = Set<UUID>()

    private let characterRepo: CharacterRepository
    private let templateRepo: TemplateRepository
    private let memoryRepo: MemoryRepository

    init(
        characterRepo: CharacterRepository? = nil,
        templateRepo: TemplateRepository? = nil,
        memoryRepo: MemoryRepository? = nil
    ) {
        self.characterRepo = characterRepo ?? LocalJSONCharacterRepository()
        self.templateRepo = templateRepo ?? LocalJSONTemplateRepository()
        self.memoryRepo = memoryRepo ?? LocalJSONMemoryRepository()
    }

    func bootstrap() async {
        isLoading = true
        defer { isLoading = false }
        let templateSeedSucceeded = await CharacterTemplateSeed.seedIfNeeded(into: templateRepo)
        if !templateSeedSucceeded {
            templateLoadError = KizunaCopy.text(
                japanese: "テンプレートの初期データを準備できませんでした。",
                english: "Starter templates could not be prepared."
            )
        }
        await CharacterLibrarySeed.seedIfNeeded(characterRepo: characterRepo)
        await reload()
    }

    func reload() async {
        let wasLoading = isLoading
        if !wasLoading { isLoading = true }
        defer {
            if !wasLoading { isLoading = false }
        }

        // キャラクター本体とテンプレートを分けて読む。テンプレート側の
        // 一時的な失敗で、既存キャラクターまで空表示にしない。
        do {
            self.allCharacters = try await characterRepo.fetchCharacters()
            didLoadCharacters = true
            loadError = nil
        } catch {
            // 既存のメモリー上の一覧は保持し、初回失敗時だけエラー画面へ
            // 分岐できるようにする。読み込み失敗を空データで上書きしない。
            loadError = .characterStorageFailure
            NSLog("[CharacterLibraryVM] character reload failed: %@", String(describing: error))
            return
        }

        do {
            self.templates = try await templateRepo.fetchTemplates()
            didLoadTemplates = true
            // 空配列も「読み込み成功した空状態」であり、前回の
            // エラーを残すとTemplatePickerが失敗表示のままになる。
            templateLoadError = nil
        } catch {
            // キャラクター一覧は利用できるため、テンプレートだけにエラーを
            // 表示する。空配列を「テンプレートなし」と誤認させない。
            templateLoadError = KizunaCopy.text(
                japanese: "テンプレートを読み込めませんでした。データは削除されていません。",
                english: "Templates could not be loaded. Your data has not been deleted."
            )
            NSLog("[CharacterLibraryVM] template reload failed: %@", String(describing: error))
        }
    }

    func retryLoad() async {
        if templates.isEmpty {
            let seedSucceeded = await CharacterTemplateSeed.seedIfNeeded(into: templateRepo)
            if !seedSucceeded {
                templateLoadError = KizunaCopy.text(
                    japanese: "テンプレートの初期データを準備できませんでした。",
                    english: "Starter templates could not be prepared."
                )
            }
        }
        await reload()
    }

    func delete(id: UUID) async {
        guard deletingIDs.insert(id).inserted else { return }
        defer { deletingIDs.remove(id) }
        deleteErrorMessage = nil
        do {
            // 保護判定と本体削除はリポジトリの同一ロック内で行う。
            // 先に一覧を読んでから削除すると、標準キャラ化や別の削除と
            // 競合した際に、保護されたキャラの関連データだけを消し得る。
            let deletionResult = try await characterRepo.deleteCharacter(id: id)
            switch deletionResult {
            case .protected:
                deleteErrorMessage = KizunaCopy.text(
                    japanese: "標準キャラクターは削除できません。",
                    english: "Standard characters cannot be deleted."
                )
                return
            case .notFound:
                deleteErrorMessage = KizunaCopy.text(
                    japanese: "キャラクターが見つかりません。一覧を更新してから再試行してください。",
                    english: "The character could not be found. Refresh the library and try again."
                )
                return
            case .deleted:
                break
            }

            // 本体削除が確定した後だけ、物語参照とメモリーを掃除する。
            // これらの掃除が失敗しても本体削除の結果を成功扱いに戻さない。
            try await StoryCharacterReferenceCleaner.remove(characterID: id)
            try await memoryRepo.deleteAllMemories(characterId: id)
            // キャラ本体が消えた後は、Personaスレッドを保存済みの
            // personaSnapshotへ切り替える。会話本文を削除せず、次回送信が
            // 削除済みUUIDを参照して失敗し続ける状態だけを解消する。
            PersonaChatStore.shared.detachCharacterReferences(for: id)
            await reload()
        } catch {
            NSLog("[CharacterLibraryVM] delete failed: %@", String(describing: error))
            let message = KizunaCopy.text(
                japanese: "キャラクターの削除を完了できませんでした。関連データの状態を確認して再試行してください。",
                english: "Character deletion did not complete. Check the related data and try again."
            )
            // NSErrorの詳細は日本語のまま返ることがあり、英語UIへそのまま
            // 混ぜると診断文が読みにくくなる。詳細はログに残し、画面には
            // 言語を揃えた安全なメッセージだけを表示する。
            deleteErrorMessage = KizunaCopy.language == .japanese
                ? "\(message)\n\(error.localizedDescription)"
                : message
        }
    }

    var filtered: [CharacterProfile] {
        var result = allCharacters
        if let g = groupFilter { result = result.filter { $0.category.group == g } }
        if let c = categoryFilter { result = result.filter { $0.category == c } }
        if let r = genreFilter { result = result.filter { $0.relationshipGenre == r } }
        if let t = tagFilter, !t.isEmpty {
            result = result.filter { $0.tags.contains(where: { $0.localizedCaseInsensitiveContains(t) }) }
        }
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty {
            let needle = trimmedSearch.lowercased()
            result = result.filter { c in
                c.name.lowercased().contains(needle)
                    || c.displayName.lowercased().contains(needle)
                    || c.shortDescription.lowercased().contains(needle)
                    || c.tags.contains(where: { $0.lowercased().contains(needle) })
            }
        }
        return result
    }

    /// 検索/絞り込みで「該当タグ」候補を返す (タグフィルターの選択肢)。
    var availableTags: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for c in allCharacters {
            for t in c.tags where seen.insert(t).inserted { out.append(t) }
        }
        return out.sorted()
    }
}
