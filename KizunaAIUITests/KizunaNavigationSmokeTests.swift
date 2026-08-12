import XCTest

final class KizunaNavigationSmokeTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(ja)",
            "-AppleLocale", "ja_JP",
            "-kizuna.launch.completed", "YES"
        ]
        app.launch()
    }

    func testPrimarySectionsAreReachable() throws {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))

        let conversationTab = tabBar.buttons["会話"]
        let storyTab = tabBar.buttons["ストーリー"]
        let myPageTab = tabBar.buttons["マイページ"]

        XCTAssertTrue(conversationTab.exists)
        XCTAssertTrue(storyTab.exists)
        XCTAssertTrue(myPageTab.exists)

        conversationTab.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["workspace.conversation.heading"]
                .waitForExistence(timeout: 5)
        )

        storyTab.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["workspace.story.heading"]
                .waitForExistence(timeout: 10)
        )

        myPageTab.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["workspace.myPage.heading"]
                .waitForExistence(timeout: 10)
        )
    }
}
