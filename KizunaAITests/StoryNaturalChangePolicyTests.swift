import XCTest
@testable import KizunaAI

final class StoryNaturalChangePolicyTests: XCTestCase {
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
