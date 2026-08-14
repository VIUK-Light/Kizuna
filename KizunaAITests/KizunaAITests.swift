import XCTest
@testable import KizunaAI

@MainActor
final class KizunaAITests: XCTestCase {
    func testStoryStateMetadataParserParsesOneValidUpdate() throws {
        let result = StoryStateMetadataParser.parse(
            "ナギ: 港を見つめた\n状態更新: {\"mood\":\"calm\",\"activeGoals\":[]}"
        )

        guard case let .valid(visibleText, payload) = result else {
            return XCTFail("a single complete STATE_UPDATE must be valid")
        }
        XCTAssertEqual(visibleText, "ナギ: 港を見つめた")
        let patch = try JSONDecoder().decode(StoryStatePatch.self, from: payload)
        XCTAssertEqual(patch.mood, "calm")
        XCTAssertEqual(patch.activeGoals, [])
    }

    func testStoryStateMetadataParserRejectsMalformedMetadataAndRemovesIt() {
        let inputs = [
            "ナギ: 返事\nSTATE_UPDATE: {\"mood\":\"calm\"}\nSTATE_UPDATE: {\"location\":\"harbor\"}",
            "ナギ: 返事\nSTATE_UPDATE: {\"mood\":\"calm\"} 余計な本文",
            "ナギ: 返事\nSTATE_UPDATE: {\"mood\":",
            "ナギ: 返事\nSTATE_UPDATE: {}",
            "ナギ: 返事\nSTATE_UPDATE: not-json"
        ]

        for input in inputs {
            guard case let .invalid(visibleText) = StoryStateMetadataParser.parse(input) else {
                return XCTFail("malformed metadata must be invalid: \(input)")
            }
            XCTAssertEqual(visibleText, "ナギ: 返事")
        }
    }

    func testStoryStateMetadataParserReturnsAbsentWithoutMarker() {
        let text = "ナギ: ただの返事"

        guard case let .absent(visibleText) = StoryStateMetadataParser.parse(text) else {
            return XCTFail("ordinary story text must not become metadata")
        }
        XCTAssertEqual(visibleText, text)
    }

    func testPersonaResponseSanitizerPreservesVisibleText() {
        let input = "<think>private reasoning</think>Visible response"

        XCTAssertEqual(
            PersonaResponseSanitizer.sanitize(input),
            "Visible response"
        )
    }

    func testPersonaResponseSanitizerPreservesMarkdownCode() {
        let input = "```text\n<think>example</think>\n```"

        XCTAssertEqual(
            PersonaResponseSanitizer.sanitize(input),
            input
        )
    }

    func testStoryTurnReducerLifecycleUsesStableTurnIdentity() {
        let turnID = UUID()
        let userMessageID = UUID()
        let assistantMessageID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let committedAt = Date(timeIntervalSince1970: 110)

        let pending = StoryTurnReducer.begin(
            turnID: turnID,
            userMessageID: userMessageID,
            attempt: 2,
            baseRevision: 7,
            startedAt: startedAt,
            updatedAt: startedAt
        )
        XCTAssertEqual(pending.status, .pending)
        XCTAssertEqual(pending.attempt, 2)
        XCTAssertEqual(pending.baseRevision, 7)

        let committed = StoryTurnReducer.commit(
            pending: pending,
            assistantMessageIDs: [assistantMessageID],
            updatedAt: committedAt
        )
        XCTAssertEqual(committed.status, .committed)
        XCTAssertEqual(committed.turnID, turnID)
        XCTAssertEqual(committed.userMessageID, userMessageID)
        XCTAssertEqual(committed.assistantMessageIDs, [assistantMessageID])
        XCTAssertEqual(committed.startedAt, startedAt)

        let interrupted = StoryTurnReducer.finish(
            pending: pending,
            status: .interrupted,
            failureCode: "app_relaunch",
            updatedAt: committedAt
        )
        XCTAssertEqual(interrupted.status, .interrupted)
        XCTAssertEqual(interrupted.failureCode, "app_relaunch")
        XCTAssertEqual(interrupted.turnID, turnID)
    }

    func testLegacyStorySessionWithoutTurnFieldsStillDecodes() throws {
        let message = StoryMessage(author: .user, text: "legacy")
        let session = StorySession(
            storyWorldId: UUID(),
            messages: [message]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(session)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "persistenceRevision")
        object.removeValue(forKey: "latestTurnCheckpoint")
        if var messages = object["messages"] as? [[String: Any]] {
            for index in messages.indices {
                messages[index].removeValue(forKey: "turnID")
            }
            object["messages"] = messages
        }
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(StorySession.self, from: legacyData)

        XCTAssertNil(decoded.persistenceRevision)
        XCTAssertNil(decoded.latestTurnCheckpoint)
        XCTAssertNil(decoded.messages.first?.turnID)
        XCTAssertEqual(decoded.messages.first?.text, "legacy")
    }

    func testLegacyStorySceneWithoutRevisionDecodesWithZeroEffectiveRevision() throws {
        let scene = StoryScene(
            storyWorldId: UUID(),
            persistenceRevision: 4,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(scene)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "persistenceRevision")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(StoryScene.self, from: legacyData)

        XCTAssertNil(decoded.persistenceRevision)
        XCTAssertEqual(decoded.effectivePersistenceRevision, 0)
    }

    func testStorySessionRepositoryBeginTurnIsIdempotentForSameTurnID() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let session = StorySession(
            id: UUID(),
            storyWorldId: worldID,
            messages: [],
            persistenceRevision: nil
        )
        try LocalJSONStoreTransaction.save(
            [session],
            fileName: "story_sessions.json",
            baseURL: storageURL
        )

        let repository = LocalJSONStorySessionRepository(storageURL: storageURL)
        let userMessage = StoryMessage(author: .user, text: "同じターン")
        let turnID = UUID()
        let first = try await repository.beginTurn(
            session: session,
            userMessage: userMessage,
            turnID: turnID,
            attempt: 1
        )
        let retryMessage = StoryMessage(id: UUID(), author: .user, text: "同じターン")
        let second = try await repository.beginTurn(
            session: session,
            userMessage: retryMessage,
            turnID: turnID,
            attempt: 1
        )

        XCTAssertEqual(first.latestTurnCheckpoint?.turnID, turnID)
        XCTAssertEqual(second.latestTurnCheckpoint?.turnID, turnID)
        XCTAssertEqual(second.latestTurnCheckpoint?.userMessageID, userMessage.id)
        XCTAssertEqual(second.persistenceRevision, first.persistenceRevision)
        XCTAssertEqual(second.messages.filter { $0.turnID == turnID }.count, 1)
        let persisted = try LocalJSONStoreTransaction.load(
            StorySession.self,
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        XCTAssertEqual(persisted.first?.messages.filter { $0.turnID == turnID }.count, 1)
        XCTAssertEqual(persisted.first?.messages.first?.id, userMessage.id)
    }

    func testStorySessionRepositoryMoveSessionAdvancesRevision() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let originalWorldID = UUID()
        let movedWorldID = UUID()
        let session = StorySession(
            id: UUID(),
            storyWorldId: originalWorldID,
            persistenceRevision: 4,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        try LocalJSONStoreTransaction.save(
            [session],
            fileName: "story_sessions.json",
            baseURL: storageURL
        )

        let repository = LocalJSONStorySessionRepository(storageURL: storageURL)
        try await repository.moveSession(id: session.id, toStoryWorldId: movedWorldID)

        let moved = try LocalJSONStoreTransaction.load(
            StorySession.self,
            fileName: "story_sessions.json",
            baseURL: storageURL
        ).first
        XCTAssertEqual(moved?.storyWorldId, movedWorldID)
        XCTAssertEqual(moved?.persistenceRevision, 5)
        XCTAssertGreaterThan(moved?.updatedAt ?? .distantPast, session.updatedAt)
    }

    func testStorySceneRepositoryAdvancesRevisionAcrossEditPaths() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let originalWorldID = UUID()
        let movedWorldID = UUID()
        let sceneID = UUID()
        let repository = LocalJSONStorySceneRepository(storageURL: storageURL)
        let initial = StoryScene(
            id: sceneID,
            storyWorldId: originalWorldID,
            summary: "初期",
            updatedAt: Date(timeIntervalSince1970: 100)
        )

        try await repository.saveScene(initial)
        var persisted = try LocalJSONStoreTransaction.load(
            StoryScene.self,
            fileName: "story_scenes.json",
            baseURL: storageURL
        ).first
        XCTAssertEqual(persisted?.persistenceRevision, 1)

        let repairedImageKey = try await repository.repairMissingImageKey(
            storyWorldId: originalWorldID,
            sceneId: sceneID,
            imageKey: "scene-image"
        )
        XCTAssertTrue(repairedImageKey)
        persisted = try LocalJSONStoreTransaction.load(
            StoryScene.self,
            fileName: "story_scenes.json",
            baseURL: storageURL
        ).first
        XCTAssertEqual(persisted?.persistenceRevision, 2)
        XCTAssertEqual(persisted?.imageKey, "scene-image")

        try await repository.moveScene(id: sceneID, toStoryWorldId: movedWorldID)
        persisted = try LocalJSONStoreTransaction.load(
            StoryScene.self,
            fileName: "story_scenes.json",
            baseURL: storageURL
        ).first
        XCTAssertEqual(persisted?.persistenceRevision, 3)
        XCTAssertEqual(persisted?.storyWorldId, movedWorldID)

        var edited = try XCTUnwrap(persisted)
        edited.summary = "編集後"
        try await repository.saveScene(edited)
        persisted = try LocalJSONStoreTransaction.load(
            StoryScene.self,
            fileName: "story_scenes.json",
            baseURL: storageURL
        ).first
        XCTAssertEqual(persisted?.persistenceRevision, 4)
        XCTAssertEqual(persisted?.summary, "編集後")
    }

    func testStorySessionRepositoryCommitRejectsStalePersistenceRevision() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let scene = StoryScene(
            id: UUID(),
            storyWorldId: worldID,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let session = StorySession(
            id: UUID(),
            storyWorldId: worldID,
            currentSceneId: scene.id
        )
        try LocalJSONStoreTransaction.save(
            [session],
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [scene],
            fileName: "story_scenes.json",
            baseURL: storageURL
        )

        let repository = LocalJSONStorySessionRepository(storageURL: storageURL)
        let userMessage = StoryMessage(author: .user, text: "開始")
        let turnID = UUID()
        let pending = try await repository.beginTurn(
            session: session,
            userMessage: userMessage,
            turnID: turnID,
            attempt: 1
        )
        var externalUpdate = pending
        externalUpdate.lastTurnProgress = "別経路の更新"
        try await repository.saveSession(externalUpdate)

        do {
            _ = try await repository.commitTurn(
                session: pending,
                scene: scene,
                turnID: turnID,
                assistantMessageIDs: []
            )
            XCTFail("a stale turn snapshot must not commit")
        } catch let error as StoryTurnPersistenceError {
            XCTAssertEqual(
                error,
                .revisionConflict(
                    expected: pending.effectivePersistenceRevision,
                    actual: externalUpdate.effectivePersistenceRevision + 1
                )
            )
        }
    }

    func testStorySessionRepositoryFinishTurnIgnoresStaleAttempt() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let sessionID = UUID()
        let turnID = UUID()
        let date = Date(timeIntervalSince1970: 100)
        let checkpoint = StoryTurnReducer.begin(
            turnID: turnID,
            userMessageID: UUID(),
            attempt: 1,
            ownerID: StoryTurnOwner.currentID,
            baseRevision: 0,
            startedAt: date,
            updatedAt: date
        )
        let session = StorySession(
            id: sessionID,
            storyWorldId: worldID,
            persistenceRevision: 1,
            latestTurnCheckpoint: checkpoint,
            updatedAt: date
        )
        try LocalJSONStoreTransaction.save(
            [session],
            fileName: "story_sessions.json",
            baseURL: storageURL
        )

        let repository = LocalJSONStorySessionRepository(storageURL: storageURL)
        try await repository.finishTurn(
            sessionID: sessionID,
            turnID: turnID,
            attempt: 2,
            status: .cancelled,
            failureCode: "stale_cleanup"
        )

        let persisted = try LocalJSONStoreTransaction.load(
            StorySession.self,
            fileName: "story_sessions.json",
            baseURL: storageURL
        ).first
        XCTAssertEqual(persisted?.latestTurnCheckpoint?.status, .pending)
        XCTAssertEqual(persisted?.latestTurnCheckpoint?.attempt, 1)
        XCTAssertEqual(persisted?.persistenceRevision, 1)
    }

    func testStorySessionRepositoryRecoveryPreservesCurrentOwner() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let sessionID = UUID()
        let checkpoint = StoryTurnReducer.begin(
            turnID: UUID(),
            userMessageID: UUID(),
            attempt: 1,
            ownerID: StoryTurnOwner.currentID,
            baseRevision: 0,
            startedAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let session = StorySession(
            id: sessionID,
            storyWorldId: worldID,
            persistenceRevision: 1,
            latestTurnCheckpoint: checkpoint
        )
        try LocalJSONStoreTransaction.save(
            [session],
            fileName: "story_sessions.json",
            baseURL: storageURL
        )

        let repository = LocalJSONStorySessionRepository(storageURL: storageURL)
        try await repository.recoverInterruptedTurns(storyWorldId: worldID)

        let persisted = try LocalJSONStoreTransaction.load(
            StorySession.self,
            fileName: "story_sessions.json",
            baseURL: storageURL
        ).first
        XCTAssertEqual(persisted?.latestTurnCheckpoint?.status, .pending)
        XCTAssertEqual(persisted?.latestTurnCheckpoint?.ownerID, StoryTurnOwner.currentID)
    }

    func testStorySessionRepositoryCommitPreservesExternallyEditedScene() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let sceneID = UUID()
        let sessionID = UUID()
        let turnID = UUID()
        let generatedAt = Date(timeIntervalSince1970: 100)
        let editedAt = Date(timeIntervalSince1970: 200)
        let checkpoint = StoryTurnReducer.begin(
            turnID: turnID,
            userMessageID: UUID(),
            attempt: 1,
            ownerID: StoryTurnOwner.currentID,
            baseRevision: 0,
            startedAt: generatedAt,
            updatedAt: generatedAt
        )
        let session = StorySession(
            id: sessionID,
            storyWorldId: worldID,
            currentSceneId: sceneID,
            persistenceRevision: 1,
            latestTurnCheckpoint: checkpoint,
            updatedAt: generatedAt
        )
        let externallyEditedScene = StoryScene(
            id: sceneID,
            storyWorldId: worldID,
            summary: "ユーザーが編集した場面",
            updatedAt: editedAt
        )
        let generatedScene = StoryScene(
            id: sceneID,
            storyWorldId: worldID,
            summary: "生成側の古い要約",
            updatedAt: generatedAt
        )
        try LocalJSONStoreTransaction.save(
            [session],
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [externallyEditedScene],
            fileName: "story_scenes.json",
            baseURL: storageURL
        )

        let repository = LocalJSONStorySessionRepository(storageURL: storageURL)
        let committed = try await repository.commitTurn(
            session: session,
            scene: generatedScene,
            turnID: turnID,
            assistantMessageIDs: []
        )

        let persistedScene = try LocalJSONStoreTransaction.load(
            StoryScene.self,
            fileName: "story_scenes.json",
            baseURL: storageURL
        ).first
        XCTAssertEqual(committed.latestTurnCheckpoint?.status, .committed)
        XCTAssertEqual(persistedScene?.summary, "ユーザーが編集した場面")
        XCTAssertEqual(persistedScene?.updatedAt, editedAt)
    }

    func testStorySessionRepositoryUsesSceneRevisionForSameTimestampConflicts() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let sceneID = UUID()
        let sessionID = UUID()
        let turnID = UUID()
        let sameDate = Date(timeIntervalSince1970: 100)
        let checkpoint = StoryTurnReducer.begin(
            turnID: turnID,
            userMessageID: UUID(),
            attempt: 1,
            ownerID: StoryTurnOwner.currentID,
            baseRevision: 0,
            startedAt: sameDate,
            updatedAt: sameDate
        )
        let session = StorySession(
            id: sessionID,
            storyWorldId: worldID,
            currentSceneId: sceneID,
            persistenceRevision: 1,
            latestTurnCheckpoint: checkpoint,
            updatedAt: sameDate
        )
        let externallyEditedScene = StoryScene(
            id: sceneID,
            storyWorldId: worldID,
            summary: "同時刻のユーザー編集",
            persistenceRevision: 2,
            updatedAt: sameDate
        )
        let staleGeneratedScene = StoryScene(
            id: sceneID,
            storyWorldId: worldID,
            summary: "古い生成側要約",
            persistenceRevision: 1,
            updatedAt: sameDate
        )
        try LocalJSONStoreTransaction.save(
            [session],
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [externallyEditedScene],
            fileName: "story_scenes.json",
            baseURL: storageURL
        )

        let repository = LocalJSONStorySessionRepository(storageURL: storageURL)
        let committed = try await repository.commitTurn(
            session: session,
            scene: staleGeneratedScene,
            turnID: turnID,
            assistantMessageIDs: []
        )

        let persistedScene = try LocalJSONStoreTransaction.load(
            StoryScene.self,
            fileName: "story_scenes.json",
            baseURL: storageURL
        ).first
        XCTAssertEqual(committed.latestTurnCheckpoint?.status, .committed)
        XCTAssertEqual(persistedScene?.summary, "同時刻のユーザー編集")
        XCTAssertEqual(persistedScene?.persistenceRevision, 2)
    }

    func testStoryTurnJournalDoesNotOverwriteNewerPersistedRecords() throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let sceneID = UUID()
        let turnID = UUID()
        let oldDate = Date(timeIntervalSince1970: 100)
        let newDate = Date(timeIntervalSince1970: 200)
        let pending = StoryTurnReducer.begin(
            turnID: turnID,
            userMessageID: UUID(),
            attempt: 1,
            ownerID: nil,
            baseRevision: 1,
            startedAt: oldDate,
            updatedAt: oldDate
        )
        let committedCheckpoint = StoryTurnReducer.commit(
            pending: pending,
            assistantMessageIDs: [],
            updatedAt: oldDate
        )
        let journalSession = StorySession(
            id: UUID(),
            storyWorldId: worldID,
            currentSceneId: sceneID,
            persistenceRevision: 2,
            latestTurnCheckpoint: committedCheckpoint,
            updatedAt: oldDate
        )
        var persistedSession = journalSession
        persistedSession.persistenceRevision = 3
        persistedSession.lastTurnProgress = "新しい保存"
        persistedSession.updatedAt = newDate
        let journalScene = StoryScene(
            id: sceneID,
            storyWorldId: worldID,
            summary: "古いジャーナル",
            updatedAt: oldDate
        )
        var persistedScene = journalScene
        persistedScene.summary = "新しい保存"
        persistedScene.updatedAt = newDate

        try LocalJSONStoreTransaction.save(
            [persistedSession],
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [persistedScene],
            fileName: "story_scenes.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [StoryTurnJournalEntry(turnID: turnID, session: journalSession, scene: journalScene)],
            fileName: "story_turn_journal.json",
            baseURL: storageURL
        )

        try StoryTurnJournal.recoverIfNeeded(baseURL: storageURL)

        let sessions = try LocalJSONStoreTransaction.load(
            StorySession.self,
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        let scenes = try LocalJSONStoreTransaction.load(
            StoryScene.self,
            fileName: "story_scenes.json",
            baseURL: storageURL
        )
        XCTAssertEqual(sessions.first?.persistenceRevision, 3)
        XCTAssertEqual(sessions.first?.lastTurnProgress, "新しい保存")
        XCTAssertEqual(scenes.first?.summary, "新しい保存")
        XCTAssertTrue(
            try LocalJSONStoreTransaction.load(
                StoryTurnJournalEntry.self,
                fileName: "story_turn_journal.json",
                baseURL: storageURL
            ).isEmpty
        )
    }

    func testStoryTurnJournalDoesNotOverwriteNewerSceneRevisionAtSameTimestamp() throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let sceneID = UUID()
        let turnID = UUID()
        let sameDate = Date(timeIntervalSince1970: 100)
        let checkpoint = StoryTurnReducer.commit(
            pending: StoryTurnReducer.begin(
                turnID: turnID,
                userMessageID: UUID(),
                attempt: 1,
                ownerID: nil,
                baseRevision: 1,
                startedAt: sameDate,
                updatedAt: sameDate
            ),
            assistantMessageIDs: [],
            updatedAt: sameDate
        )
        let journalSession = StorySession(
            id: UUID(),
            storyWorldId: worldID,
            currentSceneId: sceneID,
            persistenceRevision: 2,
            latestTurnCheckpoint: checkpoint,
            updatedAt: sameDate
        )
        let journalScene = StoryScene(
            id: sceneID,
            storyWorldId: worldID,
            summary: "古いjournal",
            persistenceRevision: 2,
            updatedAt: sameDate
        )
        var persistedScene = journalScene
        persistedScene.summary = "新しい保存"
        persistedScene.persistenceRevision = 3

        try LocalJSONStoreTransaction.save(
            [journalSession],
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [persistedScene],
            fileName: "story_scenes.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [StoryTurnJournalEntry(turnID: turnID, session: journalSession, scene: journalScene)],
            fileName: "story_turn_journal.json",
            baseURL: storageURL
        )

        try StoryTurnJournal.recoverIfNeeded(baseURL: storageURL)

        let recoveredScene = try LocalJSONStoreTransaction.load(
            StoryScene.self,
            fileName: "story_scenes.json",
            baseURL: storageURL
        ).first
        XCTAssertEqual(recoveredScene?.summary, "新しい保存")
        XCTAssertEqual(recoveredScene?.persistenceRevision, 3)
    }

    func testStoryTurnJournalDoesNotApplyLegacySceneOverRevisionAwareScene() throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let sceneID = UUID()
        let turnID = UUID()
        let oldDate = Date(timeIntervalSince1970: 100)
        let newerDate = Date(timeIntervalSince1970: 200)
        let checkpoint = StoryTurnReducer.commit(
            pending: StoryTurnReducer.begin(
                turnID: turnID,
                userMessageID: UUID(),
                attempt: 1,
                ownerID: nil,
                baseRevision: 1,
                startedAt: oldDate,
                updatedAt: oldDate
            ),
            assistantMessageIDs: [],
            updatedAt: oldDate
        )
        let journalSession = StorySession(
            id: UUID(),
            storyWorldId: worldID,
            currentSceneId: sceneID,
            persistenceRevision: 2,
            latestTurnCheckpoint: checkpoint,
            updatedAt: oldDate
        )
        // 更新前に作られたjournalを再現するため、Sceneのrevisionはnilのままにする。
        let legacyJournalScene = StoryScene(
            id: sceneID,
            storyWorldId: worldID,
            summary: "旧形式journal",
            updatedAt: newerDate
        )
        let persistedScene = StoryScene(
            id: sceneID,
            storyWorldId: worldID,
            summary: "更新後の保存",
            persistenceRevision: 1,
            updatedAt: oldDate
        )

        try LocalJSONStoreTransaction.save(
            [journalSession],
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [persistedScene],
            fileName: "story_scenes.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [StoryTurnJournalEntry(
                turnID: turnID,
                session: journalSession,
                scene: legacyJournalScene
            )],
            fileName: "story_turn_journal.json",
            baseURL: storageURL
        )

        try StoryTurnJournal.recoverIfNeeded(baseURL: storageURL)

        let recoveredScene = try LocalJSONStoreTransaction.load(
            StoryScene.self,
            fileName: "story_scenes.json",
            baseURL: storageURL
        ).first
        XCTAssertEqual(recoveredScene?.summary, "更新後の保存")
        XCTAssertEqual(recoveredScene?.persistenceRevision, 1)
    }

    func testStoryTurnJournalAppliesNewerSceneRevisionAtSameTimestamp() throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let sceneID = UUID()
        let turnID = UUID()
        let sameDate = Date(timeIntervalSince1970: 100)
        let checkpoint = StoryTurnReducer.commit(
            pending: StoryTurnReducer.begin(
                turnID: turnID,
                userMessageID: UUID(),
                attempt: 1,
                ownerID: nil,
                baseRevision: 1,
                startedAt: sameDate,
                updatedAt: sameDate
            ),
            assistantMessageIDs: [],
            updatedAt: sameDate
        )
        let journalSession = StorySession(
            id: UUID(),
            storyWorldId: worldID,
            currentSceneId: sceneID,
            persistenceRevision: 2,
            latestTurnCheckpoint: checkpoint,
            updatedAt: sameDate
        )
        let persistedScene = StoryScene(
            id: sceneID,
            storyWorldId: worldID,
            summary: "古い保存",
            persistenceRevision: 1,
            updatedAt: sameDate
        )
        let journalScene = StoryScene(
            id: sceneID,
            storyWorldId: worldID,
            summary: "新しいjournal",
            persistenceRevision: 2,
            updatedAt: sameDate
        )

        try LocalJSONStoreTransaction.save(
            [journalSession],
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [persistedScene],
            fileName: "story_scenes.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [StoryTurnJournalEntry(turnID: turnID, session: journalSession, scene: journalScene)],
            fileName: "story_turn_journal.json",
            baseURL: storageURL
        )

        try StoryTurnJournal.recoverIfNeeded(baseURL: storageURL)

        let recoveredScene = try LocalJSONStoreTransaction.load(
            StoryScene.self,
            fileName: "story_scenes.json",
            baseURL: storageURL
        ).first
        XCTAssertEqual(recoveredScene?.summary, "新しいjournal")
        XCTAssertEqual(recoveredScene?.persistenceRevision, 2)
    }

    func testStoryTurnJournalRetainsMissingSessionUntilItReturns() throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let sceneID = UUID()
        let turnID = UUID()
        let date = Date(timeIntervalSince1970: 100)
        let pending = StoryTurnReducer.begin(
            turnID: turnID,
            userMessageID: UUID(),
            attempt: 1,
            ownerID: nil,
            baseRevision: 1,
            startedAt: date,
            updatedAt: date
        )
        let session = StorySession(
            id: UUID(),
            storyWorldId: worldID,
            currentSceneId: sceneID,
            persistenceRevision: 2,
            latestTurnCheckpoint: StoryTurnReducer.commit(
                pending: pending,
                assistantMessageIDs: [],
                updatedAt: date
            ),
            updatedAt: date
        )
        let scene = StoryScene(id: sceneID, storyWorldId: worldID, updatedAt: date)
        var persistedScene = scene
        persistedScene.summary = "既存の場面"
        persistedScene.updatedAt = date.addingTimeInterval(-10)
        try LocalJSONStoreTransaction.save(
            [persistedScene],
            fileName: "story_scenes.json",
            baseURL: storageURL
        )
        // ファイル自体の欠落ではなく、対象recordだけが存在しない状態を
        // 作る。空配列を明示的に保存した上でjournalを保持できるか確認する。
        try LocalJSONStoreTransaction.save(
            [StorySession](),
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [StoryTurnJournalEntry(turnID: turnID, session: session, scene: scene)],
            fileName: "story_turn_journal.json",
            baseURL: storageURL
        )

        try StoryTurnJournal.recoverIfNeeded(baseURL: storageURL)

        XCTAssertTrue(
            try LocalJSONStoreTransaction.load(
            StorySession.self,
            fileName: "story_sessions.json",
            baseURL: storageURL
        ).isEmpty
        )
        XCTAssertEqual(
            try LocalJSONStoreTransaction.load(
                StoryScene.self,
                fileName: "story_scenes.json",
                baseURL: storageURL
            ).first?.summary,
            "既存の場面"
        )
        XCTAssertEqual(
            try LocalJSONStoreTransaction.load(
                StoryTurnJournalEntry.self,
                fileName: "story_turn_journal.json",
                baseURL: storageURL
            ).count,
            1
        )

        try LocalJSONStoreTransaction.save(
            [session],
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        try StoryTurnJournal.recoverIfNeeded(baseURL: storageURL)
        XCTAssertEqual(
            try LocalJSONStoreTransaction.load(
                StorySession.self,
                fileName: "story_sessions.json",
                baseURL: storageURL
            ).first?.latestTurnCheckpoint?.status,
            .committed
        )
        XCTAssertEqual(
            try LocalJSONStoreTransaction.load(
                StoryScene.self,
                fileName: "story_scenes.json",
                baseURL: storageURL
            ).first?.summary,
            scene.summary
        )
        XCTAssertTrue(
            try LocalJSONStoreTransaction.load(
                StoryTurnJournalEntry.self,
                fileName: "story_turn_journal.json",
                baseURL: storageURL
            ).isEmpty
        )
    }

    func testStoryTurnJournalReplaysValidEntryWhenAnotherEntryIsInvalid() throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let validSceneID = UUID()
        let validTurnID = UUID()
        let date = Date(timeIntervalSince1970: 100)
        let validCheckpoint = StoryTurnReducer.commit(
            pending: StoryTurnReducer.begin(
                turnID: validTurnID,
                userMessageID: UUID(),
                attempt: 1,
                ownerID: nil,
                baseRevision: 1,
                startedAt: date,
                updatedAt: date
            ),
            assistantMessageIDs: [],
            updatedAt: date
        )
        var persistedSession = StorySession(
            id: UUID(),
            storyWorldId: worldID,
            currentSceneId: validSceneID,
            lastTurnProgress: "古い保存",
            persistenceRevision: 1,
            latestTurnCheckpoint: validCheckpoint,
            updatedAt: date
        )
        let validScene = StoryScene(
            id: validSceneID,
            storyWorldId: worldID,
            summary: "古い場面",
            updatedAt: date
        )
        var validJournalSession = persistedSession
        validJournalSession.persistenceRevision = 2
        validJournalSession.lastTurnProgress = "有効な復旧"
        validJournalSession.updatedAt = date.addingTimeInterval(100)
        var validJournalScene = validScene
        validJournalScene.summary = "有効な場面"
        validJournalScene.updatedAt = date.addingTimeInterval(100)

        let invalidScene = StoryScene(
            id: UUID(),
            storyWorldId: UUID(),
            updatedAt: date
        )
        var invalidSession = persistedSession
        invalidSession.id = UUID()
        invalidSession.currentSceneId = invalidScene.id
        invalidSession.latestTurnCheckpoint = StoryTurnReducer.commit(
            pending: StoryTurnReducer.begin(
                turnID: UUID(),
                userMessageID: UUID(),
                attempt: 1,
                ownerID: nil,
                baseRevision: 1,
                startedAt: date,
                updatedAt: date
            ),
            assistantMessageIDs: [],
            updatedAt: date
        )

        try LocalJSONStoreTransaction.save(
            [persistedSession],
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [validScene],
            fileName: "story_scenes.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [
                StoryTurnJournalEntry(
                    turnID: validTurnID,
                    session: validJournalSession,
                    scene: validJournalScene
                ),
                StoryTurnJournalEntry(
                    turnID: UUID(),
                    session: invalidSession,
                    scene: invalidScene
                )
            ],
            fileName: "story_turn_journal.json",
            baseURL: storageURL
        )

        try StoryTurnJournal.recoverIfNeeded(baseURL: storageURL)

        let sessions = try LocalJSONStoreTransaction.load(
            StorySession.self,
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        let scenes = try LocalJSONStoreTransaction.load(
            StoryScene.self,
            fileName: "story_scenes.json",
            baseURL: storageURL
        )
        XCTAssertEqual(sessions.first?.lastTurnProgress, "有効な復旧")
        XCTAssertEqual(scenes.first?.summary, "有効な場面")
        XCTAssertTrue(
            try LocalJSONStoreTransaction.load(
                StoryTurnJournalEntry.self,
                fileName: "story_turn_journal.json",
                baseURL: storageURL
            ).isEmpty
        )
    }

    func testStoryTurnJournalRecoversValidEntryWhenMalformedRecordIsMixed() throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let sceneID = UUID()
        let turnID = UUID()
        let date = Date(timeIntervalSince1970: 100)
        let checkpoint = StoryTurnReducer.commit(
            pending: StoryTurnReducer.begin(
                turnID: turnID,
                userMessageID: UUID(),
                attempt: 1,
                ownerID: nil,
                baseRevision: 1,
                startedAt: date,
                updatedAt: date
            ),
            assistantMessageIDs: [],
            updatedAt: date
        )
        let persistedSession = StorySession(
            id: UUID(),
            storyWorldId: worldID,
            currentSceneId: sceneID,
            lastTurnProgress: "古い保存",
            persistenceRevision: 1,
            latestTurnCheckpoint: checkpoint,
            updatedAt: date
        )
        let persistedScene = StoryScene(
            id: sceneID,
            storyWorldId: worldID,
            summary: "古い場面",
            updatedAt: date
        )
        var journalSession = persistedSession
        journalSession.persistenceRevision = 2
        journalSession.lastTurnProgress = "壊れたentryがあっても復旧"
        journalSession.updatedAt = date.addingTimeInterval(100)
        var journalScene = persistedScene
        journalScene.summary = "有効な場面"
        journalScene.updatedAt = date.addingTimeInterval(100)

        try LocalJSONStoreTransaction.save(
            [persistedSession],
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [persistedScene],
            fileName: "story_scenes.json",
            baseURL: storageURL
        )

        let validEntry = StoryTurnJournalEntry(
            turnID: turnID,
            session: journalSession,
            scene: journalScene
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var rawItems = try JSONSerialization.jsonObject(
            with: encoder.encode([validEntry]),
            options: [.fragmentsAllowed]
        ) as! [Any]
        rawItems.append(["turnID": "not-a-uuid"])
        let journalData = try JSONSerialization.data(
            withJSONObject: rawItems,
            options: [.prettyPrinted, .sortedKeys]
        )
        try journalData.write(
            to: storageURL.appendingPathComponent("story_turn_journal.json"),
            options: [.atomic]
        )

        try StoryTurnJournal.recoverIfNeeded(baseURL: storageURL)

        let sessions = try LocalJSONStoreTransaction.load(
            StorySession.self,
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        let scenes = try LocalJSONStoreTransaction.load(
            StoryScene.self,
            fileName: "story_scenes.json",
            baseURL: storageURL
        )
        XCTAssertEqual(sessions.first?.lastTurnProgress, "壊れたentryがあっても復旧")
        XCTAssertEqual(scenes.first?.summary, "有効な場面")
        XCTAssertTrue(
            try LocalJSONStoreTransaction.load(
                StoryTurnJournalEntry.self,
                fileName: "story_turn_journal.json",
                baseURL: storageURL
            ).isEmpty
        )
        let backups = try FileManager.default.contentsOfDirectory(
            at: storageURL,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("story_turn_journal.corrupt-") }
        XCTAssertEqual(backups.count, 1)
    }

    func testStoryTurnJournalDoesNotOverwriteUnreadableJournal() throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let journalURL = storageURL.appendingPathComponent("story_turn_journal.json")
        try FileManager.default.createDirectory(at: journalURL, withIntermediateDirectories: true)

        XCTAssertThrowsError(try StoryTurnJournal.recoverIfNeeded(baseURL: storageURL))

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        let backups = try FileManager.default.contentsOfDirectory(
            at: storageURL,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("story_turn_journal.corrupt-") }
        XCTAssertTrue(backups.isEmpty)
    }

    private func makeStoryPersistenceTestDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("KizunaStoryPersistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    @MainActor
    func testPersonaStorePreservesCorruptRawBlobAcrossCRUDAndFinalize() {
        let suiteName = "KizunaAITests.PersonaCorrupt.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let raw = Data([0x00, 0xFF, 0x10, 0x7B])
        defaults.set(raw, forKey: "persona.threads.v1")
        defaults.set("sentinel-active", forKey: "persona.activeThreadID.v1")
        let store = PersonaChatStore(defaults: defaults)
        let persona = PersonaProfile(
            name: "Test",
            personality: "quiet",
            tone: .casual,
            relation: .friend
        )

        XCTAssertTrue(store.isPersistenceRecoveryRequired)
        let threadsBeforeMutation = store.threads
        let activeThreadBeforeMutation = store.activeThreadID
        store.finalizePersist()
        XCTAssertNil(store.createThread(with: persona, characterID: UUID()))
        store.appendMessage(
            PersonaMessage(role: .assistant, text: "hello"),
            toThread: UUID()
        )

        XCTAssertEqual(store.threads, threadsBeforeMutation)
        XCTAssertEqual(store.activeThreadID, activeThreadBeforeMutation)
        XCTAssertEqual(defaults.data(forKey: "persona.threads.v1"), raw)
        XCTAssertEqual(defaults.string(forKey: "persona.activeThreadID.v1"), "sentinel-active")

        do {
            let exportURL = try store.exportCorruptPersistedThreads()
            defer { try? FileManager.default.removeItem(at: exportURL) }
            XCTAssertEqual(try Data(contentsOf: exportURL), raw)
        } catch {
            XCTFail("corrupt data should be exportable: \(error)")
        }

        XCTAssertTrue(store.discardCorruptPersistedThreads())
        XCTAssertEqual(defaults.data(forKey: "persona.threads.v1.corrupt-backup"), raw)
        XCTAssertNil(defaults.object(forKey: "persona.activeThreadID.v1"))
    }

    @MainActor
    func testPersonaStoreTreatsNonDataRawValueAsCorruptAndAllowsExplicitRecovery() {
        let suiteName = "KizunaAITests.PersonaWrongType.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("not-a-data-blob", forKey: "persona.threads.v1")
        let store = PersonaChatStore(defaults: defaults)

        XCTAssertTrue(store.isPersistenceRecoveryRequired)
        XCTAssertEqual(defaults.string(forKey: "persona.threads.v1"), "not-a-data-blob")
        do {
            let exportURL = try store.exportCorruptPersistedThreads()
            defer { try? FileManager.default.removeItem(at: exportURL) }
            XCTAssertEqual(try String(contentsOf: exportURL, encoding: .utf8), "not-a-data-blob")
        } catch {
            XCTFail("string corruption should be exportable: \(error)")
        }
        XCTAssertTrue(store.discardCorruptPersistedThreads())
        XCTAssertFalse(store.isPersistenceRecoveryRequired)
        XCTAssertEqual(defaults.string(forKey: "persona.threads.v1.corrupt-backup"), "not-a-data-blob")
        XCTAssertEqual(defaults.data(forKey: "persona.threads.v1"), try? JSONEncoder().encode([PersonaThread]()))
    }

    @MainActor
    func testPersonaStoreStillPersistsValidData() {
        let suiteName = "KizunaAITests.PersonaValid.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = PersonaChatStore(defaults: defaults)
        let persona = PersonaProfile(
            name: "Saved",
            personality: "warm",
            tone: .casual,
            relation: .friend
        )
        guard let thread = first.createThread(with: persona) else {
            XCTFail("valid persistence should allow thread creation")
            return
        }
        first.appendMessage(
            PersonaMessage(role: .user, text: "keep this"),
            toThread: thread.id
        )

        let second = PersonaChatStore(defaults: defaults)
        XCTAssertEqual(second.threads.count, 1)
        XCTAssertEqual(second.threads.first?.messages.first?.text, "keep this")
    }

    @MainActor
    func testPersonaStoreDetachingCharacterReferenceKeepsRecentOrder() throws {
        let suiteName = "KizunaPersonaStoreTests.Detach.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let profile = PersonaProfile(
            name: "Test",
            personality: "Calm",
            tone: .calm,
            relation: .friend
        )
        let characterID = UUID()
        let olderDate = Date(timeIntervalSince1970: 100)
        let newerDate = Date(timeIntervalSince1970: 200)
        let older = PersonaThread(
            id: UUID(),
            personaSnapshot: profile,
            characterID: characterID,
            title: "Older",
            createdAt: olderDate,
            updatedAt: olderDate
        )
        let newer = PersonaThread(
            id: UUID(),
            personaSnapshot: profile,
            characterID: UUID(),
            title: "Newer",
            createdAt: newerDate,
            updatedAt: newerDate
        )
        defaults.set(
            try JSONEncoder().encode([older, newer]),
            forKey: "persona.threads.v1"
        )

        let store = PersonaChatStore(defaults: defaults)
        store.detachCharacterReference(threadID: older.id)

        XCTAssertEqual(store.threads.first?.id, older.id)
        XCTAssertNil(store.thread(id: older.id)?.characterID)
    }

    func testPersonaThreadOrderingPlacesCompletedConversationFirst() {
        let olderID = UUID()
        let newerID = UUID()
        let profile = PersonaProfile(
            name: "Test",
            personality: "Calm",
            tone: .calm,
            relation: .friend
        )
        let olderDate = Date(timeIntervalSince1970: 100)
        let newerDate = Date(timeIntervalSince1970: 200)
        let older = PersonaThread(
            id: olderID,
            personaSnapshot: profile,
            title: "Older",
            createdAt: olderDate,
            updatedAt: olderDate
        )
        let newer = PersonaThread(
            id: newerID,
            personaSnapshot: profile,
            title: "Newer",
            createdAt: olderDate,
            updatedAt: newerDate
        )

        let ordered = PersonaThreadOrdering.mostRecentFirst([older, newer])

        XCTAssertEqual(ordered.map(\.id), [newerID, olderID])
    }

    func testPersonaStoreFinalizationAndCancellationPersistAcrossReload() throws {
        let suiteName = "KizunaPersonaStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let profile = PersonaProfile(
            name: "Test",
            personality: "Calm",
            tone: .calm,
            relation: .friend
        )
        let targetID = UUID()
        let pendingID = UUID()
        let newerID = UUID()
        let oldDate = Date(timeIntervalSince1970: 100)
        let newerDate = Date(timeIntervalSince1970: 200)
        let target = PersonaThread(
            id: targetID,
            personaSnapshot: profile,
            title: "Target",
            messages: [
                PersonaMessage(role: .user, text: "hello", createdAt: oldDate),
                PersonaMessage(role: .assistant, text: "", createdAt: oldDate)
            ],
            createdAt: oldDate,
            updatedAt: oldDate
        )
        let pending = PersonaThread(
            id: pendingID,
            personaSnapshot: profile,
            title: "Pending",
            messages: [
                PersonaMessage(role: .user, text: "stop", createdAt: oldDate),
                PersonaMessage(role: .assistant, text: "…", createdAt: oldDate)
            ],
            createdAt: oldDate,
            updatedAt: oldDate
        )
        let newer = PersonaThread(
            id: newerID,
            personaSnapshot: profile,
            title: "Newer",
            messages: [PersonaMessage(role: .user, text: "new", createdAt: newerDate)],
            createdAt: newerDate,
            updatedAt: newerDate
        )
        defaults.set(
            try JSONEncoder().encode([target, pending, newer]),
            forKey: "persona.threads.v1"
        )

        let store = PersonaChatStore(defaults: defaults)
        XCTAssertTrue(store.finalizeLastAssistantMessage(in: targetID, text: "completed"))
        XCTAssertEqual(store.threads.first?.id, targetID)
        XCTAssertEqual(store.thread(id: targetID)?.messages.last?.text, "completed")

        store.removePendingAssistantMessage(in: pendingID)
        let reloaded = PersonaChatStore(defaults: defaults)

        XCTAssertEqual(reloaded.thread(id: targetID)?.messages.last?.text, "completed")
        XCTAssertFalse(reloaded.thread(id: pendingID)?.messages.last?.role == .assistant)
        XCTAssertEqual(reloaded.threads.first?.id, pendingID)
    }

    func testPersonaThreadOrderingUsesCreatedAtAndIDTieBreakers() {
        let profile = PersonaProfile(
            name: "Test",
            personality: "Calm",
            tone: .calm,
            relation: .friend
        )
        let sameDate = Date(timeIntervalSince1970: 100)
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let first = PersonaThread(
            id: firstID,
            personaSnapshot: profile,
            title: "First",
            createdAt: sameDate,
            updatedAt: sameDate
        )
        let second = PersonaThread(
            id: secondID,
            personaSnapshot: profile,
            title: "Second",
            createdAt: sameDate,
            updatedAt: sameDate
        )

        XCTAssertEqual(
            PersonaThreadOrdering.mostRecentFirst([second, first]).map(\.id),
            [firstID, secondID]
        )
    }
}
