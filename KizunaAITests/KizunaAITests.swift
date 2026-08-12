import XCTest
@testable import KizunaAI

final class KizunaAITests: XCTestCase {
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

    func testStorySessionDecodesWithoutNewEventFields() throws {
        let original = StorySession(
            storyWorldId: UUID(),
            messages: [StoryMessage(author: .narrator, text: "始まり")]
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any]
        )
        object.removeValue(forKey: "spontaneousEvents")
        object.removeValue(forKey: "nextSpontaneousEventUserTurn")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(StorySession.self, from: legacyData)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertNil(decoded.spontaneousEvents)
        XCTAssertNil(decoded.nextSpontaneousEventUserTurn)
    }

    func testStoryEventLifecycleStartsContinuesAndResolvesAtLimit() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let policy = StoryEventPolicy(
            initialDelayUserTurns: 2,
            retryDelayUserTurns: 1,
            cooldownUserTurns: 2,
            maxAIResponseTurns: 3,
            historyLimit: 8
        )
        var session = StorySession(
            storyWorldId: UUID(),
            messages: [
                StoryMessage(author: .user, text: "一"),
                StoryMessage(author: .cast(characterId: UUID(), displayName: "相手"), text: "返事")
            ],
            nextSpontaneousEventUserTurn: 2
        )
        let startMessageID = UUID()
        session.messages.append(StoryMessage(id: startMessageID, author: .user, text: "二"))
        let generationID = UUID()

        let started = policy.apply(
            update: StoryEventUpdate(action: .start, summary: "封じた手紙が見つかる"),
            to: &session,
            userMessageID: startMessageID,
            generationID: generationID,
            userInput: "二",
            now: now
        )
        let eventID = try XCTUnwrap(session.activeSpontaneousEvent?.id)
        XCTAssertEqual(started, StoryEventTransition(action: .start, eventID: eventID))
        XCTAssertEqual(session.activeSpontaneousEvent?.aiResponseTurnCount, 1)

        session.messages.append(StoryMessage(author: .user, text: "三"))
        let continued = policy.apply(
            update: StoryEventUpdate(action: .continueEvent),
            to: &session,
            userMessageID: session.messages.last!.id,
            generationID: UUID(),
            userInput: "三",
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(continued, StoryEventTransition(action: .continueEvent, eventID: eventID))
        XCTAssertEqual(session.activeSpontaneousEvent?.aiResponseTurnCount, 2)

        session.messages.append(StoryMessage(author: .user, text: "四"))
        let resolved = policy.apply(
            update: StoryEventUpdate(action: .continueEvent),
            to: &session,
            userMessageID: session.messages.last!.id,
            generationID: UUID(),
            userInput: "四",
            now: now.addingTimeInterval(2)
        )
        XCTAssertEqual(resolved, StoryEventTransition(action: .resolve, eventID: eventID))
        XCTAssertEqual(session.spontaneousEvents?.last?.status, .resolved)
        XCTAssertEqual(session.nextSpontaneousEventUserTurn, 6)
    }

    func testStoryEventIsAbandonedWhenTheNextTurnDoesNotReferenceIt() throws {
        let policy = StoryEventPolicy(
            initialDelayUserTurns: 1,
            retryDelayUserTurns: 1,
            cooldownUserTurns: 2,
            maxAIResponseTurns: 3,
            historyLimit: 8
        )
        var session = StorySession(
            storyWorldId: UUID(),
            messages: [StoryMessage(author: .user, text: "開始")],
            nextSpontaneousEventUserTurn: 1
        )
        let eventMessageID = session.messages[0].id
        _ = policy.apply(
            update: StoryEventUpdate(action: .start, summary: "窓の外の灯りが消える"),
            to: &session,
            userMessageID: eventMessageID,
            generationID: UUID(),
            userInput: "開始"
        )

        session.messages.append(StoryMessage(author: .user, text: "別の話をしよう"))
        let transition = policy.apply(
            update: nil,
            to: &session,
            userMessageID: session.messages.last!.id,
            generationID: UUID(),
            userInput: "別の話をしよう"
        )
        XCTAssertEqual(transition?.action, .abandon)
        XCTAssertEqual(session.spontaneousEvents?.last?.status, .abandoned)
        XCTAssertNil(session.activeSpontaneousEvent)
    }

    func testMalformedEventUpdateDoesNotDiscardOtherStateFields() throws {
        let json = Data(
            #"{"location":"港","eventUpdate":{"action":"unknown","summary":123}}"#.utf8
        )
        let patch = try JSONDecoder().decode(StoryStatePatch.self, from: json)

        XCTAssertEqual(patch.location, "港")
        XCTAssertNotNil(patch.eventUpdate)
        XCTAssertNil(patch.eventUpdate?.action)
        XCTAssertNil(patch.eventUpdate?.summary)
    }
}
