import Foundation
import XCTest
@testable import KizunaAI

private final class FileIOTestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var completed = false

    func markStarted() {
        lock.lock()
        started = true
        lock.unlock()
    }

    func markCompleted() {
        lock.lock()
        completed = true
        lock.unlock()
    }

    var hasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    var hasCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }
}

@MainActor
final class KizunaAITests: XCTestCase {
    private enum LocalJSONStoreTestError: Error {
        case mutationFailed
    }

    func testStoryStateMetadataParserParsesOneValidUpdate() throws {
        let result = StoryStateMetadataParser.parse(
            "ナギ: 港を見つめた\n状態更新: {\"mood\":\"calm\",\"activeGoals\":[],\"evidence\":\"港を見つめた\"}"
        )

        guard case let .valid(visibleText, payload) = result else {
            return XCTFail("a single complete STATE_UPDATE must be valid")
        }
        XCTAssertEqual(visibleText, "ナギ: 港を見つめた")
        let patch = try JSONDecoder().decode(StoryStatePatch.self, from: payload)
        XCTAssertEqual(patch.mood, "calm")
        XCTAssertEqual(patch.activeGoals, [])
        XCTAssertEqual(patch.evidence, "港を見つめた")
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

    func testStoryStateBootstrapSeedsSceneOnlyForAnEmptySessionState() {
        let scene = StoryScene(
            storyWorldId: UUID(),
            location: "港",
            timeOfDay: "夕方",
            mood: "静か",
            sceneGoal: "灯台へ向かう"
        )

        let seeded = StoryStateBootstrap.preservingExistingState(nil, scene: scene)
        XCTAssertEqual(seeded.location, "港")
        XCTAssertEqual(seeded.timeOfDay, "夕方")
        XCTAssertEqual(seeded.mood, "静か")
        XCTAssertEqual(seeded.activeGoals, ["灯台へ向かう"])

        let advanced = StoryState(
            location: "駅前",
            timeOfDay: "深夜",
            mood: "緊張",
            activeGoals: ["鍵を探す"]
        )
        XCTAssertEqual(
            StoryStateBootstrap.preservingExistingState(advanced, scene: scene),
            advanced,
            "a later turn's StoryState must not be reset from the scene seed"
        )

        let migrated = StoryStateBootstrap.preservingExistingState(
            nil,
            scene: scene,
            initialRelationshipStage: "信頼"
        )
        XCTAssertEqual(
            migrated.relationshipStage,
            "信頼",
            "legacy Session relationshipStage is promoted only during the initial State bootstrap"
        )

        let existingWithoutStage = StoryState(location: "駅前")
        XCTAssertEqual(
            StoryStateBootstrap.preservingExistingState(
                existingWithoutStage,
                scene: scene,
                initialRelationshipStage: "信頼"
            ).relationshipStage,
            "",
            "bootstrap must not overwrite an existing StoryState; the caller owns legacy promotion"
        )

        var legacySession = StorySession(
            storyWorldId: scene.storyWorldId,
            relationshipStage: "信頼",
            storyState: existingWithoutStage
        )
        StorySessionService.promoteLegacyRelationshipStage(&legacySession)
        XCTAssertEqual(legacySession.storyState?.relationshipStage, "信頼")
        XCTAssertNil(legacySession.relationshipStage)

        var canonicalSession = StorySession(
            storyWorldId: scene.storyWorldId,
            relationshipStage: "旧データ",
            storyState: StoryState(location: "駅前", relationshipStage: "親密")
        )
        StorySessionService.promoteLegacyRelationshipStage(&canonicalSession)
        XCTAssertEqual(canonicalSession.storyState?.relationshipStage, "親密")
        XCTAssertNil(canonicalSession.relationshipStage)
    }

    func testStorySessionUsesSessionCastAndLegacySceneFallback() {
        let sessionCharacterID = UUID()
        let sceneCharacterID = UUID()
        let scene = StoryScene(
            storyWorldId: UUID(),
            activeCharacterIds: [sceneCharacterID]
        )
        let session = StorySession(
            storyWorldId: scene.storyWorldId,
            activeCharacterIds: [sessionCharacterID]
        )
        let legacySession = StorySession(storyWorldId: scene.storyWorldId)

        XCTAssertEqual(
            session.resolvedActiveCharacterIds(fallback: scene),
            [sessionCharacterID]
        )
        XCTAssertEqual(
            legacySession.resolvedActiveCharacterIds(fallback: scene),
            [sceneCharacterID]
        )
    }

    func testEmptySceneSelectionKeepsThePreviouslyResolvedCast() {
        let previousIDs = [UUID(), UUID()]
        let selectedIDs: [UUID] = []

        XCTAssertEqual(
            StorySessionService.activeCharacterIDsForTurn(
                selectedIDs: selectedIDs,
                previousIDs: previousIDs,
                limit: StoryConstants.maxActiveCharacters
            ),
            previousIDs,
            "an empty selector result must not persist an empty session cast"
        )
    }

    func testExistingStoryStateDoesNotReapplySceneValuesWhenObjectiveIsMissing() {
        let existingState = StoryState(
            location: "駅前の屋上",
            timeOfDay: "午前二時",
            mood: "静かな緊張",
            activeGoals: ["すでに選び直した目的"]
        )

        let completedTurnState = StorySessionService.deterministicStateForTurn(
            existing: existingState
        )

        XCTAssertEqual(completedTurnState.location, existingState.location)
        XCTAssertEqual(completedTurnState.timeOfDay, existingState.timeOfDay)
        XCTAssertEqual(completedTurnState.mood, existingState.mood)
        XCTAssertEqual(completedTurnState.activeGoals, existingState.activeGoals)
    }

    func testResolvedStoryObjectiveIsNotReintroducedOnTheNextTurn() {
        let scene = StoryScene(
            storyWorldId: UUID(),
            sceneGoal: "灯台へ向かう"
        )
        let seeded = StoryStateBootstrap.preservingExistingState(
            nil,
            scene: scene,
            initialObjective: "灯台へ向かう"
        )
        let resolved = StoryStatePatch(
            location: nil,
            timeOfDay: nil,
            mood: nil,
            weather: nil,
            relationshipStage: nil,
            characterUpdates: nil,
            inventoryChanges: nil,
            activeGoals: []
        ).applying(to: seeded, characterIndex: [:])

        let nextTurnState = StorySessionService.deterministicStateForTurn(
            existing: resolved
        )

        XCTAssertEqual(resolved.activeGoals, [])
        XCTAssertEqual(nextTurnState.activeGoals, [])
    }

    func testResolvedStoryObjectiveIsNotReintroducedAsAnUnresolvedHook() {
        let world = StoryWorld(
            title: "夜の物語",
            storyGoal: "灯台へ向かう"
        )
        let scene = StoryScene(
            storyWorldId: world.id,
            sceneGoal: "灯台へ向かう"
        )
        let resolvedState = StoryState(activeGoals: [])

        let hooks = StorySessionService.unresolvedHooks(
            world: world,
            scene: scene,
            previous: ["灯台へ向かう", "港の違和感"],
            storyState: resolvedState
        )

        XCTAssertFalse(hooks.contains("灯台へ向かう"))
        XCTAssertTrue(hooks.contains("港の違和感"))
    }

    func testStoryPromptUsesCanonicalStoryStateInsteadOfSceneSeed() {
        let defaults = UserDefaults.standard
        let languageKey = "kizuna.language"
        let originalLanguageValue = defaults.object(forKey: languageKey)
        defer {
            if let originalLanguageValue {
                defaults.set(originalLanguageValue, forKey: languageKey)
            } else {
                defaults.removeObject(forKey: languageKey)
            }
        }
        defaults.set(KizunaLanguage.japanese.rawValue, forKey: languageKey)

        let worldID = UUID()
        let world = StoryWorld(
            title: "夜の物語",
            worldSetting: "静かな街"
        )
        let scene = StoryScene(
            storyWorldId: worldID,
            title: "古いSceneの題名",
            location: "港",
            timeOfDay: "夕方",
            mood: "静か",
            sceneGoal: "灯台へ向かう",
            summary: "港で起きた出来事の要約"
        )
        let session = StorySession(
            storyWorldId: worldID,
            currentObjective: "灯台へ向かう"
        )
        let state = StoryState(
            location: "駅前",
            timeOfDay: "深夜",
            mood: "緊張",
            activeGoals: []
        )
        let builder = StoryPromptBuilder()

        let fullPrompt = builder.build(
            world: world,
            scene: scene,
            activeCast: [],
            inactiveCast: [],
            characterIndex: [:],
            selectedMemories: [],
            session: session,
            recentMessages: [],
            userInput: "立ち止まる",
            generationModel: .b31,
            safetyDecision: nil,
            storyState: state
        )
        let localPrompt = builder.buildLocalRuntimePrompt(
            world: world,
            scene: scene,
            activeCast: [],
            characterIndex: [:],
            selectedMemories: [],
            selectedStoryMemories: [],
            session: session,
            storyState: state,
            selectedLorebookEntries: [],
            userCharacterName: nil
        )

        XCTAssertTrue(fullPrompt.contains("場所: 駅前"))
        XCTAssertTrue(localPrompt.contains("場所: 駅前"))
        XCTAssertFalse(fullPrompt.contains("場所: 港"))
        XCTAssertFalse(localPrompt.contains("場所: 港"))
        XCTAssertFalse(fullPrompt.contains("灯台へ向かう"))
        XCTAssertFalse(localPrompt.contains("灯台へ向かう"))
        XCTAssertTrue(fullPrompt.contains("港で起きた出来事の要約"))
        XCTAssertTrue(fullPrompt.contains("初期Scene説明"))
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

    func testLocalJSONStoreMutationKeepsCorruptSourceWhenMutationFails() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let valid = StoryMemory(
            storyWorldId: UUID(),
            text: "復旧できるレコード"
        )
        let fileName = "story_memories.json"
        try LocalJSONStoreTransaction.save(
            [valid],
            fileName: fileName,
            baseURL: storageURL
        )

        let fileURL = storageURL.appendingPathComponent(fileName)
        let encodedRecords = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fileURL),
            options: [.fragmentsAllowed]
        ) as? [Any]
        var records = try XCTUnwrap(encodedRecords)
        records.append(["malformed": true])
        let corruptData = try JSONSerialization.data(
            withJSONObject: records,
            options: [.sortedKeys]
        )
        try corruptData.write(to: fileURL, options: [.atomic])

        let store = LocalJSONStore<StoryMemory>(
            fileName: fileName,
            baseURL: storageURL
        )
        do {
            try await store.mutate { _ in
                throw LocalJSONStoreTestError.mutationFailed
            }
            XCTFail("a mutation failure must be propagated")
        } catch LocalJSONStoreTestError.mutationFailed {
            // Expected. The corrupt source must remain the active file until
            // the recovery mutation can be committed successfully.
        }

        XCTAssertEqual(
            try Data(contentsOf: fileURL),
            corruptData,
            "a failed recovery mutation must not replace the active source"
        )
        let backups = try FileManager.default.contentsOfDirectory(
            at: storageURL,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("story_memories.corrupt-") }
        XCTAssertEqual(backups.count, 1)

        let recovered = try await store.loadRecoveringCorruptRecords()
        XCTAssertEqual(recovered.map(\.id), [valid.id])
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

    func testLegacyWorldMemoryIsAssignedWhenWorldHasOneSession() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let otherWorldID = UUID()
        let sessionID = UUID()
        let session = StorySession(id: sessionID, storyWorldId: worldID)
        let legacy = StoryMemory(storyWorldId: worldID, text: "旧形式の出来事")
        let otherWorldLegacy = StoryMemory(storyWorldId: otherWorldID, text: "別Worldの出来事")

        try LocalJSONStoreTransaction.save(
            [session],
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [legacy, otherWorldLegacy],
            fileName: "story_memories.json",
            baseURL: storageURL
        )

        let repository = LocalJSONStoryMemoryRepository(storageURL: storageURL)
        try await repository.assignLegacyMemoriesIfSingleSession(storyWorldId: worldID)

        let scoped = try await repository.fetchMemories(
            storyWorldId: worldID,
            storySessionId: sessionID
        )
        XCTAssertEqual(scoped.map(\.id), [legacy.id])
        XCTAssertEqual(scoped.first?.storySessionId, sessionID)
        let otherWorldMemories = try await repository.fetchMemories(storyWorldId: otherWorldID)
        XCTAssertNil(otherWorldMemories.first?.storySessionId, "assignment must not cross StoryWorld boundaries")
    }

    func testLegacyWorldMemoryStaysUnassignedWhenWorldHasMultipleSessions() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let firstSessionID = UUID()
        let secondSessionID = UUID()
        let legacy = StoryMemory(storyWorldId: worldID, text: "どちらのSessionか不明")

        try LocalJSONStoreTransaction.save(
            [
                StorySession(id: firstSessionID, storyWorldId: worldID),
                StorySession(id: secondSessionID, storyWorldId: worldID)
            ],
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [legacy],
            fileName: "story_memories.json",
            baseURL: storageURL
        )

        let repository = LocalJSONStoryMemoryRepository(storageURL: storageURL)
        try await repository.assignLegacyMemoriesIfSingleSession(storyWorldId: worldID)

        let allMemories = try await repository.fetchMemories(storyWorldId: worldID)
        XCTAssertEqual(allMemories.map(\.id), [legacy.id])
        XCTAssertNil(allMemories.first?.storySessionId)
        let firstSessionMemories = try await repository.fetchMemories(
            storyWorldId: worldID,
            storySessionId: firstSessionID
        )
        let secondSessionMemories = try await repository.fetchMemories(
            storyWorldId: worldID,
            storySessionId: secondSessionID
        )
        XCTAssertTrue(firstSessionMemories.isEmpty)
        XCTAssertTrue(secondSessionMemories.isEmpty)
    }

    func testLegacyWorldMemoryMigrationPreservesCorruptRecords() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let sessionID = UUID()
        let validLegacy = StoryMemory(storyWorldId: worldID, text: "読める旧メモリー")

        try LocalJSONStoreTransaction.save(
            [StorySession(id: sessionID, storyWorldId: worldID)],
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [validLegacy],
            fileName: "story_memories.json",
            baseURL: storageURL
        )

        let memoryURL = storageURL.appendingPathComponent("story_memories.json")
        let encodedRecords = try JSONSerialization.jsonObject(
            with: Data(contentsOf: memoryURL),
            options: [.fragmentsAllowed]
        ) as? [Any]
        var records = try XCTUnwrap(encodedRecords)
        records.append(["malformed": true])
        try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
            .write(to: memoryURL, options: [.atomic])

        let repository = LocalJSONStoryMemoryRepository(storageURL: storageURL)
        try await repository.assignLegacyMemoriesIfSingleSession(storyWorldId: worldID)

        let preservedRecords = try JSONSerialization.jsonObject(
            with: Data(contentsOf: memoryURL),
            options: [.fragmentsAllowed]
        ) as? [Any]
        XCTAssertEqual(
            preservedRecords?.count,
            2,
            "migration must not save a recovered array and drop the malformed source record"
        )
        let worldMemories = try await repository.fetchMemories(storyWorldId: worldID)
        XCTAssertEqual(worldMemories.map(\.id), [validLegacy.id])
        XCTAssertNil(worldMemories.first?.storySessionId)
    }

    func testLegacyWorldMemoryMigrationRechecksChangedFileAndDefersTrimToSave() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let sessionID = UUID()
        let first = StoryMemory(
            storyWorldId: worldID,
            text: "最初の旧メモリー",
            importance: 0.2
        )
        let second = StoryMemory(
            storyWorldId: worldID,
            text: "後から追加された旧メモリー",
            importance: 0.9
        )
        try LocalJSONStoreTransaction.save(
            [StorySession(id: sessionID, storyWorldId: worldID)],
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [first],
            fileName: "story_memories.json",
            baseURL: storageURL
        )

        let repository = LocalJSONStoryMemoryRepository(
            storageURL: storageURL,
            perScopeLimit: 1
        )
        try await repository.assignLegacyMemoriesIfSingleSession(storyWorldId: worldID)

        var records = try LocalJSONStoreTransaction.load(
            StoryMemory.self,
            fileName: "story_memories.json",
            baseURL: storageURL
        )
        records.append(second)
        try LocalJSONStoreTransaction.save(
            records,
            fileName: "story_memories.json",
            baseURL: storageURL
        )

        // The changed file fingerprint invalidates the marker, so a legacy
        // record restored/imported after the first check is still migrated.
        try await repository.assignLegacyMemoriesIfSingleSession(storyWorldId: worldID)
        let migrated = try await repository.fetchMemories(
            storyWorldId: worldID,
            storySessionId: sessionID
        )
        XCTAssertEqual(Set(migrated.map(\.id)), Set([first.id, second.id]))

        // Migration itself is lossless. The established save path, not the
        // compatibility pass, owns the per-session limit.
        let third = StoryMemory(
            storyWorldId: worldID,
            text: "新しいメモリー",
            importance: 1.0,
            storySessionId: sessionID
        )
        try await repository.saveMemory(third)
        let trimmed = try await repository.fetchMemories(
            storyWorldId: worldID,
            storySessionId: sessionID
        )
        XCTAssertEqual(trimmed.count, 1)
        XCTAssertEqual(trimmed.first?.id, third.id)
    }

    func testLegacyWorldMemoryMigrationRechecksWhenOnlySessionFileChanges() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let sessionID = UUID()
        let legacy = StoryMemory(storyWorldId: worldID, text: "Session追加待ちの旧メモリー")

        try LocalJSONStoreTransaction.save(
            [StorySession](),
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [legacy],
            fileName: "story_memories.json",
            baseURL: storageURL
        )

        let repository = LocalJSONStoryMemoryRepository(storageURL: storageURL)
        try await repository.assignLegacyMemoriesIfSingleSession(storyWorldId: worldID)

        // Only the Session file changes. The migration marker must notice the
        // new owner without requiring a write to story_memories.json.
        try LocalJSONStoreTransaction.save(
            [StorySession(id: sessionID, storyWorldId: worldID)],
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000_000_000)],
            ofItemAtPath: storageURL.appendingPathComponent("story_sessions.json").path
        )

        try await repository.assignLegacyMemoriesIfSingleSession(storyWorldId: worldID)
        let migrated = try await repository.fetchMemories(
            storyWorldId: worldID,
            storySessionId: sessionID
        )
        XCTAssertEqual(migrated.map(\.id), [legacy.id])
    }

    func testStoryMemoryRepositoryLegacyAssignmentContract() async throws {
        let worldID = UUID()
        let sessionID = UUID()
        let legacy = StoryMemory(storyWorldId: worldID, text: "契約テストの旧メモリー")

        let singleSessionRepository = TestStoryMemoryRepository(
            storySessions: [StorySession(id: sessionID, storyWorldId: worldID)],
            storyMemories: [legacy]
        )
        try await singleSessionRepository.assignLegacyMemoriesIfSingleSession(storyWorldId: worldID)
        let singleSessionMemories = try await singleSessionRepository.fetchMemories(storyWorldId: worldID)
        XCTAssertEqual(
            singleSessionMemories.first?.storySessionId,
            sessionID,
            "exactly one live Session may claim a world-scoped legacy memory"
        )

        let ambiguousRepository = TestStoryMemoryRepository(
            storySessions: [
                StorySession(storyWorldId: worldID),
                StorySession(storyWorldId: worldID)
            ],
            storyMemories: [legacy]
        )
        try await ambiguousRepository.assignLegacyMemoriesIfSingleSession(storyWorldId: worldID)
        let ambiguousMemories = try await ambiguousRepository.fetchMemories(storyWorldId: worldID)
        XCTAssertNil(
            ambiguousMemories.first?.storySessionId,
            "multiple Sessions must not guess which Session owns the legacy memory"
        )

        let noSessionRepository = TestStoryMemoryRepository(storyMemories: [legacy])
        try await noSessionRepository.assignLegacyMemoriesIfSingleSession(storyWorldId: worldID)
        let noSessionMemories = try await noSessionRepository.fetchMemories(storyWorldId: worldID)
        XCTAssertNil(
            noSessionMemories.first?.storySessionId,
            "zero Sessions must leave the legacy memory unassigned"
        )
    }

    func testMemoryPromptScopeRejectsUndoPreservedUserOnlyTurn() {
        let worldID = UUID()
        let sessionID = UUID()
        let committedTurnID = UUID()
        let undoneTurnID = UUID()
        let session = StorySession(
            id: sessionID,
            storyWorldId: worldID,
            messages: [
                StoryMessage(author: .user, text: "確定した入力", turnID: committedTurnID),
                StoryMessage(
                    author: .cast(characterId: UUID(), displayName: "ナギ"),
                    text: "確定した返答",
                    turnID: committedTurnID
                ),
                StoryMessage(author: .user, text: "取り消した入力", turnID: undoneTurnID)
            ]
        )
        let committedMemory = StoryMemory(
            storyWorldId: worldID,
            text: "確定した出来事",
            storySessionId: sessionID,
            sourceTurnIds: [committedTurnID]
        )
        let undoneMemory = StoryMemory(
            storyWorldId: worldID,
            text: "取り消した出来事",
            storySessionId: sessionID,
            sourceTurnIds: [undoneTurnID]
        )

        XCTAssertEqual(session.memoryEligibleTurnIDs(), Set([committedTurnID]))
        XCTAssertEqual(
            StoryMemory.scoped(
                to: sessionID,
                sourceTurnIds: session.memoryEligibleTurnIDs(),
                from: [committedMemory, undoneMemory]
            ),
            [committedMemory]
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
        object.removeValue(forKey: "missingSessionRestoreAttempts")
        object.removeValue(forKey: "isAbandoned")
        let legacyData = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )

        let decoded = try JSONDecoder().decode(StoryMemoryRetry.self, from: legacyData)
        XCTAssertEqual(decoded, retry)
        XCTAssertFalse(decoded.isCompleted)
        XCTAssertEqual(decoded.missingSessionRestoreAttempts, 0)
        XCTAssertFalse(decoded.isAbandoned)
    }

    func testStoryMemoryImportanceIsClampedWhenDecodingUntrustedJSON() throws {
        let memory = StoryMemory(
            storyWorldId: UUID(),
            text: "範囲外の重要度",
            importance: 0.5
        )
        let encoder = JSONEncoder()
        var highObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(memory)) as? [String: Any]
        )
        highObject["importance"] = 9.0
        let high = try JSONDecoder().decode(
            StoryMemory.self,
            from: JSONSerialization.data(withJSONObject: highObject)
        )
        XCTAssertEqual(high.importance, 1.0)

        var lowObject = highObject
        lowObject["importance"] = -4.0
        let low = try JSONDecoder().decode(
            StoryMemory.self,
            from: JSONSerialization.data(withJSONObject: lowObject)
        )
        XCTAssertEqual(low.importance, 0.0)
    }

    func testStoryMemorySourceMetadataImportanceIsClampedWhenDecoding() throws {
        let sourceTurnID = UUID()
        let memory = StoryMemory(
            storyWorldId: UUID(),
            text: "出典メタデータの重要度",
            sourceTurnIds: [sourceTurnID]
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(memory)
            ) as? [String: Any]
        )
        var metadata = try XCTUnwrap(
            object["sourceTurnMetadata"] as? [String: Any]
        )
        var sourceMetadata = try XCTUnwrap(
            metadata[sourceTurnID.uuidString] as? [String: Any]
        )
        sourceMetadata["importance"] = 9.0
        metadata[sourceTurnID.uuidString] = sourceMetadata
        object["sourceTurnMetadata"] = metadata

        let decoded = try JSONDecoder().decode(
            StoryMemory.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(
            decoded.sourceTurnMetadata[sourceTurnID]?.importance,
            1.0
        )
    }

    func testStoryMemoryImportanceNormalizesNaNToZero() {
        let sourceTurnID = UUID()
        let metadata = StoryMemorySourceMetadata(
            importance: .nan,
            createdAt: Date()
        )
        let memory = StoryMemory(
            storyWorldId: UUID(),
            text: "NaN重要度を正規化する",
            importance: .nan,
            sourceTurnIds: [sourceTurnID]
        )

        XCTAssertEqual(metadata.importance, 0.0)
        XCTAssertEqual(memory.importance, 0.0)
        XCTAssertEqual(memory.sourceTurnMetadata[sourceTurnID]?.importance, 0.0)
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

    func testSourceLessStoryMemoryMergeUpdatesLegacyAggregate() {
        let createdAt = Date(timeIntervalSince1970: 100)
        let existing = StoryMemory(
            storyWorldId: UUID(),
            text: "同じ出来事",
            importance: 0.2,
            createdAt: createdAt,
            lastUsedAt: createdAt,
            sourceTurnIds: []
        )
        var incoming = existing
        incoming.id = UUID()
        incoming.importance = 0.8

        var values = [existing]
        let mergeStartedAt = Date()
        LocalJSONStoryMemoryRepository.mergeMemory(incoming, &values)
        let mergeFinishedAt = Date()

        let merged = values[0]
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(merged.importance, 0.8)
        XCTAssertEqual(merged.sourceTurnMetadata, [:])
        XCTAssertGreaterThanOrEqual(merged.lastUsedAt ?? .distantPast, mergeStartedAt)
        XCTAssertLessThanOrEqual(merged.lastUsedAt ?? .distantFuture, mergeFinishedAt)
        XCTAssertGreaterThan(merged.lastUsedAt ?? .distantPast, existing.lastUsedAt ?? .distantPast)
    }

    func testSourceLessStoryMemoryDoesNotMergeWithAttributedRecord() {
        let worldID = UUID()
        let sessionID = UUID()
        let sourceTurnID = UUID()
        let legacy = StoryMemory(
            storyWorldId: worldID,
            text: "同じ内容",
            storySessionId: sessionID
        )
        let attributed = StoryMemory(
            storyWorldId: worldID,
            text: "同じ内容",
            storySessionId: sessionID,
            sourceTurnIds: [sourceTurnID]
        )

        var values = [legacy]
        LocalJSONStoryMemoryRepository.mergeMemory(attributed, &values)

        XCTAssertEqual(values.count, 2)
        XCTAssertTrue(values.contains(where: { $0.id == legacy.id && $0.sourceTurnIds.isEmpty }))
        XCTAssertTrue(values.contains(where: { $0.id == attributed.id && $0.sourceTurnIds == [sourceTurnID] }))
    }

    func testMovingAttributedStoryMemoryDoesNotMergeWithSourceLessDestination() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let sourceWorldID = UUID()
        let destinationWorldID = UUID()
        let sessionID = UUID()
        let sourceTurnID = UUID()
        let repository = LocalJSONStoryMemoryRepository(storageURL: storageURL)
        let legacy = StoryMemory(
            storyWorldId: destinationWorldID,
            text: "移動先の旧形式",
            storySessionId: sessionID
        )
        let attributed = StoryMemory(
            storyWorldId: sourceWorldID,
            text: "移動先の旧形式",
            storySessionId: sessionID,
            sourceTurnIds: [sourceTurnID]
        )

        try await repository.saveMemory(legacy)
        try await repository.saveMemory(attributed)
        try await repository.moveMemory(attributed, to: destinationWorldID)

        let moved = try await repository.fetchMemories(
            storyWorldId: destinationWorldID,
            storySessionId: sessionID
        )
        XCTAssertEqual(moved.count, 2)

        try await repository.removeSourceTurnIds([sourceTurnID])
        let remaining = try await repository.fetchMemories(
            storyWorldId: destinationWorldID,
            storySessionId: sessionID
        )
        XCTAssertEqual(remaining.map(\.id), [legacy.id])
        XCTAssertTrue(remaining[0].sourceTurnIds.isEmpty)
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

    func testStoryMemoryRetryRestoreQuarantinesMissingSessionAfterBoundedAttempts() async throws {
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

        for attempt in 1...2 {
            try await service.restorePendingStoryMemoryRetries(
                storySessionID: sessionID,
                storyWorldID: worldID
            )
            let remaining = try await retryRepository.fetchRetries()
            XCTAssertEqual(remaining.count, 1)
            XCTAssertEqual(remaining[0].missingSessionRestoreAttempts, attempt)
            XCTAssertFalse(remaining[0].isAbandoned)
        }

        try await service.restorePendingStoryMemoryRetries(
            storySessionID: sessionID,
            storyWorldID: worldID
        )

        XCTAssertNil(service.latestRuntimeNotice)
        let remainingRetries = try await retryRepository.fetchRetries()
        XCTAssertTrue(remainingRetries.isEmpty)
        let quarantined = try LocalJSONStoreTransaction.load(
            StoryMemoryRetry.self,
            fileName: "story_memory_retries.json",
            baseURL: storageURL
        )
        XCTAssertEqual(quarantined.count, 1)
        XCTAssertEqual(quarantined[0].missingSessionRestoreAttempts, 3)
        XCTAssertTrue(quarantined[0].isAbandoned)
    }

    func testOwnerlessLegacyMemoryRetryStaysMigratableWhenSessionIsMissing() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let missingSessionID = UUID()
        let retry = StoryMemoryRetry(
            turnID: UUID(),
            userMessageID: UUID(),
            userText: "所属Sessionがまだ確定していない記憶",
            characterMemories: [],
            storyMemories: [
                StoryMemory(
                    storyWorldId: worldID,
                    text: "後で移行できる旧形式記憶"
                )
            ],
            storyWorldID: worldID
        )
        let retryRepository = LocalJSONStoryMemoryRetryRepository(storageURL: storageURL)
        try await retryRepository.saveRetry(retry)

        let service = StorySessionService(
            sessionRepo: TestStorySessionRepository(),
            storyMemoryRetryRepo: retryRepository
        )

        for _ in 1...4 {
            try await service.restorePendingStoryMemoryRetries(
                storySessionID: missingSessionID,
                storyWorldID: worldID
            )
        }

        let remaining = try await retryRepository.fetchRetries()
        XCTAssertEqual(remaining, [retry])
        XCTAssertEqual(remaining[0].missingSessionRestoreAttempts, 0)
        XCTAssertFalse(remaining[0].isAbandoned)
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
        let failedSession = StorySession(
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
        // The live Session may already have been marked failed by a stale
        // cleanup, while the journal still contains the earlier committed
        // snapshot. The journal must validate the snapshot, not the newer
        // failure state, so a missing Scene keeps the recovery material.
        var journalSession = failedSession
        journalSession.latestTurnCheckpoint = StoryTurnReducer.commit(
            pending: pending,
            assistantMessageIDs: [],
            updatedAt: date
        )
        journalSession.persistenceRevision = 2
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
            [failedSession],
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        // The journal intentionally references a missing Scene. Recovery must
        // retain the snapshot, which exercises the fence rather than relying
        // on journal deletion as the cleanup mechanism.
        try LocalJSONStoreTransaction.save(
            [StoryTurnJournalEntry(
                turnID: turnID,
                session: journalSession,
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
            session: journalSession,
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

    func testMismatchedLocalMemoryStorageRootsUsePerRepositoryFallback() async throws {
        let root = try makeStoryPersistenceTestDirectory()
        let memoryURL = root.appendingPathComponent("character-memory")
        let storyMemoryURL = root.appendingPathComponent("story-memory")
        let retryURL = root.appendingPathComponent("retry-queue")
        let worldID = UUID()
        let sessionID = UUID()
        let retry = StoryMemoryRetry(
            turnID: UUID(),
            userMessageID: UUID(),
            userText: "保存先が異なる場合も正しいファイルへ保存する",
            characterMemories: [
                CharacterMemory(
                    characterId: UUID(),
                    text: "キャラクターの記憶",
                    category: .event,
                    source: .aiOutput
                )
            ],
            storyMemories: [
                StoryMemory(
                    storyWorldId: worldID,
                    text: "物語の記憶",
                    storySessionId: sessionID
                )
            ],
            storySessionID: sessionID,
            storyWorldID: worldID
        )
        let memoryRepository = LocalJSONMemoryRepository(storageURL: memoryURL)
        let storyMemoryRepository = LocalJSONStoryMemoryRepository(storageURL: storyMemoryURL)
        let retryRepository = LocalJSONStoryMemoryRetryRepository(storageURL: retryURL)
        let service = StorySessionService(
            memoryRepo: memoryRepository,
            sessionRepo: TestStorySessionRepository(
                sessions: [StorySession(id: sessionID, storyWorldId: worldID)]
            ),
            storyMemoryRepo: storyMemoryRepository,
            storyMemoryRetryRepo: retryRepository,
            pendingStoryMemoryRetries: [retry]
        )

        try await retryRepository.saveRetry(retry)
        await service.retryStoryMemorySave(retry)

        let characterMemories = try LocalJSONStoreTransaction.load(
            CharacterMemory.self,
            fileName: "memories.json",
            baseURL: memoryURL
        )
        let storyMemories = try LocalJSONStoreTransaction.load(
            StoryMemory.self,
            fileName: "story_memories.json",
            baseURL: storyMemoryURL
        )
        XCTAssertEqual(characterMemories.map(\.text), ["キャラクターの記憶"])
        XCTAssertEqual(storyMemories.map(\.text), ["物語の記憶"])

        // The built-in transaction must not have written into the retry
        // repository's unrelated storage root.
        XCTAssertTrue(
            try LocalJSONStoreTransaction.load(
                CharacterMemory.self,
                fileName: "memories.json",
                baseURL: retryURL
            ).isEmpty
        )
        XCTAssertTrue(
            try LocalJSONStoreTransaction.load(
                StoryMemory.self,
                fileName: "story_memories.json",
                baseURL: retryURL
            ).isEmpty
        )
        let remainingRetries = try await retryRepository.fetchRetries()
        XCTAssertTrue(remainingRetries.isEmpty)
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

    func testDeletingSessionRemovesOnlyItsStoryMemories() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let deletedSessionID = UUID()
        let remainingSessionID = UUID()
        let sessionRepository = LocalJSONStorySessionRepository(storageURL: storageURL)
        try await sessionRepository.saveSession(
            StorySession(id: deletedSessionID, storyWorldId: worldID)
        )
        try await sessionRepository.saveSession(
            StorySession(id: remainingSessionID, storyWorldId: worldID)
        )

        let deletedMemory = StoryMemory(
            storyWorldId: worldID,
            text: "削除対象のSession記憶",
            storySessionId: deletedSessionID
        )
        let remainingMemory = StoryMemory(
            storyWorldId: worldID,
            text: "残すSession記憶",
            storySessionId: remainingSessionID
        )
        let legacyMemory = StoryMemory(
            storyWorldId: worldID,
            text: "残す旧形式記憶"
        )
        try LocalJSONStoreTransaction.save(
            [deletedMemory, remainingMemory, legacyMemory],
            fileName: "story_memories.json",
            baseURL: storageURL
        )

        try await sessionRepository.deleteSession(id: deletedSessionID)

        let sessions = try LocalJSONStoreTransaction.load(
            StorySession.self,
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        XCTAssertEqual(sessions.map(\.id), [remainingSessionID])

        let memories = try LocalJSONStoreTransaction.load(
            StoryMemory.self,
            fileName: "story_memories.json",
            baseURL: storageURL
        )
        XCTAssertEqual(Set(memories.map(\.id)), Set([remainingMemory.id, legacyMemory.id]))
        XCTAssertTrue(try LocalJSONStoreTransaction.withSharedLock {
            try StoryTurnJournal.hasTombstoneUnlocked(
                recordID: deletedSessionID,
                recordKind: .session,
                baseURL: storageURL
            )
        })
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

        var editedScene = scene
        editedScene.summary = "ユーザーが編集した初期説明"
        XCTAssertNotNil(
            StoryTurnCommitRecovery.committedSession(
                matching: retry,
                in: [session],
                scenes: [editedScene]
            ),
            "runtime turn recovery must not depend on a mutable Scene summary"
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

    func testStoryServicePreservesMemoryRetryQuarantineStateAfterPartialSave() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let retry = StoryMemoryRetry(
            turnID: UUID(),
            userMessageID: UUID(),
            userText: "部分保存後も隔離状態を維持する",
            characterMemories: [],
            storyMemories: [
                StoryMemory(storyWorldId: UUID(), text: "残った物語記憶")
            ],
            missingSessionRestoreAttempts: 2,
            isAbandoned: false
        )
        let memoryRepository = TestStoryMemoryRepository(shouldFailSaves: true)
        let retryRepository = LocalJSONStoryMemoryRetryRepository(storageURL: storageURL)
        try await retryRepository.saveRetry(retry)

        let service = StorySessionService(
            memoryRepo: memoryRepository,
            storyMemoryRepo: memoryRepository,
            storyMemoryRetryRepo: retryRepository,
            pendingStoryMemoryRetries: [retry]
        )

        await service.retryStoryMemorySave(retry)

        let remaining = try await retryRepository.fetchRetries()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].missingSessionRestoreAttempts, 2)
        XCTAssertFalse(remaining[0].isAbandoned)
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

    func testLocalJSONFileIOExecutorDoesNotRunOnMainThread() async throws {
        let ranOnMainThread = try await LocalJSONStoreTransaction.performOnFileIO {
            Thread.isMainThread
        }

        XCTAssertFalse(ranOnMainThread)
    }

    func testLocalJSONFileIOCancellationWaitsForOperationToFinish() async throws {
        let probe = FileIOTestProbe()
        let bodyMayFinish = DispatchSemaphore(value: 0)
        // XCTestCase is MainActor-isolated. A plain Task would inherit that
        // actor, so use a detached task to let the operation reach the
        // dedicated queue while this test yields during start-up polling.
        let task = Task.detached { () -> Bool in
            try await LocalJSONStoreTransaction.performOnFileIO {
                probe.markStarted()
                bodyMayFinish.wait()
                probe.markCompleted()
                return true
            }
        }
        var didReleaseBody = false
        defer {
            task.cancel()
            if !didReleaseBody {
                bodyMayFinish.signal()
            }
        }

        // Yield the MainActor while the detached task reaches the dedicated
        // file-I/O queue. Blocking the test actor on a semaphore here would
        // prevent a scheduling-sensitive start signal from being observed.
        let deadline = Date().addingTimeInterval(1)
        while !probe.hasStarted && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard probe.hasStarted else {
            bodyMayFinish.signal()
            didReleaseBody = true
            _ = try? await task.value
            XCTFail("the file operation must reach its started state before cancellation")
            return
        }

        task.cancel()
        bodyMayFinish.signal()
        didReleaseBody = true
        let completed = try await task.value
        XCTAssertTrue(completed)
        // The operation started before cancellation, so its completed result
        // is returned instead of pretending an atomic write was rolled back.
        XCTAssertTrue(probe.hasCompleted)
    }

    func testStoryTurnOwnerLeaseCanReleaseAndReRegisterSafely() {
        let registry = StoryTurnOwnerRegistry()
        let lease = StoryTurnOwnerLease(registry: registry)

        XCTAssertTrue(registry.activeOwnerIDs().contains(lease.id))
        lease.unregister()
        lease.unregister()
        XCTAssertFalse(registry.activeOwnerIDs().contains(lease.id))

        lease.register()
        XCTAssertTrue(registry.activeOwnerIDs().contains(lease.id))
    }

    func testLocalJSONFileIOCancellationStateTransitionsAreAtomic() {
        let cancelled = LocalJSONStoreFileIOCancellationState()
        cancelled.cancel()
        XCTAssertFalse(cancelled.begin())

        let started = LocalJSONStoreFileIOCancellationState()
        XCTAssertTrue(started.begin())
        started.cancel()
        XCTAssertFalse(started.begin())
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

    func testStorySessionRepositoryUndoRestoresPreTurnStateAndFencesMemory() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let sceneID = UUID()
        let sessionID = UUID()
        let scene = StoryScene(id: sceneID, storyWorldId: worldID)
        let userMessage = StoryMessage(author: .user, text: "港へ向かう")
        let opening = StoryMessage(author: .narrator, text: "雨の港", turnID: nil)
        let beforeState = StoryState(
            location: "駅前",
            timeOfDay: "夕方",
            mood: "静か",
            relationshipStage: "知り合い"
        )
        let original = StorySession(
            id: sessionID,
            storyWorldId: worldID,
            currentSceneId: sceneID,
            activeCharacterIds: [UUID()],
            messages: [opening],
            progressLabel: "第1章",
            currentObjective: "手紙を探す",
            lastTurnProgress: "まだ何も起きていない",
            lastSceneSummary: "駅前で待っている",
            unresolvedHooks: ["届かない手紙"],
            storyState: beforeState,
            lastSelectedModelName: "iori",
            lastUsedBackendName: "local",
            persistenceRevision: 4
        )
        try LocalJSONStoreTransaction.save(
            [original],
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [scene],
            fileName: "story_scenes.json",
            baseURL: storageURL
        )

        let repository = LocalJSONStorySessionRepository(storageURL: storageURL)
        let turnID = UUID()
        let pending = try await repository.beginTurn(
            session: original,
            userMessage: userMessage,
            turnID: turnID,
            attempt: 1
        )
        let narrator = StoryMessage(
            author: .narrator,
            text: "遠くで汽笛が鳴った",
            turnID: turnID
        )
        let cast = StoryMessage(
            author: .cast(characterId: try XCTUnwrap(original.activeCharacterIds?.first), displayName: "ナギ"),
            text: "手紙は倉庫にある",
            turnID: turnID
        )
        var generated = pending
        generated.messages.append(contentsOf: [narrator, cast])
        generated.progressLabel = "第1章・倉庫へ"
        generated.currentObjective = "倉庫を調べる"
        generated.lastTurnProgress = "倉庫の場所がわかった"
        generated.lastSceneSummary = "港の倉庫を見つめる"
        generated.unresolvedHooks = ["倉庫の鍵"]
        generated.activeCharacterIds = [try XCTUnwrap(original.activeCharacterIds?.first)]
        generated.storyState = StoryState(
            location: "港の倉庫",
            timeOfDay: "夜",
            mood: "緊張",
            relationshipStage: "信頼が芽生えた"
        )
        let committed = try await repository.commitTurn(
            session: generated,
            scene: scene,
            turnID: turnID,
            assistantMessageIDs: [narrator.id, cast.id],
            memoryRetries: []
        )

        let otherTurnID = UUID()
        let removedMemory = StoryMemory(
            storyWorldId: worldID,
            characterId: original.activeCharacterIds!.first,
            text: "倉庫の場所",
            category: .event,
            source: .summary,
            storySessionId: sessionID,
            sourceTurnIds: [turnID]
        )
        let mergedMemory = StoryMemory(
            storyWorldId: worldID,
            characterId: original.activeCharacterIds!.first,
            text: "鍵の手がかり",
            category: .event,
            source: .summary,
            storySessionId: sessionID,
            sourceTurnIds: [turnID, otherTurnID]
        )
        try LocalJSONStoreTransaction.save(
            [removedMemory, mergedMemory],
            fileName: "story_memories.json",
            baseURL: storageURL
        )
        let retry = StoryMemoryRetry(
            turnID: turnID,
            userMessageID: userMessage.id,
            userText: userMessage.text,
            characterMemories: [],
            storyMemories: [removedMemory],
            storySessionID: sessionID,
            storyWorldID: worldID
        )
        try LocalJSONStoreTransaction.save(
            [retry],
            fileName: "story_memory_retries.json",
            baseURL: storageURL
        )

        let undone = try await repository.undoCommittedTurn(
            sessionID: sessionID,
            turnID: turnID,
            attempt: 1,
            expectedRevision: committed.effectivePersistenceRevision
        )

        XCTAssertEqual(undone.persistenceRevision, committed.effectivePersistenceRevision + 1)
        XCTAssertEqual(undone.messages.map(\.id), [opening.id, userMessage.id])
        XCTAssertEqual(undone.messages.last?.text, userMessage.text)
        XCTAssertEqual(undone.progressLabel, original.progressLabel)
        XCTAssertEqual(undone.currentObjective, original.currentObjective)
        XCTAssertEqual(undone.lastTurnProgress, original.lastTurnProgress)
        XCTAssertEqual(undone.lastSceneSummary, original.lastSceneSummary)
        XCTAssertEqual(undone.unresolvedHooks, original.unresolvedHooks)
        XCTAssertEqual(undone.activeCharacterIds, original.activeCharacterIds)
        XCTAssertEqual(undone.storyState, original.storyState)
        XCTAssertEqual(undone.latestTurnCheckpoint?.status, .cancelled)
        XCTAssertEqual(undone.latestTurnCheckpoint?.failureCode, "undone")
        XCTAssertTrue(undone.latestTurnCheckpoint?.assistantMessageIDs.isEmpty == true)
        XCTAssertEqual(undone.latestTurnCheckpoint?.preTurnSnapshot, committed.latestTurnCheckpoint?.preTurnSnapshot)

        let persistedMemories = try LocalJSONStoreTransaction.load(
            StoryMemory.self,
            fileName: "story_memories.json",
            baseURL: storageURL
        )
        XCTAssertFalse(persistedMemories.contains(where: { $0.id == removedMemory.id }))
        XCTAssertEqual(
            persistedMemories.first(where: { $0.id == mergedMemory.id })?.sourceTurnIds,
            [otherTurnID]
        )
        let persistedRetries = try LocalJSONStoreTransaction.load(
            StoryMemoryRetry.self,
            fileName: "story_memory_retries.json",
            baseURL: storageURL
        )
        XCTAssertTrue(persistedRetries.isEmpty)

        let regenerated = try await repository.beginTurn(
            session: undone,
            userMessage: StoryMessage(id: UUID(), author: .user, text: userMessage.text),
            turnID: turnID,
            attempt: 2
        )
        XCTAssertEqual(regenerated.latestTurnCheckpoint?.status, .pending)
        XCTAssertEqual(regenerated.latestTurnCheckpoint?.attempt, 2)
        XCTAssertEqual(regenerated.latestTurnCheckpoint?.preTurnSnapshot, undone.latestTurnCheckpoint?.preTurnSnapshot)
        XCTAssertEqual(regenerated.messages.filter { $0.id == userMessage.id }.count, 1)
    }

    func testStorySessionRepositoryUndoRejectsStaleRevisionWithoutChangingCommittedTurn() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let scene = StoryScene(storyWorldId: worldID)
        let session = StorySession(
            storyWorldId: worldID,
            currentSceneId: scene.id,
            storyState: StoryState(location: "初期"),
            persistenceRevision: 2
        )
        try LocalJSONStoreTransaction.save([session], fileName: "story_sessions.json", baseURL: storageURL)
        try LocalJSONStoreTransaction.save([scene], fileName: "story_scenes.json", baseURL: storageURL)
        let repository = LocalJSONStorySessionRepository(storageURL: storageURL)
        let turnID = UUID()
        let pending = try await repository.beginTurn(
            session: session,
            userMessage: StoryMessage(author: .user, text: "開始"),
            turnID: turnID,
            attempt: 1
        )
        let assistant = StoryMessage(author: .narrator, text: "返答", turnID: turnID)
        var generated = pending
        generated.messages.append(assistant)
        let committed = try await repository.commitTurn(
            session: generated,
            scene: scene,
            turnID: turnID,
            assistantMessageIDs: [assistant.id],
            memoryRetries: []
        )
        let before = try LocalJSONStoreTransaction.load(
            StorySession.self,
            fileName: "story_sessions.json",
            baseURL: storageURL
        )

        do {
            _ = try await repository.undoCommittedTurn(
                sessionID: session.id,
                turnID: turnID,
                attempt: 1,
                expectedRevision: committed.effectivePersistenceRevision - 1
            )
            XCTFail("a stale Undo snapshot must be rejected")
        } catch let error as StoryTurnPersistenceError {
            XCTAssertEqual(
                error,
                .revisionConflict(
                    expected: committed.effectivePersistenceRevision - 1,
                    actual: committed.effectivePersistenceRevision
                )
            )
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let after = try LocalJSONStoreTransaction.load(
            StorySession.self,
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        XCTAssertEqual(after, before)
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

    func testStorySceneRepositoryMigratesLegacySceneRevisionOnFirstSave() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let scene = StoryScene(
            storyWorldId: worldID,
            summary: "旧形式のScene"
        )

        // persistenceRevision is intentionally nil here, matching JSON saved
        // before Scene generations were introduced.
        try LocalJSONStoreTransaction.save(
            [scene],
            fileName: "story_scenes.json",
            baseURL: storageURL
        )

        let repository = LocalJSONStorySceneRepository(storageURL: storageURL)
        let loaded = try await repository.fetchScenes(storyWorldId: worldID)
        XCTAssertNil(loaded.first?.persistenceRevision)

        try await repository.saveScene(try XCTUnwrap(loaded.first))

        let persisted = try LocalJSONStoreTransaction.load(
            StoryScene.self,
            fileName: "story_scenes.json",
            baseURL: storageURL
        ).first
        XCTAssertEqual(persisted?.persistenceRevision, 1)
    }

    func testStorySessionRepositoryRejectsCommitAfterWorldMoveAndPreservesMovedWorld() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let originalWorldID = UUID()
        let movedWorldID = UUID()
        let scene = StoryScene(
            id: UUID(),
            storyWorldId: originalWorldID,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let session = StorySession(
            id: UUID(),
            storyWorldId: originalWorldID,
            currentSceneId: scene.id,
            persistenceRevision: 4,
            updatedAt: Date(timeIntervalSince1970: 100)
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
        let turnID = UUID()
        let pending = try await repository.beginTurn(
            session: session,
            userMessage: StoryMessage(author: .user, text: "移動前のターン"),
            turnID: turnID,
            attempt: 1
        )
        try await repository.moveSession(id: session.id, toStoryWorldId: movedWorldID)

        do {
            _ = try await repository.commitTurn(
                session: pending,
                scene: scene,
                turnID: turnID,
                assistantMessageIDs: [],
                memoryRetries: []
            )
            XCTFail("a turn snapshot from before the world move must not commit")
        } catch let error as StoryTurnPersistenceError {
            XCTAssertEqual(
                error,
                .revisionConflict(
                    expected: pending.effectivePersistenceRevision,
                    actual: pending.effectivePersistenceRevision + 1
                )
            )
        }

        try await repository.finishTurn(
            sessionID: session.id,
            turnID: turnID,
            attempt: 1,
            status: .failed,
            failureCode: "world_moved"
        )
        let persisted = try LocalJSONStoreTransaction.load(
            StorySession.self,
            fileName: "story_sessions.json",
            baseURL: storageURL
        ).first
        XCTAssertEqual(persisted?.storyWorldId, movedWorldID)
        XCTAssertEqual(persisted?.persistenceRevision, pending.effectivePersistenceRevision + 2)
        XCTAssertEqual(persisted?.latestTurnCheckpoint?.status, .failed)
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

    func testStorySessionRepositoryRecoveryInterruptsUnregisteredLegacyOwner() async throws {
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
        XCTAssertEqual(persisted?.latestTurnCheckpoint?.status, .interrupted)
        XCTAssertEqual(persisted?.latestTurnCheckpoint?.failureCode, "app_relaunch")
        XCTAssertEqual(persisted?.latestTurnCheckpoint?.ownerID, StoryTurnOwner.currentID)
    }

    func testStorySessionRepositoryRecoversOwnerAfterServiceIsDestroyed() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let staleOwnerID = UUID()
        let checkpoint = StoryTurnReducer.begin(
            turnID: UUID(),
            userMessageID: UUID(),
            attempt: 1,
            ownerID: staleOwnerID,
            baseRevision: 0,
            startedAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let session = StorySession(
            id: UUID(),
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
        try await repository.recoverInterruptedTurns(
            storyWorldId: worldID,
            activeOwnerIDs: []
        )

        let persisted = try LocalJSONStoreTransaction.load(
            StorySession.self,
            fileName: "story_sessions.json",
            baseURL: storageURL
        ).first
        XCTAssertEqual(persisted?.latestTurnCheckpoint?.status, .interrupted)
        XCTAssertEqual(persisted?.latestTurnCheckpoint?.failureCode, "app_relaunch")
    }

    func testStorySessionRepositoryRetriesInterruptedTurnWithoutDuplicatingUserMessage() async throws {
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
        let userMessage = StoryMessage(author: .user, text: "中断後もこの発言を続ける")
        let turnID = UUID()
        _ = try await repository.beginTurn(
            session: session,
            userMessage: userMessage,
            turnID: turnID,
            attempt: 1
        )
        try await repository.recoverInterruptedTurns(
            storyWorldId: worldID,
            activeOwnerIDs: []
        )

        let interrupted = try XCTUnwrap(
            try LocalJSONStoreTransaction.load(
                StorySession.self,
                fileName: "story_sessions.json",
                baseURL: storageURL
            ).first
        )
        XCTAssertEqual(interrupted.latestTurnCheckpoint?.status, .interrupted)

        let retried = try await repository.beginTurn(
            session: interrupted,
            userMessage: userMessage,
            turnID: turnID,
            attempt: 2
        )
        XCTAssertEqual(retried.latestTurnCheckpoint?.status, .pending)
        XCTAssertEqual(retried.latestTurnCheckpoint?.attempt, 2)
        XCTAssertEqual(
            retried.messages.filter { $0.id == userMessage.id }.count,
            1,
            "retrying an interrupted turn must reuse the persisted user message"
        )
    }

    func testStorySessionRepositoryDiscardsInterruptedTurnAndRejectsLateCommit() async throws {
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
        let userMessage = StoryMessage(author: .user, text: "破棄する中断発言")
        let turnID = UUID()
        let pending = try await repository.beginTurn(
            session: session,
            userMessage: userMessage,
            turnID: turnID,
            attempt: 1
        )
        try await repository.recoverInterruptedTurns(
            storyWorldId: worldID,
            activeOwnerIDs: []
        )
        let interrupted = try XCTUnwrap(
            try LocalJSONStoreTransaction.load(
                StorySession.self,
                fileName: "story_sessions.json",
                baseURL: storageURL
            ).first
        )
        do {
            _ = try await repository.discardInterruptedTurn(
                sessionID: session.id,
                turnID: turnID,
                attempt: 1,
                expectedRevision: interrupted.effectivePersistenceRevision - 1
            )
            XCTFail("discard must use the caller's current persistence revision")
        } catch let error as StoryTurnPersistenceError {
            XCTAssertEqual(
                error,
                .revisionConflict(
                    expected: interrupted.effectivePersistenceRevision - 1,
                    actual: interrupted.effectivePersistenceRevision
                )
            )
        }
        let discarded = try await repository.discardInterruptedTurn(
            sessionID: session.id,
            turnID: turnID,
            attempt: 1,
            expectedRevision: interrupted.effectivePersistenceRevision
        )
        XCTAssertNil(discarded.latestTurnCheckpoint)
        XCTAssertFalse(discarded.messages.contains { $0.id == userMessage.id })

        var lateSnapshot = pending
        let assistant = StoryMessage(
            author: .narrator,
            text: "遅れて届いた生成結果",
            turnID: turnID
        )
        lateSnapshot.messages.append(assistant)
        do {
            _ = try await repository.commitTurn(
                session: lateSnapshot,
                scene: scene,
                turnID: turnID,
                assistantMessageIDs: [assistant.id],
                memoryRetries: []
            )
            XCTFail("a discarded interrupted turn must reject a late commit")
        } catch let error as StoryTurnPersistenceError {
            XCTAssertEqual(error, .turnNotPending)
        }

        let persisted = try XCTUnwrap(
            try LocalJSONStoreTransaction.load(
                StorySession.self,
                fileName: "story_sessions.json",
                baseURL: storageURL
            ).first
        )
        XCTAssertNil(persisted.latestTurnCheckpoint)
        XCTAssertFalse(persisted.messages.contains { $0.id == userMessage.id })
        XCTAssertFalse(persisted.messages.contains { $0.id == assistant.id })
    }

    func testStorySessionRepositoryDoesNotDiscardPendingTurn() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let session = StorySession(id: UUID(), storyWorldId: worldID)
        try LocalJSONStoreTransaction.save(
            [session],
            fileName: "story_sessions.json",
            baseURL: storageURL
        )

        let repository = LocalJSONStorySessionRepository(storageURL: storageURL)
        let userMessage = StoryMessage(author: .user, text: "進行中の発言を消さない")
        let turnID = UUID()
        let pending = try await repository.beginTurn(
            session: session,
            userMessage: userMessage,
            turnID: turnID,
            attempt: 1
        )

        do {
            _ = try await repository.discardInterruptedTurn(
                sessionID: session.id,
                turnID: turnID,
                attempt: 1,
                expectedRevision: pending.effectivePersistenceRevision
            )
            XCTFail("a pending turn must not be discarded")
        } catch let error as StoryTurnPersistenceError {
            XCTAssertEqual(error, .turnNotPending)
        }

        let persisted = try XCTUnwrap(
            try LocalJSONStoreTransaction.load(
                StorySession.self,
                fileName: "story_sessions.json",
                baseURL: storageURL
            ).first
        )
        XCTAssertEqual(persisted.latestTurnCheckpoint?.status, .pending)
        XCTAssertTrue(persisted.messages.contains { $0.id == userMessage.id })
    }

    func testStorySessionRepositoryDoesNotInterruptRegisteredOwner() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let liveOwnerID = UUID()
        let checkpoint = StoryTurnReducer.begin(
            turnID: UUID(),
            userMessageID: UUID(),
            attempt: 1,
            ownerID: liveOwnerID,
            baseRevision: 0,
            startedAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let session = StorySession(
            id: UUID(),
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
        try await repository.recoverInterruptedTurns(
            storyWorldId: worldID,
            activeOwnerIDs: [liveOwnerID]
        )

        let persisted = try LocalJSONStoreTransaction.load(
            StorySession.self,
            fileName: "story_sessions.json",
            baseURL: storageURL
        ).first
        XCTAssertEqual(persisted?.latestTurnCheckpoint?.status, .pending)
        XCTAssertEqual(persisted?.latestTurnCheckpoint?.ownerID, liveOwnerID)
    }

    func testStoryTurnOwnerRegistryTracksLiveServiceOwnersIndependently() {
        let first = StoryTurnOwnerRegistry.shared.register()
        let second = StoryTurnOwnerRegistry.shared.register()
        defer {
            StoryTurnOwnerRegistry.shared.unregister(first)
            StoryTurnOwnerRegistry.shared.unregister(second)
        }

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(StoryTurnOwnerRegistry.shared.activeOwnerIDs().isSuperset(of: [first, second]))
        StoryTurnOwnerRegistry.shared.unregister(first)
        XCTAssertFalse(StoryTurnOwnerRegistry.shared.activeOwnerIDs().contains(first))
        XCTAssertTrue(StoryTurnOwnerRegistry.shared.activeOwnerIDs().contains(second))
    }

    func testStorySessionServiceOwnerCanBeReleasedBeforeReplacementServiceStarts() {
        let registry = StoryTurnOwnerRegistry.shared
        let ownersBefore = registry.activeOwnerIDs()
        var first: StorySessionService? = StorySessionService()
        let firstOwners = registry.activeOwnerIDs().subtracting(ownersBefore)
        XCTAssertEqual(firstOwners.count, 1)
        guard let firstOwner = firstOwners.first else {
            return XCTFail("the first StorySessionService must register one owner")
        }

        first?.releaseOwnerForTeardown()
        first = nil
        XCTAssertFalse(registry.activeOwnerIDs().contains(firstOwner))

        var replacement: StorySessionService? = StorySessionService()
        let replacementOwners = registry.activeOwnerIDs().subtracting(ownersBefore)
        XCTAssertEqual(replacementOwners.count, 1)
        guard let replacementOwner = replacementOwners.first else {
            return XCTFail("the replacement StorySessionService must register one owner")
        }
        XCTAssertNotEqual(firstOwner, replacementOwner)

        replacement?.releaseOwnerForTeardown()
        replacement = nil
        XCTAssertEqual(registry.activeOwnerIDs(), ownersBefore)
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

    func testStorySessionRepositoryCommitKeepsSceneCatalogValues() async throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let sceneID = UUID()
        let sessionID = UUID()
        let turnID = UUID()
        let date = Date(timeIntervalSince1970: 100)
        let checkpoint = StoryTurnReducer.begin(
            turnID: turnID,
            userMessageID: UUID(),
            attempt: 1,
            ownerID: StoryTurnOwner.currentID,
            baseRevision: 1,
            startedAt: date,
            updatedAt: date
        )
        let session = StorySession(
            id: sessionID,
            storyWorldId: worldID,
            currentSceneId: sceneID,
            activeCharacterIds: [UUID()],
            lastSceneSummary: "runtimeで更新された要約",
            storyState: StoryState(
                location: "駅前",
                timeOfDay: "深夜",
                mood: "緊張"
            ),
            persistenceRevision: 1,
            latestTurnCheckpoint: checkpoint,
            updatedAt: date
        )
        let scene = StoryScene(
            id: sceneID,
            storyWorldId: worldID,
            location: "港",
            timeOfDay: "夕方",
            mood: "静か",
            activeCharacterIds: [UUID()],
            summary: "初期Sceneの説明",
            updatedAt: date
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

        _ = try await LocalJSONStorySessionRepository(storageURL: storageURL).commitTurn(
            session: session,
            scene: scene,
            turnID: turnID,
            assistantMessageIDs: [],
            memoryRetries: []
        )

        let persistedScene = try LocalJSONStoreTransaction.load(
            StoryScene.self,
            fileName: "story_scenes.json",
            baseURL: storageURL
        ).first
        XCTAssertEqual(persistedScene?.location, "港")
        XCTAssertEqual(persistedScene?.timeOfDay, "夕方")
        XCTAssertEqual(persistedScene?.mood, "静か")
        XCTAssertEqual(persistedScene?.summary, "初期Sceneの説明")
        XCTAssertEqual(persistedScene?.activeCharacterIds ?? [], scene.activeCharacterIds)
        XCTAssertEqual(persistedScene?.updatedAt, date)
        let persistedSession = try LocalJSONStoreTransaction.load(
            StorySession.self,
            fileName: "story_sessions.json",
            baseURL: storageURL
        ).first
        XCTAssertEqual(persistedSession?.lastSceneSummary ?? "", "runtimeで更新された要約")
        XCTAssertEqual(persistedSession?.activeCharacterIds, session.activeCharacterIds)
    }

    func testStoryTurnJournalUsesSceneRevisionWhenDatesShareAnISOSecond() throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let sceneID = UUID()
        let turnID = UUID()
        let baseDate = Date(timeIntervalSince1970: 100.1)
        let laterSameSecond = Date(timeIntervalSince1970: 100.9)
        let checkpoint = StoryTurnReducer.commit(
            pending: StoryTurnReducer.begin(
                turnID: turnID,
                userMessageID: UUID(),
                attempt: 1,
                ownerID: nil,
                baseRevision: 1,
                startedAt: baseDate,
                updatedAt: baseDate
            ),
            assistantMessageIDs: [],
            updatedAt: laterSameSecond
        )
        let session = StorySession(
            id: UUID(),
            storyWorldId: worldID,
            currentSceneId: sceneID,
            persistenceRevision: 1,
            latestTurnCheckpoint: checkpoint,
            updatedAt: baseDate
        )
        let persistedScene = StoryScene(
            id: sceneID,
            storyWorldId: worldID,
            summary: "old scene",
            persistenceRevision: 4,
            updatedAt: baseDate
        )
        var journalScene = persistedScene
        journalScene.summary = "recovered scene"
        journalScene.persistenceRevision = 5
        journalScene.updatedAt = laterSameSecond

        // Exercise the legacy ISO8601 representation explicitly. New writes
        // preserve sub-second precision, so two distinct numeric timestamps
        // would no longer represent the old same-second collision.
        let legacyEncoder = JSONEncoder()
        legacyEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        legacyEncoder.dateEncodingStrategy = .iso8601
        let legacySessionData = try legacyEncoder.encode([session])
        try legacySessionData.write(
            to: storageURL.appendingPathComponent("story_sessions.json"),
            options: [.atomic]
        )
        let legacySceneData = try legacyEncoder.encode([persistedScene])
        try legacySceneData.write(
            to: storageURL.appendingPathComponent("story_scenes.json"),
            options: [.atomic]
        )
        let legacyJournalData = try legacyEncoder.encode([
            StoryTurnJournalEntry(turnID: turnID, session: session, scene: journalScene)
        ])
        try legacyJournalData.write(
            to: storageURL.appendingPathComponent("story_turn_journal.json"),
            options: [.atomic]
        )

        let storedScene = try LocalJSONStoreTransaction.load(
            StoryScene.self,
            fileName: "story_scenes.json",
            baseURL: storageURL
        ).first
        let storedJournalScene = try LocalJSONStoreTransaction.load(
            StoryTurnJournalEntry.self,
            fileName: "story_turn_journal.json",
            baseURL: storageURL
        ).first?.scene
        // The legacy ISO8601 encoder drops sub-second precision, so both
        // records intentionally decode to the same second. Revision, not the
        // rounded timestamp, is what proves that the journal scene wins.
        XCTAssertEqual(storedScene?.updatedAt, storedJournalScene?.updatedAt)
        XCTAssertEqual(storedScene?.persistenceRevision, 4)
        XCTAssertEqual(storedJournalScene?.persistenceRevision, 5)

        try StoryTurnJournal.recoverIfNeeded(baseURL: storageURL)

        let recoveredScene = try LocalJSONStoreTransaction.load(
            StoryScene.self,
            fileName: "story_scenes.json",
            baseURL: storageURL
        ).first
        XCTAssertEqual(recoveredScene?.summary, "recovered scene")
        XCTAssertEqual(recoveredScene?.persistenceRevision, 5)
    }

    func testStoryTurnJournalDoesNotOverwriteNewerSceneWithOlderJournalSameSecond() throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let sceneID = UUID()
        let turnID = UUID()
        let date = Date(timeIntervalSince1970: 200.25)
        let checkpoint = StoryTurnReducer.commit(
            pending: StoryTurnReducer.begin(
                turnID: turnID,
                userMessageID: UUID(),
                attempt: 1,
                ownerID: nil,
                baseRevision: 4,
                startedAt: date,
                updatedAt: date
            ),
            assistantMessageIDs: [],
            updatedAt: date
        )
        let session = StorySession(
            id: UUID(),
            storyWorldId: worldID,
            currentSceneId: sceneID,
            persistenceRevision: 5,
            latestTurnCheckpoint: checkpoint,
            updatedAt: date
        )
        let persistedScene = StoryScene(
            id: sceneID,
            storyWorldId: worldID,
            summary: "新しいScene",
            persistenceRevision: 5,
            updatedAt: date
        )
        var olderJournalScene = persistedScene
        olderJournalScene.summary = "古いjournal"
        olderJournalScene.persistenceRevision = 4

        try LocalJSONStoreTransaction.save(
            [session],
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
                session: session,
                scene: olderJournalScene
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
        XCTAssertEqual(recoveredScene?.summary, "新しいScene")
        XCTAssertEqual(recoveredScene?.persistenceRevision, 5)
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

    func testStoryTurnJournalTombstoneRecoveryRemovesDeletedSessionMemories() throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let deletedSessionID = UUID()
        let remainingSessionID = UUID()
        try LocalJSONStoreTransaction.save(
            [
                StorySession(id: deletedSessionID, storyWorldId: worldID),
                StorySession(id: remainingSessionID, storyWorldId: worldID)
            ],
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        let deletedMemory = StoryMemory(
            storyWorldId: worldID,
            text: "tombstoneで削除する記憶",
            storySessionId: deletedSessionID
        )
        let remainingMemory = StoryMemory(
            storyWorldId: worldID,
            text: "残す記憶",
            storySessionId: remainingSessionID
        )
        try LocalJSONStoreTransaction.save(
            [deletedMemory, remainingMemory],
            fileName: "story_memories.json",
            baseURL: storageURL
        )

        try LocalJSONStoreTransaction.withSharedLock {
            try StoryTurnJournal.recordDeletionUnlocked(
                recordID: deletedSessionID,
                recordKind: .session,
                baseURL: storageURL
            )
        }
        try StoryTurnJournal.recoverIfNeeded(baseURL: storageURL)

        let memories = try LocalJSONStoreTransaction.load(
            StoryMemory.self,
            fileName: "story_memories.json",
            baseURL: storageURL
        )
        XCTAssertEqual(memories.map(\.id), [remainingMemory.id])
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

    func testStoryTurnJournalUsesSceneRevisionWithNativeDates() throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let worldID = UUID()
        let sceneID = UUID()
        let turnID = UUID()
        let baseDate = Date(timeIntervalSince1970: 100.1)
        let laterSameSecond = Date(timeIntervalSince1970: 100.9)
        let checkpoint = StoryTurnReducer.commit(
            pending: StoryTurnReducer.begin(
                turnID: turnID,
                userMessageID: UUID(),
                attempt: 1,
                ownerID: nil,
                baseRevision: 1,
                startedAt: baseDate,
                updatedAt: baseDate
            ),
            assistantMessageIDs: [],
            updatedAt: laterSameSecond
        )
        let session = StorySession(
            id: UUID(),
            storyWorldId: worldID,
            currentSceneId: sceneID,
            persistenceRevision: 1,
            latestTurnCheckpoint: checkpoint,
            updatedAt: baseDate
        )
        let persistedScene = StoryScene(
            id: sceneID,
            storyWorldId: worldID,
            summary: "old scene",
            persistenceRevision: 4,
            updatedAt: baseDate
        )
        var journalScene = persistedScene
        journalScene.summary = "recovered scene"
        journalScene.persistenceRevision = 5
        journalScene.updatedAt = laterSameSecond

        try LocalJSONStoreTransaction.save(
            [session],
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [persistedScene],
            fileName: "story_scenes.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [StoryTurnJournalEntry(turnID: turnID, session: session, scene: journalScene)],
            fileName: "story_turn_journal.json",
            baseURL: storageURL
        )

        let storedScene = try LocalJSONStoreTransaction.load(
            StoryScene.self,
            fileName: "story_scenes.json",
            baseURL: storageURL
        ).first
        let storedJournalScene = try LocalJSONStoreTransaction.load(
            StoryTurnJournalEntry.self,
            fileName: "story_turn_journal.json",
            baseURL: storageURL
        ).first?.scene
        // Native LocalJSONStore dates preserve sub-second precision. This is
        // the complementary case to the legacy ISO8601 fixture above.
        XCTAssertEqual(storedScene?.updatedAt, baseDate)
        XCTAssertEqual(storedJournalScene?.updatedAt, laterSameSecond)
        XCTAssertEqual(storedScene?.persistenceRevision, 4)
        XCTAssertEqual(storedJournalScene?.persistenceRevision, 5)

        try StoryTurnJournal.recoverIfNeeded(baseURL: storageURL)

        let recoveredScene = try LocalJSONStoreTransaction.load(
            StoryScene.self,
            fileName: "story_scenes.json",
            baseURL: storageURL
        ).first
        XCTAssertEqual(recoveredScene?.summary, "recovered scene")
        XCTAssertEqual(recoveredScene?.persistenceRevision, 5)
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
        let rawObject = try JSONSerialization.jsonObject(
            with: encoder.encode([validEntry]),
            options: [.fragmentsAllowed]
        )
        guard var rawItems = rawObject as? [Any] else {
            return XCTFail("encoded journal must be a JSON array")
        }
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

    func testStoryTurnJournalUsesPairOrderingMatrix() throws {
        enum Ordering: Equatable {
            case older
            case equal
            case newer
        }

        let cases: [(name: String, session: Ordering, scene: Ordering, retains: Bool)] = [
            ("older/older", .older, .older, false),
            ("older/equal", .older, .equal, false),
            ("older/newer", .older, .newer, true),
            ("equal/older", .equal, .older, false),
            ("equal/equal", .equal, .equal, false),
            ("equal/newer", .equal, .newer, false),
            ("newer/older", .newer, .older, true),
            ("newer/equal", .newer, .equal, false),
            ("newer/newer", .newer, .newer, false)
        ]

        func persistedSession(
            from journal: StorySession,
            ordering: Ordering
        ) -> StorySession {
            var value = journal
            switch ordering {
            case .older:
                value.persistenceRevision = journal.effectivePersistenceRevision + 1
                value.updatedAt = journal.updatedAt.addingTimeInterval(1)
            case .equal:
                break
            case .newer:
                value.persistenceRevision = journal.effectivePersistenceRevision - 1
                value.updatedAt = journal.updatedAt.addingTimeInterval(-1)
            }
            return value
        }

        func persistedScene(
            from journal: StoryScene,
            ordering: Ordering
        ) -> StoryScene {
            var value = journal
            switch ordering {
            case .older:
                value.persistenceRevision = journal.effectivePersistenceRevision + 1
                value.updatedAt = journal.updatedAt.addingTimeInterval(1)
            case .equal:
                break
            case .newer:
                value.persistenceRevision = journal.effectivePersistenceRevision - 1
                value.updatedAt = journal.updatedAt.addingTimeInterval(-1)
            }
            return value
        }

        for testCase in cases {
            let storageURL = try makeStoryPersistenceTestDirectory()
            let fixture = makeCommittedJournalFixture()
            let session = persistedSession(
                from: fixture.entry.session,
                ordering: testCase.session
            )
            let scene = persistedScene(
                from: fixture.entry.scene,
                ordering: testCase.scene
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
                [fixture.entry],
                fileName: "story_turn_journal.json",
                baseURL: storageURL
            )

            try StoryTurnJournal.recoverIfNeeded(baseURL: storageURL)

            let recoveredSession = try XCTUnwrap(
                LocalJSONStoreTransaction.load(
                    StorySession.self,
                    fileName: "story_sessions.json",
                    baseURL: storageURL
                ).first
            )
            let recoveredScene = try XCTUnwrap(
                LocalJSONStoreTransaction.load(
                    StoryScene.self,
                    fileName: "story_scenes.json",
                    baseURL: storageURL
                ).first
            )
            // A mixed newer/older pair is intentionally retained as a unit;
            // neither side may be applied until the pair can be resolved.
            let expectedSession = testCase.retains
                ? session
                : (testCase.session == .newer ? fixture.entry.session : session)
            let expectedScene = testCase.retains
                ? scene
                : (testCase.scene == .newer ? fixture.entry.scene : scene)
            XCTAssertEqual(recoveredSession, expectedSession, testCase.name)
            XCTAssertEqual(recoveredScene, expectedScene, testCase.name)

            let remainingEntries = try LocalJSONStoreTransaction.load(
                StoryTurnJournalEntry.self,
                fileName: "story_turn_journal.json",
                baseURL: storageURL
            )
            if testCase.retains {
                XCTAssertEqual(remainingEntries, [fixture.entry], testCase.name)
            } else {
                XCTAssertTrue(remainingEntries.isEmpty, testCase.name)
            }
        }
    }

    func testStoryTurnJournalRetainsEqualMetadataWithDifferentPayload() throws {
        enum AmbiguousRecord {
            case session
            case scene
        }

        for record in [AmbiguousRecord.session, .scene] {
            let storageURL = try makeStoryPersistenceTestDirectory()
            let fixture = makeCommittedJournalFixture()
            var session = fixture.entry.session
            var scene = fixture.entry.scene
            switch record {
            case .session:
                session.lastTurnProgress = "同じrevisionだが異なるSession payload"
            case .scene:
                scene.summary = "同じrevisionだが異なるScene payload"
            }
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
                [fixture.entry],
                fileName: "story_turn_journal.json",
                baseURL: storageURL
            )

            try StoryTurnJournal.recoverIfNeeded(baseURL: storageURL)
            XCTAssertEqual(
                try LocalJSONStoreTransaction.load(
                    StoryTurnJournalEntry.self,
                    fileName: "story_turn_journal.json",
                    baseURL: storageURL
                ),
                [fixture.entry]
            )
            XCTAssertEqual(
                try LocalJSONStoreTransaction.load(
                    StorySession.self,
                    fileName: "story_sessions.json",
                    baseURL: storageURL
                ).first,
                session
            )
            XCTAssertEqual(
                try LocalJSONStoreTransaction.load(
                    StoryScene.self,
                    fileName: "story_scenes.json",
                    baseURL: storageURL
                ).first,
                scene
            )

            try StoryTurnJournal.recoverIfNeeded(baseURL: storageURL)
            XCTAssertEqual(
                try LocalJSONStoreTransaction.load(
                    StoryTurnJournalEntry.self,
                    fileName: "story_turn_journal.json",
                    baseURL: storageURL
                ),
                [fixture.entry],
                "an ambiguous pair must remain recoverable after repeated recovery"
            )
        }
    }

    func testStoryTurnJournalDoesNotHandoffRetriesForRetainedPair() throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let fixture = makeCommittedJournalFixture()
        var newerPersistedScene = fixture.entry.scene
        newerPersistedScene.persistenceRevision = fixture.entry.scene.effectivePersistenceRevision + 1
        newerPersistedScene.updatedAt = fixture.entry.scene.updatedAt.addingTimeInterval(1)
        let retry = StoryMemoryRetry(
            turnID: fixture.entry.turnID,
            userMessageID: try XCTUnwrap(
                fixture.entry.session.latestTurnCheckpoint?.userMessageID
            ),
            userText: "pair conflict retry",
            characterMemories: [],
            storyMemories: [],
            storySessionID: fixture.entry.session.id,
            storyWorldID: fixture.entry.session.storyWorldId
        )
        let entry = StoryTurnJournalEntry(
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
            [newerPersistedScene],
            fileName: "story_scenes.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [entry],
            fileName: "story_turn_journal.json",
            baseURL: storageURL
        )

        try StoryTurnJournal.recoverIfNeeded(baseURL: storageURL)

        XCTAssertEqual(
            try LocalJSONStoreTransaction.load(
                StoryTurnJournalEntry.self,
                fileName: "story_turn_journal.json",
                baseURL: storageURL
            ),
            [entry]
        )
        XCTAssertTrue(
            try LocalJSONStoreTransaction.load(
                StoryMemoryRetry.self,
                fileName: "story_memory_retries.json",
                baseURL: storageURL
            ).isEmpty,
            "a retained pair must not hand off memory retries before pair resolution"
        )
    }

    func testStoryTurnJournalHandsOffRetriesForStalePair() throws {
        let storageURL = try makeStoryPersistenceTestDirectory()
        let fixture = makeCommittedJournalFixture()
        var laterSession = fixture.entry.session
        laterSession.persistenceRevision = fixture.entry.session.effectivePersistenceRevision + 1
        laterSession.updatedAt = fixture.entry.session.updatedAt.addingTimeInterval(1)
        var laterScene = fixture.entry.scene
        laterScene.persistenceRevision = fixture.entry.scene.effectivePersistenceRevision + 1
        laterScene.updatedAt = fixture.entry.scene.updatedAt.addingTimeInterval(1)
        let retry = StoryMemoryRetry(
            turnID: fixture.entry.turnID,
            userMessageID: try XCTUnwrap(
                fixture.entry.session.latestTurnCheckpoint?.userMessageID
            ),
            userText: "stale pair memory retry",
            characterMemories: [],
            storyMemories: [],
            storySessionID: fixture.entry.session.id,
            storyWorldID: fixture.entry.session.storyWorldId
        )
        let entry = StoryTurnJournalEntry(
            turnID: fixture.entry.turnID,
            session: fixture.entry.session,
            scene: fixture.entry.scene,
            memoryRetries: [retry]
        )

        try LocalJSONStoreTransaction.save(
            [laterSession],
            fileName: "story_sessions.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [laterScene],
            fileName: "story_scenes.json",
            baseURL: storageURL
        )
        try LocalJSONStoreTransaction.save(
            [entry],
            fileName: "story_turn_journal.json",
            baseURL: storageURL
        )

        try StoryTurnJournal.recoverIfNeeded(baseURL: storageURL)

        XCTAssertTrue(
            try LocalJSONStoreTransaction.load(
                StoryTurnJournalEntry.self,
                fileName: "story_turn_journal.json",
                baseURL: storageURL
            ).isEmpty,
            "a stale pair must be consumed after its memory retry is handed off"
        )
        XCTAssertEqual(
            try LocalJSONStoreTransaction.load(
                StoryMemoryRetry.self,
                fileName: "story_memory_retries.json",
                baseURL: storageURL
            ),
            [retry]
        )

        try StoryTurnJournal.recoverIfNeeded(baseURL: storageURL)
        XCTAssertEqual(
            try LocalJSONStoreTransaction.load(
                StoryMemoryRetry.self,
                fileName: "story_memory_retries.json",
                baseURL: storageURL
            ),
            [retry],
            "recovery must not duplicate an already handed-off retry"
        )
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
        XCTAssertFalse(store.appendMessage(
            PersonaMessage(role: .assistant, text: "hello"),
            toThread: UUID()
        ))

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
        XCTAssertThrowsError(try store.exportPersistedThreadsJSON())
        XCTAssertThrowsError(try store.exportPersistedThreadsText())
        XCTAssertFalse(store.deleteAllThreads())

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
    func testPersonaStoreExportsRawJSONAndHumanReadableHistory() throws {
        let suiteName = "KizunaAITests.PersonaExport.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let profileID = UUID()
        let characterID = UUID()
        let threadID = UUID()
        let messageID = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let profile = PersonaProfile(
            id: profileID,
            name: "保存テスト",
            age: 24,
            personality: "落ち着いている",
            tone: .casual,
            relation: .friend,
            freeFormAddendum: "港の近くで暮らしている"
        )
        let thread = PersonaThread(
            id: threadID,
            personaSnapshot: profile,
            characterID: characterID,
            title: "港での会話",
            messages: [
                PersonaMessage(
                    id: messageID,
                    role: .user,
                    text: "この記録を残して",
                    createdAt: date
                )
            ],
            createdAt: date,
            updatedAt: date
        )
        defaults.set(try JSONEncoder().encode([thread]), forKey: "persona.threads.v1")

        let store = PersonaChatStore(defaults: defaults)
        XCTAssertFalse(store.isPersistenceRecoveryRequired)

        let rawURL = try store.exportRawPersistedThreads()
        defer { try? FileManager.default.removeItem(at: rawURL) }
        XCTAssertEqual(try Data(contentsOf: rawURL), defaults.data(forKey: "persona.threads.v1"))
        XCTAssertTrue(rawURL.path.contains("Kizuna-Persona-Exports"))

        let jsonURL = try store.exportPersistedThreadsJSON()
        defer { try? FileManager.default.removeItem(at: jsonURL) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: rawURL.path))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(
            PersonaThreadExportDocument.self,
            from: Data(contentsOf: jsonURL)
        )
        XCTAssertEqual(document.schemaVersion, PersonaThreadExportDocument.currentSchemaVersion)
        XCTAssertFalse(document.appVersion.isEmpty)
        XCTAssertEqual(document.threads.count, 1)
        XCTAssertEqual(document.threads.first?.id, threadID)
        XCTAssertEqual(document.threads.first?.characterID, characterID)
        XCTAssertEqual(document.threads.first?.messages.first?.id, messageID)
        XCTAssertEqual(document.threads.first?.messages.first?.role, .user)
        XCTAssertEqual(document.threads.first?.messages.first?.text, "この記録を残して")
        XCTAssertEqual(document.threads.first?.messages.first?.createdAt, date)

        let textURL = try store.exportPersistedThreadsText()
        defer { try? FileManager.default.removeItem(at: textURL) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: rawURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonURL.path))
        let readableText = try String(contentsOf: textURL, encoding: .utf8)
        XCTAssertTrue(readableText.contains(threadID.uuidString))
        XCTAssertTrue(readableText.contains(characterID.uuidString))
        XCTAssertTrue(readableText.contains("role: user"))
        XCTAssertTrue(readableText.contains("この記録を残して"))
        XCTAssertTrue(readableText.contains("personaSnapshot.name: 保存テスト"))
    }

    func testPersonaExportShareItemOwnsBytesAfterSourceFileIsRemoved() throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Kizuna-Persona-ShareItem-\(UUID().uuidString).json")
        let expectedData = Data("{\"shared\":true}".utf8)
        try expectedData.write(to: sourceURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let shareItem = try KizunaPersonaExportShareItem(fileURL: sourceURL)
        try FileManager.default.removeItem(at: sourceURL)

        XCTAssertEqual(shareItem.data, expectedData)
        XCTAssertEqual(shareItem.fileName, sourceURL.lastPathComponent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func testPersonaStoreInitializationRetriesOrphanedExportCleanup() throws {
        let directoryURL = KizunaPersonaExportFileLifecycle.directoryURL
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let orphanURL = directoryURL
            .appendingPathComponent("orphan-\(UUID().uuidString).json")
        try Data("orphan".utf8).write(to: orphanURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: orphanURL) }

        let suiteName = "KizunaAITests.PersonaExportCleanup.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        _ = PersonaChatStore(defaults: defaults)

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
    }

    @MainActor
    func testPersonaStoreDeletesAllValidHistoryAndKeepsAnEmptyPersistedState() throws {
        let suiteName = "KizunaAITests.PersonaDeleteAll.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PersonaChatStore(defaults: defaults)
        let profile = PersonaProfile(
            name: "削除テスト",
            personality: "calm",
            tone: .calm,
            relation: .friend
        )
        guard let thread = store.createThread(with: profile) else {
            return XCTFail("valid persistence should allow thread creation")
        }
        XCTAssertTrue(store.appendMessage(
            PersonaMessage(role: .user, text: "delete me"),
            toThread: thread.id
        ))

        XCTAssertTrue(store.deleteAllThreads())
        XCTAssertTrue(store.threads.isEmpty)
        XCTAssertNil(store.activeThreadID)
        XCTAssertFalse(store.isPersistenceRecoveryRequired)
        XCTAssertEqual(
            defaults.data(forKey: "persona.threads.v1"),
            try JSONEncoder().encode([PersonaThread]())
        )
        XCTAssertNil(defaults.object(forKey: "persona.activeThreadID.v1"))
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

    func testPersonaUnfinishedAssistantIsNotPersistedBeforeFinalization() throws {
        let suiteName = "KizunaPersonaStoreTests.UnfinishedAssistant.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let profile = PersonaProfile(
            name: "Test",
            personality: "Calm",
            tone: .calm,
            relation: .friend
        )
        let thread = try XCTUnwrap(
            PersonaChatStore(defaults: defaults).createThread(with: profile)
        )
        let userMessage = PersonaMessage(role: .user, text: "hello")
        let generationID = UUID()
        let store = PersonaChatStore(defaults: defaults)
        store.appendMessage(userMessage, toThread: thread.id)

        let afterInterruptedGeneration = PersonaChatStore(defaults: defaults)
        XCTAssertEqual(
            afterInterruptedGeneration.thread(id: thread.id)?.messages.map(\.role),
            [.user]
        )
        XCTAssertEqual(
            afterInterruptedGeneration.appendFinalizedAssistantMessage(
                in: thread.id,
                messageID: generationID,
                text: "completed"
            ),
            .inserted
        )
        XCTAssertEqual(
            afterInterruptedGeneration.appendFinalizedAssistantMessage(
                in: thread.id,
                messageID: generationID,
                text: "duplicate"
            ),
            .rejected
        )
        XCTAssertEqual(
            afterInterruptedGeneration.appendFinalizedAssistantMessage(
                in: thread.id,
                messageID: generationID,
                text: "completed"
            ),
            .alreadyPresent
        )
        let reloaded = PersonaChatStore(defaults: defaults)
        XCTAssertEqual(
            reloaded.thread(id: thread.id)?.messages.map(\.text),
            ["hello", "completed"]
        )
    }

    func testPersonaCancellationRemovesMeaningfulUnscreenedPartial() throws {
        let suiteName = "KizunaPersonaStoreTests.PartialCancellation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let profile = PersonaProfile(
            name: "Test",
            personality: "Calm",
            tone: .calm,
            relation: .friend
        )
        let threadID = UUID()
        let thread = PersonaThread(
            id: threadID,
            personaSnapshot: profile,
            title: "Partial",
            messages: [
                PersonaMessage(role: .user, text: "first"),
                PersonaMessage(role: .assistant, text: "completed response"),
                PersonaMessage(role: .user, text: "second"),
                PersonaMessage(role: .assistant, text: "unscreened partial response")
            ]
        )
        defaults.set(
            try JSONEncoder().encode([thread]),
            forKey: "persona.threads.v1"
        )

        let store = PersonaChatStore(defaults: defaults)
        store.removeLastAssistantMessage(in: threadID)

        XCTAssertEqual(
            store.thread(id: threadID)?.messages.map(\.text),
            ["first", "completed response", "second"]
        )
        let reloaded = PersonaChatStore(defaults: defaults)
        XCTAssertEqual(
            reloaded.thread(id: threadID)?.messages.map(\.text),
            ["first", "completed response", "second"]
        )
    }

    func testPersonaActiveAssistantRemovalDoesNotDeleteCompletedResponse() throws {
        let suiteName = "KizunaPersonaStoreTests.IdentityCleanup.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let profile = PersonaProfile(
            name: "Test",
            personality: "Calm",
            tone: .calm,
            relation: .friend
        )
        let threadID = UUID()
        let completedID = UUID()
        let thread = PersonaThread(
            id: threadID,
            personaSnapshot: profile,
            title: "Completed",
            messages: [
                PersonaMessage(role: .user, text: "first"),
                PersonaMessage(
                    id: completedID,
                    role: .assistant,
                    text: "completed response"
                )
            ]
        )
        defaults.set(
            try JSONEncoder().encode([thread]),
            forKey: "persona.threads.v1"
        )

        let store = PersonaChatStore(defaults: defaults)
        XCTAssertFalse(
            store.removeAssistantMessage(in: threadID, messageID: UUID())
        )
        XCTAssertEqual(
            store.thread(id: threadID)?.messages.map(\.text),
            ["first", "completed response"]
        )
    }

    func testPersonaOutputSafetyPolicyNeverFallsBackToUnsafeText() {
        XCTAssertNil(PersonaOutputSafetyPolicy.completedText(from: nil))
        XCTAssertNil(PersonaOutputSafetyPolicy.completedText(from: "   "))
        XCTAssertNil(PersonaOutputSafetyPolicy.completedText(from: "…"))
        XCTAssertEqual(
            PersonaOutputSafetyPolicy.completedText(from: "<think>private</think>reply"),
            "reply"
        )
        XCTAssertNil(
            PersonaOutputSafetyPolicy.persistableText(
                action: .requireEdit,
                original: "unsafe original",
                rewritten: nil
            )
        )
        XCTAssertNil(
            PersonaOutputSafetyPolicy.persistableText(
                action: .requireEdit,
                original: "unsafe original",
                rewritten: "safe-looking rewrite"
            )
        )
        XCTAssertNil(
            PersonaOutputSafetyPolicy.persistableText(
                action: .soften,
                original: "unsafe original",
                rewritten: "  \n"
            )
        )
        XCTAssertEqual(
            PersonaOutputSafetyPolicy.persistableText(
                action: .soften,
                original: "unsafe original",
                rewritten: "  safe rewrite  \n"
            ),
            "safe rewrite"
        )
        XCTAssertEqual(
            PersonaOutputSafetyPolicy.sanitizedRewrite("<think>private</think>  safe rewrite  "),
            "safe rewrite"
        )
        XCTAssertTrue(PersonaMessage.isPendingAssistantText("  …  "))
        XCTAssertTrue(PersonaMessage.isPendingAssistantText("..."))
        XCTAssertTrue(PersonaMessage.isPendingAssistantText(" \n"))
        XCTAssertFalse(PersonaMessage.isPendingAssistantText("completed"))
        XCTAssertEqual(
            PersonaOutputSafetyPolicy.persistableText(
                action: .warn,
                original: "allowed with warning",
                rewritten: nil
            ),
            "allowed with warning"
        )
    }

    func testStoryOutputSafetyPolicyNeverFallsBackToBlockedText() {
        XCTAssertNil(
            StoryOutputSafetyPolicy.persistableText(
                action: .requireEdit,
                original: "unsafe original",
                rewritten: nil
            )
        )
        XCTAssertNil(
            StoryOutputSafetyPolicy.persistableText(
                action: .requireEdit,
                original: "unsafe original",
                rewritten: "apparently safe rewrite"
            )
        )
        XCTAssertNil(
            StoryOutputSafetyPolicy.persistableText(
                action: .soften,
                original: "unsafe original",
                rewritten: nil
            )
        )
        XCTAssertNil(
            StoryOutputSafetyPolicy.persistableText(
                action: .soften,
                original: "unsafe original",
                rewritten: ""
            )
        )
        XCTAssertNil(
            StoryOutputSafetyPolicy.persistableText(
                action: .soften,
                original: "unsafe original",
                rewritten: "   "
            )
        )
        XCTAssertEqual(
            StoryOutputSafetyPolicy.persistableText(
                action: .soften,
                original: "unsafe original",
                rewritten: "safe rewrite"
            ),
            "safe rewrite"
        )
        XCTAssertEqual(
            StoryOutputSafetyPolicy.persistableText(
                action: .warn,
                original: "allowed with warning",
                rewritten: nil
            ),
            "allowed with warning"
        )
    }

    func testStoryOutputSafetyPolicyDropsStatePatchWhenTextIsRewritten() {
        let original = StoryStatePatch(
            location: "unsafe original location",
            mood: "tense"
        )

        XCTAssertNil(
            StoryOutputSafetyPolicy.persistableStatePatch(
                action: .soften,
                original: original
            )
        )
        XCTAssertEqual(
            StoryOutputSafetyPolicy.persistableStatePatch(
                action: .allow,
                original: original
            ),
            original
        )
        XCTAssertNil(
            StoryOutputSafetyPolicy.persistableStatePatch(
                action: .requireEdit,
                original: original
            )
        )
    }

    func testStoryStatePatchSafetyPayloadIncludesNestedState() throws {
        let patch = StoryStatePatch(
            location: "山奥の倉庫",
            characterUpdates: [
                StoryCharacterStatePatch(
                    characterName: "ナギ",
                    innerThought: "秘密の計画を隠している"
                )
            ],
            inventoryChanges: [
                StoryInventoryChange(
                    action: .add,
                    name: "封印された箱",
                    detail: "開けると危険な手順が書かれている",
                    owner: "ナギ"
                )
            ],
            activeGoals: ["倉庫から脱出する"]
        )

        let safetyText = try XCTUnwrap(patch.safetyEvaluationText())
        XCTAssertTrue(safetyText.hasPrefix("STATE_UPDATE: {"))
        XCTAssertTrue(safetyText.contains("山奥の倉庫"))
        XCTAssertTrue(safetyText.contains("秘密の計画を隠している"))
        XCTAssertTrue(safetyText.contains("危険な手順が書かれている"))
        XCTAssertTrue(safetyText.contains("倉庫から脱出する"))
    }

    func testStoryOutputSafetyPolicyKeepsStatePatchForAllowAndWarn() {
        let original = StoryStatePatch(
            location: "harbor",
            mood: "calm"
        )

        XCTAssertEqual(
            StoryOutputSafetyPolicy.persistableStatePatch(
                action: .allow,
                original: original
            ),
            original
        )
        XCTAssertEqual(
            StoryOutputSafetyPolicy.persistableStatePatch(
                action: .warn,
                original: original
            ),
            original
        )
        XCTAssertNil(
            StoryOutputSafetyPolicy.persistableStatePatch(
                action: .soften,
                original: original
            )
        )
    }

    func testStoryOutputSafetyPolicyDropsPreRewriteStructuredState() {
        let original = StoryStatePatch(
            location: "unsafe location",
            mood: "unsafe mood"
        )

        XCTAssertNil(
            StoryOutputSafetyPolicy.persistableStructuredStatePatch(
                outputAction: .soften,
                stateAction: .allow,
                dedicatedPatch: nil,
                fallbackPatch: original
            )
        )
        XCTAssertNil(
            StoryOutputSafetyPolicy.persistableStructuredStatePatch(
                outputAction: .allow,
                stateAction: .soften,
                dedicatedPatch: nil,
                fallbackPatch: original
            )
        )
        XCTAssertEqual(
            StoryOutputSafetyPolicy.persistableStructuredStatePatch(
                outputAction: .allow,
                stateAction: .allow,
                dedicatedPatch: original,
                fallbackPatch: StoryStatePatch(location: "unselected fallback")
            ),
            original
        )
        XCTAssertEqual(
            StoryOutputSafetyPolicy.persistableStructuredStatePatch(
                outputAction: .warn,
                stateAction: .warn,
                dedicatedPatch: nil,
                fallbackPatch: original
            ),
            original
        )
    }

    func testPersonaServicePersistsOnlyCompletedReply() async throws {
        let (_, store, thread) = try makePersonaServiceTestContext()
        let runtime = PersonaTestRuntime(reply: "completed reply", preview: "partial preview")
        let service = PersonaChatService(
            runtime: runtime,
            store: store,
            safetyPipeline: SafetyPipeline(
                outputChecker: PersonaTestOutputSafetyChecker(decision: .allow)
            ),
            watchdogNanoseconds: 1_000_000_000
        )

        XCTAssertTrue(service.send("hello", to: thread))
        await waitForPersonaService(service) { runtime.generatedRequestCount > 0 && $0 == .idle }

        XCTAssertEqual(
            store.thread(id: thread.id)?.messages.map(\.text),
            ["hello", "completed reply"]
        )
        XCTAssertFalse(store.thread(id: thread.id)?.messages.contains { $0.text == "partial preview" } == true)
    }

    func testPersonaServiceCancellationDropsUnscreenedPreviewAndKeepsUserTurn() async throws {
        let (_, store, thread) = try makePersonaServiceTestContext()
        let runtime = PersonaTestRuntime(
            reply: "late reply",
            preview: "unscreened partial",
            delayNanoseconds: 1_000_000_000
        )
        let service = PersonaChatService(
            runtime: runtime,
            store: store,
            watchdogNanoseconds: 2_000_000_000
        )

        XCTAssertTrue(service.send("stop this", to: thread))
        await waitForPersonaService(service) { _ in runtime.generatedRequestCount > 0 }
        service.cancel()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(store.thread(id: thread.id)?.messages.map(\.text), ["stop this"])
        XCTAssertEqual(service.phase, .idle)
        XCTAssertGreaterThan(runtime.cancelledGenerationCount, 0)
    }

    func testPersonaServiceFailureLeavesRetryableUserTurn() async throws {
        let (_, store, thread) = try makePersonaServiceTestContext()
        let runtime = PersonaTestRuntime(reply: nil)
        let service = PersonaChatService(
            runtime: runtime,
            store: store,
            watchdogNanoseconds: 1_000_000_000
        )

        XCTAssertTrue(service.send("try again", to: thread))
        await waitForPersonaService(service) {
            if case .error = $0 { return true }
            return false
        }
        XCTAssertEqual(store.thread(id: thread.id)?.messages.map(\.text), ["try again"])

        runtime.reply = "retried reply"
        service.retryLastMessage()
        await waitForPersonaService(service) { runtime.generatedRequestCount > 1 && $0 == .idle }
        XCTAssertEqual(
            store.thread(id: thread.id)?.messages.map(\.text),
            ["try again", "retried reply"]
        )
    }

    func testPersonaServiceWatchdogDropsUnfinishedGeneration() async throws {
        let (_, store, thread) = try makePersonaServiceTestContext()
        let runtime = PersonaTestRuntime(
            reply: "too late",
            preview: "watchdog preview",
            delayNanoseconds: 1_000_000_000
        )
        let service = PersonaChatService(
            runtime: runtime,
            store: store,
            watchdogNanoseconds: 20_000_000
        )

        XCTAssertTrue(service.send("wait", to: thread))
        await waitForPersonaService(service) {
            if case .error = $0 { return true }
            return false
        }

        XCTAssertEqual(store.thread(id: thread.id)?.messages.map(\.text), ["wait"])
        XCTAssertGreaterThan(runtime.cancelledGenerationCount, 0)
    }

    func testPersonaServiceSafetyFailureNeverPersistsOriginalReply() async throws {
        let (_, requireEditStore, requireEditThread) = try makePersonaServiceTestContext()
        let requireEditService = PersonaChatService(
            runtime: PersonaTestRuntime(reply: "unsafe original"),
            store: requireEditStore,
            safetyPipeline: SafetyPipeline(
                outputChecker: PersonaTestOutputSafetyChecker(
                    decision: SafetyDecision(action: .requireEdit)
                )
            ),
            watchdogNanoseconds: 1_000_000_000
        )

        XCTAssertTrue(requireEditService.send("unsafe", to: requireEditThread))
        await waitForPersonaService(requireEditService) {
            if case .error = $0 { return true }
            return false
        }
        XCTAssertEqual(requireEditStore.thread(id: requireEditThread.id)?.messages.map(\.text), ["unsafe"])

        let (_, softenStore, softenThread) = try makePersonaServiceTestContext()
        let softenService = PersonaChatService(
            runtime: PersonaTestRuntime(reply: "unsafe original"),
            store: softenStore,
            safetyPipeline: SafetyPipeline(
                outputChecker: PersonaTestOutputSafetyChecker(
                    decision: SafetyDecision(
                        action: .soften,
                        rewrittenText: "<think>hidden</think> safe rewrite"
                    )
                )
            ),
            watchdogNanoseconds: 1_000_000_000
        )

        XCTAssertTrue(softenService.send("rewrite", to: softenThread))
        await waitForPersonaService(softenService) { $0 == .idle }
        XCTAssertEqual(
            softenStore.thread(id: softenThread.id)?.messages.map(\.text),
            ["rewrite", "safe rewrite"]
        )
    }

    func testPersonaServiceCharacterPipelinePersistsOnlySafeOutput() async throws {
        let character = CharacterProfile(
            name: "Library Character",
            displayName: "Library Character",
            category: .chatBuddy,
            relationshipGenre: .none
        )

        let (allowDefaults, allowStore, allowThread) = try makePersonaServiceTestContext(character: character)
        let allowRuntime = PersonaTestRuntime(reply: "character reply")
        let allowRepository = PersonaTestCharacterRepository(character: character)
        let allowService = makeCharacterPersonaService(
            character: character,
            store: allowStore,
            runtime: allowRuntime,
            outputDecision: SafetyDecision(action: .allow),
            characterRepository: allowRepository
        )
        XCTAssertTrue(allowService.send("hello", to: allowThread))
        await waitForPersonaService(allowService) { $0 == .idle }
        XCTAssertEqual(allowRepository.fetchCount, 1)
        XCTAssertEqual(allowRuntime.generatedRequestCount, 1)
        XCTAssertTrue(allowRuntime.lastOverrideSystemPrompt?.contains("Library Character") == true)
        XCTAssertEqual(
            allowStore.thread(id: allowThread.id)?.messages.map(\.text),
            ["hello", "character reply"]
        )
        XCTAssertFalse(
            allowStore.thread(id: allowThread.id)?.messages.contains {
                $0.role == .assistant && PersonaMessage.isPendingAssistantText($0.text)
            } == true
        )
        let reloadedAllowStore = PersonaChatStore(defaults: allowDefaults)
        XCTAssertEqual(
            reloadedAllowStore.thread(id: allowThread.id)?.messages.map(\.text),
            ["hello", "character reply"]
        )

        let (_, requireEditStore, requireEditThread) = try makePersonaServiceTestContext(character: character)
        let requireEditService = makeCharacterPersonaService(
            character: character,
            store: requireEditStore,
            runtime: PersonaTestRuntime(reply: "unsafe character reply"),
            outputDecision: SafetyDecision(action: .requireEdit)
        )
        XCTAssertTrue(requireEditService.send("unsafe", to: requireEditThread))
        await waitForPersonaService(requireEditService) {
            if case .error = $0 { return true }
            return false
        }
        XCTAssertEqual(
            requireEditStore.thread(id: requireEditThread.id)?.messages.map(\.text),
            ["unsafe"]
        )

        let (_, softenStore, softenThread) = try makePersonaServiceTestContext(character: character)
        let softenService = makeCharacterPersonaService(
            character: character,
            store: softenStore,
            runtime: PersonaTestRuntime(reply: "unsafe character reply"),
            outputDecision: SafetyDecision(
                action: .soften,
                rewrittenText: "<think>hidden</think>  softened character reply  "
            )
        )
        XCTAssertTrue(softenService.send("rewrite", to: softenThread))
        await waitForPersonaService(softenService) { $0 == .idle }
        XCTAssertEqual(
            softenStore.thread(id: softenThread.id)?.messages.map(\.text),
            ["rewrite", "softened character reply"]
        )
    }

    func testPersonaServiceCharacterPipelineWatchdogDropsLateReplyAndAllowsRetry() async throws {
        let character = CharacterProfile(
            name: "Watchdog Character",
            displayName: "Watchdog Character",
            category: .chatBuddy,
            relationshipGenre: .none
        )
        let (_, store, thread) = try makePersonaServiceTestContext(character: character)
        let runtime = PersonaTestRuntime(
            reply: "late character reply",
            delayNanoseconds: 1_000_000_000
        )
        let service = makeCharacterPersonaService(
            character: character,
            store: store,
            runtime: runtime,
            outputDecision: SafetyDecision(action: .allow),
            watchdogNanoseconds: 20_000_000
        )

        XCTAssertTrue(service.send("wait", to: thread))
        await waitForPersonaService(service) {
            if case .error = $0 { return true }
            return false
        }
        XCTAssertEqual(store.thread(id: thread.id)?.messages.map(\.text), ["wait"])
        XCTAssertGreaterThan(runtime.cancelledGenerationCount, 0)

        runtime.delayNanoseconds = 0
        runtime.reply = "retried character reply"
        service.retryLastMessage()
        await waitForPersonaService(service) { $0 == .idle }
        XCTAssertEqual(
            store.thread(id: thread.id)?.messages.map(\.text),
            ["wait", "retried character reply"]
        )
    }

    func testPersonaServiceRejectsSendWhileRecoveryIsRequired() throws {
        let suiteName = "KizunaPersonaServiceTests.Recovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data([0x00, 0xFF, 0x7B]), forKey: "persona.threads.v1")
        let store = PersonaChatStore(defaults: defaults)
        let profile = PersonaProfile(
            name: "Recovery",
            personality: "Calm",
            tone: .calm,
            relation: .friend
        )
        let thread = PersonaThread(personaSnapshot: profile, title: "Recovery")
        let runtime = PersonaTestRuntime(reply: "must not run")
        let service = PersonaChatService(runtime: runtime, store: store)

        XCTAssertTrue(store.isPersistenceRecoveryRequired)
        XCTAssertFalse(service.send("blocked", to: thread))
        XCTAssertEqual(runtime.generatedRequestCount, 0)
        XCTAssertTrue(store.threads.isEmpty)
        XCTAssertEqual(defaults.data(forKey: "persona.threads.v1"), Data([0x00, 0xFF, 0x7B]))
    }

    private func makePersonaServiceTestContext(
        character: CharacterProfile? = nil
    ) throws -> (UserDefaults, PersonaChatStore, PersonaThread) {
        let suiteName = "KizunaPersonaServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = PersonaChatStore(defaults: defaults)
        let profile = PersonaProfile(
            name: "Test",
            personality: "Calm",
            tone: .calm,
            relation: .friend
        )
        let thread = try XCTUnwrap(
            store.createThread(with: profile, characterID: character?.id)
        )
        return (defaults, store, thread)
    }

    private func makeCharacterPersonaService(
        character: CharacterProfile,
        store: PersonaChatStore,
        runtime: PersonaReplyGenerating,
        outputDecision: SafetyDecision,
        characterRepository: CharacterRepository? = nil,
        watchdogNanoseconds: UInt64 = 1_000_000_000
    ) -> PersonaChatService {
        PersonaChatService(
            runtime: runtime,
            store: store,
            safetyPipeline: SafetyPipeline(
                outputChecker: PersonaTestOutputSafetyChecker(decision: outputDecision)
            ),
            characterRepo: characterRepository ?? PersonaTestCharacterRepository(character: character),
            memoryRepo: PersonaTestMemoryRepository(),
            smallClassifier: PersonaTestSmallModelClassifier(),
            memorySelector: PersonaTestMemorySelector(),
            memorySummarizer: PersonaTestMemorySummarizer(),
            watchdogNanoseconds: watchdogNanoseconds
        )
    }

    private func waitForPersonaService(
        _ service: PersonaChatService,
        condition: (PersonaChatService.Phase) -> Bool
    ) async {
        for _ in 0..<100 {
            if condition(service.phase) { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Persona service did not reach the expected state: \(service.phase)")
    }
}

private final class PersonaTestCharacterRepository: CharacterRepository, @unchecked Sendable {
    private let lock = NSLock()
    let character: CharacterProfile
    private var fetchCountStorage = 0

    var fetchCount: Int {
        withLock { fetchCountStorage }
    }

    init(character: CharacterProfile) {
        self.character = character
    }

    func fetchCharacters() async throws -> [CharacterProfile] {
        withLock { fetchCountStorage += 1 }
        return [character]
    }

    func saveCharacter(_ character: CharacterProfile) async throws {}

    func deleteCharacter(id: UUID) async throws -> CharacterDeletionResult {
        .notFound
    }

    func fetchLorebook(characterId: UUID) async throws -> CharacterLorebook? {
        nil
    }

    func saveLorebook(_ lorebook: CharacterLorebook) async throws {}

    private func withLock<Result>(_ body: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class PersonaTestMemoryRepository: MemoryRepository, @unchecked Sendable {
    func fetchMemories(characterId: UUID) async throws -> [CharacterMemory] {
        []
    }

    func saveMemory(_ memory: CharacterMemory) async throws {}

    func deleteMemory(id: UUID) async throws {}

    func deleteAllMemories(characterId: UUID) async throws {}

    func markUsed(ids: [UUID]) async throws {}
}

private final class PersonaTestSmallModelClassifier: SmallModelClassifying, @unchecked Sendable {
    func classify(text: String, labels: [String]) async -> SmallModelClassification {
        SmallModelClassification(label: "casual_chat", confidence: 1.0)
    }
}

private final class PersonaTestMemorySelector: MemorySelecting, @unchecked Sendable {
    func select(query: String, candidates: [CharacterMemory], topK: Int) async -> [CharacterMemory] {
        Array(candidates.prefix(topK))
    }
}

private final class PersonaTestMemorySummarizer: MemorySummarizing, @unchecked Sendable {
    func extract(
        userText: String,
        assistantText: String,
        character: CharacterProfile
    ) async -> [CharacterMemory] {
        []
    }
}

private final class PersonaTestRuntime: PersonaReplyGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var storedReply: String?
    private var storedDelayNanoseconds: UInt64
    private var storedOverrideSystemPrompt: String?
    let preview: String?

    var delayNanoseconds: UInt64 {
        get { withLock { storedDelayNanoseconds } }
        set { withLock { storedDelayNanoseconds = newValue } }
    }

    var lastOverrideSystemPrompt: String? {
        withLock { storedOverrideSystemPrompt }
    }

    var reply: String? {
        get { withLock { storedReply } }
        set { withLock { storedReply = newValue } }
    }

    var generatedRequestCount: Int {
        withLock { generatedRequestCountStorage }
    }

    var cancelledGenerationCount: Int {
        withLock { cancelledGenerationCountStorage }
    }

    private var generatedRequestCountStorage = 0
    private var cancelledGenerationCountStorage = 0

    init(reply: String?, preview: String? = nil, delayNanoseconds: UInt64 = 0) {
        self.storedReply = reply
        self.storedDelayNanoseconds = delayNanoseconds
        self.preview = preview
        self.storedOverrideSystemPrompt = nil
    }

    deinit {}

    func generatePersonaReply(
        prompt: String,
        contextPrompt: String?,
        coachMode: AICoachService.CoachMode,
        reasoningMode: ReasoningMode,
        childAge: Int,
        pageInfo: AICoachService.PageInfo?,
        safetySnapshot: AICoachService.SafetySnapshot?,
        advancedSettings: GemmaAdvancedSettings,
        overrideSystemPrompt: String?,
        generationID: UUID?,
        onUpdate: (@MainActor @Sendable (LocalAssistantStructuredTurnUpdate) -> Void)?
    ) async -> String? {
        let (currentReply, currentDelayNanoseconds) = withLock {
            generatedRequestCountStorage += 1
            storedOverrideSystemPrompt = overrideSystemPrompt
            return (storedReply, storedDelayNanoseconds)
        }
        if let preview {
            await onUpdate?(.visiblePreview(preview))
        }
        if currentDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: currentDelayNanoseconds)
        }
        return currentReply
    }

    func cancelActiveGeneration(generationID: UUID?) {
        withLock {
            cancelledGenerationCountStorage += 1
        }
    }

    private func withLock<Result>(_ body: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class PersonaTestOutputSafetyChecker: OutputSafetyChecking, @unchecked Sendable {
    let decision: SafetyDecision

    init(decision: SafetyDecision) {
        self.decision = decision
    }

    func evaluate(_ text: String, character: CharacterProfile) async -> SafetyDecision {
        decision
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
    private let storySessions: [StorySession]
    private var storyMemories: [StoryMemory]
    private var characterSaveCount = 0
    private var storySaveCount = 0

    init(
        shouldFailSaves: Bool = false,
        shouldThrowStoryRecordDeleted: Bool = false,
        storySessions: [StorySession] = [],
        storyMemories: [StoryMemory] = []
    ) {
        self.shouldFailSaves = shouldFailSaves
        self.shouldThrowStoryRecordDeleted = shouldThrowStoryRecordDeleted
        self.storySessions = storySessions
        self.storyMemories = storyMemories
    }

    func fetchMemories(characterId: UUID) async throws -> [CharacterMemory] { [] }

    func saveMemory(_ memory: CharacterMemory) async throws {
        if shouldFailSaves { throw TestError.saveFailed }
        characterSaveCount += 1
    }

    func deleteMemory(id: UUID) async throws {}
    func deleteAllMemories(characterId: UUID) async throws {}
    func markUsed(ids: [UUID]) async throws {}

    func fetchMemories(storyWorldId: UUID) async throws -> [StoryMemory] {
        storyMemories.filter { $0.storyWorldId == storyWorldId }
    }

    func fetchMemories(storyWorldId: UUID, storySessionId: UUID) async throws -> [StoryMemory] {
        StoryMemory.scoped(
            to: storySessionId,
            from: storyMemories.filter { $0.storyWorldId == storyWorldId }
        )
    }

    func assignLegacyMemoriesIfSingleSession(storyWorldId: UUID) async throws {
        let sessions = storySessions.filter { $0.storyWorldId == storyWorldId }
        guard sessions.count == 1, let sessionID = sessions.first?.id else { return }
        for index in storyMemories.indices {
            guard storyMemories[index].storyWorldId == storyWorldId,
                  storyMemories[index].storySessionId == nil else { continue }
            storyMemories[index].storySessionId = sessionID
        }
    }

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
        attempt: Int,
        ownerID: UUID
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

    func recoverInterruptedTurns(
        storyWorldId: UUID,
        activeOwnerIDs: Set<UUID>
    ) async throws {}
    func discardInterruptedTurn(
        sessionID: UUID,
        turnID: UUID,
        attempt: Int,
        expectedRevision: UInt64
    ) async throws -> StorySession {
        guard let session = sessions.first(where: { $0.id == sessionID }) else {
            throw StoryTurnPersistenceError.sessionNotFound
        }
        return session
    }
    func undoCommittedTurn(
        sessionID: UUID,
        turnID: UUID,
        attempt: Int,
        expectedRevision: UInt64
    ) async throws -> StorySession {
        guard let session = sessions.first(where: { $0.id == sessionID }) else {
            throw StoryTurnPersistenceError.sessionNotFound
        }
        return session
    }
    func deleteSession(id: UUID) async throws {}
}
