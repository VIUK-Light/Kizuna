import Foundation
import XCTest
@testable import KizunaAI

@MainActor
final class KizunaRouteAndAppearanceTests: XCTestCase {
    func testCharacterProfileConversionPreservesAppearanceIdentity() {
        let characterID = UUID()
        let imageData = Data([0x01, 0x02, 0x03])
        let character = CharacterProfile(
            id: characterID,
            name: "Aoi",
            displayName: "アオイ",
            avatarImageData: imageData,
            imageKey: "PersonaAoiAvatar",
            category: .originalFreeform,
            relationshipGenre: .none,
            personality: "落ち着いている"
        )

        let profile = PersonaProfile(character: character)

        XCTAssertEqual(profile.id, characterID)
        XCTAssertEqual(profile.name, character.visibleName)
        XCTAssertEqual(profile.avatarStyleID, character.imageKey)
        XCTAssertEqual(profile.avatarImageData, imageData)
    }

    func testAppearanceRefreshUpdatesEveryThreadLinkedToCharacter() throws {
        let suiteName = "KizunaRouteAndAppearanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let characterID = UUID()
        let oldProfile = PersonaProfile(
            name: "アオイ",
            personality: "old",
            tone: .calm,
            relation: .friend,
            avatarStyleID: "old-style",
            avatarImageData: Data([0x10])
        )
        let first = PersonaThread(
            personaSnapshot: oldProfile,
            characterID: characterID,
            title: "first",
            messages: [PersonaMessage(role: .user, text: "hello")]
        )
        let second = PersonaThread(
            personaSnapshot: oldProfile,
            characterID: characterID,
            title: "second",
            messages: [PersonaMessage(role: .user, text: "hello again")]
        )
        defaults.set(try JSONEncoder().encode([first, second]), forKey: "persona.threads.v1")

        let store = PersonaChatStore(defaults: defaults)
        let newImage = Data([0x20, 0x21])
        let didChange = store.refreshCharacterAppearance(
            for: characterID,
            avatarStyleID: "PersonaAoiAvatar",
            avatarImageData: newImage
        )

        XCTAssertTrue(didChange)
        XCTAssertEqual(store.threads.count, 2)
        XCTAssertTrue(store.threads.allSatisfy {
            $0.personaSnapshot.avatarStyleID == "PersonaAoiAvatar"
                && $0.personaSnapshot.avatarImageData == newImage
        })
    }

    func testPersonaAndStoryRoutesHaveDistinctStableIDs() {
        let threadID = UUID()
        let worldID = UUID()
        let sessionID = UUID()
        let personaRoute = KizunaConversationRoute.persona(threadID: threadID)
        let storyRoute = KizunaConversationRoute.story(worldID: worldID, sessionID: sessionID)

        XCTAssertNotEqual(personaRoute.id, storyRoute.id)
        XCTAssertEqual(personaRoute.kind, .persona)
        XCTAssertEqual(storyRoute.kind, .story)
    }
}
