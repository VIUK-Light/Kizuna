/*
仕様:
- 役割: Story モードの 4 画面用 ViewModel (Library/Create/Detail/Session)。
- 主な型: StoryWorldLibraryViewModel, StoryWorldCreateViewModel, StoryWorldDetailViewModel,
         StorySessionViewModel.
*/

import Foundation
import Combine

/// デバッグ設定から休憩提案カードの表示テストを依頼するための共有窓口。
enum KizunaDebugOptions {
    static let restSuggestionEnabledKey = "kizuna.debug.restSuggestion.enabled"
    static let restSuggestionRequestKey = "kizuna.debug.restSuggestion.requestedAt"
    static let restSuggestionRequestNotification = Notification.Name("kizuna.debug.restSuggestion.requested")
    static let safetyConcernRequestKey = "kizuna.debug.safetyConcern.requestedAt"
    static let safetyConcernRequestNotification = Notification.Name("kizuna.debug.safetyConcern.requested")
    /// 設定シートの dismiss 完了をワークスペースへ伝える通知。デバッグ要求時の
    /// Story 表示はこの通知を受けてから行うため、固定待機を必要としない。
    static let settingsDismissedNotification = Notification.Name("kizuna.debug.settings.dismissed")

    static func requestRestSuggestionUI() {
        let timestamp = Date().timeIntervalSince1970
        UserDefaults.standard.set(timestamp, forKey: restSuggestionRequestKey)
        AppLog.note("[KizunaDebug] rest suggestion requested: %.3f", timestamp)
        NotificationCenter.default.post(name: restSuggestionRequestNotification, object: nil)
    }

    static func requestSafetyConcernUI() {
        let timestamp = Date().timeIntervalSince1970
        UserDefaults.standard.set(timestamp, forKey: safetyConcernRequestKey)
        AppLog.note("[KizunaDebug] safety concern requested: %.3f", timestamp)
        NotificationCenter.default.post(name: safetyConcernRequestNotification, object: nil)
    }
}

// MARK: - Library

enum StoryLibraryLoadIssue: String, Equatable, Sendable {
    case storageFailure

    var messageKey: String { "ストーリーの保存データを読み込めません" }
}

/// 世界と関連レコードを複数のJSONストアから削除する処理は、アプリ終了や
/// 1つのストアの一時的なI/O失敗で途中停止しうる。削除対象のIDだけを
/// UserDefaultsへ記録し、次のライブラリー起動時に同じ冪等処理を再試行する。
/// 本文やキャラクター情報は保存しない。
enum StoryWorldDeletionJournal {
    private static let key = "kizuna.story.pendingWorldDeletions"

    static var pendingIDs: [UUID] {
        let values = UserDefaults.standard.stringArray(forKey: key) ?? []
        return values.compactMap(UUID.init(uuidString:))
    }

    static func mark(_ id: UUID) {
        var ids = pendingIDs
        guard ids.contains(id) == false else { return }
        ids.append(id)
        UserDefaults.standard.set(ids.map(\.uuidString), forKey: key)
    }

    static func clear(_ id: UUID) {
        let remaining = pendingIDs.filter { $0 != id }
        UserDefaults.standard.set(remaining.map(\.uuidString), forKey: key)
    }
}

/// 新規StoryはWorld/Cast/Lorebook/Sceneを複数のJSONへ保存するため、
/// 保存途中でプロセスが終了すると「作成中」の状態を推測できなくなる。
/// 作成開始を先に記録し、全保存成功後だけcommittedへ進めることで、
/// 次回ライブラリー起動時に未完了の新規データを確実に掃除する。
enum StoryWorldCreationJournal {
    enum State: String, Codable {
        case staging
        case committed
    }

    struct Entry: Codable, Equatable {
        let worldID: UUID
        let generatedCharacterIDs: [UUID]
        var state: State
    }

    private static let key = "kizuna.story.pendingWorldCreations"

    static var entries: [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else {
            return []
        }
        return decoded
    }

    static func markStaging(worldID: UUID, generatedCharacterIDs: [UUID]) {
        var values = entries
        let entry = Entry(
            worldID: worldID,
            generatedCharacterIDs: generatedCharacterIDs,
            state: .staging
        )
        if let index = values.firstIndex(where: { $0.worldID == worldID }) {
            values[index] = entry
        } else {
            values.append(entry)
        }
        persist(values)
    }

    static func markCommitted(worldID: UUID) {
        var values = entries
        guard let index = values.firstIndex(where: { $0.worldID == worldID }) else { return }
        values[index].state = .committed
        persist(values)
    }

    static func clear(worldID: UUID) {
        persist(entries.filter { $0.worldID != worldID })
    }

    private static func persist(_ values: [Entry]) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

@MainActor
final class StoryWorldLibraryViewModel: ObservableObject {
    @Published private(set) var worlds: [StoryWorld] = []
    @Published private(set) var charactersById: [UUID: CharacterProfile] = [:]
    @Published private(set) var isBootstrapping = false
    /// Workspaceが表示を切り替えても、同じViewModelのメモリー上の一覧を再利用する。
    @Published private(set) var didBootstrap = false
    @Published private(set) var loadError: StoryLibraryLoadIssue?
    @Published private(set) var seedError: CharacterLibrarySeed.SeedIssue?
    @Published private(set) var migrationError: String?
    @Published var searchText: String = ""
    @Published var groupFilter: CategoryGroup? = nil

    private let worldRepo: StoryWorldRepository = LocalJSONStoryWorldRepository()
    private let characterRepo: CharacterRepository = LocalJSONCharacterRepository()
    private let castRepo: CastRepository = LocalJSONCastRepository()
    private let sceneRepo: StorySceneRepository = LocalJSONStorySceneRepository()
    private let sessionRepo: StorySessionRepository = LocalJSONStorySessionRepository()
    private let lorebookRepo: StoryLorebookRepository = LocalJSONStoryLorebookRepository()
    private let storyMemoryRepo: StoryMemoryRepository = LocalJSONStoryMemoryRepository()

    func bootstrap() async {
        guard !isBootstrapping else { return }
        guard !didBootstrap else { return }
        isBootstrapping = true
        loadError = nil
        seedError = nil
        migrationError = nil

        // 前回の削除がアプリ終了や一時的なI/O失敗で途中停止していた場合、
        // 一覧を表示する前に同じ削除を再試行する。各操作は対象IDに対して
        // 冪等なので、途中まで消えていても安全に続きから実行できる。
        await resumePendingWorldDeletions()
        await resumePendingWorldCreations()

        // 既存データは初期シードを待たずに表示する。大きなJSONを持つMacでも
        // 一覧が空のまま固まったように見えないようにする。
        await reload()

        // 旧バージョンが残した同名の標準Worldを、一覧で隠すだけにしない。
        // seedの前に正規UUIDへ関連レコードを移しておくことで、再シードや
        // 履歴画面がhidden UUIDを再発見する問題を防ぐ。
        await migrateDuplicateSystemWorlds()

        let error = await CharacterLibrarySeed.seedIfNeeded(characterRepo: characterRepo, worldRepo: worldRepo)
        seedError = error
        // シードが新しく作った標準Worldにも、同じ移行ルールを適用する。
        await migrateDuplicateSystemWorlds()
        await reload()
        isBootstrapping = false
        // 一時的なI/O／Bundle失敗を「初期化済み」として固定しない。
        // エラー表示を残したまま、次回表示時に自動再試行できるようにする。
        didBootstrap = error == nil && loadError == nil && migrationError == nil
    }

    func reload() async {
        do {
            let fetchedWorlds = try await worldRepo.fetchWorlds()
            self.worlds = deduplicatedSystemWorlds(fetchedWorlds)
            let characters = try await characterRepo.fetchCharacters()
            self.charactersById = characters.reduce(into: [:]) { result, character in
                guard result[character.id] == nil else { return }
                result[character.id] = character
            }
            loadError = nil
        } catch {
            let message = String(describing: error)
            loadError = .storageFailure
            AppLog.error("[StoryLibraryVM] reload failed: %@", message)
        }
    }

    func retryBootstrap() async {
        didBootstrap = false
        await bootstrap()
    }

    private func deduplicatedSystemWorlds(_ fetchedWorlds: [StoryWorld]) -> [StoryWorld] {
        var seenSystemWorlds = Set<String>()
        return fetchedWorlds.filter { world in
            guard world.isSystemProtected == true else { return true }
            // 以前のシードはタイトルの大文字・空白・Unicode正規化だけが違う
            // 複製を残すことがあった。標準ストーリーのタイトルは一意なので、
            // 説明文が少し変わっていても同じタイトルを1件に畳む。
            let key = normalizedSystemWorldKey(world)
            guard seenSystemWorlds.insert(key).inserted else {
                AppLog.note("[StoryLibraryVM] hiding duplicate system world title: %@ (%@)", world.title, world.id.uuidString)
                return false
            }
            return true
        }
    }

    private func normalizedSystemWorldKey(_ world: StoryWorld) -> String {
        func normalize(_ value: String) -> String {
            value
                .precomposedStringWithCanonicalMapping
                .lowercased()
                .filter { !$0.isWhitespace && !$0.isPunctuation && $0 != "\u{200B}" }
        }
        return normalize(world.title)
    }

    /// 旧データに存在する同名のsystem Worldをcanonical Worldへ統合する。
    /// 一覧のfilterだけでは、履歴や別画面がraw repositoryを読むと重複が戻る。
    private func migrateDuplicateSystemWorlds() async {
        guard let localWorldRepo = worldRepo as? LocalJSONStoryWorldRepository else {
            // クラウド等の別Repositoryでは、削除を伴うローカル移行を行わない。
            return
        }
        do {
            let systemWorlds = (try await worldRepo.fetchWorlds()).filter { $0.isSystemProtected == true }
            let grouped = Dictionary(grouping: systemWorlds, by: normalizedSystemWorldKey)
            for worlds in grouped.values where worlds.count > 1 {
                // 古いシードが同名ユーザー物語を保護化してしまった場合、
                // ユーザー側のほうが最近更新されている可能性がある。
                // 最初に作られたWorldをcanonicalにして、後発側の関連データを
                // そこへ移すことで、標準WorldをユーザーWorldで置き換えない。
                let ordered = worlds.sorted {
                    if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                    return $0.updatedAt < $1.updatedAt
                }
                guard let canonical = ordered.first else { continue }
                for duplicate in ordered.dropFirst() {
                    do {
                        try await mergeWorldMetadata(from: duplicate.id, to: canonical.id)
                        try await migrateWorldData(from: duplicate.id, to: canonical.id)
                        try await localWorldRepo.purgeSystemWorld(id: duplicate.id)
                        AppLog.note(
                            "[StoryLibraryVM] migrated duplicate system world %@ (%@) -> %@",
                            duplicate.title,
                            duplicate.id.uuidString,
                            canonical.id.uuidString
                        )
                    } catch {
                        // 1件の壊れた重複が、別タイトルの移行まで止めない。
                        // purgeは最後に行うため、失敗したデータは次回起動で再試行できる。
                        AppLog.note(
                            "[StoryLibraryVM] duplicate system world %@ (%@) migration failed: %@",
                            duplicate.title,
                            duplicate.id.uuidString,
                            String(describing: error)
                        )
                        migrationError = KizunaCopy.text(
                            japanese: "重複ストーリーの統合に失敗しました。一覧は表示できますが、再試行してください。",
                            english: "Some duplicate stories could not be merged. The library is available, but please retry."
                        )
                    }
                }
            }
        } catch {
            // 一覧を空にしたり、ユーザーデータを推測で削除したりせず、
            // 次回起動で再試行できるよう診断だけを残す。
            AppLog.error("[StoryLibraryVM] duplicate system world migration failed: %@", String(describing: error))
            migrationError = KizunaCopy.text(
                japanese: "重複ストーリーの統合に失敗しました。一覧は表示できますが、再試行してください。",
                english: "Some duplicate stories could not be merged. The library is available, but please retry."
            )
        }
    }

    private func resumePendingWorldDeletions() async {
        for id in StoryWorldDeletionJournal.pendingIDs {
            do {
                guard let world = try await worldRepo.fetchWorlds().first(where: { $0.id == id }) else {
                    // 世界レコードは消えていても、関連データだけ残っている可能性がある。
                    try await deleteRelatedWorldData(id: id)
                    StoryWorldDeletionJournal.clear(id)
                    continue
                }
                guard world.isSystemProtected != true else {
                    // 保護された標準Worldを誤って削除しない。
                    StoryWorldDeletionJournal.clear(id)
                    continue
                }
                try await deleteRelatedWorldData(id: id)
                try await worldRepo.deleteWorld(id: id)
                StoryWorldDeletionJournal.clear(id)
            } catch {
                AppLog.error("[StoryLibraryVM] pending world deletion retry failed %@: %@", id.uuidString, String(describing: error))
                migrationError = KizunaCopy.text(
                    japanese: "前回のストーリー削除を完了できませんでした。再試行してください。",
                    english: "A previous story deletion could not be completed. Please retry."
                )
            }
        }
    }

    private func resumePendingWorldCreations() async {
        for entry in StoryWorldCreationJournal.entries {
            guard entry.state == .staging else {
                // 全関連データの保存が成功した後にプロセスが終了した場合は、
                // 作成済みWorldを削除せず、残ったjournalだけを片付ける。
                StoryWorldCreationJournal.clear(worldID: entry.worldID)
                continue
            }

            do {
                // 作成画面はSession/Memoryをまだ作らないが、関連データの掃除は
                // 既存の削除経路と同じ順序・冪等性を使う。
                try await deleteRelatedWorldData(id: entry.worldID)
                try await worldRepo.deleteWorld(id: entry.worldID)
                for characterID in entry.generatedCharacterIDs {
                    let result = try await characterRepo.deleteCharacter(id: characterID)
                    if result == .deleted || result == .needsCleanup {
                        try await characterRepo.completeCharacterDeletionCleanup(id: characterID)
                    }
                }
                StoryWorldCreationJournal.clear(worldID: entry.worldID)
            } catch {
                AppLog.error(
                    "[StoryLibraryVM] pending story creation cleanup failed %@: %@",
                    entry.worldID.uuidString,
                    String(describing: error)
                )
                migrationError = KizunaCopy.text(
                    japanese: "未完了のストーリー作成を整理できませんでした。再試行してください。",
                    english: "An unfinished story creation could not be cleaned up. Please retry."
                )
            }
        }
    }

    private func deleteRelatedWorldData(id: UUID) async throws {
        for session in try await sessionRepo.fetchSessions(storyWorldId: id) {
            try await sessionRepo.deleteSession(id: session.id)
        }
        for entry in try await lorebookRepo.fetchAllEntries(storyWorldId: id) {
            try await lorebookRepo.deleteEntry(id: entry.id)
        }
        try await castRepo.deleteAllCast(storyWorldId: id)
        try await sceneRepo.deleteAllScenes(storyWorldId: id)
        try await storyMemoryRepo.deleteAllMemories(storyWorldId: id)
    }

    /// Merge references that live on StoryWorld itself before the duplicate
    /// record is purged. Cast/scene/session rows alone are not enough: a
    /// character that exists only on the duplicate must remain selectable, and
    /// language-specific metadata must not disappear during migration.
    private func mergeWorldMetadata(from duplicateID: UUID, to canonicalID: UUID) async throws {
        let worlds = try await worldRepo.fetchWorlds()
        guard var canonical = worlds.first(where: { $0.id == canonicalID }),
              let duplicate = worlds.first(where: { $0.id == duplicateID }) else { return }

        func orderedUnique<T: Hashable>(_ values: [T]) -> [T] {
            var seen = Set<T>()
            return values.filter { seen.insert($0).inserted }
        }

        func fillIfEmpty(_ target: inout String, from source: String) {
            guard target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            target = source
        }

        let mergedCharacterIDs = orderedUnique(canonical.characterIds + duplicate.characterIds)
        if mergedCharacterIDs != canonical.characterIds {
            canonical.characterIds = mergedCharacterIDs
        }
        if canonical.mainCharacterId == nil {
            canonical.mainCharacterId = duplicate.mainCharacterId
        }
        canonical.tags = orderedUnique(canonical.tags + duplicate.tags)
        canonical.safetyRules = orderedUnique(canonical.safetyRules + duplicate.safetyRules)
        fillIfEmpty(&canonical.shortDescription, from: duplicate.shortDescription)
        fillIfEmpty(&canonical.worldSetting, from: duplicate.worldSetting)
        fillIfEmpty(&canonical.userRole, from: duplicate.userRole)
        fillIfEmpty(&canonical.openingScene, from: duplicate.openingScene)
        fillIfEmpty(&canonical.storyGoal, from: duplicate.storyGoal)
        fillIfEmpty(&canonical.mood, from: duplicate.mood)

        var localizations = canonical.localizations ?? [:]
        for (language, duplicateLocalization) in duplicate.localizations ?? [:] {
            guard var merged = localizations[language] else {
                localizations[language] = duplicateLocalization
                continue
            }
            if merged.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                merged.title = duplicateLocalization.title
            }
            if merged.shortDescription?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                merged.shortDescription = duplicateLocalization.shortDescription
            }
            if merged.worldSetting?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                merged.worldSetting = duplicateLocalization.worldSetting
            }
            if merged.userRole?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                merged.userRole = duplicateLocalization.userRole
            }
            if merged.openingScene?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                merged.openingScene = duplicateLocalization.openingScene
            }
            if merged.storyGoal?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                merged.storyGoal = duplicateLocalization.storyGoal
            }
            if merged.mood?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                merged.mood = duplicateLocalization.mood
            }
            if merged.tags?.isEmpty != false {
                merged.tags = duplicateLocalization.tags
            }
            localizations[language] = merged
        }
        canonical.localizations = localizations.isEmpty ? nil : localizations
        try await worldRepo.saveWorld(canonical)
    }

    private func migrateWorldData(from duplicateID: UUID, to canonicalID: UUID) async throws {
        let canonicalCast = try await castRepo.fetchCast(storyWorldId: canonicalID)
        var canonicalCharacterIDs = Set(canonicalCast.map(\.characterId))
        for var member in try await castRepo.fetchCast(storyWorldId: duplicateID) {
            if canonicalCharacterIDs.contains(member.characterId) {
                try await castRepo.deleteCast(id: member.id)
            } else {
                member.storyWorldId = canonicalID
                try await castRepo.saveCast(member)
                canonicalCharacterIDs.insert(member.characterId)
            }
        }

        for scene in try await sceneRepo.fetchScenes(storyWorldId: duplicateID) {
            if let localSceneRepo = sceneRepo as? LocalJSONStorySceneRepository {
                try await localSceneRepo.moveScene(id: scene.id, toStoryWorldId: canonicalID)
            } else {
                // Cloud implementations should provide an equivalent migration
                // operation. Do not rewrite timestamps through saveScene here.
                AppLog.note("[StoryLibraryVM] skipped scene migration for unsupported repository")
            }
        }

        for session in try await sessionRepo.fetchSessions(storyWorldId: duplicateID) {
            if let localSessionRepo = sessionRepo as? LocalJSONStorySessionRepository {
                try await localSessionRepo.moveSession(id: session.id, toStoryWorldId: canonicalID)
            } else {
                // Cloud implementations should provide an equivalent migration
                // operation. Do not rewrite timestamps through saveSession here.
                AppLog.note("[StoryLibraryVM] skipped session migration for unsupported repository")
            }
        }

        for var entry in try await lorebookRepo.fetchAllEntries(storyWorldId: duplicateID) {
            entry.storyWorldId = canonicalID
            try await lorebookRepo.saveEntry(entry)
        }

        if let localStoryMemoryRepo = storyMemoryRepo as? LocalJSONStoryMemoryRepository {
            for memory in try await localStoryMemoryRepo.fetchMemories(storyWorldId: duplicateID) {
                try await localStoryMemoryRepo.moveMemory(memory, to: canonicalID)
            }
        } else {
            // A non-local repository can define its own atomic move operation.
            // Do not copy/delete here: doing so is not safe when IDs are used as
            // the repository's replacement key.
            AppLog.note("[StoryLibraryVM] skipped memory migration for unsupported repository")
        }
    }

    func delete(id: UUID) async throws {
        guard let world = worlds.first(where: { $0.id == id }), world.isSystemProtected != true else { return }
        StoryWorldDeletionJournal.mark(id)
        // 一覧画面からの削除も詳細画面と同じく関連データを掃除する。
        // エラーはUIへ返し、世界だけ閉じて孤児データを隠すことを防ぐ。
        try await deleteRelatedWorldData(id: id)
        try await worldRepo.deleteWorld(id: id)
        StoryWorldDeletionJournal.clear(id)
        await reload()
    }

    var filtered: [StoryWorld] {
        var result = worlds
        if let g = groupFilter { result = result.filter { $0.genre.group == g } }
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !needle.isEmpty {
            result = result.filter { w in
                let displayed = w.localizedForCurrentLanguage
                return displayed.title.lowercased().contains(needle)
                    || displayed.shortDescription.lowercased().contains(needle)
                    || displayed.worldSetting.lowercased().contains(needle)
                    || displayed.tags.contains(where: { $0.lowercased().contains(needle) })
            }
        }
        // 物語の好みはプロフィール入力から外したため、存在しない
        // preferenceを使った推薦で並び順を変えず、更新日時だけで安定表示する。
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    func coverCharacter(for world: StoryWorld) -> CharacterProfile? {
        let storyCharacterIDs = Set(world.characterIds)
        if let mainCharacterId = world.mainCharacterId,
           storyCharacterIDs.contains(mainCharacterId),
           let character = charactersById[mainCharacterId] {
            return character
        }
        return world.characterIds.compactMap { charactersById[$0] }.first
    }
}

// MARK: - Create

@MainActor
final class StoryWorldCreateViewModel: ObservableObject {
    @Published var draft: StoryWorld
    @Published var sceneDraft: StoryScene
    @Published private(set) var castDrafts: [CastMember] = []
    // StoryWorld内で使うLorebook。キャラ欄ではなく物語編集画面から管理する。
    @Published private(set) var lorebookDrafts: [StoryLorebookEntry] = []
    @Published private(set) var availableCharacters: [CharacterProfile] = []
    @Published private(set) var isReadyToSave = false
    @Published private(set) var isSaving = false
    @Published private(set) var loadError: String?
    @Published var saveError: String? = nil
    @Published var generationBrief: String = ""
    @Published private(set) var isGeneratingTemplate: Bool = false
    @Published private(set) var generationStatus: String? = nil
    @Published private(set) var generationError: String? = nil
    @Published private(set) var hasAppliedGeneratedTemplate = false

    /// 雛形生成中にだけ作ったキャラ。保存ボタンが成功するまでRepositoryへ
    /// 書き込まず、再生成/キャンセルでライブラリーへ孤児を残さない。
    private var pendingGeneratedCharacters: [UUID: CharacterProfile] = [:]
    private let isCreatingNewWorld: Bool

    private let worldRepo: StoryWorldRepository = LocalJSONStoryWorldRepository()
    private let castRepo: CastRepository = LocalJSONCastRepository()
    private let characterRepo: CharacterRepository = LocalJSONCharacterRepository()
    private let sceneRepo: StorySceneRepository = LocalJSONStorySceneRepository()
    private let lorebookRepo: StoryLorebookRepository = LocalJSONStoryLorebookRepository()
    private let safetyPipeline = SafetyPipeline.shared
    private var generationTask: Task<Void, Never>? = nil

    init(existing: StoryWorld? = nil) {
        self.isCreatingNewWorld = existing == nil
        if let existing {
            self.draft = existing
            self.sceneDraft = StoryScene(
                storyWorldId: existing.id,
                title: Self.defaultSceneTitle(for: existing.title),
                mood: existing.mood,
                sceneGoal: existing.storyGoal,
                summary: existing.openingScene
            )
        } else {
            let world = StoryWorld(
                title: "",
                genre: .originalFreeform,
                relationshipGenre: .none
            )
            self.draft = world
            self.sceneDraft = StoryScene(storyWorldId: world.id)
        }
    }

    var validationIssues: [String] {
        var issues: [String] = []
        if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(KizunaCopy.text(japanese: "タイトルを入力してください。", english: "Enter a title."))
        }
        if castDrafts.isEmpty {
            issues.append(KizunaCopy.text(japanese: "キャラクターを1人以上追加してください。", english: "Add at least one character."))
        }
        let castIDs = Set(castDrafts.map(\.characterId))
        if sceneDraft.activeCharacterIds.isEmpty || !Set(sceneDraft.activeCharacterIds).isSubset(of: castIDs) {
            issues.append(KizunaCopy.text(
                japanese: "初期シーンに出すキャラクターを1人以上選択してください。",
                english: "Select at least one character for the opening scene."
            ))
        }
        guard let mainCharacterID = draft.mainCharacterId,
              castDrafts.contains(where: { $0.characterId == mainCharacterID && $0.roleInStory == .main }) else {
            issues.append(KizunaCopy.text(
                japanese: "メインキャラクターを1人指定してください。",
                english: "Choose one main character."
            ))
            return issues
        }
        if castDrafts.filter({ $0.roleInStory == .main }).count != 1 {
            issues.append(KizunaCopy.text(
                japanese: "メインキャラクターは1人だけにしてください。",
                english: "Choose exactly one main character."
            ))
        }
        return issues
    }

    var canSave: Bool {
        isReadyToSave
            && !isGeneratingTemplate
            && !isSaving
            && validationIssues.isEmpty
    }

    func load() async {
        isReadyToSave = false
        loadError = nil
        do {
            // 関連データはすべてローカル変数へ読み込んでから下書きへ反映する。
            // 途中のfetchが失敗した場合に「先に取得できた配列だけ反映」すると、
            // UIが部分状態になり、旧データを空配列で置換保存する危険が残る。
            // ここでは1件でも失敗したら下書きを変更せず、保存をロックして再試行を促す。
            let fetchedCharacters = try await characterRepo.fetchCharacters()
            let fetchedCast = try await castRepo.fetchCast(storyWorldId: draft.id)
            // Keep disabled entries in the edit snapshot as well. `replaceEntries`
            // is a full replacement, so loading only enabled rows would delete
            // every disabled lorebook entry the next time the user saves.
            let fetchedLorebook = try await lorebookRepo.fetchAllEntries(storyWorldId: draft.id)
            let fetchedScenes = try await sceneRepo.fetchScenes(storyWorldId: draft.id)

            var nextScene = sceneDraft
            if let firstScene = fetchedScenes.first {
                nextScene = firstScene
            } else if nextScene.title.isEmpty {
                nextScene.title = Self.defaultSceneTitle(for: draft.title)
                nextScene.mood = draft.mood
                nextScene.sceneGoal = draft.storyGoal
                nextScene.summary = draft.openingScene
            }

            self.availableCharacters = fetchedCharacters
            self.castDrafts = fetchedCast
            self.lorebookDrafts = fetchedLorebook
            self.sceneDraft = nextScene
            if !fetchedCast.isEmpty {
                // 旧データを編集で開いた場合も、形式と初期シーン選択を
                // 同じ正規化規則へ通し、画面と保存値のずれを残さない。
                setCastMode(draft.resolvedCastMode)
            }
            saveError = nil
            isReadyToSave = true
        } catch {
            loadError = String(describing: error)
            saveError = KizunaCopy.text(
                japanese: "保存データを完全に読み込めませんでした。内容を空のまま保存できないため、再読み込みしてください。",
                english: "The saved story data could not be loaded completely. Reload before saving so existing cast and lorebook data are not erased."
            )
            AppLog.error("[StoryWorldCreateVM] load failed: %@", String(describing: error))
        }
    }

    func addCharacter(_ profile: CharacterProfile) {
        guard !castDrafts.contains(where: { $0.characterId == profile.id }) else { return }
        if !availableCharacters.contains(where: { $0.id == profile.id }) {
            availableCharacters.append(profile)
        }
        let cast = CastMember(
            storyWorldId: draft.id,
            characterId: profile.id,
            roleInStory: castDrafts.isEmpty ? .main : .secondary,
            importance: castDrafts.isEmpty ? 0.9 : 0.5,
            introductionTiming: castDrafts.isEmpty ? .opening : .early,
            relationshipToUser: profile.relationshipToUser
        )
        castDrafts.append(cast)
        if !draft.characterIds.contains(profile.id) { draft.characterIds.append(profile.id) }
        if draft.mainCharacterId == nil { draft.mainCharacterId = profile.id }
        if sceneDraft.activeCharacterIds.isEmpty {
            sceneDraft.activeCharacterIds = [profile.id]
        }
    }

    // Lorebookカードを1件追加する。キーワードは空白・読点区切りで受け取る。
    func addLorebookEntry(title: String, keywordsText: String, content: String) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, !cleanContent.isEmpty else { return }
        let keywords = keywordsText
            .split(whereSeparator: { $0 == "," || $0 == "、" || $0 == " " || $0 == "\n" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        lorebookDrafts.append(
            StoryLorebookEntry(
                storyWorldId: draft.id,
                title: cleanTitle,
                keywords: keywords,
                content: cleanContent
            )
        )
    }

    func removeLorebookEntry(id: UUID) {
        lorebookDrafts.removeAll { $0.id == id }
    }

    func startTemplateGeneration() {
        guard generationTask == nil, !isGeneratingTemplate else { return }
        generationTask = Task { [weak self] in
            await self?.generateTemplateWith31BThinking()
        }
    }

    func cancelTemplateGeneration() {
        guard isGeneratingTemplate else { return }
        generationTask?.cancel()
        generationStatus = KizunaCopy.text(
            japanese: "雛形の生成を中止しました。",
            english: "Template generation was canceled."
        )
        generationError = nil
        isGeneratingTemplate = false
    }

    func generateTemplateWith31BThinking() async {
        guard !isSaving else {
            generationError = KizunaCopy.text(
                japanese: "保存中は雛形を再生成できません。保存が終わってから試してください。",
                english: "The template cannot be regenerated while the story is being saved. Try again afterward."
            )
            return
        }
        let brief = generationBrief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brief.isEmpty else {
            generationError = KizunaCopy.text(
                japanese: "作りたいストーリーの方向性を入力してください。",
                english: "Describe the kind of story you want to create."
            )
            return
        }

        guard StoryGemma31BAPIService.shared.hasAPIKey else {
            generationError = KizunaCopy.text(
                japanese: "Gemma4 APIキーが未設定です。\(KizunaCopy.appName)の設定からNAGI APIキーを登録してください。",
                english: "The Gemma4 API key is not set. Add the NAGI API key in \(KizunaCopy.appName)'s settings."
            )
            return
        }

        isGeneratingTemplate = true
        generationStatus = KizunaCopy.text(
            japanese: "Gemma4 31B APIで雛形を作成中…",
            english: "Creating a draft with the Gemma4 31B API…"
        )
        generationError = nil
        defer {
            isGeneratingTemplate = false
            generationTask = nil
        }

        let systemPrompt = Self.storyTemplateSystemPrompt + "\n\n" + (KizunaCopy.language == .english
            ? "All human-readable string values in the JSON (title, descriptions, settings, scenes, character text, tags, and rules) must be written in English. Keep enum values exactly as specified. If the request asks for multiple characters, set castMode to ensemble, set characterCount to the number of generated characters, and include every requested character in characters."
            : "JSON内のタイトル、説明、設定、シーン、キャラクター本文、タグ、ルールは日本語で書いてください。enum値はschemaの表記をそのまま使ってください。複数キャラの指定がある場合はcastModeをensembleにし、characterCountを生成キャラ数に合わせ、指定したキャラをcharactersへすべて含めてください。")
        let reply: String
        do {
            reply = try await StoryGemma31BAPIService.shared.generate(
                systemPrompt: systemPrompt,
                userPrompt: brief,
                temperature: 0.45,
                maxOutputTokens: 8192
            ).text
            try Task.checkCancellation()
        } catch {
            if Task.isCancelled {
                generationStatus = KizunaCopy.text(
                    japanese: "雛形の生成を中止しました。",
                    english: "Template generation was canceled."
                )
                generationError = nil
                return
            }
            AppLog.error("[StoryWorldCreateVM] template generation failed: %@", error.localizedDescription)
            generationError = KizunaCopy.text(
                japanese: "雛形の生成に失敗しました。API設定と入力内容を確認して、もう一度試してください。",
                english: "The template could not be generated. Check the API settings and your idea, then try again."
            )
            generationStatus = nil
            return
        }

        guard let data = Self.extractJSONObjectData(from: reply) else {
            generationError = KizunaCopy.text(
                japanese: "雛形の生成に失敗しました。JSONとして読める出力がありません。",
                english: "The template could not be generated because the response did not contain readable JSON."
            )
            generationStatus = nil
            return
        }

        do {
            let template = try JSONDecoder().decode(GeneratedStoryTemplate.self, from: data)
            try await applyGeneratedTemplate(template)
            generationError = nil
            generationStatus = KizunaCopy.text(
                japanese: "雛形をフォームへ反映しました。",
                english: "The template was applied to the form."
            )
        } catch {
            AppLog.error("[StoryWorldCreateVM] template decode/apply failed: %@", error.localizedDescription)
            generationError = KizunaCopy.text(
                japanese: "雛形の読み込みに失敗しました。生成内容を確認して、もう一度試してください。",
                english: "The template could not be loaded. Check the generated content and try again."
            )
            generationStatus = nil
        }
    }

    /// 作成画面を閉じる/雛形を再生成する時に、未保存の生成キャラを破棄する。
    func discardPendingGeneratedCharacters() async {
        let pendingIDs = Set(pendingGeneratedCharacters.keys)
        guard !pendingIDs.isEmpty else { return }
        pendingGeneratedCharacters.removeAll()
        castDrafts.removeAll { pendingIDs.contains($0.characterId) }
        draft.characterIds.removeAll { pendingIDs.contains($0) }
        sceneDraft.activeCharacterIds.removeAll { pendingIDs.contains($0) }
        if let mainID = draft.mainCharacterId, pendingIDs.contains(mainID) {
            draft.mainCharacterId = castDrafts.first?.characterId
        }
        availableCharacters.removeAll { pendingIDs.contains($0.id) }
        // 旧バージョンで同じViewModelがすでに保存していた場合も掃除する。
        // 新しい経路では未保存なので、存在しないIDの削除は安全なno-op。
        for id in pendingIDs {
            guard let result = try? await characterRepo.deleteCharacter(id: id) else { continue }
            if result == .deleted || result == .needsCleanup {
                // この経路では物語・メモリーをまだ作っていないため、
                // リポジトリ所有の掃除を完了してpending markerを残さない。
                try? await characterRepo.completeCharacterDeletionCleanup(id: id)
            }
        }
    }

    func removeCharacter(characterID: UUID) {
        castDrafts.removeAll { $0.characterId == characterID }
        for idx in castDrafts.indices {
            castDrafts[idx].relationshipToOtherCharacters.removeAll {
                $0.fromCharacterId == characterID || $0.toCharacterId == characterID
            }
        }
        draft.characterIds.removeAll { $0 == characterID }
        sceneDraft.activeCharacterIds.removeAll { $0 == characterID }
        if draft.mainCharacterId == characterID {
            // 主役を削除した場合は、残ったキャストの先頭を主役へ昇格する。
            // IDだけ差し替えると表示上は準主役のまま、セッションだけが主役として
            // 扱う不整合が起きるため、CastRoleとmainCharacterIdを同時に更新する。
            if let replacement = castDrafts.first {
                draft.mainCharacterId = replacement.characterId
                for index in castDrafts.indices {
                    castDrafts[index].roleInStory = castDrafts[index].characterId == replacement.characterId
                        ? .main
                        : (castDrafts[index].roleInStory == .main ? .secondary : castDrafts[index].roleInStory)
                }
            } else {
                draft.mainCharacterId = nil
            }
        }
    }

    func setRole(_ role: CastRole, for characterID: UUID) {
        guard let idx = castDrafts.firstIndex(where: { $0.characterId == characterID }) else { return }
        if role == .main {
            // 主役は1人に固定し、Worldの参照先も同じ操作で更新する。
            for index in castDrafts.indices where index != idx {
                if castDrafts[index].roleInStory == .main {
                    castDrafts[index].roleInStory = .secondary
                }
            }
            draft.mainCharacterId = characterID
        } else if draft.mainCharacterId == characterID {
            // 現在の主役を別役へ下げる場合は、残りのキャストから決定的に昇格。
            let replacement = castDrafts.enumerated().first { index, member in
                index != idx && member.characterId != characterID
            }?.element.characterId
            guard let replacement else {
                // 唯一のキャストを主役以外へ変更すると主役ゼロのWorldに
                // なるため、保存可能な不変条件を維持したまま操作を無視する。
                draft.mainCharacterId = characterID
                castDrafts[idx].roleInStory = .main
                return
            }
            draft.mainCharacterId = replacement
            for index in castDrafts.indices where castDrafts[index].characterId == replacement {
                castDrafts[index].roleInStory = .main
            }
        }
        castDrafts[idx].roleInStory = role == .main ? .main : role
    }

    func setImportance(_ value: Double, for characterID: UUID) {
        guard let idx = castDrafts.firstIndex(where: { $0.characterId == characterID }) else { return }
        castDrafts[idx].importance = min(max(value, 0), 1)
    }

    func setIntroductionTiming(_ timing: IntroductionTiming, for characterID: UUID) {
        guard let idx = castDrafts.firstIndex(where: { $0.characterId == characterID }) else { return }
        castDrafts[idx].introductionTiming = timing
    }

    func setStoryRelationshipToUser(_ text: String, for characterID: UUID) {
        guard let idx = castDrafts.firstIndex(where: { $0.characterId == characterID }) else { return }
        castDrafts[idx].relationshipToUser = text
    }

    func setActiveInOpeningScene(_ isActive: Bool, for characterID: UUID) {
        if isActive {
            // 単体物語の開始シーンは主役NPCだけ。別キャラを選ぶと前の選択を置き換える。
            if draft.isSoloStory {
                sceneDraft.activeCharacterIds = [characterID]
                return
            }
            guard !sceneDraft.activeCharacterIds.contains(characterID),
                  sceneDraft.activeCharacterIds.count < StoryConstants.maxActiveCharacters else { return }
            sceneDraft.activeCharacterIds.append(characterID)
        } else {
            // 開始シーンには少なくとも1人を残す。最後のトグルを外したまま
            // 保存時に先頭キャラへ黙って補完する挙動を防ぎ、画面状態と保存値を一致させる。
            guard sceneDraft.activeCharacterIds.count > 1 else { return }
            sceneDraft.activeCharacterIds.removeAll { $0 == characterID }
        }
    }

    /// Story形式の変更と初期シーンの参加者を同じ操作で正規化する。
    /// 形式Pickerがdraft.castModeだけを書き換えると、ensembleで選んだ複数人が
    /// soloへ切り替えた後も画面に残り、保存時のprefixで黙って失われていた。
    func setCastMode(_ mode: StoryCastMode) {
        draft.castMode = mode
        let castIDs = castDrafts.map(\.characterId)
        let validActiveIDs = sceneDraft.activeCharacterIds.filter { castIDs.contains($0) }

        switch mode {
        case .solo:
            let preferredID = draft.mainCharacterId.flatMap { castIDs.contains($0) ? $0 : nil }
                ?? validActiveIDs.first
                ?? castIDs.first
            sceneDraft.activeCharacterIds = preferredID.map { [$0] } ?? []
        case .ensemble:
            sceneDraft.activeCharacterIds = Array(validActiveIDs.prefix(StoryConstants.maxActiveCharacters))
            if sceneDraft.activeCharacterIds.isEmpty, let firstID = castIDs.first {
                sceneDraft.activeCharacterIds = [firstID]
            }
        }
    }

    func relationship(from fromID: UUID, to toID: UUID) -> CharacterRelationship {
        castDrafts
            .first(where: { $0.characterId == fromID })?
            .relationshipToOtherCharacters
            .first(where: { $0.toCharacterId == toID })
        ?? CharacterRelationship(fromCharacterId: fromID, toCharacterId: toID)
    }

    /// 新規作成だけを対象に、途中まで保存された関連データを可能な限り
    /// 掃除する。各JSONは独立しているため、1つの失敗で残りの掃除を止めず、
    /// 失敗が残った場合はjournalを次回起動へ引き継ぐ。
    private func rollbackNewWorldCreation(
        worldID: UUID,
        generatedCharacterIDs: [UUID]
    ) async -> Bool {
        var didFail = false

        do {
            for entry in try await lorebookRepo.fetchAllEntries(storyWorldId: worldID) {
                try await lorebookRepo.deleteEntry(id: entry.id)
            }
        } catch {
            didFail = true
            AppLog.error("[StoryWorldCreateVM] rollback lorebook cleanup failed: %@", error.localizedDescription)
        }

        do {
            try await castRepo.deleteAllCast(storyWorldId: worldID)
        } catch {
            didFail = true
            AppLog.error("[StoryWorldCreateVM] rollback cast cleanup failed: %@", error.localizedDescription)
        }

        do {
            try await sceneRepo.deleteAllScenes(storyWorldId: worldID)
        } catch {
            didFail = true
            AppLog.error("[StoryWorldCreateVM] rollback scene cleanup failed: %@", error.localizedDescription)
        }

        do {
            try await worldRepo.deleteWorld(id: worldID)
        } catch {
            didFail = true
            AppLog.error("[StoryWorldCreateVM] rollback world cleanup failed: %@", error.localizedDescription)
        }

        for characterID in generatedCharacterIDs {
            do {
                let result = try await characterRepo.deleteCharacter(id: characterID)
                if result == .deleted || result == .needsCleanup {
                    try await characterRepo.completeCharacterDeletionCleanup(id: characterID)
                }
            } catch {
                didFail = true
                AppLog.error(
                    "[StoryWorldCreateVM] rollback generated character cleanup failed %@: %@",
                    characterID.uuidString,
                    error.localizedDescription
                )
            }
        }

        return !didFail
    }

    func updateRelationship(
        from fromID: UUID,
        to toID: UUID,
        type: RelationshipType? = nil,
        description: String? = nil,
        tension: Double? = nil,
        trust: Double? = nil
    ) {
        guard fromID != toID,
              let idx = castDrafts.firstIndex(where: { $0.characterId == fromID }) else { return }
        var relation = relationship(from: fromID, to: toID)
        if let type { relation.relationshipType = type }
        if let description { relation.description = description }
        if let tension { relation.tension = min(max(tension, 0), 1) }
        if let trust { relation.trust = min(max(trust, 0), 1) }
        if let relIdx = castDrafts[idx].relationshipToOtherCharacters.firstIndex(where: { $0.toCharacterId == toID }) {
            castDrafts[idx].relationshipToOtherCharacters[relIdx] = relation
        } else {
            castDrafts[idx].relationshipToOtherCharacters.append(relation)
        }
    }

    func save() async -> StoryWorld? {
        guard !isSaving else { return nil }
        guard !isGeneratingTemplate else {
            saveError = KizunaCopy.text(
                japanese: "雛形の生成中は保存できません。生成が終わってから試してください。",
                english: "The story cannot be saved while a template is being generated. Try again when generation finishes."
            )
            return nil
        }
        isSaving = true
        defer { isSaving = false }
        saveError = nil
        guard isReadyToSave else {
            saveError = KizunaCopy.text(
                japanese: "保存データの読み込みが終わるまで保存できません。",
                english: "Saving is disabled until the saved data finishes loading."
            )
            return nil
        }
        let issues = validationIssues
        guard issues.isEmpty else {
            saveError = issues.joined(separator: "\n")
            return nil
        }

        // Repository writes are awaited one by one.  Save one immutable editor
        // snapshot rather than reading live @Published arrays between writes;
        // this keeps World/Cast/Lorebook/Scene from mixing revisions when a
        // caller changes a binding programmatically during a delayed save.
        let draftSnapshot = draft
        let sceneSnapshot = sceneDraft
        let castSnapshot = castDrafts
        let lorebookSnapshot = lorebookDrafts
        let pendingCharactersSnapshot = pendingGeneratedCharacters
        if isCreatingNewWorld {
            StoryWorldCreationJournal.markStaging(
                worldID: draftSnapshot.id,
                generatedCharacterIDs: Array(pendingCharactersSnapshot.keys)
            )
        }
        do {
            // 破壊的な置換の前に、すべての既存関連データを読み取っておく。
            // ここで読み取りに失敗した場合はWorld/Cast/Lorebook/Sceneのいずれも
            // 書き換えず、次回の再試行で正しいスナップショットを取り直せる。
            _ = try await lorebookRepo.fetchAllEntries(storyWorldId: draft.id)
            let existingScenes = try await sceneRepo.fetchScenes(storyWorldId: draft.id)

            // 関連データの読取が全て成功した後にだけ生成キャラを確定する。
            // 雛形を反映しただけではCharacterRepositoryへ書かず、読取失敗・
            // キャンセル・再生成のいずれでもキャラだけが孤児にならないようにする。
            for profile in pendingCharactersSnapshot.values {
                try await characterRepo.saveCharacter(profile)
            }

            // World 保存
            var world = draftSnapshot.normalizedForPersistence
            let openingSummary = sceneSnapshot.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !openingSummary.isEmpty {
                world.openingScene = openingSummary
            }
            // Keep the editor in sync with the persisted invariant so a
            // duplicate does not reappear when the same draft is shown again.
            draft.tags = world.tags
            draft.safetyRules = world.safetyRules
            world.updatedAt = Date()
            try await worldRepo.saveWorld(world)
            // Cast 保存。Repository側の一括置換を使い、deleteAllCastの後に
            // 1件ずつ保存して途中で失敗する部分更新を避ける。
            try await castRepo.replaceCast(castSnapshot, storyWorldId: world.id)
            // LorebookもWorld単位で置き換え、削除されたカードを残さない。
            // 無効化済みエントリも編集保存時に置き換える。enabled のみ取得すると
            // UIから見えない古いカードが story_lorebook.json に残り続ける。
            try await lorebookRepo.replaceEntries(lorebookSnapshot, storyWorldId: world.id)
            // Opening Scene を 1 件 seed / update
            var opening = sceneSnapshot
            opening.storyWorldId = world.id
            if opening.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                opening.title = Self.defaultSceneTitle(for: world.title)
            }
            if opening.mood.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                opening.mood = world.mood
            }
            if opening.sceneGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                opening.sceneGoal = world.storyGoal
            }
            if opening.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                opening.summary = world.openingScene
            }
            if opening.activeCharacterIds.isEmpty {
                let limit = world.isSoloStory ? StoryConstants.soloActiveCharacters : StoryConstants.maxActiveCharacters
                opening.activeCharacterIds = Array(castSnapshot.prefix(limit).map(\.characterId))
            }
            let activeLimit = world.isSoloStory ? StoryConstants.soloActiveCharacters : StoryConstants.maxActiveCharacters
            opening.activeCharacterIds = Array(opening.activeCharacterIds.prefix(activeLimit))
            if existingScenes.isEmpty {
                try await sceneRepo.saveScene(opening)
            } else {
                opening.id = existingScenes[0].id
                opening.createdAt = existingScenes[0].createdAt
                opening.updatedAt = Date()
                try await sceneRepo.saveScene(opening)
            }
            if isCreatingNewWorld {
                StoryWorldCreationJournal.markCommitted(worldID: world.id)
            }
            pendingGeneratedCharacters.removeAll()
            if isCreatingNewWorld {
                StoryWorldCreationJournal.clear(worldID: world.id)
            }
            return world
        } catch {
            AppLog.error("[StoryWorldCreateVM] save failed: %@", error.localizedDescription)
            let rollbackSucceeded: Bool?
            if isCreatingNewWorld {
                let didRollback = await rollbackNewWorldCreation(
                    worldID: draftSnapshot.id,
                    generatedCharacterIDs: Array(pendingCharactersSnapshot.keys)
                )
                rollbackSucceeded = didRollback
                if didRollback {
                    StoryWorldCreationJournal.clear(worldID: draftSnapshot.id)
                } else {
                    StoryWorldCreationJournal.markStaging(
                        worldID: draftSnapshot.id,
                        generatedCharacterIDs: Array(pendingCharactersSnapshot.keys)
                    )
                }
            } else {
                rollbackSucceeded = nil
                // 編集失敗では既存Worldを推測で削除しない。入力を残したまま
                // 再試行できるよう、既存の作成画面を維持する。
                pendingGeneratedCharacters.removeAll()
            }
            saveError = KizunaCopy.text(
                japanese: rollbackSucceeded == true
                    ? "保存に失敗したため、新規ストーリーを取り消しました。入力を確認して、もう一度試してください。"
                    : rollbackSucceeded == false
                        ? "保存に失敗し、作成途中のデータを一部整理できませんでした。次回起動時に整理を再試行します。"
                        : "保存に失敗しました。入力内容と保存先を確認して、もう一度試してください。",
                english: rollbackSucceeded == true
                    ? "The new story was rolled back after saving failed. Check the input and try again."
                    : rollbackSucceeded == false
                        ? "Saving failed and some unfinished data could not be cleaned up. Cleanup will retry next time."
                        : "The story could not be saved. Check the content and storage, then try again."
            )
            return nil
        }
    }

    private static func defaultSceneTitle(for storyTitle: String) -> String {
        let suffix = KizunaCopy.text(japanese: "第 1 場面", english: "Scene 1")
        let trimmedTitle = storyTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? suffix : "\(trimmedTitle) - \(suffix)"
    }

    private func applyGeneratedTemplate(_ template: GeneratedStoryTemplate) async throws {
        await discardPendingGeneratedCharacters()
        let story = template.story
        draft.title = story.title
        draft.shortDescription = story.shortDescription
        draft.genre = Self.category(from: story.genre)
        draft.relationshipGenre = Self.relationship(from: story.relationshipGenre)
        draft.tags = story.tags
        draft.worldSetting = story.worldSetting
        draft.userRole = story.userRole
        draft.openingScene = story.openingScene
        draft.storyGoal = story.storyGoal
        draft.mood = story.mood
        draft.safetyRules = template.generationRules
        draft = draft.normalizedForPersistence

        let scene = template.initialScene
        sceneDraft.title = scene.title
        sceneDraft.location = scene.location
        sceneDraft.timeOfDay = scene.timeOfDay
        sceneDraft.mood = scene.mood
        sceneDraft.sceneGoal = scene.sceneGoal
        sceneDraft.conflict = scene.conflict
        sceneDraft.summary = scene.summary
        sceneDraft.activeCharacterIds = []

        castDrafts.removeAll()
        draft.characterIds.removeAll()
        draft.mainCharacterId = nil

        // 指定がなければ、ユーザーと主役NPC1人だけの単体物語にする。
        // 明示されたcastMode/characterCount、生成配列、入力文の順で
        // 複数キャラの意図を確認し、生成結果を先頭1人へ黙って縮めない。
        let brief = generationBrief.localizedLowercase
        let templateMode = template.castMode?.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        let templateRequestsEnsemble = ["ensemble", "multiple", "multi", "group", "team", "cast"]
            .contains { templateMode?.contains($0) == true }
        let generatedCharacterCount = template.characters.count
        let declaredCharacterCount = template.characterCount ?? 0
        let generatedMultipleCharacters = generatedCharacterCount > 1 || declaredCharacterCount > 1
        // 構造化されたcastMode/characterCountと生成配列を最優先する。モデルが
        // castModeをsoloのまま返しても複数キャラを生成した場合は、先頭だけを
        // 残して黙って捨てず、ユーザーの生成結果をensembleとして保持する。
        let briefRequestsEnsemble = brief.contains("群像")
            || generationBrief.localizedCaseInsensitiveContains("複数人")
            || generationBrief.localizedCaseInsensitiveContains("複数")
            || generationBrief.localizedCaseInsensitiveContains("チーム")
            || generationBrief.localizedCaseInsensitiveContains("仲間たち")
            || brief.contains("ensemble")
            || brief.contains("ensemble cast")
            || brief.contains("multiple characters")
            || brief.contains("multiple character")
            || brief.contains("several characters")
            || brief.contains("many characters")
            || brief.contains("multi-character")
            || brief.contains("multiple people")
            || brief.contains("group")
            || brief.contains("team")
            || brief.contains("friends")
            || brief.contains("companions")
        // 入力文の複数指定は、モデルがcastMode=soloを誤って返しても優先する。
        let wantsEnsemble = generatedMultipleCharacters || templateRequestsEnsemble || briefRequestsEnsemble
        draft.castMode = wantsEnsemble ? .ensemble : .solo
        let generatedCharacters = template.characters.prefix(wantsEnsemble ? 4 : 1)
        for generated in generatedCharacters {
            let profile = CharacterProfile(
                name: generated.name,
                displayName: generated.displayName.isEmpty ? generated.name : generated.displayName,
                shortDescription: generated.shortDescription,
                imageKey: generated.imageKey,
                category: Self.category(from: generated.category),
                relationshipGenre: Self.relationship(from: generated.relationshipGenre),
                personality: generated.personality,
                speakingStyle: generated.speakingStyle,
                background: generated.background,
                relationshipToUser: generated.relationshipToUser,
                scenario: generated.scenario,
                firstMessage: generated.firstMessage,
                tags: generated.tags,
                rules: generated.rules,
                safetyRules: generated.safetyRules,
                visibility: .private,
                safetyRating: .general
            )
            // 保存は世界全体のSaveが成功する直前まで遅延する。
            // ここで即時保存すると、雛形の再生成/キャンセルだけでキャラが
            // キャラクターライブラリーへ残ってしまう。
            addCharacter(profile)
            pendingGeneratedCharacters[profile.id] = profile
            setRole(Self.castRole(from: generated.storyRole), for: profile.id)
            setIntroductionTiming(generated.activeInInitialScene ? .opening : Self.introductionTiming(from: generated.introductionTiming), for: profile.id)
            setImportance(generated.importance, for: profile.id)
            setStoryRelationshipToUser(generated.storyRelationshipToUser, for: profile.id)
            setActiveInOpeningScene(generated.activeInInitialScene, for: profile.id)
        }

        var charactersByName: [String: Set<UUID>] = [:]
        for character in availableCharacters {
            charactersByName[character.visibleName, default: []].insert(character.id)
            charactersByName[character.name, default: []].insert(character.id)
        }
        for relationship in template.relationships {
            guard let fromIDs = charactersByName[relationship.from], fromIDs.count == 1,
                  let toIDs = charactersByName[relationship.to], toIDs.count == 1 else {
                // 同名キャラを辞書の最後/最初へ暗黙に結びつけない。テンプレート側で
                // displayNameを一意にするか、作成後にユーザーが関係を設定する。
                continue
            }
            guard let fromID = fromIDs.first, let toID = toIDs.first else { continue }
            updateRelationship(
                from: fromID,
                to: toID,
                type: Self.relationshipType(from: relationship.relationshipType),
                description: relationship.description,
                tension: relationship.tension,
                trust: relationship.trust
            )
        }
        hasAppliedGeneratedTemplate = true
    }

    private static let storyTemplateSystemPrompt = """
    あなたは\(KizunaCopy.appName)のストーリー作成エンジンです。
    ユーザーの短い説明から、カスタムGPTのように動く物語テンプレートを1つ作ります。
    出力はJSONオブジェクトのみ。Markdown、説明文、コードフェンスは禁止。

    必須JSON schema:
    {
      "story": {
        "title": "string",
        "shortDescription": "string",
        "genre": "school_romance | slice_of_life | detective | fantasy_rpg | sci_fi | club_activity | original_freeform",
        "relationshipGenre": "none | friendship | bl | gl | senpai_kouhai | mentor_student | rival | freeform",
        "worldSetting": "string",
        "userRole": "string",
        "openingScene": "string",
        "storyGoal": "string",
        "mood": "string",
        "tags": ["string"]
      },
      "initialScene": {
        "title": "string",
        "location": "string",
        "timeOfDay": "string",
        "mood": "string",
        "sceneGoal": "string",
        "conflict": "string",
        "summary": "string"
      },
      "characters": [
        {
          "name": "string",
          "displayName": "string",
          "shortDescription": "string",
          "category": "school_romance | classmate | senpai_kouhai | best_friend | detective | fantasy_rpg | sci_fi | club_activity | original_freeform",
          "relationshipGenre": "friendship | bl | gl | senpai_kouhai | mentor_student | rival | freeform",
          "personality": "string",
          "speakingStyle": "string",
          "background": "string",
          "relationshipToUser": "string",
          "scenario": "string",
          "firstMessage": "名前: 本文",
          "tags": ["string"],
          "rules": ["string"],
          "safetyRules": ["string"],
          "storyRole": "main | friend | mentor | rival | secondary",
          "introductionTiming": "opening | early | middle | late | optional",
          "activeInInitialScene": true,
          "importance": 1.0,
          "storyRelationshipToUser": "string",
          "imageKey": "optional_string"
        }
      ],
      "relationships": [
        {
          "from": "displayName",
          "to": "displayName",
          "relationshipType": "friend | classmate | senior_junior | rival | mentor",
          "description": "string",
          "trust": 0.5,
          "tension": 0.2
        }
      ],
      "castMode": "solo | ensemble",
      "characterCount": 1,
      "generationRules": [
        "最初の行は必ず「ナレーション: 本文」",
        "場面が自然なら1ターンで複数キャラが話してよい",
        "キャラ発話は「名前: 本文」",
        "複数キャラを出す時は発話ごとに名前を分ける",
        "active以外のキャラは同じ場にいて自然に反応する時だけ短く喋る",
        "会話だけで終わらせず、場面・表情・沈黙・空気を少し描写する",
        "思考過程、案、選択肢、メタ発言は出さない"
      ]
    }

    原則はユーザーと主役NPC1人の物語にする。ユーザーが複数人・群像劇を明示した時だけ、補助キャラを最大3人追加する。
    初期シーンで同席させるのは原則として主役NPC1人だけにする。
    恋愛や対立は段階的に進める。安全ルールは物語ジャンルに合わせる。
    """

    private static func extractJSONObjectData(from text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}") else { return nil }
        let json = String(trimmed[start...end])
        guard let data = json.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else { return nil }
        return data
    }

    private static func category(from raw: String) -> CharacterCategory {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let category = CharacterCategory(rawValue: normalized) { return category }
        if normalized.contains("ミステリー") || normalized.localizedCaseInsensitiveContains("detective") { return .detective }
        if normalized.contains("SF") || normalized.contains("未来") || normalized.localizedCaseInsensitiveContains("sci") { return .sciFi }
        if normalized.contains("ファンタジー") || normalized.contains("冒険") { return .fantasyRpg }
        if normalized.contains("部活") || normalized.contains("ロボット") { return .clubActivity }
        if normalized.contains("日常") || normalized.contains("喫茶") { return .sliceOfLife }
        if normalized.contains("先輩") { return .senpaiKouhai }
        if normalized.contains("同級") { return .classmate }
        return .originalFreeform
    }

    private static func relationship(from raw: String) -> RelationshipGenre {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let genre = RelationshipGenre(rawValue: normalized) { return genre }
        if normalized.localizedCaseInsensitiveContains("BL") { return .bl }
        if normalized.localizedCaseInsensitiveContains("GL") { return .gl }
        if normalized.contains("先輩") || normalized.contains("後輩") { return .senpaiKouhai }
        if normalized.contains("ライバル") { return .rival }
        if normalized.contains("師") || normalized.contains("先生") { return .mentorStudent }
        if normalized.contains("友") || normalized.contains("仲間") || normalized.contains("相棒") { return .friendship }
        return .freeform
    }

    private static func castRole(from raw: String) -> CastRole {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let role = CastRole(rawValue: normalized) { return role }
        if normalized.contains("メイン") || normalized.contains("主") { return .main }
        if normalized.contains("友") || normalized.contains("仲間") { return .friend }
        if normalized.contains("先輩") || normalized.contains("指導") { return .mentor }
        if normalized.contains("ライバル") { return .rival }
        return .secondary
    }

    private static func introductionTiming(from raw: String) -> IntroductionTiming {
        if let timing = IntroductionTiming(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) { return timing }
        if raw.contains("初") || raw.contains("opening") { return .opening }
        if raw.contains("中") || raw.contains("middle") { return .middle }
        if raw.contains("後") || raw.contains("late") { return .late }
        return .early
    }

    private static func relationshipType(from raw: String) -> RelationshipType {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let type = RelationshipType(rawValue: normalized) { return type }
        if normalized.contains("同級") { return .classmate }
        if normalized.contains("先輩") || normalized.contains("後輩") || normalized.contains("先生") || normalized.contains("mentor") { return .seniorJunior }
        if normalized.contains("ライバル") { return .rival }
        return .friend
    }
}

private struct GeneratedStoryTemplate: Decodable {
    struct Story: Decodable {
        var title: String
        var shortDescription: String
        var genre: String
        var relationshipGenre: String
        var worldSetting: String
        var userRole: String
        var openingScene: String
        var storyGoal: String
        var mood: String
        var tags: [String]
    }

    struct InitialScene: Decodable {
        var title: String
        var location: String
        var timeOfDay: String
        var mood: String
        var sceneGoal: String
        var conflict: String?
        var summary: String
    }

    struct Character: Decodable {
        var name: String
        var displayName: String
        var shortDescription: String
        var category: String
        var relationshipGenre: String
        var personality: String
        var speakingStyle: String
        var background: String
        var relationshipToUser: String
        var scenario: String
        var firstMessage: String
        var tags: [String]
        var rules: [String]
        var safetyRules: [String]
        var storyRole: String
        var introductionTiming: String
        var activeInInitialScene: Bool
        var importance: Double
        var storyRelationshipToUser: String
        var imageKey: String?
    }

    struct Relationship: Decodable {
        var from: String
        var to: String
        var relationshipType: String
        var description: String
        var trust: Double
        var tension: Double
    }

    var story: Story
    var initialScene: InitialScene
    var characters: [Character]
    var relationships: [Relationship]
    var generationRules: [String]
    /// Gemma4が英語で返す構造化ヒント。旧プロンプトには存在しないため任意。
    var castMode: String?
    var characterCount: Int?
}

// MARK: - Detail

@MainActor
final class StoryWorldDetailViewModel: ObservableObject {
    @Published private(set) var world: StoryWorld
    @Published private(set) var cast: [CastMember] = []
    @Published private(set) var scenes: [StoryScene] = []
    @Published private(set) var sessions: [StorySession] = []
    // この物語だけに属する思い出。全体メモリーとは分けて表示・取得する。
    @Published private(set) var storyMemories: [StoryMemory] = []
    @Published private(set) var characterIndex: [UUID: CharacterProfile] = [:]
    @Published private(set) var castLoadFailed = false
    @Published private(set) var sceneLoadFailed = false
    @Published private(set) var sessionLoadFailed = false
    @Published private(set) var sessionSaveFailed = false
    @Published private(set) var characterLoadFailed = false
    /// Castの自動修復に失敗した場合、元の保存内容を保持したままUIへ公開する。
    @Published private(set) var castRepairFailed = false

    private let worldRepo: StoryWorldRepository = LocalJSONStoryWorldRepository()
    private let castRepo: CastRepository = LocalJSONCastRepository()
    private let sceneRepo: StorySceneRepository = LocalJSONStorySceneRepository()
    private let sessionRepo: StorySessionRepository = LocalJSONStorySessionRepository()
    private let lorebookRepo: StoryLorebookRepository = LocalJSONStoryLorebookRepository()
    private let storyMemoryRepo: StoryMemoryRepository = LocalJSONStoryMemoryRepository()
    private let characterRepo: CharacterRepository = LocalJSONCharacterRepository()

    init(world: StoryWorld) {
        self.world = world
    }

    func reload() async {
        castRepairFailed = false
        // キャストの読込失敗を空配列として扱うと、reconciledCastが「全員削除」と
        // 判断し、保存済みの関係設定まで上書きしてしまう。キャストだけは失敗時に
        // 既存の表示を保持して、明示的な再試行を待つ。
        let cast: [CastMember]
        do {
            cast = try await castRepo.fetchCast(storyWorldId: world.id)
            castLoadFailed = false
        } catch {
            castLoadFailed = true
            AppLog.error("[StoryWorldDetailVM] cast load failed: %@", error.localizedDescription)
            return
        }
        let scenes: [StoryScene]
        let sessions: [StorySession]
        let memories: [StoryMemory]
        let chars: [CharacterProfile]
        do {
            async let scenesFetch = sceneRepo.fetchScenes(storyWorldId: world.id)
            async let sessionsFetch = sessionRepo.fetchSessions(storyWorldId: world.id)
            async let memoriesFetch = storyMemoryRepo.fetchMemories(storyWorldId: world.id)
            async let charsFetch = characterRepo.fetchCharacters()
            (scenes, sessions, memories, chars) = try await (scenesFetch, sessionsFetch, memoriesFetch, charsFetch)
            sceneLoadFailed = false
            sessionLoadFailed = false
            characterLoadFailed = false
        } catch {
            // 読込失敗を空配列へ変換すると、新規セッション作成やキャスト修復が
            // 既存データを上書きする。スナップショット全体を保持して再試行する。
            AppLog.error("[StoryWorldDetailVM] snapshot load failed: %@", error.localizedDescription)
            sceneLoadFailed = true
            sessionLoadFailed = true
            characterLoadFailed = true
            return
        }
        let repairedCast = reconciledCast(cast, for: world, existingScenes: scenes)
        let needsCastRepair = Set(cast.map(\.characterId)) != Set(repairedCast.map(\.characterId))
            || cast.count != repairedCast.count
        if needsCastRepair {
            do {
                // 既存Castの削除と修復後の全件保存を1回のread-modify-writeに
                // まとめる。途中失敗で永続化データだけが空/部分状態になるのを防ぐ。
                try await castRepo.replaceCast(repairedCast, storyWorldId: world.id)
                self.cast = repairedCast
            } catch {
                // 修復に失敗した世代を成功扱いにせず、元のCastを表示して
                // ユーザーが再試行できるようにする。元データはrepository側で
                // replaceCastが原子的に保持する。
                castRepairFailed = true
                self.cast = cast
                AppLog.error("[StoryWorldDetailVM] cast repair failed: %@", error.localizedDescription)
            }
        } else {
            self.cast = cast
        }
        self.scenes = scenes
        self.sessions = sessions
        self.storyMemories = memories
        self.characterIndex = chars.reduce(into: [:]) { result, character in
            guard result[character.id] == nil else { return }
            result[character.id] = character
        }
    }

    @discardableResult
    func createOrResumeSession(
        preferredSessionID: UUID? = nil,
        forceNew: Bool = false
    ) async -> (StorySession, StoryScene)? {
        guard !sceneLoadFailed, !sessionLoadFailed, !characterLoadFailed else { return nil }
        sessionSaveFailed = false
        if !forceNew,
           let preferredSessionID,
           let session = sessions.first(where: { $0.id == preferredSessionID }),
           let sceneId = session.currentSceneId,
           let scene = scenes.first(where: { $0.id == sceneId }) {
            return (session, scene)
        }
        if !forceNew,
           preferredSessionID == nil,
           let last = sessions.first,
           let sceneId = last.currentSceneId,
           let scene = scenes.first(where: { $0.id == sceneId }) {
            return (last, scene)
        }
        // 新規セッション + 先頭シーン
        guard let firstScene = scenes.first else { return nil }

        // セッション保存中にシーンが削除・置換されると currentSceneId だけが
        // 無効になる。ここで既存セッションを先頭シーンへ修復しないと、画面を
        // 開くたびに同じセッションが新規作成され、会話履歴が分裂する。
        if !forceNew, let brokenIndex = sessions.firstIndex(where: { session in
            if let preferredSessionID { return session.id == preferredSessionID }
            return session.id == sessions.first?.id
        }) {
            var repaired = sessions[brokenIndex]
            repaired.currentSceneId = firstScene.id
            if repaired.activeCharacterIds == nil {
                repaired.activeCharacterIds = firstScene.activeCharacterIds
            }
            if repaired.progressLabel?.isEmpty != false { repaired.progressLabel = "第1章 きっかけ" }
            if repaired.currentObjective?.isEmpty != false { repaired.currentObjective = firstScene.sceneGoal.isEmpty ? world.storyGoal : firstScene.sceneGoal }
            if repaired.lastSceneSummary?.isEmpty != false {
                repaired.lastSceneSummary = firstScene.summary.isEmpty ? world.openingScene : firstScene.summary
            }
            do {
                try await sessionRepo.saveSession(repaired)
            } catch {
                sessionSaveFailed = true
                AppLog.error("[StoryWorldDetailVM] repaired session save failed: %@", error.localizedDescription)
                return nil
            }
            await reload()
            return (repaired, firstScene)
        }

        let initialObjective = firstScene.sceneGoal.isEmpty ? world.storyGoal : firstScene.sceneGoal
        var session = StorySession(
            storyWorldId: world.id,
            currentSceneId: firstScene.id,
            activeCharacterIds: firstScene.activeCharacterIds,
            progressLabel: "第1章 きっかけ",
            currentObjective: initialObjective,
            lastTurnProgress: nil,
            lastSceneSummary: firstScene.summary.isEmpty ? world.openingScene : firstScene.summary,
            unresolvedHooks: [firstScene.conflict, world.storyGoal].compactMap { $0 }.filter { !$0.isEmpty },
            storyState: StoryState(
                location: firstScene.location,
                timeOfDay: firstScene.timeOfDay,
                mood: firstScene.mood,
                activeGoals: initialObjective.isEmpty ? [] : [initialObjective]
            )
        )
        // opening を narration として 1 件投入 (見やすさのため)
        if !world.openingScene.isEmpty {
            session.messages.append(StoryMessage(author: .narrator, text: world.openingScene))
        }
        do {
            try await sessionRepo.saveSession(session)
        } catch {
            sessionSaveFailed = true
            AppLog.error("[StoryWorldDetailVM] new session save failed: %@", error.localizedDescription)
            return nil
        }
        await reload()
        return (session, firstScene)
    }

    /// Delete this world and every owned record.
    ///
    /// This method intentionally propagates the first repository error.  The
    /// detail view uses the throwing result to keep the sheet open and show a
    /// retryable error; swallowing the error here would make a partial delete
    /// look successful and leave the user with orphaned records.
    func delete() async throws {
        // 標準ストーリーはUI以外からこのメソッドが呼ばれても削除しない。
        guard world.isSystemProtected != true else { return }

        StoryWorldDeletionJournal.mark(world.id)

        // セッションとLorebookは別ファイルのため、世界だけ消すと孤児データが残る。
        let sessions = try await sessionRepo.fetchSessions(storyWorldId: world.id)
        for session in sessions {
            try await sessionRepo.deleteSession(id: session.id)
        }
        let lorebookEntries = try await lorebookRepo.fetchAllEntries(storyWorldId: world.id)
        for entry in lorebookEntries {
            try await lorebookRepo.deleteEntry(id: entry.id)
        }
        try await castRepo.deleteAllCast(storyWorldId: world.id)
        try await sceneRepo.deleteAllScenes(storyWorldId: world.id)
        // 物語を削除する時は、その世界だけの思い出も一緒に削除する。
        try await storyMemoryRepo.deleteAllMemories(storyWorldId: world.id)
        try await worldRepo.deleteWorld(id: world.id)
        StoryWorldDeletionJournal.clear(world.id)
    }

    private func defaultCastMembers(for world: StoryWorld, existingScenes: [StoryScene]) -> [CastMember] {
        let activeIDs = Set(existingScenes.first?.activeCharacterIds ?? Array(world.characterIds.prefix(StoryConstants.maxActiveCharacters)))
        return world.characterIds.enumerated().map { index, characterID in
            CastMember(
                storyWorldId: world.id,
                characterId: characterID,
                roleInStory: characterID == world.mainCharacterId || index == 0 ? .main : .secondary,
                importance: characterID == world.mainCharacterId || index == 0 ? 1.0 : 0.65,
                introductionTiming: activeIDs.contains(characterID) ? .opening : .early,
                relationshipToUser: "",
                isActiveInCurrentScene: activeIDs.contains(characterID)
            )
        }
    }

    private func reconciledCast(
        _ existing: [CastMember],
        for world: StoryWorld,
        existingScenes: [StoryScene]
    ) -> [CastMember] {
        guard !world.characterIds.isEmpty else { return [] }
        let defaults = defaultCastMembers(for: world, existingScenes: existingScenes)
        let existingByCharacterID = existing.reduce(into: [UUID: CastMember]()) { result, member in
            // 重複行がある場合は、最初の1件を正として安定させる。
            if result[member.characterId] == nil { result[member.characterId] = member }
        }
        return defaults.map { existingByCharacterID[$0.characterId] ?? $0 }
    }
}

// MARK: - Session (Scene chat)

/// 休憩提案を表示するための UI 用データ。
/// 生成済みの本文を保持し、同じ発動条件でモデルを二重実行しない。
struct StoryRestSuggestion: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let characterID: UUID?
    let characterName: String
}

@MainActor
final class StorySessionViewModel: ObservableObject {
    @Published private(set) var session: StorySession
    @Published private(set) var scene: StoryScene
    @Published private(set) var world: StoryWorld
    @Published private(set) var cast: [CastMember] = []
    @Published private(set) var characterIndex: [UUID: CharacterProfile] = [:]
    @Published private(set) var bootstrapError: String?
    /// Optional auxiliary retry state must not block the conversation. Keep a
    /// lightweight warning so the user can distinguish "loaded" from
    /// "loaded, but retry work could not be restored".
    @Published private(set) var bootstrapWarning: String?
    @Published private(set) var isRestoringBootstrapWarning = false
    /// A relaunch-recovered turn is actionable in the chat surface. Keep the
    /// operation state separate from the normal generation phase so a failed
    /// discard never makes the incomplete turn look silently resolved.
    @Published private(set) var isHandlingInterruptedTurn = false
    @Published private(set) var interruptedTurnRecoveryError: String?
    /// Only the latest committed AI response can be changed. Keep the action
    /// state separate from generation so an Undo/Regenerate save cannot be
    /// mistaken for an in-flight model request.
    @Published private(set) var isHandlingResponseAction = false
    @Published private(set) var responseActionError: String?
    @Published private(set) var refreshError: String?
    @Published private(set) var sendPreparationError: String?
    @Published private(set) var lastStartedUserMessageID: UUID?
    /// アプリ側で判定した休憩提案。nil の間は提案カードを表示しない。
    @Published var restSuggestion: StoryRestSuggestion?
    /// 了承メッセージの保存中は通常送信を止め、保存結果を待つ。
    @Published private(set) var isSavingRestAcknowledgement = false
    @Published private(set) var restAcknowledgementError: String?
    @Published var generationModel: StoryGenerationModel {
        didSet {
            guard !isApplyingTemporaryGenerationModel else { return }
            preferredGenerationModel = generationModel
            defaults.set(generationModel.rawValue, forKey: generationModelKey)
        }
    }

    let service = StorySessionService()

    private let defaults = UserDefaults.standard
    private let castRepo: CastRepository = LocalJSONCastRepository()
    private let sceneRepo: StorySceneRepository = LocalJSONStorySceneRepository()
    private let sessionRepo: StorySessionRepository = LocalJSONStorySessionRepository()
    private let characterRepo: CharacterRepository = LocalJSONCharacterRepository()
    private let generationModelKey: String
    private var preferredGenerationModel: StoryGenerationModel
    private var isApplyingTemporaryGenerationModel = false

    // 休憩提案の時計はアプリ側だけが管理する。モデルには判定を任せない。
    private var continuousUseStartedAt = Date()
    private var restSuggestionSuppressedUntil: Date?
    private var isGeneratingRestSuggestion = false
    // 同じ60分窓で専用生成を繰り返さないためのアプリ側フラグ。
    private var restSuggestionAttempted = false
    // アプリ内デバッグモードで、UI確認用に30秒後の提案カードを予約する。
    private var debugRestSuggestionTask: Task<Void, Never>?
    private var debugRestSuggestionObserver: NSObjectProtocol?
    private var debugSafetyConcernTask: Task<Void, Never>?
    private var debugSafetyConcernObserver: NSObjectProtocol?
    private var debugRequestPollingTask: Task<Void, Never>?
    private var sendPreparationTask: Task<Void, Never>?
    private var sendPreparationID: UUID?
    private var interruptedRecoveryPreparationID: UUID?
    private var restAcknowledgementTask: Task<Void, Never>?
    private var restAcknowledgementID: UUID?

    init(world: StoryWorld, session: StorySession, scene: StoryScene) {
        self.world = world
        self.session = session
        self.scene = scene
        self.generationModelKey = "storySessionGenerationModel.\(world.id.uuidString)"
        let stored = UserDefaults.standard.string(forKey: generationModelKey)
        let savedModel = stored.flatMap(StoryGenerationModel.init(rawValue:)) ?? .e4b
        self.preferredGenerationModel = savedModel
        self.generationModel = savedModel
        registerDebugRestSuggestionObserver()
        registerDebugSafetyConcernObserver()
        startDebugRequestPolling()
    }

    var preferredModel: StoryGenerationModel {
        preferredGenerationModel
    }

    func applyTemporaryGenerationModel(_ model: StoryGenerationModel) {
        guard generationModel != model else { return }
        isApplyingTemporaryGenerationModel = true
        generationModel = model
        isApplyingTemporaryGenerationModel = false
    }

    func restorePreferredGenerationModel() {
        applyTemporaryGenerationModel(preferredGenerationModel)
    }

    deinit {
        // ViewModel deinit is nonisolated. Release the owner synchronously so
        // a replacement view can recover a pending turn immediately; keep the
        // remaining cancellation/persistence cleanup on the MainActor.
        let service = service
        service.releaseOwnerForTeardown()
        Task { @MainActor in
            service.shutdown()
        }
        debugRestSuggestionTask?.cancel()
        debugSafetyConcernTask?.cancel()
        debugRequestPollingTask?.cancel()
        sendPreparationTask?.cancel()
        restAcknowledgementTask?.cancel()
        if let debugRestSuggestionObserver {
            NotificationCenter.default.removeObserver(debugRestSuggestionObserver)
        }
        if let debugSafetyConcernObserver {
            NotificationCenter.default.removeObserver(debugSafetyConcernObserver)
        }
    }

    func bootstrap() async {
        bootstrapWarning = nil
        interruptedTurnRecoveryError = nil
        do {
            // 前回のプロセス終了時に残ったpendingターンは、生成を再開せず
            // interruptedとして明示的に終了させる。通常ターンのpolling中に
            // fetchするだけではこの処理を実行しない。
            try await sessionRepo.recoverInterruptedTurns(
                storyWorldId: world.id,
                activeOwnerIDs: StoryTurnOwnerRegistry.shared.activeOwnerIDs()
            )
            // recoverInterruptedTurns mutates the durable snapshot. Refresh the
            // local copy before the view decides whether to show recovery UI;
            // otherwise it would keep displaying the stale pending checkpoint
            // that was passed in before recovery ran.
            let recoveredSessions = try await sessionRepo.fetchSessions(storyWorldId: world.id)
            if let recovered = recoveredSessions.first(where: { $0.id == session.id }) {
                session = recovered
            }
        } catch {
            bootstrapError = KizunaCopy.text(
                japanese: "物語の保存状態を確認できませんでした。再試行してください。",
                english: "The story's saved state could not be checked. Try again."
            )
            AppLog.error("[StorySessionVM] interrupted turn recovery failed: %@", error.localizedDescription)
            return
        }
        await restorePendingMemoryRetries()
        do {
            async let castFetch = castRepo.fetchCast(storyWorldId: world.id)
            async let charsFetch = characterRepo.fetchCharacters()
            let (cast, chars) = try await (castFetch, charsFetch)
            self.cast = cast
            self.characterIndex = chars.reduce(into: [:]) { result, character in
                guard result[character.id] == nil else { return }
                result[character.id] = character
            }
            bootstrapError = nil
        } catch {
            bootstrapError = KizunaCopy.text(
                japanese: "キャラクター情報を読み込めませんでした。再試行してください。",
                english: "The story characters could not be loaded. Try again."
            )
            AppLog.error("[StorySessionVM] bootstrap failed: %@", error.localizedDescription)
            return
        }
        consumePendingDebugRestSuggestionRequest()
        consumePendingDebugSafetyConcernRequest()
    }

    /// 通知を取り逃しても、Story画面が生きている間は予約キーを拾えるようにする。
    private func startDebugRequestPolling() {
        guard debugRequestPollingTask == nil else { return }
        debugRequestPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.consumePendingDebugRestSuggestionRequest()
                self.consumePendingDebugSafetyConcernRequest()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// Restores only the auxiliary memory retry queue. This is intentionally
    /// separate from bootstrap so a retry tap cannot reload the whole screen,
    /// re-run interrupted-turn recovery, or duplicate repository fetches.
    func retryBootstrapMemoryRestore() async {
        await restorePendingMemoryRetries()
    }

    private func restorePendingMemoryRetries() async {
        guard !isRestoringBootstrapWarning else { return }
        isRestoringBootstrapWarning = true
        defer { isRestoringBootstrapWarning = false }
        do {
            // Auxiliary memory saves are independent from the visible turn,
            // but their retry payload must survive view dismissal and app
            // restart. Restore only this Session's queue.
            try await service.restorePendingStoryMemoryRetries(
                storySessionID: session.id,
                storyWorldID: world.id
            )
            bootstrapWarning = nil
        } catch {
            bootstrapWarning = KizunaCopy.text(
                japanese: "保存待ちの記憶を読み込めませんでした。保存先を確認して再試行してください。",
                english: "Pending memory saves could not be loaded. Check storage and try again."
            )
            AppLog.error("[StorySessionVM] memory retry restore failed: %@", error.localizedDescription)
        }
    }

    private func registerDebugRestSuggestionObserver() {
        debugRestSuggestionObserver = NotificationCenter.default.addObserver(
            forName: KizunaDebugOptions.restSuggestionRequestNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.startDebugRestSuggestionTimer()
            }
        }
    }

    private func consumePendingDebugRestSuggestionRequest() {
        guard UserDefaults.standard.bool(forKey: KizunaDebugOptions.restSuggestionEnabledKey) else { return }
        let requestedAt = UserDefaults.standard.double(forKey: KizunaDebugOptions.restSuggestionRequestKey)
        // Storyを開くまでの時間を制限しない。設定画面から先に予約しても失わない。
        guard requestedAt > 0, Date().timeIntervalSince1970 - requestedAt < 24 * 60 * 60 else { return }
        UserDefaults.standard.removeObject(forKey: KizunaDebugOptions.restSuggestionRequestKey)
        AppLog.note("[KizunaDebug] rest suggestion request consumed")
        startDebugRestSuggestionTimer()
    }

    /// 設定画面のボタン押下後だけ、休憩提案カードと選択肢UIを確認する。
    private func startDebugRestSuggestionTimer() {
        guard UserDefaults.standard.bool(forKey: KizunaDebugOptions.restSuggestionEnabledKey) else { return }
        guard debugRestSuggestionTask == nil else { return }
        debugRestSuggestionTask = Task { [weak self] in
            defer { self?.debugRestSuggestionTask = nil }
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self, self.restSuggestion == nil else { return }
            UserDefaults.standard.removeObject(forKey: KizunaDebugOptions.restSuggestionRequestKey)
            let character = self.lastSpeakingCharacter() ?? self.activeCharacters.first
            let characterName = character?.visibleName ?? "相手"
            self.restSuggestion = StoryRestSuggestion(
                text: "【DEBUG】休憩提案カードの表示テストです。",
                characterID: self.characterID(for: character),
                characterName: characterName
            )
            AppLog.note("[KizunaDebug] rest suggestion card published")
        }
    }

    private func registerDebugSafetyConcernObserver() {
        debugSafetyConcernObserver = NotificationCenter.default.addObserver(
            forName: KizunaDebugOptions.safetyConcernRequestNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.startDebugSafetyConcernTimer()
            }
        }
    }

    private func consumePendingDebugSafetyConcernRequest() {
        guard UserDefaults.standard.bool(forKey: KizunaDebugOptions.restSuggestionEnabledKey) else { return }
        let requestedAt = UserDefaults.standard.double(forKey: KizunaDebugOptions.safetyConcernRequestKey)
        // Storyを開くまでの時間を制限しない。設定画面から先に予約しても失わない。
        guard requestedAt > 0, Date().timeIntervalSince1970 - requestedAt < 24 * 60 * 60 else { return }
        UserDefaults.standard.removeObject(forKey: KizunaDebugOptions.safetyConcernRequestKey)
        AppLog.note("[KizunaDebug] safety concern request consumed")
        startDebugSafetyConcernTimer()
    }

    /// 設定画面のボタン押下後だけ、相談サポートカードを30秒後に表示する。
    private func startDebugSafetyConcernTimer() {
        guard UserDefaults.standard.bool(forKey: KizunaDebugOptions.restSuggestionEnabledKey) else { return }
        guard debugSafetyConcernTask == nil else { return }
        debugSafetyConcernTask = Task { [weak self] in
            defer { self?.debugSafetyConcernTask = nil }
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            UserDefaults.standard.removeObject(forKey: KizunaDebugOptions.safetyConcernRequestKey)
            self.service.showDebugSafetyConcern()
            AppLog.note("[KizunaDebug] safety concern card published")
        }
    }

    @discardableResult
    func send(_ userText: String) -> Bool {
        sendPreparationError = nil
        lastStartedUserMessageID = nil
        return enqueueSend(userText, existingUserMessageID: nil)
    }

    /// Removes the latest committed AI response while preserving the User
    /// message. The repository performs the CAS; a failed save leaves this
    /// ViewModel's committed snapshot untouched.
    func undoLatestResponse() {
        guard !isHandlingResponseAction,
              service.phase != .thinking,
              let checkpoint = session.latestTurnCheckpoint,
              checkpoint.status == .committed,
              checkpoint.preTurnSnapshot != nil,
              latestCommittedResponse != nil else { return }

        let sessionSnapshot = session
        isHandlingResponseAction = true
        responseActionError = nil
        Task { [weak self] in
            guard let self else { return }
            defer { self.isHandlingResponseAction = false }
            do {
                let updated = try await self.service.undoCommittedResponse(session: sessionSnapshot)
                guard self.session.id == sessionSnapshot.id else { return }
                self.session = updated
            } catch {
                self.responseActionError = KizunaCopy.text(
                    japanese: "この応答を取り消せませんでした。保存状態は変更していません。",
                    english: "This response could not be undone. The saved conversation was left unchanged."
                )
                await self.refreshAfterTurn()
                AppLog.error("[StorySessionVM] undo response failed: %@", error.localizedDescription)
            }
        }
    }

    /// Undo and immediately retry the same logical turn. The persisted
    /// cancelled checkpoint keeps the User message and beginTurn increments
    /// the attempt without creating a second committed response set.
    func regenerateLatestResponse() {
        guard !isHandlingResponseAction,
              service.phase != .thinking,
              !isSavingRestAcknowledgement,
              sendPreparationTask == nil,
              let checkpoint = session.latestTurnCheckpoint,
              checkpoint.status == .committed,
              checkpoint.preTurnSnapshot != nil,
              latestCommittedResponse != nil,
              let userMessage = session.messages.last(where: {
                  $0.id == checkpoint.userMessageID && $0.author.isUser
              }) else { return }

        let sessionSnapshot = session
        let userMessageID = userMessage.id
        let userText = userMessage.text
        isHandlingResponseAction = true
        responseActionError = nil
        Task { [weak self] in
            guard let self else { return }
            defer { self.isHandlingResponseAction = false }
            do {
                let undone = try await self.service.undoCommittedResponse(session: sessionSnapshot)
                guard self.session.id == sessionSnapshot.id else { return }
                self.session = undone
                guard self.enqueueSend(
                    userText,
                    existingUserMessageID: userMessageID,
                    allowDuringResponseAction: true,
                    regenerationSnapshot: sessionSnapshot
                ) else {
                    await self.restoreRegenerationSnapshot(sessionSnapshot)
                    self.responseActionError = KizunaCopy.text(
                        japanese: "再生成を開始できませんでした。残っている発言からもう一度お試しください。",
                        english: "Regeneration could not start. Try again from the preserved message."
                    )
                    return
                }
            } catch {
                self.responseActionError = KizunaCopy.text(
                    japanese: "再生成の準備に失敗しました。保存状態は変更していません。",
                    english: "Regeneration could not be prepared. The saved conversation was left unchanged."
                )
                await self.refreshAfterTurn()
                AppLog.error("[StorySessionVM] regenerate response failed: %@", error.localizedDescription)
            }
        }
    }

    /// Reuses the exact user message and logical turn after a relaunch marked
    /// its pending checkpoint as interrupted. StorySessionService increments
    /// the persisted attempt and beginTurn keeps the user message idempotent.
    @discardableResult
    func retryInterruptedTurn() -> Bool {
        guard !isHandlingInterruptedTurn,
              let message = interruptedTurnMessage else { return false }
        interruptedTurnRecoveryError = nil
        isHandlingInterruptedTurn = true
        let accepted = enqueueSend(
            message.text,
            existingUserMessageID: message.id,
            isInterruptedRecovery: true
        )
        guard accepted else {
            isHandlingInterruptedTurn = false
            interruptedTurnRecoveryError = KizunaCopy.text(
                japanese: "いま別の処理を実行中です。少し待ってからもう一度お試しください。",
                english: "Another operation is in progress. Wait a moment and try again."
            )
            return false
        }
        return true
    }

    /// Removes only the incomplete turn after a CAS against the snapshot that
    /// the user saw. A late model callback then cannot pass commitTurn because
    /// the checkpoint has been removed under the same file lock.
    func discardInterruptedTurn() {
        guard !isHandlingInterruptedTurn,
              let checkpoint = interruptedTurn,
              session.latestTurnCheckpoint?.attempt == checkpoint.attempt else { return }
        let sessionID = session.id
        let turnID = checkpoint.turnID
        let attempt = checkpoint.attempt
        let expectedRevision = session.effectivePersistenceRevision
        isHandlingInterruptedTurn = true
        interruptedTurnRecoveryError = nil
        Task { [weak self] in
            guard let self else { return }
            defer { self.isHandlingInterruptedTurn = false }
            do {
                let updated = try await self.sessionRepo.discardInterruptedTurn(
                    sessionID: sessionID,
                    turnID: turnID,
                    attempt: attempt,
                    expectedRevision: expectedRevision
                )
                guard self.session.id == sessionID else { return }
                self.session = updated
            } catch {
                self.interruptedTurnRecoveryError = KizunaCopy.text(
                    japanese: "中断した発言を破棄できませんでした。保存状態を再確認してください。",
                    english: "The interrupted message could not be discarded. Check the saved state and try again."
                )
                await self.refreshAfterTurn()
            }
        }
    }

    /// Starts a normal or retry turn through the same preparation path. A retry
    /// carries the existing user-message ID to StorySessionService, which makes
    /// the user append idempotent even when the stored error card is retried.
    @discardableResult
    private func enqueueSend(
        _ userText: String,
        existingUserMessageID: UUID?,
        isInterruptedRecovery: Bool = false,
        allowDuringResponseAction: Bool = false,
        regenerationSnapshot: StorySession? = nil
    ) -> Bool {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              service.phase != .thinking,
              !isSavingRestAcknowledgement,
              (allowDuringResponseAction || !isHandlingResponseAction),
              sendPreparationTask == nil else { return false }
        sendPreparationError = nil
        // 直前ターンの保存完了通知と送信タップが競合すると、古い session スナップショットで
        // 次のターンを開始して新しい発言を上書きする。送信前に最新状態を一度だけ読み直す。
        let preparationID = UUID()
        sendPreparationID = preparationID
        if isInterruptedRecovery {
            interruptedRecoveryPreparationID = preparationID
        }
        sendPreparationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.sendPreparationID == preparationID {
                    self.sendPreparationTask = nil
                    self.sendPreparationID = nil
                }
                if isInterruptedRecovery,
                   self.interruptedRecoveryPreparationID == preparationID {
                    self.interruptedRecoveryPreparationID = nil
                    self.isHandlingInterruptedTurn = false
                }
            }
            guard !Task.isCancelled, self.sendPreparationID == preparationID else {
                if let regenerationSnapshot {
                    await self.restoreRegenerationSnapshot(regenerationSnapshot)
                }
                return
            }
            guard await self.refreshAfterTurn() else {
                self.sendPreparationError = self.refreshError ?? KizunaCopy.text(
                    japanese: "保存状態を確認できないため、送信を開始できませんでした。",
                    english: "The message could not start because the saved state could not be verified."
                )
                if let regenerationSnapshot {
                    await self.restoreRegenerationSnapshot(regenerationSnapshot)
                }
                return
            }
            // キャンセルと再送が近接すると、古い準備タスクが最新の送信を
            // 横取りしないよう、IDとTask.isCancelledの両方を確認する。
            guard !Task.isCancelled,
                  self.sendPreparationID == preparationID,
                  self.service.phase != .thinking else {
                if let regenerationSnapshot {
                    await self.restoreRegenerationSnapshot(regenerationSnapshot)
                }
                return
            }
            guard let startedUserMessageID = self.service.send(
                trimmed,
                session: self.session,
                world: self.world,
                scene: self.scene,
                generationModel: self.generationModel,
                existingUserMessageID: existingUserMessageID
            ) else {
                if isInterruptedRecovery {
                    self.interruptedTurnRecoveryError = KizunaCopy.text(
                        japanese: "再試行を開始できませんでした。保存待ちの処理が終わってから、もう一度お試しください。",
                        english: "The retry could not start. Try again after the pending save finishes."
                    )
                } else {
                    self.sendPreparationError = KizunaCopy.text(
                        japanese: "送信を開始できませんでした。入力内容は保持しています。もう一度お試しください。",
                        english: "The message could not start. Your text was kept; try again."
                    )
                }
                if let regenerationSnapshot {
                    await self.restoreRegenerationSnapshot(regenerationSnapshot)
                }
                return
            }
            self.lastStartedUserMessageID = startedUserMessageID

            // Service 内で session/scene が永続化されるので、こちらは UI 更新のため
            // 軽くポーリングで再取得する (将来 Combine pipeline 化)。
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, self.sendPreparationID == preparationID else { return }
                await self.refreshAfterTurn()
                if self.service.phase == .idle {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard !Task.isCancelled, self.sendPreparationID == preparationID else { return }
                    await self.refreshAfterTurn()
                    break
                }
            }
            guard !Task.isCancelled, self.sendPreparationID == preparationID else { return }
            await self.refreshAfterTurn()
        }
        return true
    }

    /// Retries the user turn associated with one persisted system error card.
    /// Older cards without metadata fall back to the closest preceding user
    /// message, so sessions written before this change remain retryable.
    @discardableResult
    func retryLastMessage(for systemMessageID: UUID) -> Bool {
        guard let targetUserMessageID = retryTargetUserMessageID(for: systemMessageID),
              let userMessage = session.messages.first(where: { message in
                  message.id == targetUserMessageID && message.author.isUser
              }) else {
            return false
        }
        return enqueueSend(userMessage.text, existingUserMessageID: targetUserMessageID)
    }

    /// 永続化されていない一時ランタイム通知を再試行する。補助保存の
    /// 通知は保存操作だけを再実行し、userTurn通知だけが本文生成へ戻る。
    @discardableResult
    func retryRuntimeNotice(_ notice: StoryRuntimeNotice) -> Bool {
        switch notice.retryAction {
        case let .storyTurnCommit(retry):
            Task { [weak self] in
                guard let self else { return }
                await self.service.retryStoryTurnCommit(retry)
                await self.refreshAfterTurn()
            }
            return true
        case let .storyMemory(retry):
            Task { [weak self] in
                guard let self else { return }
                await self.service.retryStoryMemorySave(retry)
                await self.refreshAfterTurn()
            }
            return true
        case let .narration(text):
            service.dismissRuntimeNotice()
            Task { [weak self] in
                guard let self else { return }
                await self.service.addNarration(text, session: self.session)
                await self.refreshAfterTurn()
            }
            return true
        case let .restAcknowledgement(characterID, characterName):
            service.dismissRuntimeNotice()
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.service.addRestAcknowledgement(
                        characterID: characterID,
                        characterName: characterName,
                        session: self.session
                    )
                    await self.refreshAfterTurn()
                } catch is CancellationError {
                    return
                } catch {
                    // The service publishes persistence failures itself, but
                    // keep unexpected retry failures visible instead of
                    // turning the retry tap into a silent no-op.
                    self.restAcknowledgementError = KizunaCopy.text(
                        japanese: "続行メッセージを保存できませんでした。もう一度お試しください。",
                        english: "The continue message could not be saved. Try again."
                    )
                    AppLog.error("[StorySessionVM] runtime acknowledgement retry failed: %@", error.localizedDescription)
                }
            }
            return true
        case .userTurn:
            // enqueueSend refreshes the persisted session immediately before
            // calling the service. Always carry the stable notice ID instead
            // of deciding from this possibly stale ViewModel snapshot; the
            // repository beginTurn path is idempotent whether the message is
            // already persisted or needs to be appended.
            let accepted = enqueueSend(
                notice.userText,
                existingUserMessageID: notice.persistedUserMessageIDForRetry
            )
            if accepted {
                service.dismissRuntimeNotice()
            }
            return accepted
        }
    }

    /// Resolves a system card to its persisted user turn. The metadata path is
    /// stable across restarts; the positional fallback handles legacy records.
    private func retryTargetUserMessageID(for systemMessageID: UUID) -> UUID? {
        guard let systemIndex = session.messages.firstIndex(where: { message in
            message.id == systemMessageID
        }), case .system = session.messages[systemIndex].author else { return nil }
        let systemMessage = session.messages[systemIndex]
        if let persistedID = StoryRetryMetadata.userMessageID(in: systemMessage.text) {
            return persistedID
        }
        return session.messages[..<systemIndex].reversed().first(where: { message in
            message.author.isUser
        })?.id
    }

    /// 生成停止時は、サービス本体だけでなく送信前の状態再読込も止める。
    /// これを残すと停止直後の再送が一時的に弾かれる。
    func cancelGeneration() {
        sendPreparationID = nil
        sendPreparationTask?.cancel()
        sendPreparationTask = nil
        if interruptedRecoveryPreparationID != nil {
            interruptedRecoveryPreparationID = nil
            isHandlingInterruptedTurn = false
        }
        restAcknowledgementID = nil
        restAcknowledgementTask?.cancel()
        restAcknowledgementTask = nil
        isSavingRestAcknowledgement = false
        service.cancel()
    }

    private func restoreRegenerationSnapshot(_ snapshot: StorySession) async {
        guard session.id == snapshot.id,
              session.latestTurnCheckpoint?.status == .cancelled,
              session.latestTurnCheckpoint?.failureCode == "undone" else { return }
        do {
            session = try await sessionRepo.restoreUndoneTurn(
                snapshot,
                expectedRevision: session.effectivePersistenceRevision
            )
        } catch {
            responseActionError = KizunaCopy.text(
                japanese: "再生成を開始できず、元の応答も復元できませんでした。保存状態を確認してください。",
                english: "Regeneration could not start and the original reply could not be restored. Check the saved state."
            )
            AppLog.error("[StorySessionVM] regeneration rollback failed: %@", error.localizedDescription)
        }
    }

    func addNarration(_ text: String) {
        Task { [weak self] in
            guard let self else { return }
            await self.service.addNarration(text, session: self.session)
            await self.refreshAfterTurn()
        }
    }

    @discardableResult
    func refreshAfterTurn() async -> Bool {
        do {
            let sessions = try await sessionRepo.fetchSessions(storyWorldId: world.id)
            guard let updatedSession = sessions.first(where: { $0.id == session.id }) else {
                throw StoryTurnPersistenceError.sessionNotFound
            }
            let scenes = try await sceneRepo.fetchScenes(storyWorldId: world.id)
            guard let updatedScene = scenes.first(where: { $0.id == scene.id }) else {
                throw StoryTurnPersistenceError.turnNotUndoable
            }
            self.session = updatedSession
            self.scene = updatedScene
            refreshError = nil
            return true
        } catch {
            refreshError = KizunaCopy.text(
                japanese: "保存状態を読み込めませんでした。送信前に再試行してください。",
                english: "The saved state could not be loaded. Retry before sending."
            )
            AppLog.error("[StorySessionVM] refresh after turn failed: %@", error.localizedDescription)
            return false
        }
    }

    /// キャラクター発話が保存された直後だけ、60 分条件をアプリ側で判定する。
    /// 条件を満たしても、専用生成はこのメソッドから 1 回だけ呼び出す。
    func evaluateRestSuggestionAfterTurn() async {
        guard service.phase == .idle,
              restSuggestion == nil,
              !isGeneratingRestSuggestion,
              let lastMessage = session.messages.last,
              case .cast = lastMessage.author else { return }

        let now = Date()
        guard now.timeIntervalSince(continuousUseStartedAt) >= 60 * 60 else { return }
        if let suppressedUntil = restSuggestionSuppressedUntil, now < suppressedUntil { return }
        if restSuggestionSuppressedUntil != nil {
            // 120分の抑制が終わったら、次の提案窓を開始できる。
            restSuggestionSuppressedUntil = nil
            restSuggestionAttempted = false
        }
        guard !restSuggestionAttempted else { return }

        restSuggestionAttempted = true
        isGeneratingRestSuggestion = true
        defer { isGeneratingRestSuggestion = false }

        let character = lastSpeakingCharacter() ?? activeCharacters.first
        let characterName = character?.visibleName ?? "相手"
        guard let generatedText = await service.generateRestSuggestion(
            character: character,
            world: world,
            scene: scene,
            generationModel: generationModel
        ) else {
            // モデルが生成できない場合は固定文を出さず、休憩提案を表示しない。
            // 時計を再スタートし、次の60分窓までは再生成しない。
            continuousUseStartedAt = now
            restSuggestionAttempted = false
            return
        }
        let text = generatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        restSuggestion = StoryRestSuggestion(
            text: text,
            characterID: characterID(for: character),
            characterName: characterName
        )
    }

    /// 「少し休む」は強制終了せず、次の連続利用の時計だけを再スタートする。
    func chooseRestSuggestionBreak() {
        restAcknowledgementError = nil
        restSuggestion = nil
        continuousUseStartedAt = Date()
        restSuggestionSuppressedUntil = nil
        restSuggestionAttempted = false
    }

    /// 「このまま続ける」は短い了承を 1 回だけ記録し、その後 120 分は抑制する。
    func chooseRestSuggestionContinue() {
        guard let suggestion = restSuggestion,
              !isSavingRestAcknowledgement,
              !isHandlingResponseAction else { return }
        restAcknowledgementError = nil
        restSuggestionSuppressedUntil = Date().addingTimeInterval(120 * 60)
        restSuggestionAttempted = true

        // Prefer the identity captured when the suggestion was generated. A
        // later refresh can change the last message, and resolving by display
        // name alone is ambiguous. Fall back to the current last speaker only
        // when the suggestion's UUID is no longer present in the index.
        let resolvedCharacter: CharacterProfile? = {
            if let suggestedID = suggestion.characterID,
               let suggestedCharacter = characterIndex[suggestedID] {
                return suggestedCharacter
            }
            return lastSpeakingCharacter() ?? activeCharacters.first
        }()
        guard let character = resolvedCharacter,
              let characterID = characterID(for: character) else {
            // Do not silently turn the tap into a no-op. Keep the card visible,
            // clear the suppression window, and let the user retry after the
            // cast/index has been reloaded.
            restSuggestionSuppressedUntil = nil
            restSuggestionAttempted = false
            restAcknowledgementError = KizunaCopy.text(
                japanese: "続行するキャラクターを特定できません。キャストを再読み込みしてからもう一度お試しください。",
                english: "The character for this suggestion could not be resolved. Reload the cast and try again."
            )
            return
        }
        let name = character.visibleName
        let acknowledgementID = UUID()
        restAcknowledgementID = acknowledgementID
        isSavingRestAcknowledgement = true
        restAcknowledgementTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.restAcknowledgementID == acknowledgementID {
                    self.isSavingRestAcknowledgement = false
                    self.restAcknowledgementTask = nil
                }
            }
            do {
                // A turn may have completed immediately before the card was
                // tapped. Read the current record before appending so this
                // action never saves an older session snapshot.
                let latestSessions = try await self.sessionRepo.fetchSessions(storyWorldId: self.world.id)
                guard let latestSession = latestSessions.first(where: { $0.id == self.session.id }) else {
                    throw StoryRestAcknowledgementError.sessionUnavailable
                }
                try await self.service.addRestAcknowledgement(
                    characterID: characterID,
                    characterName: name,
                    session: latestSession
                )
                guard !Task.isCancelled,
                      self.restAcknowledgementID == acknowledgementID else { return }
                await self.refreshAfterTurn()
                self.restSuggestion = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      self.restAcknowledgementID == acknowledgementID else { return }
                // Keep the card and its text so the user can retry without
                // losing the decision or pretending it was saved.
                self.restSuggestion = suggestion
                self.restSuggestionSuppressedUntil = nil
                self.restSuggestionAttempted = false
                self.restAcknowledgementError = KizunaCopy.text(
                    japanese: "続行メッセージを保存できませんでした。もう一度お試しください。",
                    english: "The continue message could not be saved. Try again."
                )
                AppLog.error("[StorySessionVM] rest acknowledgement save failed: %@", error.localizedDescription)
            }
        }
    }

    private func lastSpeakingCharacter() -> CharacterProfile? {
        for message in session.messages.reversed() {
            guard case let .cast(characterID, _) = message.author else { continue }
            if let character = characterIndex[characterID] { return character }
        }
        return nil
    }

    private func characterID(for character: CharacterProfile?) -> UUID? {
        guard let character else { return nil }
        return characterIndex.first(where: { $0.value.id == character.id })?.key
    }

    var activeCharacters: [CharacterProfile] {
        session.resolvedActiveCharacterIds(fallback: scene)
            .compactMap { characterIndex[$0] }
    }

    var interruptedTurn: StoryTurnCheckpoint? {
        guard let checkpoint = session.latestTurnCheckpoint,
              checkpoint.status == .interrupted else { return nil }
        return checkpoint
    }

    var interruptedTurnMessage: StoryMessage? {
        guard let checkpoint = interruptedTurn else { return nil }
        return session.messages.first { $0.id == checkpoint.userMessageID }
    }

    /// The action affordance is intentionally limited to the latest committed
    /// generated response. Older messages and legacy checkpoints without a
    /// pre-turn snapshot remain read-only rather than risking an incomplete
    /// restoration.
    var latestCommittedResponse: StoryMessage? {
        guard let checkpoint = session.latestTurnCheckpoint,
              checkpoint.status == .committed,
              checkpoint.preTurnSnapshot != nil,
              !checkpoint.assistantMessageIDs.isEmpty else { return nil }
        let assistantIDs = Set(checkpoint.assistantMessageIDs)
        return session.messages.last { message in
            guard assistantIDs.contains(message.id) else { return false }
            switch message.author {
            case .narrator, .cast(_, _):
                return true
            case .user, .system:
                return false
            }
        }
    }

    var latestCommittedResponseMessageID: UUID? {
        latestCommittedResponse?.id
    }
}

private enum StoryRestAcknowledgementError: Error {
    case sessionUnavailable
}
