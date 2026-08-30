import XCTest

final class OatmealUITests: XCTestCase {
    func testLaunchShowsHistoryAndPrimaryAction() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["meeting-history"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.buttons["start-meeting"].exists ||
            app.descendants(matching: .any)["model-setup"].exists
        )
    }
}
