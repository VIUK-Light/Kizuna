/*
仕様:
- 役割: StorySessionから継続カードを構築し、現在のCharacterProfileを解決する。
- 方針: PersonaThreadはPersonaChatStoreが正本、StorySessionはStoryRepositoryが正本。
  このVMは一覧表示用の読み取りアダプターに限定する。
*/

import Foundation
import Combine

@MainActor
final class KizunaContinuationViewModel: ObservableObject {
    @Published private(set) var storyItems: [KizunaContinuationItem] = []
    @Published private(set) var currentCharacters: [UUID: CharacterProfile] = [:]
    @Published private(set) var loadError: String?

    private let worldRepo: StoryWorldRepository
    private let sessionRepo: StorySessionRepository
    private let characterRepo: CharacterRepository

    init(
        worldRepo: StoryWorldRepository = LocalJSONStoryWorldRepository(),
        sessionRepo: StorySessionRepository = LocalJSONStorySessionRepository(),
        characterRepo: CharacterRepository = LocalJSONCharacterRepository()
    ) {
        self.worldRepo = worldRepo
        self.sessionRepo = sessionRepo
        self.characterRepo = characterRepo
    }

    func reload() async {
        loadError = nil

        do {
            let characters = try await characterRepo.fetchCharacters()
            currentCharacters = Dictionary(uniqueKeysWithValues: characters.map { ($0.id, $0) })
        } catch {
            // Storyの継続一覧は表示できるため、画像だけ旧スナップショットへ戻す。
            // 前回の成功値を残すと、読込に失敗した世代でも古い画像を現在値として
            // 表示してしまうため、personaItem(for:) のsnapshot fallbackへ戻す。
            currentCharacters = [:]
            AppLog.error("[KizunaContinuationVM] character load failed: %@", String(describing: error))
        }

        do {
            let worlds = try await worldRepo.fetchWorlds()
            var items: [KizunaContinuationItem] = []
            var seenSessionIDs = Set<UUID>()
            var failedWorldCount = 0

            for world in worlds {
                do {
                    let sessions = try await sessionRepo.fetchSessions(storyWorldId: world.id)
                    for session in sessions where seenSessionIDs.insert(session.id).inserted {
                        let preview = session.messages.last?.text
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .nonEmpty
                            ?? KizunaCopy.text(japanese: "新しい物語", english: "New story")
                        let localizedWorld = world.localizedForCurrentLanguage
                        items.append(
                            KizunaContinuationItem(
                                route: .story(worldID: world.id, sessionID: session.id),
                                kind: .story,
                                title: localizedWorld.title,
                                preview: preview,
                                updatedAt: session.updatedAt,
                                personaProfile: nil,
                                storyWorld: world
                            )
                        )
                    }
                } catch {
                    failedWorldCount += 1
                    AppLog.error(
                        "[KizunaContinuationVM] story sessions load failed for %@: %@",
                        world.id.uuidString,
                        String(describing: error)
                    )
                }
            }

            storyItems = items.sorted { $0.updatedAt > $1.updatedAt }
            if failedWorldCount > 0 {
                loadError = KizunaCopy.text(
                    japanese: "一部のストーリー履歴を読み込めませんでした。",
                    english: "Some story history could not be loaded."
                )
            }
        } catch {
            loadError = KizunaCopy.text(
                japanese: "ストーリー履歴を読み込めませんでした。",
                english: "Story history could not be loaded."
            )
            AppLog.error("[KizunaContinuationVM] story world load failed: %@", String(describing: error))
        }
    }

    func personaItem(for thread: PersonaThread) -> KizunaContinuationItem {
        var displayProfile = thread.personaSnapshot
        if let characterID = thread.characterID,
           let character = currentCharacters[characterID] {
            displayProfile.avatarStyleID = character.imageKey
            displayProfile.avatarImageData = character.avatarImageData
        }
        let preview = thread.latestDisplayableMessage?.text
            .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? KizunaCopy.text(japanese: "新しい会話", english: "New conversation")
        return KizunaContinuationItem(
            route: .persona(threadID: thread.id),
            kind: .persona,
            title: thread.title,
            preview: preview,
            updatedAt: thread.updatedAt,
            personaProfile: displayProfile,
            storyWorld: nil
        )
    }

    func storyWorld(for route: KizunaConversationRoute) -> StoryWorld? {
        guard case .story(let worldID, _) = route else { return nil }
        return storyItems.first(where: { $0.storyWorld?.id == worldID })?.storyWorld
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
