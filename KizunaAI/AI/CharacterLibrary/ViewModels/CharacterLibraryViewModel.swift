/*
仕様:
- 役割: CharacterLibraryView の状態と検索/フィルター処理を保持。
- 主な型: `CharacterLibraryViewModel` (ObservableObject, MainActor).
- 編集ポイント: フィルター追加、ソート順、検索ロジック変更。
*/

import Foundation
import Combine

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

    private let characterRepo: CharacterRepository
    private let templateRepo: TemplateRepository

    init(
        characterRepo: CharacterRepository? = nil,
        templateRepo: TemplateRepository? = nil
    ) {
        self.characterRepo = characterRepo ?? LocalJSONCharacterRepository()
        self.templateRepo = templateRepo ?? LocalJSONTemplateRepository()
    }

    func bootstrap() async {
        isLoading = true
        defer { isLoading = false }
        await CharacterTemplateSeed.seedIfNeeded(into: templateRepo)
        await CharacterLibrarySeed.seedIfNeeded(characterRepo: characterRepo)
        await reload()
    }

    func reload() async {
        do {
            self.allCharacters = try await characterRepo.fetchCharacters()
            self.templates = try await templateRepo.fetchTemplates()
        } catch {
            NSLog("[CharacterLibraryVM] reload failed: %@", String(describing: error))
        }
    }

    func delete(id: UUID) async {
        do {
            try await characterRepo.deleteCharacter(id: id)
            await reload()
        } catch {
            NSLog("[CharacterLibraryVM] delete failed: %@", String(describing: error))
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
