import XCTest

final class KizunaNavigationSmokeTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Keep the PR1 smoke test aligned with the current navigation. PR2
        // will update these labels when the standard TabView is introduced.
        app.launchArguments = [
            "-AppleLanguages", "(ja)",
            "-AppleLocale", "ja_JP",
            "-kizuna.launch.completed", "YES"
        ]
        app.launch()
    }

    func testPrimarySectionsAreReachable() throws {
        XCTAssertTrue(app.buttons["ストーリー"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["あなたの物語"].exists)
        XCTAssertTrue(app.buttons["マイページ"].exists)

        app.buttons["あなたの物語"].tap()
        XCTAssertTrue(app.buttons["あなたの物語"].exists)

        app.buttons["ストーリー"].tap()
        XCTAssertTrue(app.buttons["ストーリー"].exists)

        app.buttons["マイページ"].tap()
        XCTAssertTrue(app.buttons["マイページ"].exists)
    }
}
