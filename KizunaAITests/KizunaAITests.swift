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

    func testStoryMemoryScopeExcludesOtherSessionsAndLegacyRecords() {
        let worldID = UUID()
        let sessionID = UUID()
        let otherSessionID = UUID()
        let sourceTurnID = UUID()
        let current = StoryMemory(
            storyWorldId: worldID,
            text: "current session event",
            storySessionId: sessionID,
            sourceTurnIds: [sourceTurnID]
        )
        let other = StoryMemory(
            storyWorldId: worldID,
            text: "other session event",
            storySessionId: otherSessionID
        )
        let legacy = StoryMemory(
            storyWorldId: worldID,
            text: "legacy event"
        )

        XCTAssertEqual(
            StoryMemory.scoped(to: sessionID, from: [current, other, legacy]),
            [current]
        )
        XCTAssertEqual(
            StoryMemory.scoped(
                to: sessionID,
                sourceTurnIds: [sourceTurnID],
                from: [current, other, legacy]
            ),
            [current]
        )
        XCTAssertTrue(
            StoryMemory.scoped(
                to: sessionID,
                sourceTurnIds: [UUID()],
                from: [current, other, legacy]
            ).isEmpty
        )
    }

    func testStoryMemoryProvenanceUsesDurableTurnIDNotGenerationAttemptID() {
        let generationID = UUID()
        let turnID = UUID()
        let message = StoryMessage(
            author: .narrator,
            text: "保存された場面",
            generationID: generationID,
            turnID: turnID
        )
        let memory = StoryMemory(
            storyWorldId: UUID(),
            text: "場面の記憶",
            storySessionId: UUID(),
            sourceTurnIds: [turnID]
        )

        XCTAssertEqual(message.turnID, turnID)
        XCTAssertEqual(memory.sourceTurnIds, [turnID])
        XCTAssertFalse(memory.sourceTurnIds.contains(generationID))
    }

    func testStoryMemorySessionIDIsBackwardCompatibleWhenAbsent() throws {
        let sessionID = UUID()
        let sourceTurnID = UUID()
        let memory = StoryMemory(
            storyWorldId: UUID(),
            text: "event",
            storySessionId: sessionID,
            sourceTurnIds: [sourceTurnID]
        )
        let encoded = try JSONEncoder().encode(memory)
        let decoded = try JSONDecoder().decode(StoryMemory.self, from: encoded)

        XCTAssertEqual(decoded.storySessionId, sessionID)
        XCTAssertEqual(decoded.sourceTurnIds, [sourceTurnID])

        let legacyJSON = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "storyWorldId": "00000000-0000-0000-0000-000000000002",
          "characterId": null,
          "text": "legacy event",
          "category": "event",
          "importance": 0.5,
          "source": "system",
          "createdAt": 0,
          "lastUsedAt": null
        }
        """
        let legacyData = try XCTUnwrap(legacyJSON.data(using: .utf8))
        let legacy = try JSONDecoder().decode(StoryMemory.self, from: legacyData)
        XCTAssertNil(legacy.storySessionId)
        XCTAssertTrue(legacy.sourceTurnIds.isEmpty)
    }

    func testStoryMemoryAggregatesIgnoreOrphanedSourceMetadata() {
        let validSourceTurnID = UUID()
        let orphanedSourceTurnID = UUID()
        let createdAt = Date(timeIntervalSince1970: 100)
        var memory = StoryMemory(
            storyWorldId: UUID(),
            text: "event",
            importance: 0.2,
            createdAt: createdAt,
            sourceTurnIds: [validSourceTurnID],
            sourceTurnMetadata: [
                validSourceTurnID: StoryMemorySourceMetadata(
                    importance: 0.2,
                    createdAt: createdAt,
                    lastUsedAt: createdAt
                ),
                orphanedSourceTurnID: StoryMemorySourceMetadata(
                    importance: 0.99,
                    createdAt: createdAt,
                    lastUsedAt: createdAt.addingTimeInterval(100)
                )
            ]
        )

        memory.recomputeAggregatesFromSourceMetadata()

        XCTAssertEqual(Set(memory.sourceTurnMetadata.keys), Set([validSourceTurnID]))
        XCTAssertEqual(memory.importance, 0.2)
        XCTAssertEqual(memory.lastUsedAt, createdAt)
    }

    func testSavingNewSessionDoesNotTrimOtherSessionOrLegacyScope() async throws {
        let storageURL = KizunaDataMigration.characterLibraryURL
            .appendingPathComponent("story-memory-scope-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storageURL) }

        let repository = LocalJSONStoryMemoryRepository(
            storageURL: storageURL,
            perScopeLimit: 1
        )
        let worldID = UUID()
        let existingSessionID = UUID()
        let newSessionID = UUID()
        let existingSessionMemories = [
            StoryMemory(storyWorldId: worldID, text: "existing 1", storySessionId: existingSessionID),
            StoryMemory(storyWorldId: worldID, text: "existing 2", storySessionId: existingSessionID)
        ]
        let legacyMemories = [
            StoryMemory(storyWorldId: worldID, text: "legacy 1"),
            StoryMemory(storyWorldId: worldID, text: "legacy 2")
        ]

        // Seed the pre-existing scopes directly. Saving those records through
        // the repository would intentionally apply the configured per-scope
        // limit to each scope and would not test the regression boundary.
        try LocalJSONStoreTransaction.save(
            existingSessionMemories + legacyMemories,
            fileName: "story_memories.json",
            baseURL: storageURL
        )
        try await repository.saveMemory(
            StoryMemory(storyWorldId: worldID, text: "new session", storySessionId: newSessionID)
        )

        let existingSession = try await repository.fetchMemories(
            storyWorldId: worldID,
            storySessionId: existingSessionID
        )
        XCTAssertEqual(Set(existingSession.map(\.id)), Set(existingSessionMemories.map(\.id)))

        let allMemories = try await repository.fetchMemories(storyWorldId: worldID)
        XCTAssertEqual(
            Set(allMemories.filter { $0.storySessionId == nil }.map(\.id)),
            Set(legacyMemories.map(\.id))
        )
    }

    func testLocalJSONStoryMemoryRepositoryKeepsSessionScopesAndLegacyRecords() async throws {
        let fileName = "story-memories-test-\(UUID().uuidString).json"
        let fileURL = KizunaDataMigration.characterLibraryURL.appendingPathComponent(fileName)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let repository = LocalJSONStoryMemoryRepository(fileName: fileName)
        let worldID = UUID()
        let otherWorldID = UUID()
        let sessionID = UUID()
        let otherSessionID = UUID()
        let current = StoryMemory(
            storyWorldId: worldID,
            text: "current",
            storySessionId: sessionID,
            sourceTurnIds: [UUID()]
        )
        let otherSession = StoryMemory(
            storyWorldId: worldID,
            text: "other session",
            storySessionId: otherSessionID,
            sourceTurnIds: [UUID()]
        )
        let legacy = StoryMemory(storyWorldId: worldID, text: "legacy")
        let otherWorld = StoryMemory(
            storyWorldId: otherWorldID,
            text: "other world",
            storySessionId: sessionID,
            sourceTurnIds: [UUID()]
        )

        for memory in [current, otherSession, legacy, otherWorld] {
            try await repository.saveMemory(memory)
        }

        let scoped = try await repository.fetchMemories(
            storyWorldId: worldID,
            storySessionId: sessionID
        )
        XCTAssertEqual(scoped.map(\.id), [current.id])

        let allInWorld = try await repository.fetchMemories(storyWorldId: worldID)
        XCTAssertEqual(Set(allInWorld.map(\.id)), Set([current.id, otherSession.id, legacy.id]))

        let mergedText = "merged event"
        let firstSourceTurnID = UUID()
        let secondSourceTurnID = UUID()
        let firstMerged = StoryMemory(
            storyWorldId: worldID,
            text: mergedText,
            importance: 0.2,
            createdAt: Date(timeIntervalSince1970: 100),
            storySessionId: sessionID,
            sourceTurnIds: [firstSourceTurnID]
        )
        let secondMerged = StoryMemory(
            storyWorldId: worldID,
            text: mergedText,
            importance: 0.9,
            createdAt: Date(timeIntervalSince1970: 200),
            storySessionId: sessionID,
            sourceTurnIds: [secondSourceTurnID]
        )
        try await repository.saveMemory(firstMerged)
        let firstSaved = try await repository.fetchMemories(
            storyWorldId: worldID,
            storySessionId: sessionID
        ).first(where: { $0.text == mergedText })
        XCTAssertNotNil(firstSaved?.lastUsedAt)
        XCTAssertEqual(
            firstSaved?.lastUsedAt,
            firstSaved?.sourceTurnMetadata[firstSourceTurnID]?.lastUsedAt
        )
        try await repository.saveMemory(secondMerged)
        let mergedBeforeMark = try await repository.fetchMemories(
            storyWorldId: worldID,
            storySessionId: sessionID
        ).first(where: { $0.text == mergedText })
        XCTAssertNotNil(mergedBeforeMark)
        let mergedBeforeMarkID = try XCTUnwrap(mergedBeforeMark?.id)
        try await repository.markUsed(ids: [mergedBeforeMarkID])
        let marked = try await repository.fetchMemories(
            storyWorldId: worldID,
            storySessionId: sessionID
        ).first(where: { $0.text == mergedText })
        let markedFirstUsedAt = marked?.sourceTurnMetadata[firstSourceTurnID]?.lastUsedAt
        XCTAssertNotNil(markedFirstUsedAt)
        try await repository.removeSourceTurnIds([secondSourceTurnID])

        let merged = try await repository.fetchMemories(storyWorldId: worldID, storySessionId: sessionID)
            .first(where: { $0.text == mergedText })
        XCTAssertEqual(merged?.sourceTurnIds, [firstSourceTurnID])
        XCTAssertEqual(merged?.importance, firstSaved?.importance)
        XCTAssertEqual(
            merged?.sourceTurnMetadata[firstSourceTurnID]?.lastUsedAt,
            markedFirstUsedAt
        )
        XCTAssertEqual(
            merged?.lastUsedAt,
            merged?.sourceTurnMetadata[firstSourceTurnID]?.lastUsedAt
        )
    }

    func testStoryRuntimeNoticeKeepsAuxiliarySaveSeparateFromUserTurnRetry() {
        let turnID = UUID()
        let memory = StoryMemory(
            storyWorldId: UUID(),
            text: "港で約束した",
            category: .event,
            source: .summary
        )
        let retry = StoryMemoryRetry(
            turnID: turnID,
            userMessageID: UUID(),
            userText: "約束を思い出す",
            characterMemories: [],
            storyMemories: [memory]
        )
        let notice = StoryRuntimeNotice(
            text: "保存に失敗しました",
            userMessageID: retry.userMessageID,
            userText: retry.userText,
            backendName: "memory save failed",
            backend: .persistence,
            retryAction: .storyMemory(retry)
        )

        XCTAssertTrue(notice.retryAction.isAuxiliarySave)
        guard case let .storyMemory(persistedRetry) = notice.retryAction else {
            return XCTFail("memory failures must not use the user-turn retry path")
        }
        XCTAssertEqual(persistedRetry, retry)
    }

    func testStoryTurnCommitRecoveryMatchesOnlyTheExactCommittedTurn() {
        let storyWorldID = UUID()
        let sessionID = UUID()
        let turnID = UUID()
        let userMessageID = UUID()
        let assistantMessageID = UUID()
        let session = StorySession(
            id: sessionID,
            storyWorldId: storyWorldID,
            latestTurnCheckpoint: StoryTurnCheckpoint(
                turnID: turnID,
                userMessageID: userMessageID,
                status: .committed,
                assistantMessageIDs: [assistantMessageID]
            )
        )
        let retry = StoryTurnCommitRetry(
            session: StorySession(id: sessionID, storyWorldId: storyWorldID),
            scene: StoryScene(storyWorldId: storyWorldID),
            turnID: turnID,
            attempt: 1,
            assistantMessageIDs: [assistantMessageID],
            characterMemories: [],
            storyMemories: [],
            userMessageID: userMessageID,
            userText: "保存済みのターン"
        )

        XCTAssertEqual(
            StoryTurnCommitRecovery.committedSession(matching: retry, in: [session]),
            session
        )

        var differentTurn = session
        differentTurn.latestTurnCheckpoint = StoryTurnCheckpoint(
            turnID: UUID(),
            userMessageID: userMessageID,
            status: .committed,
            assistantMessageIDs: [assistantMessageID]
        )
        XCTAssertNil(StoryTurnCommitRecovery.committedSession(matching: retry, in: [differentTurn]))

        var pending = session
        pending.latestTurnCheckpoint = StoryTurnCheckpoint(
            turnID: turnID,
            userMessageID: userMessageID,
            status: .pending,
            assistantMessageIDs: [assistantMessageID]
        )
        XCTAssertNil(StoryTurnCommitRecovery.committedSession(matching: retry, in: [pending]))
    }

    func testStoryServiceRetriesMemoryWithoutGeneratingAnotherTurn() async throws {
        let memoryRepository = TestStoryMemoryRepository()
        let retry = StoryMemoryRetry(
            turnID: UUID(),
            userMessageID: UUID(),
            userText: "港で約束したことを思い出す",
            characterMemories: [
                CharacterMemory(
                    characterId: UUID(),
                    text: "港で約束した",
                    category: .event,
                    source: .aiOutput
                )
            ],
            storyMemories: [
                StoryMemory(
                    storyWorldId: UUID(),
                    text: "港で約束した",
                    category: .event,
                    source: .summary
                )
            ]
        )
        let service = StorySessionService(
            memoryRepo: memoryRepository,
            storyMemoryRepo: memoryRepository,
            pendingStoryMemoryRetries: [retry]
        )

        await service.retryStoryMemorySave(retry)

        let counts = await memoryRepository.saveCounts()
        XCTAssertEqual(counts.character, 1)
        XCTAssertEqual(counts.story, 1)
        XCTAssertEqual(service.savedTurnRevision, 1)
        XCTAssertNil(service.latestRuntimeNotice)
    }

    func testStoryServiceRetriesCommittedTurnWithSameTurnIdentity() async throws {
        let sessionRepository = TestStorySessionRepository()
        let session = StorySession(storyWorldId: UUID())
        let scene = StoryScene(storyWorldId: session.storyWorldId)
        let retry = StoryTurnCommitRetry(
            session: session,
            scene: scene,
            turnID: UUID(),
            attempt: 3,
            assistantMessageIDs: [UUID()],
            characterMemories: [],
            storyMemories: [],
            userMessageID: UUID(),
            userText: "同じターンを保存する"
        )
        let service = StorySessionService(
            sessionRepo: sessionRepository,
            pendingStoryTurnCommitRetries: [retry]
        )

        await service.retryStoryTurnCommit(retry)

        let commit = await sessionRepository.lastCommit
        XCTAssertEqual(commit?.turnID, retry.turnID)
        XCTAssertEqual(commit?.assistantMessageIDs, retry.assistantMessageIDs)
        XCTAssertEqual(service.savedTurnRevision, 1)
        XCTAssertNil(service.latestRuntimeNotice)
    }

    func testStoryServiceCommitRetryHandsFailedMemoriesToMemoryRetry() async throws {
        let sessionRepository = TestStorySessionRepository()
        let memoryRepository = TestStoryMemoryRepository(shouldFailSaves: true)
        let session = StorySession(storyWorldId: UUID())
        let scene = StoryScene(storyWorldId: session.storyWorldId)
        let characterMemory = CharacterMemory(
            characterId: UUID(),
            text: "港で交わした約束",
            category: .event,
            source: .aiOutput
        )
        let storyMemory = StoryMemory(
            storyWorldId: session.storyWorldId,
            text: "約束が残った",
            category: .event,
            source: .summary
        )
        let retry = StoryTurnCommitRetry(
            session: session,
            scene: scene,
            turnID: UUID(),
            attempt: 3,
            assistantMessageIDs: [UUID()],
            characterMemories: [characterMemory],
            storyMemories: [storyMemory],
            userMessageID: UUID(),
            userText: "同じターンを保存する"
        )
        let service = StorySessionService(
            memoryRepo: memoryRepository,
            sessionRepo: sessionRepository,
            storyMemoryRepo: memoryRepository,
            pendingStoryTurnCommitRetries: [retry]
        )

        await service.retryStoryTurnCommit(retry)

        let commit = await sessionRepository.lastCommit
        XCTAssertEqual(commit?.turnID, retry.turnID)
        XCTAssertEqual(commit?.assistantMessageIDs, retry.assistantMessageIDs)
        XCTAssertEqual(service.savedTurnRevision, 0)
        guard case let .storyMemory(memoryRetry) = service.latestRuntimeNotice?.retryAction else {
            return XCTFail("failed memory writes must become a memory-only retry")
        }
        XCTAssertEqual(memoryRetry.turnID, retry.turnID)
        XCTAssertEqual(memoryRetry.characterMemories, retry.characterMemories)
        XCTAssertEqual(memoryRetry.storyMemories, retry.storyMemories)
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

    func testStorySessionRepositoryCommitRetryReusesCommittedTurn() async throws {
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
        let userMessage = StoryMessage(author: .user, text: "同じ本文を再利用")
        let turnID = UUID()
        let pending = try await repository.beginTurn(
            session: session,
            userMessage: userMessage,
            turnID: turnID,
            attempt: 1
        )
        let assistant = StoryMessage(
            author: .narrator,
            text: "生成済みの場面",
            turnID: turnID
        )
        var generated = pending
        generated.messages.append(assistant)

        let committed = try await repository.commitTurn(
            session: generated,
            scene: scene,
            turnID: turnID,
            assistantMessageIDs: [assistant.id]
        )
        let retried = try await repository.commitTurn(
            session: generated,
            scene: scene,
            turnID: turnID,
            assistantMessageIDs: [assistant.id]
        )

        XCTAssertEqual(committed.latestTurnCheckpoint?.status, .committed)
        XCTAssertEqual(retried.latestTurnCheckpoint?.status, .committed)
        XCTAssertEqual(retried.latestTurnCheckpoint?.turnID, turnID)
        XCTAssertEqual(
            retried.messages.filter { $0.id == assistant.id }.count,
            1,
            "a persistence retry must not append another assistant message"
        )
        let persisted = try LocalJSONStoreTransaction.load(
            StorySession.self,
            fileName: "story_sessions.json",
            baseURL: storageURL
        ).first
        XCTAssertEqual(persisted?.messages.filter { $0.id == assistant.id }.count, 1)
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
        var rawItems = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: encoder.encode([validEntry]),
                options: [.fragmentsAllowed]
            ) as? [Any]
        )
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
}

private actor TestStoryMemoryRepository: MemoryRepository, StoryMemoryRepository {
    private enum TestError: Error {
        case saveFailed
    }

    private let shouldFailSaves: Bool
    private var characterSaveCount = 0
    private var storySaveCount = 0

    init(shouldFailSaves: Bool = false) {
        self.shouldFailSaves = shouldFailSaves
    }

    func fetchMemories(characterId: UUID) async throws -> [CharacterMemory] { [] }

    func saveMemory(_ memory: CharacterMemory) async throws {
        if shouldFailSaves { throw TestError.saveFailed }
        characterSaveCount += 1
    }

    func deleteMemory(id: UUID) async throws {}
    func deleteAllMemories(characterId: UUID) async throws {}
    func markUsed(ids: [UUID]) async throws {}

    func fetchMemories(storyWorldId: UUID) async throws -> [StoryMemory] { [] }

    func saveMemory(_ memory: StoryMemory) async throws {
        if shouldFailSaves { throw TestError.saveFailed }
        storySaveCount += 1
    }

    func deleteAllMemories(storyWorldId: UUID) async throws {}

    func saveCounts() -> (character: Int, story: Int) {
        (characterSaveCount, storySaveCount)
    }
}

private actor TestStorySessionRepository: StorySessionRepository {
    struct Commit: Sendable {
        let turnID: UUID
        let assistantMessageIDs: [UUID]
    }

    private(set) var lastCommit: Commit?

    func fetchSessions(storyWorldId: UUID) async throws -> [StorySession] { [] }
    func saveSession(_ session: StorySession) async throws {}

    func beginTurn(
        session: StorySession,
        userMessage: StoryMessage,
        turnID: UUID,
        attempt: Int
    ) async throws -> StorySession {
        session
    }

    func commitTurn(
        session: StorySession,
        scene: StoryScene,
        turnID: UUID,
        assistantMessageIDs: [UUID]
    ) async throws -> StorySession {
        lastCommit = Commit(turnID: turnID, assistantMessageIDs: assistantMessageIDs)
        return session
    }

    func finishTurn(
        sessionID: UUID,
        turnID: UUID,
        attempt: Int,
        status: StoryTurnStatus,
        failureCode: String?
    ) async throws {}

    func recoverInterruptedTurns(storyWorldId: UUID) async throws {}
    func deleteSession(id: UUID) async throws {}
}
