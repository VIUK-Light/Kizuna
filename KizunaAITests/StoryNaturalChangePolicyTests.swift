import Foundation
import XCTest
@testable import KizunaAI

final class StoryNaturalChangePolicyTests: XCTestCase {
    func testStoryInitiativeFlagsAreIndependentAndDefaultOff() {
        let suiteName = "KizunaStoryInitiativeFlags.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(StoryInitiativeFlags.isEnabled(for: .b31, defaults: defaults))
        XCTAssertFalse(StoryInitiativeFlags.isEnabled(for: .e4b, defaults: defaults))

        XCTAssertTrue(
            StoryInitiativeFlags.isEnabled(
                for: .b31,
                defaults: defaults,
                arguments: ["KizunaAI", StoryInitiativeFlags.nagiLaunchArgument]
            )
        )
        XCTAssertFalse(
            StoryInitiativeFlags.isEnabled(
                for: .e4b,
                defaults: defaults,
                arguments: ["KizunaAI", StoryInitiativeFlags.nagiLaunchArgument]
            )
        )

        StoryInitiativeFlags.setEnabled(true, for: .b31, defaults: defaults)
        XCTAssertTrue(StoryInitiativeFlags.isEnabled(for: .b31, defaults: defaults))
        XCTAssertFalse(StoryInitiativeFlags.isEnabled(for: .e4b, defaults: defaults))

        StoryInitiativeFlags.setEnabled(true, for: .e4b, defaults: defaults)
        StoryInitiativeFlags.setEnabled(false, for: .b31, defaults: defaults)
        XCTAssertFalse(StoryInitiativeFlags.isEnabled(for: .b31, defaults: defaults))
        XCTAssertTrue(StoryInitiativeFlags.isEnabled(for: .e4b, defaults: defaults))
    }

    func testNAGISystemPromptDoesNotEmbedCurrentUserMessage() {
        let world = StoryWorld(id: UUID(), title: "Prompt test")
        let scene = StoryScene(storyWorldId: world.id)
        let session = StorySession(storyWorldId: world.id)
        let userToken = "UNIQUE_CURRENT_USER_INPUT_7F2C"

        let prompt = StoryPromptBuilder().build(
            world: world,
            scene: scene,
            activeCast: [],
            inactiveCast: [],
            characterIndex: [:],
            selectedMemories: [],
            session: session,
            recentMessages: [],
            userInput: userToken,
            generationModel: .b31,
            safetyDecision: nil,
            storyState: StoryState(),
            storyInitiativeEnabled: true
        )

        XCTAssertFalse(
            prompt.contains(userToken),
            "NAGI receives the current user message through the user-role request"
        )
    }

    func testNAGIAcceptanceSeedIsSerializedInGenerationConfig() throws {
        let request = StoryGemma31BGenerateContentRequest(
            systemPrompt: "story system",
            userPrompt: "story input",
            temperature: 0.72,
            maxOutputTokens: 128,
            thinkingLevel: "minimal",
            seed: 3
        )
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
                as? [String: Any]
        )
        let generationConfig = try XCTUnwrap(object["generationConfig"] as? [String: Any])

        XCTAssertEqual(generationConfig["seed"] as? Int, 3)
    }

    func testLocalPromptKeepsInitiativeContextWithinByteLimitAndOneStoryMemory() {
        let world = StoryWorld(
            id: UUID(),
            title: "Harbor",
            worldSetting: "A quiet harbor",
            storyGoal: "Find the lighthouse key"
        )
        let characterID = UUID()
        let character = CharacterProfile(
            id: characterID,
            name: "Nagi",
            displayName: "Nagi",
            category: .chatBuddy,
            relationshipGenre: .none,
            personality: "calm",
            speakingStyle: "brief",
            relationshipToUser: "trusted partner",
            scenario: "find the key before dusk"
        )
        let castMember = CastMember(
            storyWorldId: world.id,
            characterId: characterID,
            relationshipToUser: "watchful",
            isActiveInCurrentScene: true
        )
        let scene = StoryScene(
            storyWorldId: world.id,
            location: "harbor",
            timeOfDay: "dusk",
            mood: "quiet",
            sceneGoal: "Find the lighthouse key"
        )
        let state = StoryState(
            characterStates: [
                StoryCharacterState(
                    characterId: characterID,
                    characterName: "Nagi",
                    goal: "protect the key",
                    relationship: "trust"
                )
            ]
        )
        let session = StorySession(storyWorldId: world.id)
        let firstMemory = StoryMemory(
            storyWorldId: world.id,
            text: "first-memory",
            importance: 0.9,
            storySessionId: session.id
        )
        let secondMemory = StoryMemory(
            storyWorldId: world.id,
            text: "second-memory",
            importance: 0.8,
            storySessionId: session.id
        )

        let prompt = StoryPromptBuilder().buildLocalRuntimePrompt(
            world: world,
            scene: scene,
            activeCast: [castMember],
            characterIndex: [characterID: character],
            selectedMemories: [],
            selectedStoryMemories: [firstMemory, secondMemory],
            session: session,
            storyState: state,
            selectedLorebookEntries: [],
            userCharacterName: nil,
            storyInitiativeEnabled: true
        )

        XCTAssertLessThanOrEqual(prompt.lengthOfBytes(using: .utf8), 1_250)
        XCTAssertTrue(prompt.contains("find the key before dusk"))
        XCTAssertTrue(prompt.contains("protect the key"))
        XCTAssertTrue(prompt.contains("first-memory"))
        XCTAssertFalse(prompt.contains("second-memory"))
    }

    func testAcceptsOneEnvironmentChangeGroup() {
        let patch = StoryStatePatch(
            location: "駅前",
            timeOfDay: "夕方",
            mood: nil,
            weather: nil,
            relationshipStage: nil,
            characterUpdates: nil,
            inventoryChanges: nil,
            activeGoals: nil
        )

        let accepted = StoryNaturalChangePolicy.acceptedPatch(from: patch)

        XCTAssertEqual(accepted?.location, "駅前")
        XCTAssertEqual(accepted?.timeOfDay, "夕方")
    }

    func testRejectsStateChangeWithoutMatchingEvidenceWhenContextIsProvided() {
        let patch = StoryStatePatch(
            location: "駅前",
            timeOfDay: nil,
            mood: nil,
            weather: nil,
            relationshipStage: nil,
            characterUpdates: nil,
            inventoryChanges: nil,
            activeGoals: nil,
            evidence: "関係のない引用"
        )

        XCTAssertNil(
            StoryNaturalChangePolicy.acceptedPatch(
                from: patch,
                evidenceText: ["ナギ: 港を見つめた", "今日は静かに話した"]
            )
        )
    }

    func testAcceptsStateChangeWhenEvidenceMatchesVisibleTurn() throws {
        let patch = StoryStatePatch(
            location: "駅前",
            timeOfDay: nil,
            mood: nil,
            weather: nil,
            relationshipStage: nil,
            characterUpdates: nil,
            inventoryChanges: nil,
            activeGoals: nil,
            evidence: "駅前へ歩き出した"
        )

        let accepted = try XCTUnwrap(
            StoryNaturalChangePolicy.acceptedPatch(
                from: patch,
                evidenceText: ["ナギ: 駅前へ歩き出した。"]
            )
        )
        XCTAssertEqual(accepted.location, "駅前")
        XCTAssertEqual(accepted.evidence, "駅前へ歩き出した")
    }

    func testAcceptsDecoratedEvidenceAfterVisibleTextSanitization() throws {
        let patch = StoryStatePatch(
            location: "駅前",
            timeOfDay: nil,
            mood: nil,
            weather: nil,
            relationshipStage: nil,
            characterUpdates: nil,
            inventoryChanges: nil,
            activeGoals: nil,
            evidence: "*駅前へ歩き出した*"
        )

        let accepted = try XCTUnwrap(
            StoryNaturalChangePolicy.acceptedPatch(
                from: patch,
                evidenceText: ["ナギ: 駅前へ歩き出した。"]
            )
        )
        XCTAssertEqual(accepted.location, "駅前")
    }

    func testRejectsEvidenceShorterThanFourCharactersWhenContextIsProvided() {
        let patch = StoryStatePatch(
            location: "駅前",
            timeOfDay: nil,
            mood: nil,
            weather: nil,
            relationshipStage: nil,
            characterUpdates: nil,
            inventoryChanges: nil,
            activeGoals: nil,
            evidence: "駅前"
        )

        XCTAssertNil(
            StoryNaturalChangePolicy.acceptedPatch(
                from: patch,
                evidenceText: ["ナギ: 駅前"]
            )
        )
    }

    func testRejectsMultipleObservableChangeGroups() {
        let patch = StoryStatePatch(
            location: "森",
            timeOfDay: nil,
            mood: nil,
            weather: nil,
            relationshipStage: "信頼",
            characterUpdates: nil,
            inventoryChanges: nil,
            activeGoals: nil
        )

        XCTAssertNil(StoryNaturalChangePolicy.acceptedPatch(from: patch))
    }

    func testRejectsMultipleCharacterAndInventoryChanges() {
        let characterPatch = StoryStatePatch(
            location: nil,
            timeOfDay: nil,
            mood: nil,
            weather: nil,
            relationshipStage: nil,
            characterUpdates: [
                StoryCharacterStatePatch(characterName: "ナギ", mood: "驚き"),
                StoryCharacterStatePatch(characterName: "イオリ", mood: "警戒")
            ],
            inventoryChanges: nil,
            activeGoals: nil
        )
        XCTAssertNil(StoryNaturalChangePolicy.acceptedPatch(from: characterPatch))

        let inventoryPatch = StoryStatePatch(
            location: nil,
            timeOfDay: nil,
            mood: nil,
            weather: nil,
            relationshipStage: nil,
            characterUpdates: nil,
            inventoryChanges: [
                StoryInventoryChange(action: .add, name: "鍵", detail: nil, owner: nil),
                StoryInventoryChange(action: .add, name: "手紙", detail: nil, owner: nil)
            ],
            activeGoals: nil
        )
        XCTAssertNil(StoryNaturalChangePolicy.acceptedPatch(from: inventoryPatch))
    }

    func testAllowsExplicitObjectiveResolution() {
        let patch = StoryStatePatch(
            location: nil,
            timeOfDay: nil,
            mood: nil,
            weather: nil,
            relationshipStage: nil,
            characterUpdates: nil,
            inventoryChanges: nil,
            activeGoals: []
        )

        XCTAssertEqual(
            StoryNaturalChangePolicy.acceptedPatch(from: patch)?.activeGoals,
            []
        )
    }

    func testResolvedObjectiveClearsSessionDisplayObjective() {
        let patch = StoryStatePatch(
            location: nil,
            timeOfDay: nil,
            mood: nil,
            weather: nil,
            relationshipStage: nil,
            characterUpdates: nil,
            inventoryChanges: nil,
            activeGoals: []
        )

        XCTAssertNil(
            StoryNaturalChangePolicy.objectiveAfterAcceptedPatch(
                currentObjective: "灯台へ向かう",
                patch: patch
            )
        )
    }

    func testDropsNoOpFieldsAgainstCurrentState() {
        let current = StoryState(location: "駅前", weather: "晴れ")
        let patch = StoryStatePatch(
            location: "駅前",
            timeOfDay: "夕方",
            mood: nil,
            weather: "晴れ",
            relationshipStage: nil,
            characterUpdates: nil,
            inventoryChanges: nil,
            activeGoals: nil
        )

        let accepted = StoryNaturalChangePolicy.acceptedPatch(
            from: patch,
            currentState: current
        )

        XCTAssertEqual(accepted?.location, nil)
        XCTAssertEqual(accepted?.weather, nil)
        XCTAssertEqual(accepted?.timeOfDay, "夕方")
    }

    func testPartialInventoryUpsertPreservesUnmentionedFields() throws {
        let current = StoryState(
            inventory: [
                StoryInventoryItem(name: "鍵", detail: "銀色", owner: "ナギ")
            ]
        )
        let patch = StoryStatePatch(
            location: nil,
            timeOfDay: nil,
            mood: nil,
            weather: nil,
            relationshipStage: nil,
            characterUpdates: nil,
            inventoryChanges: [
                StoryInventoryChange(
                    action: .add,
                    name: "鍵",
                    detail: "古びた銀色",
                    owner: nil
                )
            ],
            activeGoals: nil
        )

        let accepted = try XCTUnwrap(
            StoryNaturalChangePolicy.acceptedPatch(
                from: patch,
                currentState: current
            )
        )
        XCTAssertEqual(accepted.inventoryChanges?.first?.action, .update)

        let next = accepted.applying(to: current, characterIndex: [:])
        XCTAssertEqual(next.inventory.first?.detail, "古びた銀色")
        XCTAssertEqual(next.inventory.first?.owner, "ナギ")
    }

    func testIgnoresWhitespaceOnlyObjectivePayload() {
        let patch = StoryStatePatch(
            location: nil,
            timeOfDay: nil,
            mood: nil,
            weather: nil,
            relationshipStage: nil,
            characterUpdates: nil,
            inventoryChanges: nil,
            activeGoals: ["   "]
        )

        XCTAssertNil(StoryNaturalChangePolicy.acceptedPatch(from: patch))
    }
}
