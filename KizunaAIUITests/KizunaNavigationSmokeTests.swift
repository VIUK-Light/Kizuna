import XCTest

final class KizunaNavigationSmokeTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(ja)",
            "-AppleLocale", "ja_JP",
            "-kizuna.language", "ja",
            "-kizuna.launch.completed", "YES"
        ]
        app.launch()
    }

    func testPrimarySectionsAreReachable() throws {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))

        let homeTab = tabBar.buttons["ホーム"]
        let continuationsTab = tabBar.buttons["続きから"]
        let myPageTab = tabBar.buttons["My"]

        XCTAssertTrue(homeTab.exists)
        XCTAssertTrue(continuationsTab.exists)
        XCTAssertTrue(myPageTab.exists)

        homeTab.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["workspace.home.heading"]
                .waitForExistence(timeout: 5)
        )
        let personaEntry = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.persona."))
            .firstMatch
        let storyEntry = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.story."))
            .firstMatch
        let addCharacter = app.buttons["home.empty.addCharacter"]
        let addStory = app.buttons["home.empty.addStory"]
        let hasPersonaEntry = personaEntry.waitForExistence(timeout: 5)
            || addCharacter.waitForExistence(timeout: 5)
        let hasStoryEntry = storyEntry.waitForExistence(timeout: 5)
            || addStory.waitForExistence(timeout: 5)
        XCTAssertTrue(hasPersonaEntry)
        XCTAssertTrue(hasStoryEntry)

        continuationsTab.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["workspace.continuations"]
                .waitForExistence(timeout: 10)
        )

        myPageTab.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["workspace.myPage.heading"]
                .waitForExistence(timeout: 10)
        )
    }

    func testMyPageDataManagementIsReachable() throws {
        let myPageTab = app.tabBars.buttons["My"]
        XCTAssertTrue(myPageTab.waitForExistence(timeout: 10))
        myPageTab.tap()

        let dataManagementButton = app.buttons["myPage.dataManagement"]
        if !dataManagementButton.waitForExistence(timeout: 3) {
            app.swipeUp()
        }
        XCTAssertTrue(dataManagementButton.waitForExistence(timeout: 5))
        dataManagementButton.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["myPage.dataManagement.heading"]
                .waitForExistence(timeout: 5)
        )
    }
}
