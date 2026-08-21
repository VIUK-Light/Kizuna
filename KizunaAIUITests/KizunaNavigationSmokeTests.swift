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
        let continuationsTab = tabBar.buttons["会話"]
        let myPageTab = tabBar.buttons["My"]

        XCTAssertTrue(homeTab.exists)
        XCTAssertTrue(continuationsTab.exists)
        XCTAssertTrue(myPageTab.exists)

        homeTab.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["workspace.home.heading"]
                .waitForExistence(timeout: 5)
        )
        // CI data may contain neither category, one category, or both. The
        // home contract is that at least one catalog row or empty-state CTA
        // is reachable; it does not require Persona and Story fixtures to be
        // seeded together.
        let homeDestination = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "home."))
            .firstMatch
        XCTAssertTrue(homeDestination.waitForExistence(timeout: 10))

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
