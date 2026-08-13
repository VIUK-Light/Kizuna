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

    func testLocalJSONStoreDecoderReadsNumericAndBothISO8601DateForms() throws {
        let decoder = LocalJSONStoreCoding.makeDecoder()

        let numeric = try decoder.decode(
            Date.self,
            from: Data("1234.5".utf8)
        )
        XCTAssertEqual(
            numeric.timeIntervalSinceReferenceDate,
            1234.5,
            accuracy: 0.000_001
        )

        let seconds = try decoder.decode(
            Date.self,
            from: Data("\"2026-08-14T12:34:56Z\"".utf8)
        )
        let secondsFormatter = ISO8601DateFormatter()
        secondsFormatter.formatOptions = [.withInternetDateTime]
        let expectedSeconds = try XCTUnwrap(
            secondsFormatter.date(from: "2026-08-14T12:34:56Z")
        )
        XCTAssertEqual(
            seconds.timeIntervalSince1970,
            expectedSeconds.timeIntervalSince1970,
            accuracy: 0.000_001
        )

        let fractional = try decoder.decode(
            Date.self,
            from: Data("\"2026-08-14T12:34:56.789Z\"".utf8)
        )
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expectedFractional = try XCTUnwrap(
            fractionalFormatter.date(from: "2026-08-14T12:34:56.789Z")
        )
        XCTAssertEqual(
            fractional.timeIntervalSince1970,
            expectedFractional.timeIntervalSince1970,
            accuracy: 0.000_001
        )
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

    func testSessionScopedLegacyMemoryWithNoProvenanceRemainsEligible() {
        let worldID = UUID()
        let sessionID = UUID()
        let otherSessionID = UUID()
        let activeTurnID = UUID()
        let current = StoryMemory(
            storyWorldId: worldID,
            text: "current event",
            storySessionId: sessionID,
            sourceTurnIds: [activeTurnID]
        )
        let matchingLegacy = StoryMemory(
            storyWorldId: worldID,
            text: "legacy event from this session",
            storySessionId: sessionID
        )
        let otherLegacy = StoryMemory(
            storyWorldId: worldID,
            text: "legacy event from another session",
            storySessionId: otherSessionID
        )
        let worldOnlyLegacy = StoryMemory(storyWorldId: worldID, text: "world-only legacy")

        XCTAssertEqual(
            StoryMemory.scoped(
                to: sessionID,
                sourceTurnIds: [activeTurnID],
                from: [current, matchingLegacy, otherLegacy, worldOnlyLegacy]
            ),
            [current, matchingLegacy]
        )
        XCTAssertEqual(
            StoryMemory.scoped(
                to: sessionID,
                sourceTurnIds: [],
                from: [current, matchingLegacy, otherLegacy, worldOnlyLegacy]
            ),
            [matchingLegacy]
        )
    }

    func testStoryMemoryRetryDecodesLegacyPayloadWithoutCompletionMarker() throws {
        let retry = StoryMemoryRetry(
            turnID: UUID(),
            userMessageID: UUID(),
            userText: "旧形式の再試行",
            characterMemories: [],
            storyMemories: [
                StoryMemory(storyWorldId: UUID(), text: "旧形式の記憶")
            ]
        )
        let encoded = try JSONEncoder().encode(retry)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "isCompleted")
        let legacyData = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )

        let decoded = try JSONDecoder().decode(StoryMemoryRetry.self, from: legacyData)
        XCTAssertEqual(decoded, retry)
        XCTAssertFalse(decoded.isCompleted)
    }

    func testFileIOCancellationStateAtomicallyClaimsQueuedOperation() {
        let cancelled = LocalJSONStoreFileIOCancellationState()
        cancelled.cancel()
        XCTAssertFalse(cancelled.begin())

        let started = LocalJSONStoreFileIOCancellationState()
        XCTAssertTrue(started.begin())
        started.cancel()
        XCTAssertFalse(started.begin())
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

    func testStoryMemoryRebuildsMissingSourceMetadataBeforeRecomputing() {
        let sourceTurnID = UUID()
        let createdAt = Date(timeIntervalSince1970: 100)
        var memory = StoryMemory(
            storyWorldId: UUID(),
            text: "partial provenance",
            importance: 0.7,
            createdAt: createdAt,
            lastUsedAt: createdAt.addingTimeInterval(10),
            sourceTurnIds: [sourceTurnID],
            sourceTurnMetadata: [:]
        )

        memory.recomputeAggregatesFromSourceMetadata()

        XCTAssertEqual(
            memory.sourceTurnMetadata[sourceTurnID],
            StoryMemorySourceMetadata(
                importance: 0.7,
                createdAt: createdAt,
                lastUsedAt: createdAt.addingTimeInterval(10)
            )
        )
        XCTAssertEqual(memory.importance, 0.7)
        XCTAssertEqual(memory.lastUsedAt, createdAt.addingTimeInterval(10))
    }

    func testSourceLessStoryMemoryMergeKeepsProvenanceAggregatesInSync() {
        let sourceTurnID = UUID()
        let createdAt = Date(timeIntervalSince1970: 100)
        let existing = StoryMemory(
            storyWorldId: UUID(),
            text: "同じ出来事",
            importance: 0.2,
            createdAt: createdAt,
            lastUsedAt: createdAt,
            sourceTurnIds: [sourceTurnID],
            sourceTurnMetadata: [
                sourceTurnID: StoryMemorySourceMetadata(
                    importance: 0.2,
                    createdAt: createdAt,
                    lastUsedAt: createdAt
                )
            ]
        )
        var incoming = existing
        incoming.id = UUID()
        incoming.importance = 0.8
        incoming.sourceTurnIds = []
        incoming.sourceTurnMetadata = [:]

        var values = [existing]
        LocalJSONStoryMemoryRepository.mergeMemory(incoming, &values)

        let merged = values[0]
        XCTAssertEqual(merged.importance, 0.8)
        XCTAssertEqual(
            merged.sourceTurnMetadata[sourceTurnID]?.importance,
            merged.importance
        )
        XCTAssertEqual(
            merged.sourceTurnMetadata[sourceTurnID]?.lastUsedAt,
            merged.lastUsedAt
        )
    }

    func testStoryMemorySourceMetadataUsesObjectAndReadsLegacyUUIDDictionary() throws {
        let sourceTurnID = UUID()
        let metadata = StoryMemorySourceMetadata(
            importance: 0.8,
            createdAt: Date(timeIntervalSince1970: 100),
            lastUsedAt: Date(timeIntervalSince1970: 200)
        )
        let memory = StoryMemory(
            storyWorldId: UUID(),
            text: "metadata format",
            sourceTurnIds: [sourceTurnID],
            sourceTurnMetadata: [sourceTurnID: metadata]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(memory)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let currentMetadata = try XCTUnwrap(
            object["sourceTurnMetadata"] as? [String: Any]
        )
        XCTAssertEqual(Set(currentMetadata.keys), Set([sourceTurnID.uuidString]))

        let legacyMetadata = try JSONSerialization.jsonObject(
            with: encoder.encode([sourceTurnID: metadata])
        )
        object["sourceTurnMetadata"] = legacyMetadata
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(StoryMemory.self, from: legacyData)
        XCTAssertEqual(decoded.sourceTurnMetadata[sourceTurnID], metadata)
    }

    func testStoryMemoryMissingMetadataIsFilledDuringLegacyDecode() throws {
        let sourceTurnID = UUID()
        let memory = StoryMemory(
            storyWorldId: UUID(),
            text: "legacy metadata missing",
            importance: 0.6,
            createdAt: Date(timeIntervalSince1970: 100),
            sourceTurnIds: [sourceTurnID]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(memory)) as? [String: Any]
        )
        object.removeValue(forKey: "sourceTurnMetadata")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(StoryMemory.self, from: legacyData)

        XCTAssertEqual(
            decoded.sourceTurnMetadata[sourceTurnID],
            StoryMemorySourceMetadata(
                importance: memory.importance,
                createdAt: memory.createdAt,
                lastUsedAt: memory.lastUsedAt
            )
        )
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

    func testStoryMemoryRetryPersistsAcrossServiceRecreationAndStaysSessionScoped() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let sessionID = UUID()
        let otherSessionID = UUID()
        let retry = StoryMemoryRetry(
            turnID: UUID(),
            userMessageID: UUID(),
            userText: "保存した記憶を残す",
            characterMemories: [],
            storyMemories: [
                StoryMemory(
                    storyWorldId: worldID,
                    text: "再起動後も残る出来事",
                    storySessionId: sessionID,
                    sourceTurnIds: [UUID()]
                )
            ],
            storySessionID: sessionID,
            storyWorldID: worldID
        )
        let otherRetry = StoryMemoryRetry(
            turnID: UUID(),
            userMessageID: UUID(),
            userText: "別セッションの記憶",
            characterMemories: [],
            storyMemories: [
                StoryMemory(
                    storyWorldId: worldID,
                    text: "別セッションの出来事",
                    storySessionId: otherSessionID,
                    sourceTurnIds: [UUID()]
                )
            ],
            storySessionID: otherSessionID,
            storyWorldID: worldID
        )

        let firstRepository = LocalJSONStoryMemoryRetryRepository(storageURL: storageURL)
        try await firstRepository.saveRetry(retry)
        try await firstRepository.saveRetry(otherRetry)

        let committedSession = StorySession(
            id: sessionID,
            storyWorldId: worldID,
            latestTurnCheckpoint: StoryTurnCheckpoint(
                turnID: retry.turnID,
                userMessageID: retry.userMessageID,
                status: .committed
            )
        )
        let recreatedService = StorySessionService(
            sessionRepo: TestStorySessionRepository(sessions: [committedSession]),
            storyMemoryRetryRepo: LocalJSONStoryMemoryRetryRepository(storageURL: storageURL)
        )
        try await recreatedService.restorePendingStoryMemoryRetries(
            storySessionID: sessionID,
            storyWorldID: worldID
        )

        guard case let .storyMemory(restored)? = recreatedService.latestRuntimeNotice?.retryAction else {
            return XCTFail("the current session's retry must be restored after service recreation")
        }
        XCTAssertEqual(restored, retry)

        try await LocalJSONStoryMemoryRetryRepository(storageURL: storageURL)
            .deleteRetry(turnID: retry.turnID)
        let remaining = try await LocalJSONStoryMemoryRetryRepository(storageURL: storageURL).fetchRetries()
        XCTAssertEqual(remaining, [otherRetry])
    }

    func testStoryMemoryRetryRepositoryPreservesInsertionOrder() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let firstTurnID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let secondTurnID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let first = StoryMemoryRetry(
            turnID: firstTurnID,
            userMessageID: UUID(),
            userText: "先に失敗した保存",
            characterMemories: [],
            storyMemories: []
        )
        let second = StoryMemoryRetry(
            turnID: secondTurnID,
            userMessageID: UUID(),
            userText: "後に失敗した保存",
            characterMemories: [],
            storyMemories: []
        )
        let repository = LocalJSONStoryMemoryRetryRepository(storageURL: storageURL)

        try await repository.saveRetry(first)
        try await repository.saveRetry(second)

        let persistedTurnIDs = try await repository.fetchRetries().map(\.turnID)
        XCTAssertEqual(persistedTurnIDs, [firstTurnID, secondTurnID])
    }

    func testStoryMemoryRetryFromOlderCommittedTurnSurvivesRestore() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let sessionID = UUID()
        let olderTurnID = UUID()
        let latestTurnID = UUID()
        let olderRetry = StoryMemoryRetry(
            turnID: olderTurnID,
            userMessageID: UUID(),
            userText: "古いターンの記憶を保存する",
            characterMemories: [],
            storyMemories: [
                StoryMemory(
                    storyWorldId: worldID,
                    text: "古いターンの出来事",
                    storySessionId: sessionID,
                    sourceTurnIds: [olderTurnID]
                )
            ],
            storySessionID: sessionID,
            storyWorldID: worldID
        )
        let retryRepository = LocalJSONStoryMemoryRetryRepository(storageURL: storageURL)
        try await retryRepository.saveRetry(olderRetry)

        let session = StorySession(
            id: sessionID,
            storyWorldId: worldID,
            messages: [
                StoryMessage(
                    author: .narrator,
                    text: "古いターンは確定済み",
                    turnID: olderTurnID
                )
            ],
            latestTurnCheckpoint: StoryTurnCheckpoint(
                turnID: latestTurnID,
                userMessageID: UUID(),
                status: .committed
            )
        )
        let memoryRepository = TestStoryMemoryRepository()
        let service = StorySessionService(
            memoryRepo: memoryRepository,
            sessionRepo: TestStorySessionRepository(sessions: [session]),
            storyMemoryRepo: memoryRepository,
            storyMemoryRetryRepo: retryRepository
        )

        try await service.restorePendingStoryMemoryRetries(
            storySessionID: sessionID,
            storyWorldID: worldID
        )
        await service.retryStoryMemorySave(olderRetry)

        let counts = await memoryRepository.saveCounts()
        XCTAssertEqual(counts.story, 1)
        let remainingRetries = try await retryRepository.fetchRetries()
        XCTAssertTrue(remainingRetries.isEmpty)
    }

    func testLegacyWorldScopedMemoryRetryStaysUnassignedAfterRestore() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let sessionID = UUID()
        let retry = StoryMemoryRetry(
            turnID: UUID(),
            userMessageID: UUID(),
            userText: "旧形式の保留記憶",
            characterMemories: [],
            storyMemories: [
                StoryMemory(
                    storyWorldId: worldID,
                    text: "所属Session不明の出来事"
                )
            ],
            storyWorldID: worldID
        )
        let session = StorySession(id: sessionID, storyWorldId: worldID)
        let retryRepository = LocalJSONStoryMemoryRetryRepository(storageURL: storageURL)
        try await retryRepository.saveRetry(retry)

        let service = StorySessionService(
            sessionRepo: TestStorySessionRepository(sessions: [session]),
            storyMemoryRetryRepo: retryRepository
        )

        try await service.restorePendingStoryMemoryRetries(
            storySessionID: sessionID,
            storyWorldID: worldID
        )

        XCTAssertNil(
            service.latestRuntimeNotice,
            "legacy world-only retries must not be guessed into the current session"
        )
        let remainingRetries = try await retryRepository.fetchRetries()
        XCTAssertEqual(remainingRetries, [retry])
    }

    func testStoryMemoryRetryRestoreSkipsMissingSession() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let sessionID = UUID()
        let retry = StoryMemoryRetry(
            turnID: UUID(),
            userMessageID: UUID(),
            userText: "存在しないSessionへ記憶を戻さない",
            characterMemories: [
                CharacterMemory(
                    characterId: UUID(),
                    text: "復元してはいけない記憶",
                    category: .event,
                    source: .aiOutput
                )
            ],
            storyMemories: [],
            storySessionID: sessionID,
            storyWorldID: worldID
        )
        let retryRepository = LocalJSONStoryMemoryRetryRepository(storageURL: storageURL)
        try await retryRepository.saveRetry(retry)

        let service = StorySessionService(
            sessionRepo: TestStorySessionRepository(),
            storyMemoryRetryRepo: retryRepository
        )

        try await service.restorePendingStoryMemoryRetries(
            storySessionID: sessionID,
            storyWorldID: worldID
        )

        XCTAssertNil(service.latestRuntimeNotice)
        let remainingRetries = try await retryRepository.fetchRetries()
        XCTAssertEqual(remainingRetries, [retry])
    }

    func testStaleMemoryRetryUsesCompletionFenceWhenJournalRetainsMissingScene() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let sessionID = UUID()
        let sceneID = UUID()
        let turnID = UUID()
        let userMessageID = UUID()
        let date = Date(timeIntervalSince1970: 300)
        let pending = StoryTurnReducer.begin(
            turnID: turnID,
            userMessageID: userMessageID,
            attempt: 1,
            ownerID: nil,
            baseRevision: 1,
            startedAt: date,
            updatedAt: date
        )
        let session = StorySession(
            id: sessionID,
            storyWorldId: worldID,
            currentSceneId: sceneID,
            persistenceRevision: 1,
            latestTurnCheckpoint: StoryTurnReducer.finish(
                pending: pending,
                status: .failed,
                failureCode: "interrupted",
                updatedAt: date
            ),
            updatedAt: date
        )
        let scene = StoryScene(id: sceneID, storyWorldId: worldID, updatedAt: date)
        let retry = StoryMemoryRetry(
            turnID: turnID,
            userMessageID: userMessageID,
            userText: "欠落したSceneのretryを破棄する",
            characterMemories: [],
            storyMemories: [
                StoryMemory(
                    storyWorldId: worldID,
                    text: "未コミットターンの記憶",
                    storySessionId: sessionID,
                    sourceTurnIds: [turnID]
                )
            ],
            storySessionID: sessionID,
            storyWorldID: worldID
        )

        try LocalJSONStoreTransaction.save(
            [session],
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        // The journal intentionally references a missing Scene. Recovery must
        // retain the snapshot, which exercises the fence rather than relying
        // on journal deletion as the cleanup mechanism.
        try LocalJSONStoreTransaction.save(
            [StoryTurnJournalEntry(
                turnID: turnID,
                session: session,
                scene: scene,
                memoryRetries: [retry]
            )],
            fileName: "story_turn_journal.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [retry],
            fileName: "story_memory_retries.json",
            baseURL: storageURL
        )

        let retryRepository = LocalJSONStoryMemoryRetryRepository(storageURL: storageURL)
        let service = StorySessionService(
            sessionRepo: LocalJSONStorySessionRepository(storageURL: storageURL),
            storyMemoryRetryRepo: retryRepository
        )

        try await service.restorePendingStoryMemoryRetries(
            storySessionID: sessionID,
            storyWorldID: worldID
        )

        XCTAssertNil(service.latestRuntimeNotice)
        let actionableRetries = try await retryRepository.fetchRetries()
        XCTAssertTrue(actionableRetries.isEmpty)

        let completedRetry = try LocalJSONStoreTransaction.load(
            StoryMemoryRetry.self,
            fileName: "story_memory_retries.json",
            baseURL: storageURL
        )
        XCTAssertEqual(completedRetry.count, 1)
        XCTAssertTrue(completedRetry[0].isCompleted)

        let retainedJournal = try LocalJSONStoreTransaction.load(
            StoryTurnJournalEntry.self,
            fileName: "story_turn_journal.json",
            baseURL: storageURL
        )
        XCTAssertEqual(retainedJournal, [StoryTurnJournalEntry(
            turnID: turnID,
            session: session,
            scene: scene,
            memoryRetries: [retry]
        )])

        // A later recovery must preserve the completion fence instead of
        // re-creating an actionable retry from the retained journal.
        try StoryTurnJournal.recoverIfNeeded(baseURL: storageURL)
        let afterSecondRecovery = try LocalJSONStoreTransaction.load(
            StoryMemoryRetry.self,
            fileName: "story_memory_retries.json",
            baseURL: storageURL
        )
        XCTAssertEqual(afterSecondRecovery, completedRetry)
    }

    func testMixedSessionMemoryRetryIsNotAssignedToEitherSession() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let currentSessionID = UUID()
        let otherSessionID = UUID()
        let retry = StoryMemoryRetry(
            turnID: UUID(),
            userMessageID: UUID(),
            userText: "混在した所属を現在Sessionへ戻さない",
            characterMemories: [],
            storyMemories: [
                StoryMemory(
                    storyWorldId: worldID,
                    text: "別Sessionの記憶",
                    storySessionId: otherSessionID
                )
            ],
            storySessionID: currentSessionID,
            storyWorldID: worldID
        )
        let retryRepository = LocalJSONStoryMemoryRetryRepository(storageURL: storageURL)
        try await retryRepository.saveRetry(retry)

        let service = StorySessionService(
            sessionRepo: TestStorySessionRepository(
                sessions: [StorySession(id: currentSessionID, storyWorldId: worldID)]
            ),
            storyMemoryRetryRepo: retryRepository
        )

        try await service.restorePendingStoryMemoryRetries(
            storySessionID: currentSessionID,
            storyWorldID: worldID
        )

        XCTAssertNil(service.latestRuntimeNotice)
        let remainingRetries = try await retryRepository.fetchRetries()
        XCTAssertEqual(remainingRetries, [retry])
    }

    func testMissingLiveSessionMemoryRetryRemainsDurableWithoutDeletingMemory() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let sessionID = UUID()
        let retry = StoryMemoryRetry(
            turnID: UUID(),
            userMessageID: UUID(),
            userText: "まだ復元されていないSessionの記憶",
            characterMemories: [
                CharacterMemory(
                    characterId: UUID(),
                    text: "後で保存できる記憶",
                    category: .event,
                    source: .aiOutput
                )
            ],
            storyMemories: [
                StoryMemory(
                    storyWorldId: worldID,
                    text: "後で保存できる物語記憶",
                    storySessionId: sessionID
                )
            ],
            storySessionID: sessionID,
            storyWorldID: worldID
        )
        let retryRepository = LocalJSONStoryMemoryRetryRepository(storageURL: storageURL)
        try await retryRepository.saveRetry(retry)

        let deferredResult = try await retryRepository.saveMemoryRetryRecords(retry)
        XCTAssertEqual(
            deferredResult,
            retry,
            "a missing non-tombstoned Session must defer rather than acknowledge the retry"
        )

        let memoryRepository = TestStoryMemoryRepository()
        let service = StorySessionService(
            memoryRepo: memoryRepository,
            storyMemoryRepo: memoryRepository,
            storyMemoryRetryRepo: retryRepository,
            storyMemoryRetryMemoryTransaction: retryRepository,
            pendingStoryMemoryRetries: [retry]
        )

        await service.retryStoryMemorySave(retry)

        let counts = await memoryRepository.saveCounts()
        XCTAssertEqual(counts.character, 0)
        XCTAssertEqual(counts.story, 0)
        XCTAssertNotNil(service.latestRuntimeNotice)
        let remainingRetries = try await retryRepository.fetchRetries()
        XCTAssertEqual(remainingRetries, [retry])
    }

    func testLegacyWorldOnlyStoryMemoryRetryRemainsUnwrittenInTransaction() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let retry = StoryMemoryRetry(
            turnID: UUID(),
            userMessageID: UUID(),
            userText: "所属Session不明の直接transaction",
            characterMemories: [],
            storyMemories: [
                StoryMemory(
                    storyWorldId: worldID,
                    text: "推測で保存してはいけない記憶"
                )
            ],
            storyWorldID: worldID
        )
        let retryRepository = LocalJSONStoryMemoryRetryRepository(storageURL: storageURL)

        let deferredResult = try await retryRepository.saveMemoryRetryRecords(retry)
        XCTAssertEqual(
            deferredResult,
            retry,
            "a legacy world-only StoryMemory must remain queued"
        )
        XCTAssertTrue(
            try LocalJSONStoreTransaction.load(
                StoryMemory.self,
                fileName: "story_memories.json",
                baseURL: storageURL
            ).isEmpty
        )
    }

    func testDeletedSessionMemoryRetryDoesNotCallMemoryRepositories() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let sessionID = UUID()
        let session = StorySession(id: sessionID, storyWorldId: worldID)
        let sessionRepository = LocalJSONStorySessionRepository(storageURL: storageURL)
        try await sessionRepository.saveSession(session)

        let retry = StoryMemoryRetry(
            turnID: UUID(),
            userMessageID: UUID(),
            userText: "削除後に記憶を保存しない",
            characterMemories: [
                CharacterMemory(
                    characterId: UUID(),
                    text: "削除後に復活してはいけない記憶",
                    category: .event,
                    source: .aiOutput
                )
            ],
            storyMemories: [
                StoryMemory(
                    storyWorldId: worldID,
                    text: "削除後に復活してはいけない物語記憶",
                    storySessionId: sessionID
                )
            ],
            storySessionID: sessionID,
            storyWorldID: worldID
        )
        let retryRepository = LocalJSONStoryMemoryRetryRepository(storageURL: storageURL)
        try await retryRepository.saveRetry(retry)
        try await sessionRepository.deleteSession(id: sessionID)

        let deletedSessionResult = try await retryRepository.saveMemoryRetryRecords(retry)
        XCTAssertNil(deletedSessionResult)

        let memoryRepository = TestStoryMemoryRepository()
        let memoryRetryTransaction = TestStoryMemoryRetryMemoryTransaction()
        let service = StorySessionService(
            memoryRepo: memoryRepository,
            sessionRepo: sessionRepository,
            storyMemoryRepo: memoryRepository,
            storyMemoryRetryRepo: retryRepository,
            storyMemoryRetryMemoryTransaction: memoryRetryTransaction,
            pendingStoryMemoryRetries: [retry]
        )

        await service.retryStoryMemorySave(retry)

        let counts = await memoryRepository.saveCounts()
        XCTAssertEqual(counts.character, 0)
        XCTAssertEqual(counts.story, 0)
        let transactionSaveCount = await memoryRetryTransaction.saveCount()
        XCTAssertEqual(transactionSaveCount, 1)
        let remainingRetries = try await retryRepository.fetchRetries()
        XCTAssertTrue(remainingRetries.isEmpty)
        XCTAssertTrue(
            try LocalJSONStoreTransaction.load(
                CharacterMemory.self,
                fileName: "memories.json",
                baseURL: storageURL
            ).isEmpty
        )
        XCTAssertTrue(
            try LocalJSONStoreTransaction.load(
                StoryMemory.self,
                fileName: "story_memories.json",
                baseURL: storageURL
            ).isEmpty
        )
    }

    func testLegacyPayloadSessionTombstoneDoesNotResurrectStoryMemory() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let sessionID = UUID()
        let sessionRepository = LocalJSONStorySessionRepository(storageURL: storageURL)
        try await sessionRepository.saveSession(
            StorySession(id: sessionID, storyWorldId: worldID)
        )
        try await sessionRepository.deleteSession(id: sessionID)

        // Bypass saveRetry to model a record written before payload-side
        // session validation existed. The envelope has no owner, but the
        // embedded StoryMemory still names the deleted Session.
        let retry = StoryMemoryRetry(
            turnID: UUID(),
            userMessageID: UUID(),
            userText: "legacy payload",
            characterMemories: [],
            storyMemories: [
                StoryMemory(
                    storyWorldId: worldID,
                    text: "削除済みSessionの記憶",
                    storySessionId: sessionID
                )
            ],
            storySessionID: nil,
            storyWorldID: worldID
        )
        try LocalJSONStoreTransaction.save(
            [retry],
            fileName: "story_memory_retries.json",
            baseURL: storageURL
        )

        let retryRepository = LocalJSONStoryMemoryRetryRepository(storageURL: storageURL)
        let deletedPayloadResult = try await retryRepository.saveMemoryRetryRecords(retry)
        XCTAssertNil(deletedPayloadResult)
        XCTAssertTrue(
            try LocalJSONStoreTransaction.load(
                StoryMemory.self,
                fileName: "story_memories.json",
                baseURL: storageURL
            ).isEmpty
        )
    }

    func testStoryRuntimeNoticeUserRetryKeepsStableMessageIDWithoutCachedSession() {
        let userMessageID = UUID()
        let notice = StoryRuntimeNotice(
            text: "応答を再試行できます",
            userMessageID: userMessageID,
            userText: "前の発言を続ける",
            backendName: "generation failed",
            backend: .local,
            retryAction: .userTurn
        )

        XCTAssertEqual(notice.persistedUserMessageIDForRetry, userMessageID)
    }

    func testStoryTurnCommitRecoveryMatchesOnlyTheExactCommittedTurn() {
        let storyWorldID = UUID()
        let sessionID = UUID()
        let turnID = UUID()
        let userMessageID = UUID()
        let assistantMessageID = UUID()
        let secondAssistantMessageID = UUID()
        let sceneID = UUID()
        let activeCharacterID = UUID()
        let scene = StoryScene(
            id: sceneID,
            storyWorldId: storyWorldID,
            activeCharacterIds: [activeCharacterID],
            summary: "保存済みの場面"
        )
        let session = StorySession(
            id: sessionID,
            storyWorldId: storyWorldID,
            currentSceneId: sceneID,
            latestTurnCheckpoint: StoryTurnCheckpoint(
                turnID: turnID,
                userMessageID: userMessageID,
                status: .committed,
                assistantMessageIDs: [assistantMessageID, secondAssistantMessageID]
            )
        )
        let retry = StoryTurnCommitRetry(
            session: StorySession(
                id: sessionID,
                storyWorldId: storyWorldID,
                currentSceneId: sceneID
            ),
            scene: scene,
            turnID: turnID,
            attempt: 1,
            assistantMessageIDs: [assistantMessageID, secondAssistantMessageID],
            characterMemories: [],
            storyMemories: [],
            userMessageID: userMessageID,
            userText: "保存済みのターン"
        )

        XCTAssertEqual(
            StoryTurnCommitRecovery.committedSession(
                matching: retry,
                in: [session],
                scenes: [scene]
            ),
            session
        )

        var differentTurn = session
        differentTurn.latestTurnCheckpoint = StoryTurnCheckpoint(
            turnID: UUID(),
            userMessageID: userMessageID,
            status: .committed,
            assistantMessageIDs: [assistantMessageID, secondAssistantMessageID]
        )
        XCTAssertNil(
            StoryTurnCommitRecovery.committedSession(
                matching: retry,
                in: [differentTurn],
                scenes: [scene]
            )
        )

        var pending = session
        pending.latestTurnCheckpoint = StoryTurnCheckpoint(
            turnID: turnID,
            userMessageID: userMessageID,
            status: .pending,
            assistantMessageIDs: [assistantMessageID, secondAssistantMessageID]
        )
        XCTAssertNil(
            StoryTurnCommitRecovery.committedSession(
                matching: retry,
                in: [pending],
                scenes: [scene]
            )
        )

        var reordered = session
        reordered.latestTurnCheckpoint = StoryTurnCheckpoint(
            turnID: turnID,
            userMessageID: userMessageID,
            status: .committed,
            assistantMessageIDs: [secondAssistantMessageID, assistantMessageID]
        )
        XCTAssertNil(
            StoryTurnCommitRecovery.committedSession(
                matching: retry,
                in: [reordered],
                scenes: [scene]
            ),
            "assistant message order is part of the committed snapshot"
        )

        XCTAssertNil(
            StoryTurnCommitRecovery.committedSession(
                matching: retry,
                in: [session],
                scenes: []
            ),
            "a committed session without its scene must remain retryable"
        )

        var staleScene = scene
        staleScene.summary = "古い場面"
        XCTAssertNil(
            StoryTurnCommitRecovery.committedSession(
                matching: retry,
                in: [session],
                scenes: [staleScene]
            ),
            "a committed session with a stale scene must remain retryable"
        )

        var changedStoryState = session
        changedStoryState.storyState = StoryState(
            location: "別の場所",
            mood: "別の状態"
        )
        XCTAssertNil(
            StoryTurnCommitRecovery.committedSession(
                matching: retry,
                in: [changedStoryState],
                scenes: [scene]
            ),
            "a committed checkpoint with a different StoryState must remain retryable"
        )
    }

    func testPendingTurnCommitRetryRemainsReachableAfterNoticeDismissal() {
        let worldID = UUID()
        let sessionID = UUID()
        let sceneID = UUID()
        let turnID = UUID()
        let userMessageID = UUID()
        let retry = StoryTurnCommitRetry(
            session: StorySession(
                id: sessionID,
                storyWorldId: worldID,
                currentSceneId: sceneID
            ),
            scene: StoryScene(id: sceneID, storyWorldId: worldID),
            turnID: turnID,
            attempt: 1,
            assistantMessageIDs: [],
            characterMemories: [],
            storyMemories: [],
            userMessageID: userMessageID,
            userText: "保存を続ける"
        )
        let service = StorySessionService(pendingStoryTurnCommitRetries: [retry])

        service.dismissRuntimeNotice()

        guard case let .storyTurnCommit(restored)? = service.latestRuntimeNotice?.retryAction else {
            return XCTFail("pending turn commits must keep an actionable notice")
        }
        XCTAssertEqual(restored, retry)
    }

    func testStoryTurnCommitRecoveryMatchesGeneratedStateAndMessages() {
        let worldID = UUID()
        let sessionID = UUID()
        let sceneID = UUID()
        let turnID = UUID()
        let userMessageID = UUID()
        let assistantMessageID = UUID()
        let ownerID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let generatedState = StoryState(
            location: "港",
            timeOfDay: "夕方",
            mood: "静か",
            activeGoals: ["灯台へ向かう"],
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let userMessage = StoryMessage(
            id: userMessageID,
            author: .user,
            text: "灯台へ行こう",
            turnID: turnID
        )
        let assistantMessage = StoryMessage(
            id: assistantMessageID,
            author: .narrator,
            text: "港の灯りが揺れた。",
            generationID: UUID(),
            turnID: turnID
        )
        let pendingCheckpoint = StoryTurnCheckpoint(
            turnID: turnID,
            userMessageID: userMessageID,
            status: .pending,
            attempt: 2,
            ownerID: ownerID,
            baseRevision: 7,
            startedAt: startedAt,
            updatedAt: startedAt
        )
        let generatedSession = StorySession(
            id: sessionID,
            storyWorldId: worldID,
            currentSceneId: sceneID,
            messages: [userMessage, assistantMessage],
            progressLabel: "第1章",
            currentObjective: "灯台へ向かう",
            relationshipStage: "信頼",
            lastTurnProgress: "灯台へ向かうことになった",
            lastSceneSummary: "夕方の港",
            unresolvedHooks: ["灯台の明かり"],
            storyState: generatedState,
            lastSelectedModelName: "iori",
            lastUsedBackendName: "local",
            latestTurnCheckpoint: pendingCheckpoint
        )
        var committedSession = generatedSession
        committedSession.latestTurnCheckpoint = StoryTurnCheckpoint(
            turnID: turnID,
            userMessageID: userMessageID,
            status: .committed,
            attempt: 2,
            ownerID: ownerID,
            baseRevision: 7,
            assistantMessageIDs: [assistantMessageID],
            startedAt: startedAt,
            updatedAt: Date(timeIntervalSince1970: 300)
        )
        committedSession.persistenceRevision = 8
        committedSession.updatedAt = Date(timeIntervalSince1970: 300)
        let scene = StoryScene(
            id: sceneID,
            storyWorldId: worldID,
            summary: "夕方の港"
        )
        let retry = StoryTurnCommitRetry(
            session: generatedSession,
            scene: scene,
            turnID: turnID,
            attempt: 2,
            assistantMessageIDs: [assistantMessageID],
            characterMemories: [],
            storyMemories: [],
            userMessageID: userMessageID,
            userText: "灯台へ行こう"
        )

        XCTAssertEqual(
            StoryTurnCommitRecovery.committedSession(
                matching: retry,
                in: [committedSession],
                scenes: [scene]
            ),
            committedSession
        )

        var changedMessage = committedSession
        changedMessage.messages[1].text = "別の展開になった。"
        XCTAssertNil(
            StoryTurnCommitRecovery.committedSession(
                matching: retry,
                in: [changedMessage],
                scenes: [scene]
            )
        )

        var changedState = committedSession
        changedState.storyState?.mood = "嵐"
        XCTAssertNil(
            StoryTurnCommitRecovery.committedSession(
                matching: retry,
                in: [changedState],
                scenes: [scene]
            )
        )
    }

    func testStoryTurnCommitRecoveryAcceptsRepositorySceneIDNormalization() {
        let worldID = UUID()
        let sessionID = UUID()
        let sceneID = UUID()
        let turnID = UUID()
        let userMessageID = UUID()
        let assistantMessageID = UUID()
        let scene = StoryScene(id: sceneID, storyWorldId: worldID, summary: "保存済み")
        let retrySession = StorySession(
            id: sessionID,
            storyWorldId: worldID,
            currentSceneId: nil,
            latestTurnCheckpoint: StoryTurnCheckpoint(
                turnID: turnID,
                userMessageID: userMessageID,
                status: .pending,
                attempt: 1
            )
        )
        var persistedSession = retrySession
        persistedSession.currentSceneId = sceneID
        persistedSession.latestTurnCheckpoint = StoryTurnCheckpoint(
            turnID: turnID,
            userMessageID: userMessageID,
            status: .committed,
            attempt: 1,
            assistantMessageIDs: [assistantMessageID]
        )
        let retry = StoryTurnCommitRetry(
            session: retrySession,
            scene: scene,
            turnID: turnID,
            attempt: 1,
            assistantMessageIDs: [assistantMessageID],
            characterMemories: [],
            storyMemories: [],
            userMessageID: userMessageID,
            userText: "続ける"
        )

        XCTAssertNotNil(
            StoryTurnCommitRecovery.committedSession(
                matching: retry,
                in: [persistedSession],
                scenes: [scene]
            ),
            "repository normalization of a nil currentSceneId must not create a false failure"
        )
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

    func testStoryServiceDropsDeletedStoryMemoryInFallbackRetryPath() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let sessionID = UUID()
        let memoryRepository = TestStoryMemoryRepository(
            shouldThrowStoryRecordDeleted: true
        )
        let retryRepository = LocalJSONStoryMemoryRetryRepository(storageURL: storageURL)
        let retry = StoryMemoryRetry(
            turnID: UUID(),
            userMessageID: UUID(),
            userText: "削除済みSessionのfallback再試行",
            characterMemories: [],
            storyMemories: [
                StoryMemory(
                    storyWorldId: worldID,
                    text: "削除済みSessionの物語記憶",
                    storySessionId: sessionID
                )
            ],
            storySessionID: sessionID,
            storyWorldID: worldID
        )
        let service = StorySessionService(
            memoryRepo: memoryRepository,
            storyMemoryRepo: memoryRepository,
            storyMemoryRetryRepo: retryRepository,
            pendingStoryMemoryRetries: [retry]
        )

        await service.retryStoryMemorySave(retry)

        let counts = await memoryRepository.saveCounts()
        XCTAssertEqual(counts.story, 0)
        XCTAssertNil(service.latestRuntimeNotice)
        let remainingRetries = try await retryRepository.fetchRetries()
        XCTAssertTrue(remainingRetries.isEmpty)
    }

    func testStoryServiceDeletesDurableMemoryRetryAfterSuccessfulSave() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let memoryRepository = TestStoryMemoryRepository()
        let retryRepository = LocalJSONStoryMemoryRetryRepository(storageURL: storageURL)
        let retry = StoryMemoryRetry(
            turnID: UUID(),
            userMessageID: UUID(),
            userText: "保存済みの記憶を再送しない",
            characterMemories: [],
            storyMemories: [
                StoryMemory(
                    storyWorldId: UUID(),
                    text: "一度だけ保存する出来事",
                    category: .event,
                    source: .summary
                )
            ]
        )
        try await retryRepository.saveRetry(retry)

        let service = StorySessionService(
            memoryRepo: memoryRepository,
            storyMemoryRepo: memoryRepository,
            storyMemoryRetryRepo: retryRepository,
            pendingStoryMemoryRetries: [retry]
        )

        await service.retryStoryMemorySave(retry)

        let remainingRetries = try await retryRepository.fetchRetries()
        XCTAssertTrue(remainingRetries.isEmpty)
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
        XCTAssertEqual(
            service.savedTurnRevision,
            1,
            "a committed assistant turn must advance the UI revision even when memory retry remains"
        )
        guard case let .storyMemory(memoryRetry) = service.latestRuntimeNotice?.retryAction else {
            return XCTFail("failed memory writes must become a memory-only retry")
        }
        XCTAssertEqual(memoryRetry.turnID, retry.turnID)
        XCTAssertEqual(memoryRetry.characterMemories, retry.characterMemories)
        var expectedStoryMemories = retry.storyMemories
        expectedStoryMemories[0].storySessionId = session.id
        XCTAssertEqual(memoryRetry.storyMemories, expectedStoryMemories)
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
            assistantMessageIDs: [assistant.id],
            memoryRetries: []
        )
        let retried = try await repository.commitTurn(
            session: generated,
            scene: scene,
            turnID: turnID,
            assistantMessageIDs: [assistant.id],
            memoryRetries: []
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
                assistantMessageIDs: [],
                memoryRetries: []
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
            assistantMessageIDs: [],
            memoryRetries: []
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

    func testStoryTurnJournalDecodesLegacyEntryWithoutMemoryRetries() throws {
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
        let session = StorySession(
            storyWorldId: worldID,
            currentSceneId: sceneID,
            latestTurnCheckpoint: checkpoint,
            updatedAt: date
        )
        let scene = StoryScene(
            id: sceneID,
            storyWorldId: worldID,
            updatedAt: date
        )
        let entry = StoryTurnJournalEntry(
            turnID: turnID,
            session: session,
            scene: scene
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(entry)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "memoryRetries")
        let legacyData = try JSONSerialization.data(
            withJSONObject: [object],
            options: [.sortedKeys]
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(
            [StoryTurnJournalEntry].self,
            from: legacyData
        )
        XCTAssertEqual(decoded.first?.turnID, turnID)
        XCTAssertEqual(decoded.first?.memoryRetries, [])
    }

    func testStoryTurnJournalMakesMemoryRetryDurableDuringRecovery() throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let sessionID = UUID()
        let sceneID = UUID()
        let turnID = UUID()
        let userMessageID = UUID()
        let date = Date(timeIntervalSince1970: 100)
        let checkpoint = StoryTurnReducer.commit(
            pending: StoryTurnReducer.begin(
                turnID: turnID,
                userMessageID: userMessageID,
                attempt: 1,
                ownerID: nil,
                baseRevision: 1,
                startedAt: date,
                updatedAt: date
            ),
            assistantMessageIDs: [],
            updatedAt: date
        )
        let session = StorySession(
            id: sessionID,
            storyWorldId: worldID,
            currentSceneId: sceneID,
            persistenceRevision: 2,
            latestTurnCheckpoint: checkpoint,
            updatedAt: date
        )
        let scene = StoryScene(id: sceneID, storyWorldId: worldID, updatedAt: date)
        let retry = StoryMemoryRetry(
            turnID: turnID,
            userMessageID: userMessageID,
            userText: "復旧後も記憶を保存する",
            characterMemories: [],
            storyMemories: [
                StoryMemory(
                    storyWorldId: worldID,
                    text: "復旧対象の出来事",
                    storySessionId: sessionID,
                    sourceTurnIds: [turnID]
                )
            ],
            storySessionID: sessionID,
            storyWorldID: worldID
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
        try LocalJSONStoreTransaction.save(
            [StoryTurnJournalEntry(
                turnID: turnID,
                session: session,
                scene: scene,
                memoryRetries: [retry]
            )],
            fileName: "story_turn_journal.json",
            baseURL: storageURL
        )

        try StoryTurnJournal.recoverIfNeeded(baseURL: storageURL)

        XCTAssertEqual(
            try LocalJSONStoreTransaction.load(
                StoryMemoryRetry.self,
                fileName: "story_memory_retries.json",
                baseURL: storageURL
            ),
            [retry]
        )
        XCTAssertTrue(
            try LocalJSONStoreTransaction.load(
                StoryTurnJournalEntry.self,
                fileName: "story_turn_journal.json",
                baseURL: storageURL
            ).isEmpty
        )
    }

    func testStoryTurnJournalDoesNotReintroduceCompletedMemoryRetry() throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let fixture = makeCommittedJournalFixture()
        let retry = StoryMemoryRetry(
            turnID: fixture.entry.turnID,
            userMessageID: fixture.entry.session.latestTurnCheckpoint!.userMessageID,
            userText: "完了済みの記憶",
            characterMemories: [],
            storyMemories: [
                StoryMemory(
                    storyWorldId: fixture.entry.session.storyWorldId,
                    text: "すでに保存済み",
                    storySessionId: fixture.entry.session.id,
                    sourceTurnIds: [fixture.entry.turnID]
                )
            ],
            storySessionID: fixture.entry.session.id,
            storyWorldID: fixture.entry.session.storyWorldId,
            isCompleted: true
        )
        let staleJournalEntry = StoryTurnJournalEntry(
            turnID: fixture.entry.turnID,
            session: fixture.entry.session,
            scene: fixture.entry.scene,
            memoryRetries: [retry]
        )

        try LocalJSONStoreTransaction.save(
            [fixture.persistedSession],
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [fixture.persistedScene],
            fileName: "story_scenes.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [staleJournalEntry],
            fileName: "story_turn_journal.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [retry],
            fileName: "story_memory_retries.json",
            baseURL: storageURL
        )

        try StoryTurnJournal.recoverIfNeeded(baseURL: storageURL)

        XCTAssertTrue(
            try LocalJSONStoreTransaction.load(
                StoryMemoryRetry.self,
                fileName: "story_memory_retries.json",
                baseURL: storageURL
            ).isEmpty,
            "a completed marker must not be replaced by the stale journal retry"
        )
        XCTAssertTrue(
            try LocalJSONStoreTransaction.load(
                StoryTurnJournalEntry.self,
                fileName: "story_turn_journal.json",
                baseURL: storageURL
            ).isEmpty
        )
    }

    func testStoryTurnJournalDoesNotRestoreMemoryRetryAfterSessionTombstone() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let sessionID = UUID()
        let sceneID = UUID()
        let turnID = UUID()
        let userMessageID = UUID()
        let date = Date(timeIntervalSince1970: 150)
        let checkpoint = StoryTurnReducer.commit(
            pending: StoryTurnReducer.begin(
                turnID: turnID,
                userMessageID: userMessageID,
                attempt: 1,
                ownerID: nil,
                baseRevision: 1,
                startedAt: date,
                updatedAt: date
            ),
            assistantMessageIDs: [],
            updatedAt: date
        )
        let session = StorySession(
            id: sessionID,
            storyWorldId: worldID,
            currentSceneId: sceneID,
            persistenceRevision: 2,
            latestTurnCheckpoint: checkpoint,
            updatedAt: date
        )
        let scene = StoryScene(id: sceneID, storyWorldId: worldID, updatedAt: date)
        let retry = StoryMemoryRetry(
            turnID: turnID,
            userMessageID: userMessageID,
            userText: "削除された物語へ記憶を戻さない",
            characterMemories: [],
            storyMemories: [
                StoryMemory(
                    storyWorldId: worldID,
                    text: "削除されたセッションの記憶",
                    storySessionId: sessionID,
                    sourceTurnIds: [turnID]
                )
            ],
            storySessionID: sessionID,
            storyWorldID: worldID
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
        try LocalJSONStoreTransaction.save(
            [StoryTurnJournalEntry(
                turnID: turnID,
                session: session,
                scene: scene,
                memoryRetries: [retry]
            )],
            fileName: "story_turn_journal.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [retry],
            fileName: "story_memory_retries.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.withSharedLock {
            try StoryTurnJournal.recordDeletionUnlocked(
                recordID: sessionID,
                recordKind: .session,
                baseURL: storageURL
            )
        }

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
            ),
            [scene]
        )
        XCTAssertTrue(
            try LocalJSONStoreTransaction.load(
                StoryMemoryRetry.self,
                fileName: "story_memory_retries.json",
                baseURL: storageURL
            ).isEmpty
        )
        do {
            try await LocalJSONStoryMemoryRetryRepository(storageURL: storageURL)
                .saveRetry(retry)
            XCTFail("a deleted session must not accept a stale memory retry")
        } catch let error as StoryTurnPersistenceError {
            XCTAssertEqual(
                error,
                .recordDeleted(kind: .session, id: sessionID)
            )
        }
        do {
            try await LocalJSONStoryMemoryRepository(storageURL: storageURL)
                .saveMemory(retry.storyMemories[0])
            XCTFail("a deleted session must not accept a stale direct memory save")
        } catch let error as StoryTurnPersistenceError {
            XCTAssertEqual(
                error,
                .recordDeleted(kind: .session, id: sessionID)
            )
        }
        XCTAssertTrue(
            try LocalJSONStoreTransaction.load(
                StoryTurnJournalEntry.self,
                fileName: "story_turn_journal.json",
                baseURL: storageURL
            ).isEmpty
        )
    }

    func testStoryTurnJournalRepairsCorruptMemoryRetryFileDuringRecovery() throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let sessionID = UUID()
        let sceneID = UUID()
        let turnID = UUID()
        let date = Date(timeIntervalSince1970: 200)
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
        let session = StorySession(
            id: sessionID,
            storyWorldId: worldID,
            currentSceneId: sceneID,
            persistenceRevision: 2,
            latestTurnCheckpoint: checkpoint,
            updatedAt: date
        )
        let scene = StoryScene(id: sceneID, storyWorldId: worldID, updatedAt: date)
        let retry = StoryMemoryRetry(
            turnID: turnID,
            userMessageID: checkpoint.userMessageID,
            userText: "壊れたキューでも記憶を残す",
            characterMemories: [],
            storyMemories: [StoryMemory(storyWorldId: worldID, text: "復旧対象")],
            storySessionID: sessionID,
            storyWorldID: worldID
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
        try LocalJSONStoreTransaction.save(
            [StoryTurnJournalEntry(turnID: turnID, session: session, scene: scene, memoryRetries: [retry])],
            fileName: "story_turn_journal.json",
            baseURL: storageURL
        )
        try Data("[{\"invalid\":true}]".utf8).write(
            to: storageURL.appendingPathComponent("story_memory_retries.json"),
            options: .atomic
        )

        try StoryTurnJournal.recoverIfNeeded(baseURL: storageURL)

        XCTAssertEqual(
            try LocalJSONStoreTransaction.load(
                StoryMemoryRetry.self,
                fileName: "story_memory_retries.json",
                baseURL: storageURL
            ),
            [retry]
        )
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: storageURL,
                includingPropertiesForKeys: nil
            ).contains { $0.lastPathComponent.hasPrefix("story_memory_retries.corrupt-") }
        )
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

    func testStoryTurnJournalDiscardsEntryAfterIntentionalSceneDeletion() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let fixture = makeCommittedJournalFixture()
        try LocalJSONStoreTransaction.save(
            [fixture.persistedSession],
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [fixture.persistedScene],
            fileName: "story_scenes.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [fixture.entry],
            fileName: "story_turn_journal.json",
            baseURL: storageURL
        )

        let repository = LocalJSONStorySceneRepository(storageURL: storageURL)
        try await repository.deleteScene(id: fixture.persistedScene.id)
        try StoryTurnJournal.recoverIfNeeded(baseURL: storageURL)

        XCTAssertEqual(
            try LocalJSONStoreTransaction.load(
                StorySession.self,
                fileName: "story_sessions.json",
                baseURL: storageURL
            ).first?.lastTurnProgress,
            fixture.persistedSession.lastTurnProgress
        )
        XCTAssertTrue(
            try LocalJSONStoreTransaction.load(
                StoryScene.self,
                fileName: "story_scenes.json",
                baseURL: storageURL
            ).isEmpty
        )
        XCTAssertTrue(
            try LocalJSONStoreTransaction.load(
                StoryTurnJournalEntry.self,
                fileName: "story_turn_journal.json",
                baseURL: storageURL
            ).isEmpty
        )
        let tombstones = try LocalJSONStoreTransaction.load(
            StoryTurnJournalTombstone.self,
            fileName: "story_turn_journal_tombstones.json",
            baseURL: storageURL
        )
        XCTAssertEqual(tombstones.count, 1)
        XCTAssertEqual(tombstones.first?.recordID, fixture.persistedScene.id)
        XCTAssertEqual(tombstones.first?.recordKind, .scene)

        do {
            try await repository.saveScene(fixture.persistedScene)
            XCTFail("a deleted scene must not be recreated by a stale save")
        } catch let error as StoryTurnPersistenceError {
            XCTAssertEqual(
                error,
                .recordDeleted(kind: .scene, id: fixture.persistedScene.id)
            )
        }
    }

    func testSceneDeletionRecordsTombstoneWhenRecordIsAlreadyMissing() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let fixture = makeCommittedJournalFixture()
        try LocalJSONStoreTransaction.save(
            [fixture.persistedSession],
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        // The scene record is already absent, but the journal still identifies
        // the UUID that the user explicitly deleted.
        try LocalJSONStoreTransaction.save(
            [fixture.entry],
            fileName: "story_turn_journal.json",
            baseURL: storageURL
        )

        let repository = LocalJSONStorySceneRepository(storageURL: storageURL)
        try await repository.deleteScene(id: fixture.persistedScene.id)
        try StoryTurnJournal.recoverIfNeeded(baseURL: storageURL)

        XCTAssertTrue(
            try LocalJSONStoreTransaction.load(
                StoryTurnJournalEntry.self,
                fileName: "story_turn_journal.json",
                baseURL: storageURL
            ).isEmpty
        )
        XCTAssertEqual(
            try LocalJSONStoreTransaction.load(
                StoryTurnJournalTombstone.self,
                fileName: "story_turn_journal_tombstones.json",
                baseURL: storageURL
            ).first?.recordID,
            fixture.persistedScene.id
        )
    }

    func testStoryTurnJournalReconcilesTombstoneWhenRecordDeletionWasInterrupted() throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let fixture = makeCommittedJournalFixture()
        try LocalJSONStoreTransaction.save(
            [fixture.persistedSession],
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [fixture.persistedScene],
            fileName: "story_scenes.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [
                StoryTurnJournalTombstone(
                    recordID: fixture.persistedScene.id,
                    recordKind: .scene,
                    deletedAt: Date(timeIntervalSince1970: 200)
                )
            ],
            fileName: "story_turn_journal_tombstones.json",
            baseURL: storageURL
        )

        try StoryTurnJournal.recoverIfNeeded(baseURL: storageURL)

        XCTAssertTrue(
            try LocalJSONStoreTransaction.load(
                StoryScene.self,
                fileName: "story_scenes.json",
                baseURL: storageURL
            ).isEmpty
        )
        XCTAssertEqual(
            try LocalJSONStoreTransaction.load(
                StorySession.self,
                fileName: "story_sessions.json",
                baseURL: storageURL
            ).first?.id,
            fixture.persistedSession.id
        )
    }

    func testStoryTurnJournalDiscardsEntryAfterIntentionalSessionDeletion() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let fixture = makeCommittedJournalFixture()
        try LocalJSONStoreTransaction.save(
            [fixture.persistedSession],
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [fixture.persistedScene],
            fileName: "story_scenes.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [fixture.entry],
            fileName: "story_turn_journal.json",
            baseURL: storageURL
        )

        let repository = LocalJSONStorySessionRepository(storageURL: storageURL)
        try await repository.deleteSession(id: fixture.persistedSession.id)
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
            fixture.persistedScene.summary
        )
        XCTAssertTrue(
            try LocalJSONStoreTransaction.load(
                StoryTurnJournalEntry.self,
                fileName: "story_turn_journal.json",
                baseURL: storageURL
            ).isEmpty
        )

        do {
            try await repository.saveSession(fixture.persistedSession)
            XCTFail("a deleted session must not be recreated by a stale save")
        } catch let error as StoryTurnPersistenceError {
            XCTAssertEqual(
                error,
                .recordDeleted(kind: .session, id: fixture.persistedSession.id)
            )
        }
    }

    func testStoryTurnJournalRetainsJournalWhenTombstoneFileIsUnreadable() throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let fixture = makeCommittedJournalFixture()
        try LocalJSONStoreTransaction.save(
            [fixture.persistedSession],
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [fixture.persistedScene],
            fileName: "story_scenes.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [fixture.entry],
            fileName: "story_turn_journal.json",
            baseURL: storageURL
        )
        try Data("{\"unexpected\":true}".utf8).write(
            to: storageURL.appendingPathComponent("story_turn_journal_tombstones.json"),
            options: [.atomic]
        )

        XCTAssertThrowsError(try StoryTurnJournal.recoverIfNeeded(baseURL: storageURL))
        XCTAssertEqual(
            try LocalJSONStoreTransaction.load(
                StoryTurnJournalEntry.self,
                fileName: "story_turn_journal.json",
                baseURL: storageURL
            ),
            [fixture.entry]
        )
    }

    func testMalformedTombstonePreventsJournalQuarantine() throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let fixture = makeCommittedJournalFixture()
        let journalURL = storageURL.appendingPathComponent("story_turn_journal.json")
        let malformedJournal = Data("{\"invalid\":true}".utf8)

        try LocalJSONStoreTransaction.save(
            [fixture.persistedSession],
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [fixture.persistedScene],
            fileName: "story_scenes.json",
            baseURL: storageURL
        )
        try malformedJournal.write(to: journalURL, options: [.atomic])
        try Data("{\"unexpected\":true}".utf8).write(
            to: storageURL.appendingPathComponent("story_turn_journal_tombstones.json"),
            options: [.atomic]
        )

        XCTAssertThrowsError(try StoryTurnJournal.recoverIfNeeded(baseURL: storageURL))
        XCTAssertEqual(try Data(contentsOf: journalURL), malformedJournal)
        let backups = try FileManager.default.contentsOfDirectory(
            at: storageURL,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("story_turn_journal.corrupt-") }
        XCTAssertTrue(backups.isEmpty)
    }

    func testStorySceneBulkDeletionWritesTombstonesForEveryScene() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let scenes = [
            StoryScene(storyWorldId: worldID),
            StoryScene(storyWorldId: worldID),
            StoryScene(storyWorldId: UUID())
        ]
        try LocalJSONStoreTransaction.save(
            scenes,
            fileName: "story_scenes.json",
            baseURL: storageURL
        )

        let repository = LocalJSONStorySceneRepository(storageURL: storageURL)
        try await repository.deleteAllScenes(storyWorldId: worldID)

        XCTAssertEqual(
            try LocalJSONStoreTransaction.load(
                StoryScene.self,
                fileName: "story_scenes.json",
                baseURL: storageURL
            ).map(\.id),
            [scenes[2].id]
        )
        XCTAssertEqual(
            Set(
                try LocalJSONStoreTransaction.load(
                    StoryTurnJournalTombstone.self,
                    fileName: "story_turn_journal_tombstones.json",
                    baseURL: storageURL
                ).map(\.recordID)
            ),
            Set(scenes.prefix(2).map(\.id))
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

    private func makeCommittedJournalFixture() -> (
        persistedSession: StorySession,
        persistedScene: StoryScene,
        entry: StoryTurnJournalEntry
    ) {
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
            lastTurnProgress: "保存済み",
            persistenceRevision: 1,
            latestTurnCheckpoint: checkpoint,
            updatedAt: date
        )
        let persistedScene = StoryScene(
            id: sceneID,
            storyWorldId: worldID,
            summary: "保存済みの場面",
            persistenceRevision: 1,
            updatedAt: date
        )
        var journalSession = persistedSession
        journalSession.lastTurnProgress = "復旧されるはずの保存"
        journalSession.persistenceRevision = 2
        journalSession.updatedAt = date.addingTimeInterval(10)
        var journalScene = persistedScene
        journalScene.summary = "復旧されるはずの場面"
        journalScene.persistenceRevision = 2
        journalScene.updatedAt = date.addingTimeInterval(10)
        return (
            persistedSession,
            persistedScene,
            StoryTurnJournalEntry(
                turnID: turnID,
                session: journalSession,
                scene: journalScene
            )
        )
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

private actor TestStoryMemoryRetryMemoryTransaction: StoryMemoryRetryMemoryTransaction {
    private var count = 0

    func saveMemoryRetryRecords(_ retry: StoryMemoryRetry) async throws -> StoryMemoryRetry? {
        count += 1
        return nil
    }

    func saveCount() -> Int {
        count
    }
}

private actor TestStoryMemoryRepository: MemoryRepository, StoryMemoryRepository {
    private enum TestError: Error {
        case saveFailed
    }

    private let shouldFailSaves: Bool
    private let shouldThrowStoryRecordDeleted: Bool
    private var characterSaveCount = 0
    private var storySaveCount = 0

    init(
        shouldFailSaves: Bool = false,
        shouldThrowStoryRecordDeleted: Bool = false
    ) {
        self.shouldFailSaves = shouldFailSaves
        self.shouldThrowStoryRecordDeleted = shouldThrowStoryRecordDeleted
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

    func fetchMemories(storyWorldId: UUID, storySessionId: UUID) async throws -> [StoryMemory] { [] }

    func saveMemory(_ memory: StoryMemory) async throws {
        if shouldThrowStoryRecordDeleted {
            throw StoryTurnPersistenceError.recordDeleted(
                kind: .session,
                id: UUID()
            )
        }
        if shouldFailSaves { throw TestError.saveFailed }
        storySaveCount += 1
    }

    func deleteAllMemories(storyWorldId: UUID) async throws {}

    func removeSourceTurnIds(_ sourceTurnIds: Set<UUID>) async throws {}

    func saveCounts() -> (character: Int, story: Int) {
        (characterSaveCount, storySaveCount)
    }
}

private actor TestStorySessionRepository: StorySessionRepository {
    struct Commit: Sendable {
        let turnID: UUID
        let assistantMessageIDs: [UUID]
    }

    private let sessions: [StorySession]
    private(set) var lastCommit: Commit?

    init(sessions: [StorySession] = []) {
        self.sessions = sessions
    }

    func fetchSessions(storyWorldId: UUID) async throws -> [StorySession] {
        sessions.filter { $0.storyWorldId == storyWorldId }
    }
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
        assistantMessageIDs: [UUID],
        memoryRetries: [StoryMemoryRetry]
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
